-- Durable dispatch attempts and atomic ride-offer batch creation.

create table if not exists public.ride_dispatch_attempts (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null references public.rides(id) on delete cascade,
  search_radius_m integer not null check(search_radius_m between 100 and 100000),
  offered_driver_count integer not null default 0 check(offered_driver_count >= 0),
  result text not null check(result in ('offers_created','no_drivers','waiting_for_responses','ride_assigned','ride_closed')),
  attempted_at timestamptz not null default now()
);
create index if not exists ride_dispatch_attempts_ride_time_idx
  on public.ride_dispatch_attempts(ride_id,attempted_at desc);
alter table public.ride_dispatch_attempts enable row level security;
revoke all on public.ride_dispatch_attempts from anon,authenticated;

create or replace function public.find_nearby_drivers(
  p_pickup_ewkt text,
  p_pincode_id bigint,
  p_vehicle_category_id bigint,
  p_radius_m integer,
  p_limit integer default 25
)
returns table(driver_id uuid,distance_m numeric,geohash_7 text,location_recorded_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pickup extensions.geography;
  v_location_max_age integer;
  v_business_model text;
begin
  if p_radius_m is null or p_radius_m<100 or p_radius_m>100000 then
    raise exception 'Invalid search radius' using errcode='22023';
  end if;
  if p_vehicle_category_id is null or p_pincode_id is null then
    raise exception 'Pincode and vehicle category are required' using errcode='22023';
  end if;
  v_pickup := extensions.st_geogfromtext(p_pickup_ewkt);

  select c.business_model into v_business_model
  from public.service_area_pincodes p
  join public.service_areas a on a.id=p.service_area_id and a.is_active
  join lateral (
    select cc.business_model from public.service_area_commercial_configs cc
    where cc.pincode_id=p.id and cc.is_active and cc.valid_from<=now()
      and (cc.valid_until is null or cc.valid_until>now())
    order by cc.valid_from desc limit 1
  ) c on true
  where p.id=p_pincode_id and p.is_active;
  if v_business_model is null then
    raise exception 'Pincode is inactive or has no current commercial configuration' using errcode='P0001';
  end if;

  select coalesce(dc.location_max_age_seconds,45) into v_location_max_age
  from (select 1) seed
  left join public.service_area_dispatch_configs dc on dc.pincode_id=p_pincode_id;

  return query
  select dp.user_id,
    extensions.st_distance(dl.location,v_pickup)::numeric,
    dl.geohash_7,
    dl.recorded_at
  from public.driver_profiles dp
  join public.driver_locations dl on dl.driver_id=dp.user_id
  where dp.verification_status='approved'
    and dp.availability_status='online'
    and dp.vehicle_category_id=p_vehicle_category_id
    and dl.recorded_at>=now()-make_interval(secs=>v_location_max_age)
    and extensions.st_dwithin(dl.location,v_pickup,p_radius_m)
    and not exists (
      select 1 from public.rides r where r.driver_id=dp.user_id
        and r.status in ('accepted','driver_arriving','arrived','in_progress')
    )
    and not exists (
      select 1 from public.ride_offers o where o.driver_id=dp.user_id
        and o.status='pending' and o.expires_at>now()
    )
    and not exists (
      select 1 from public.ride_chain_offers co where co.driver_id=dp.user_id
        and co.status in ('offered','preaccepted') and co.expires_at>now()
    )
    and (
      v_business_model='commission'
      or exists (
        select 1 from public.driver_subscriptions ds
        where ds.driver_id=dp.user_id and ds.pincode_id=p_pincode_id
          and ds.status='active' and ds.period_start<=now() and ds.period_end>now()
      )
    )
  order by extensions.st_distance(dl.location,v_pickup)
  limit greatest(1,least(coalesce(p_limit,25),100));
end;
$$;
revoke all on function public.find_nearby_drivers(text,bigint,bigint,integer,integer) from public,anon,authenticated;
grant execute on function public.find_nearby_drivers(text,bigint,bigint,integer,integer) to service_role;

create or replace function public.get_ride_dispatch_context(p_ride_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.rides%rowtype;
  v_dispatch public.service_area_dispatch_configs%rowtype;
  v_pincode public.service_area_pincodes%rowtype;
begin
  select * into v_ride from public.rides where id=p_ride_id;
  if not found then raise exception 'Ride not found' using errcode='P0002'; end if;
  select * into v_pincode from public.service_area_pincodes where id=v_ride.pincode_id;
  select * into v_dispatch from public.service_area_dispatch_configs where pincode_id=v_ride.pincode_id;
  return jsonb_build_object(
    'ride_id',v_ride.id,
    'status',v_ride.status,
    'driver_id',v_ride.driver_id,
    'pincode_id',v_ride.pincode_id,
    'pincode',v_pincode.pincode,
    'vehicle_category_id',v_ride.vehicle_category_id,
    'pickup_ewkt',extensions.st_asewkt(v_ride.pickup_location::extensions.geometry),
    'dispatch',case when v_dispatch.id is null then jsonb_build_object(
      'initial_radius_m',2000,'max_radius_m',15000,'radius_step_m',2000,
      'offer_batch_size',5,'offer_ttl_seconds',15,'chain_pickup_distance_m',1500,
      'chain_offer_ttl_seconds',90
    ) else to_jsonb(v_dispatch) end
  );
end;
$$;

create or replace function public.create_ride_offer_batch(
  p_ride_id uuid,
  p_radius_m integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.rides%rowtype;
  v_context jsonb;
  v_batch_size integer;
  v_offer_ttl integer;
  v_location_max_age integer;
  v_candidate record;
  v_created jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_pending integer := 0;
begin
  select * into v_ride from public.rides where id=p_ride_id for update;
  if not found then raise exception 'Ride not found' using errcode='P0002'; end if;

  if v_ride.driver_id is not null then
    insert into public.ride_dispatch_attempts(ride_id,search_radius_m,offered_driver_count,result)
    values(p_ride_id,greatest(100,coalesce(p_radius_m,100)) ,0,'ride_assigned');
    return jsonb_build_object('status','ride_assigned','offers',v_created);
  end if;
  if v_ride.status not in ('requested','searching','offered') then
    insert into public.ride_dispatch_attempts(ride_id,search_radius_m,offered_driver_count,result)
    values(p_ride_id,greatest(100,coalesce(p_radius_m,100)),0,'ride_closed');
    return jsonb_build_object('status','ride_closed','offers',v_created);
  end if;

  select count(*) into v_pending from public.ride_offers
  where ride_id=p_ride_id and status='pending' and expires_at>now();
  if v_pending>0 then
    insert into public.ride_dispatch_attempts(ride_id,search_radius_m,offered_driver_count,result)
    values(p_ride_id,greatest(100,coalesce(p_radius_m,100)),0,'waiting_for_responses');
    return jsonb_build_object('status','waiting_for_responses','pending_count',v_pending,'offers',v_created);
  end if;

  select coalesce(dc.offer_batch_size,5),coalesce(dc.offer_ttl_seconds,15),
         coalesce(dc.location_max_age_seconds,45)
  into v_batch_size,v_offer_ttl,v_location_max_age
  from (select 1) seed
  left join public.service_area_dispatch_configs dc on dc.pincode_id=v_ride.pincode_id;

  v_context := public.get_ride_dispatch_context(p_ride_id);
  update public.rides set status='searching' where id=p_ride_id and status='requested';

  for v_candidate in
    select * from public.find_nearby_drivers(
      v_context->>'pickup_ewkt',
      v_ride.pincode_id,
      v_ride.vehicle_category_id,
      p_radius_m,
      v_batch_size
    )
  loop
    insert into public.ride_offers(ride_id,driver_id,status,offered_at,expires_at)
    values(p_ride_id,v_candidate.driver_id,'pending',now(),now()+make_interval(secs=>v_offer_ttl))
    on conflict(ride_id,driver_id) do nothing;
    if found then
      v_count:=v_count+1;
      v_created:=v_created || jsonb_build_array(jsonb_build_object(
        'driver_id',v_candidate.driver_id,
        'distance_m',v_candidate.distance_m,
        'geohash_7',v_candidate.geohash_7,
        'expires_in_seconds',v_offer_ttl
      ));
    end if;
  end loop;

  if v_count>0 then
    update public.rides set status='offered' where id=p_ride_id and driver_id is null;
    insert into public.ride_events(ride_id,event_type,previous_status,new_status,details)
    values(p_ride_id,'dispatch_offers_created','searching','offered',
      jsonb_build_object('radius_m',p_radius_m,'offer_count',v_count));
    insert into public.ride_dispatch_attempts(ride_id,search_radius_m,offered_driver_count,result)
    values(p_ride_id,p_radius_m,v_count,'offers_created');
  else
    insert into public.ride_dispatch_attempts(ride_id,search_radius_m,offered_driver_count,result)
    values(p_ride_id,p_radius_m,0,'no_drivers');
  end if;

  return jsonb_build_object('status',case when v_count>0 then 'offers_created' else 'no_drivers' end,'offers',v_created);
end;
$$;

create or replace function public.create_ride_chain_offer_batch(p_next_ride_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_next public.rides%rowtype;
  v_dispatch public.service_area_dispatch_configs%rowtype;
  v_candidate record;
  v_created jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_batch_size integer;
  v_ttl integer;
begin
  select * into v_next from public.rides where id=p_next_ride_id for update;
  if not found or v_next.driver_id is not null
     or v_next.status not in ('requested','searching','offered') then
    return jsonb_build_object('status','ride_unavailable','offers',v_created);
  end if;

  select * into v_dispatch from public.service_area_dispatch_configs where pincode_id=v_next.pincode_id;
  v_batch_size:=coalesce(v_dispatch.offer_batch_size,5);
  v_ttl:=coalesce(v_dispatch.chain_offer_ttl_seconds,90);

  for v_candidate in
    select * from public.find_ride_chain_candidates(p_next_ride_id)
    limit v_batch_size
  loop
    insert into public.ride_chain_offers(
      next_ride_id,current_ride_id,driver_id,status,
      estimated_remaining_distance_m,distance_from_current_destination_m,
      estimated_seconds_to_destination,offered_at,expires_at
    )
    values(
      p_next_ride_id,v_candidate.current_ride_id,v_candidate.driver_id,'offered',
      v_candidate.remaining_distance_m,
      v_candidate.distance_to_next_pickup_m,
      v_candidate.estimated_seconds_to_destination,
      now(),now()+make_interval(secs=>v_ttl)
    )
    on conflict(next_ride_id,driver_id) do nothing;
    if found then
      v_count:=v_count+1;
      v_created:=v_created || jsonb_build_array(jsonb_build_object(
        'driver_id',v_candidate.driver_id,
        'current_ride_id',v_candidate.current_ride_id,
        'distance_to_pickup_m',v_candidate.distance_to_next_pickup_m,
        'estimated_seconds_to_destination',v_candidate.estimated_seconds_to_destination,
        'expires_in_seconds',v_ttl
      ));
    end if;
  end loop;

  return jsonb_build_object('status',case when v_count>0 then 'offers_created' else 'no_candidates' end,'offers',v_created);
end;
$$;

revoke all on function public.get_ride_dispatch_context(uuid) from public,anon,authenticated;
revoke all on function public.create_ride_offer_batch(uuid,integer) from public,anon,authenticated;
revoke all on function public.create_ride_chain_offer_batch(uuid) from public,anon,authenticated;
grant execute on function public.get_ride_dispatch_context(uuid) to service_role;
grant execute on function public.create_ride_offer_batch(uuid,integer) to service_role;
grant execute on function public.create_ride_chain_offer_batch(uuid) to service_role;

comment on table public.ride_dispatch_attempts is 'Server-recorded offer batches and expanding-radius search attempts.';
comment on function public.create_ride_offer_batch(uuid,integer) is 'Creates an expiring offer batch atomically for eligible nearby drivers.';
comment on function public.create_ride_chain_offer_batch(uuid) is 'Creates provisional next-ride offers for eligible drivers nearing an active trip destination.';

