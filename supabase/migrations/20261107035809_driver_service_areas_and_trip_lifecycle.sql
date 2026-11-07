-- Driver service-area membership, secure trip-start OTP verification and driver lifecycle.

create table if not exists public.driver_service_pincodes (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references auth.users(id) on delete cascade,
  pincode_id bigint not null references public.service_area_pincodes(id) on delete restrict,
  status text not null default 'pending' check(status in ('pending','active','rejected','suspended')),
  is_primary boolean not null default false,
  requested_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  review_note text,
  unique(driver_id,pincode_id)
);
create index if not exists driver_service_pincodes_pincode_idx
  on public.driver_service_pincodes(pincode_id,status,driver_id);
create index if not exists driver_service_pincodes_driver_idx
  on public.driver_service_pincodes(driver_id,status);
alter table public.driver_service_pincodes enable row level security;
create policy driver_service_pincodes_read_own
  on public.driver_service_pincodes for select to authenticated
  using ((select auth.uid())=driver_id);
revoke all on public.driver_service_pincodes from anon,authenticated;
grant select on public.driver_service_pincodes to authenticated;

create table if not exists public.ride_otp_attempts (
  id bigint generated always as identity primary key,
  ride_id uuid not null references public.rides(id) on delete cascade,
  driver_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default now(),
  succeeded boolean not null
);
create index if not exists ride_otp_attempts_driver_time_idx
  on public.ride_otp_attempts(ride_id,driver_id,attempted_at desc);
alter table public.ride_otp_attempts enable row level security;
revoke all on public.ride_otp_attempts from anon,authenticated;

-- Require a driver to be approved for the requested pincode for every normal dispatch.
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
  join public.driver_service_pincodes dsp
    on dsp.driver_id=dp.user_id and dsp.pincode_id=p_pincode_id and dsp.status='active'
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
        and o.status in ('pending','accepted') and o.expires_at>now()
    )
    and not exists (
      select 1 from public.ride_offers used where used.ride_id = (
        select id from public.rides where id = (
          select r.id from public.rides r
          where r.id=used.ride_id limit 1
        )
      ) and used.driver_id=dp.user_id and used.status in ('rejected','expired','withdrawn')
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
    and not exists (
      select 1 from public.ride_offers existing
      where existing.driver_id=dp.user_id
        and existing.status in ('pending','accepted')
        and existing.expires_at>now()
    )
  order by extensions.st_distance(dl.location,v_pickup)
  limit greatest(1,least(coalesce(p_limit,25),100));
end;
$$;
revoke all on function public.find_nearby_drivers(text,bigint,bigint,integer,integer) from public,anon,authenticated;
grant execute on function public.find_nearby_drivers(text,bigint,bigint,integer,integer) to service_role;

-- Chain discovery also requires an active service-area association for the next pickup.
create or replace function public.find_ride_chain_candidates(p_next_ride_id uuid)
returns table(
  driver_id uuid,
  current_ride_id uuid,
  distance_to_next_pickup_m numeric,
  remaining_distance_m numeric,
  estimated_seconds_to_destination integer,
  expires_in_seconds integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_next public.rides%rowtype;
  v_max_pickup_distance integer;
  v_location_max_age integer;
  v_offer_ttl integer;
  v_business_model text;
begin
  select * into v_next from public.rides where id=p_next_ride_id for share;
  if not found or v_next.driver_id is not null
     or v_next.status not in ('requested','searching','offered') then
    raise exception 'Next ride is not available for chaining' using errcode='P0001';
  end if;

  select coalesce(dc.chain_pickup_distance_m,1500),
         coalesce(dc.location_max_age_seconds,45),
         coalesce(dc.chain_offer_ttl_seconds,90),
         cc.business_model
  into v_max_pickup_distance,v_location_max_age,v_offer_ttl,v_business_model
  from public.service_area_pincodes p
  join public.service_areas a on a.id=p.service_area_id and a.is_active
  join lateral (
    select c.business_model from public.service_area_commercial_configs c
    where c.pincode_id=p.id and c.is_active and c.valid_from<=now()
      and (c.valid_until is null or c.valid_until>now())
    order by c.valid_from desc limit 1
  ) cc on true
  left join public.service_area_dispatch_configs dc on dc.pincode_id=p.id
  where p.id=v_next.pincode_id and p.is_active;

  if v_business_model is null then
    raise exception 'Next ride pincode has no active commercial configuration' using errcode='P0001';
  end if;

  return query
  select dp.user_id,current_trip.id,
    extensions.st_distance(current_trip.destination_location,v_next.pickup_location)::numeric,
    extensions.st_distance(dl.location,current_trip.destination_location)::numeric,
    case when dl.speed_mps is not null and dl.speed_mps>0.5
      then ceil(extensions.st_distance(dl.location,current_trip.destination_location)/dl.speed_mps)::integer
      else null end,
    v_offer_ttl
  from public.rides current_trip
  join public.driver_profiles dp on dp.user_id=current_trip.driver_id
  join public.driver_locations dl on dl.driver_id=dp.user_id
  join public.driver_service_pincodes dsp
    on dsp.driver_id=dp.user_id and dsp.pincode_id=v_next.pincode_id and dsp.status='active'
  where current_trip.status='in_progress'
    and current_trip.driver_id is not null
    and current_trip.vehicle_category_id=v_next.vehicle_category_id
    and dp.verification_status='approved'
    and dp.availability_status='busy'
    and dl.recorded_at>=now()-make_interval(secs=>v_location_max_age)
    and extensions.st_dwithin(current_trip.destination_location,v_next.pickup_location,v_max_pickup_distance)
    and not exists (
      select 1 from public.ride_chain_offers existing
      where existing.next_ride_id=v_next.id and existing.driver_id=dp.user_id
        and existing.status in ('offered','preaccepted') and existing.expires_at>now()
    )
    and (
      v_business_model='commission'
      or exists (
        select 1 from public.driver_subscriptions ds
        where ds.driver_id=dp.user_id and ds.pincode_id=v_next.pincode_id
          and ds.status='active' and ds.period_start<=now() and ds.period_end>now()
      )
    )
  order by
    case when dl.speed_mps is not null and dl.speed_mps>0.5
      then extensions.st_distance(dl.location,current_trip.destination_location)/dl.speed_mps
      else null end nulls last,
    extensions.st_distance(current_trip.destination_location,v_next.pickup_location);
end;
$$;
revoke all on function public.find_ride_chain_candidates(uuid) from public,anon,authenticated;
grant execute on function public.find_ride_chain_candidates(uuid) to service_role;

-- Store a bcrypt hash of the SHA-256 token, not the six-digit OTP itself.
create or replace function public.create_ride_booking(
  p_customer_id uuid,
  p_pincode text,
  p_vehicle_category_id bigint,
  p_pickup_longitude double precision,
  p_pickup_latitude double precision,
  p_destination_longitude double precision,
  p_destination_latitude double precision,
  p_pickup_address text,
  p_destination_address text,
  p_distance_m integer,
  p_duration_s integer,
  p_estimated_fare numeric,
  p_fare_breakdown jsonb,
  p_booking_idempotency_key text,
  p_pickup_otp_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles%rowtype;
  v_pincode public.service_area_pincodes%rowtype;
  v_commercial public.service_area_commercial_configs%rowtype;
  v_category public.vehicle_categories%rowtype;
  v_fare public.fare_configs%rowtype;
  v_ride public.rides%rowtype;
  v_pickup extensions.geography;
  v_destination extensions.geography;
begin
  if p_customer_id is null or p_booking_idempotency_key is null
     or length(p_booking_idempotency_key)<8 or length(p_booking_idempotency_key)>128 then
    raise exception 'Invalid customer or idempotency key' using errcode='22023';
  end if;
  if p_pincode !~ '^[1-9][0-9]{5}$' then raise exception 'Invalid Indian pincode' using errcode='22023'; end if;
  if p_pickup_longitude not between -180 and 180 or p_destination_longitude not between -180 and 180
     or p_pickup_latitude not between -90 and 90 or p_destination_latitude not between -90 and 90 then
    raise exception 'Invalid coordinate range' using errcode='22023';
  end if;
  if p_pickup_address is null or btrim(p_pickup_address)='' or p_destination_address is null or btrim(p_destination_address)='' then
    raise exception 'Pickup and destination addresses are required' using errcode='22023';
  end if;
  if p_distance_m is null or p_distance_m<=0 or p_duration_s is null or p_duration_s<=0
     or p_estimated_fare is null or p_estimated_fare<0 or p_fare_breakdown is null
     or p_pickup_otp_hash is null or length(p_pickup_otp_hash)<32 then
    raise exception 'Invalid route or fare quote' using errcode='22023';
  end if;

  select * into v_profile from public.profiles where id=p_customer_id for share;
  if not found or v_profile.account_status<>'active'
     or not exists(select 1 from public.user_roles ur where ur.user_id=p_customer_id and ur.role='customer') then
    raise exception 'Active customer account is required' using errcode='42501';
  end if;

  select * into v_ride from public.rides
  where customer_id=p_customer_id and booking_idempotency_key=p_booking_idempotency_key;
  if found then return jsonb_build_object('ride',to_jsonb(v_ride),'created',false); end if;

  select p.* into v_pincode
  from public.service_area_pincodes p
  join public.service_areas a on a.id=p.service_area_id and a.is_active
  where p.pincode=p_pincode and p.is_active
  for share of p;
  if not found then raise exception 'Service is not active for this pincode' using errcode='P0001'; end if;
  if v_pincode.boundary is null then raise exception 'Pickup boundary has not been configured for this pincode' using errcode='P0001'; end if;

  v_pickup:=extensions.st_setsrid(extensions.st_makepoint(p_pickup_longitude,p_pickup_latitude),4326)::extensions.geography;
  v_destination:=extensions.st_setsrid(extensions.st_makepoint(p_destination_longitude,p_destination_latitude),4326)::extensions.geography;
  if not extensions.st_covers(v_pincode.boundary::extensions.geometry,v_pickup::extensions.geometry) then
    raise exception 'Pickup coordinate is outside the selected service pincode' using errcode='22023';
  end if;

  select * into v_commercial from public.service_area_commercial_configs c
  where c.pincode_id=v_pincode.id and c.is_active and c.valid_from<=now()
    and (c.valid_until is null or c.valid_until>now())
  order by c.valid_from desc limit 1;
  if not found then raise exception 'No active commercial model is configured for this pincode' using errcode='P0001'; end if;

  select * into v_category from public.vehicle_categories where id=p_vehicle_category_id and is_active;
  if not found then raise exception 'Vehicle category is not available' using errcode='P0001'; end if;

  select * into v_fare from public.fare_configs f
  where f.service_area_id=v_pincode.service_area_id and f.vehicle_category_id=p_vehicle_category_id
    and f.is_active and f.valid_from<=now() and (f.valid_until is null or f.valid_until>now())
  order by f.valid_from desc limit 1;
  if not found then raise exception 'Fare configuration is not available for this pincode and vehicle category' using errcode='P0001'; end if;

  insert into public.rides(
    customer_id,service_area_id,vehicle_category_id,status,pickup_location,destination_location,
    pickup_address,destination_address,estimated_distance_m,estimated_duration_s,estimated_fare,currency,
    pincode_id,commercial_config_id,commercial_model_snapshot,commercial_terms_snapshot,
    fare_config_id,fare_breakdown,booking_idempotency_key,pickup_otp_hash
  )
  values(
    p_customer_id,v_pincode.service_area_id,p_vehicle_category_id,'requested',v_pickup,v_destination,
    btrim(p_pickup_address),btrim(p_destination_address),p_distance_m,p_duration_s,p_estimated_fare,v_fare.currency,
    v_pincode.id,v_commercial.id,v_commercial.business_model,
    jsonb_build_object('business_model',v_commercial.business_model,
      'subscription_amount',v_commercial.subscription_amount,
      'subscription_period',v_commercial.subscription_period,
      'commission_percent',v_commercial.commission_percent,
      'currency',v_commercial.currency,'valid_from',v_commercial.valid_from,'valid_until',v_commercial.valid_until),
    v_fare.id,p_fare_breakdown,p_booking_idempotency_key,
    extensions.crypt(p_pickup_otp_hash,extensions.gen_salt('bf',10))
  )
  returning * into v_ride;

  insert into public.ride_events(ride_id,actor_user_id,event_type,previous_status,new_status,details)
  values(v_ride.id,p_customer_id,'ride_booked',null,'requested',
    jsonb_build_object('pincode',p_pincode,'vehicle_category_id',p_vehicle_category_id));

  return jsonb_build_object('ride',to_jsonb(v_ride),'created',true);
end;
$$;
revoke all on function public.create_ride_booking(uuid,text,bigint,double precision,double precision,double precision,double precision,text,text,integer,integer,numeric,jsonb,text,text)
from public,anon,authenticated;
grant execute on function public.create_ride_booking(uuid,text,bigint,double precision,double precision,double precision,double precision,text,text,integer,integer,numeric,jsonb,text,text)
to service_role;

create or replace function public.driver_ride_transition(
  p_ride_id uuid,
  p_driver_id uuid,
  p_action text,
  p_otp_sha256 text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.rides%rowtype;
  v_attempts integer;
  v_new_status text;
begin
  select * into v_ride from public.rides where id=p_ride_id for update;
  if not found or v_ride.driver_id<>p_driver_id then
    return jsonb_build_object('ok',false,'code','RIDE_NOT_ASSIGNED','message','This ride is not assigned to this driver');
  end if;

  if p_action='arriving' then
    if v_ride.status<>'accepted' then return jsonb_build_object('ok',false,'code','INVALID_STATE'); end if;
    v_new_status:='driver_arriving';
  elsif p_action='arrived' then
    if v_ride.status<>'driver_arriving' then return jsonb_build_object('ok',false,'code','INVALID_STATE'); end if;
    v_new_status:='arrived';
  elsif p_action='start' then
    if v_ride.status<>'arrived' then return jsonb_build_object('ok',false,'code','INVALID_STATE'); end if;
    if p_otp_sha256 is null then return jsonb_build_object('ok',false,'code','OTP_REQUIRED'); end if;

    select count(*) into v_attempts
    from public.ride_otp_attempts
    where ride_id=p_ride_id and driver_id=p_driver_id
      and succeeded=false and attempted_at>now()-interval '15 minutes';
    if v_attempts>=5 then return jsonb_build_object('ok',false,'code','OTP_RATE_LIMIT'); end if;

    if v_ride.pickup_otp_hash is null
       or extensions.crypt(p_otp_sha256,v_ride.pickup_otp_hash)<>v_ride.pickup_otp_hash then
      insert into public.ride_otp_attempts(ride_id,driver_id,succeeded)
      values(p_ride_id,p_driver_id,false);
      insert into public.ride_events(ride_id,actor_user_id,event_type,details)
      values(p_ride_id,p_driver_id,'pickup_otp_failed',jsonb_build_object('attempt_count',v_attempts+1));
      return jsonb_build_object('ok',false,'code','OTP_INVALID','attempts_remaining',greatest(0,4-v_attempts));
    end if;

    insert into public.ride_otp_attempts(ride_id,driver_id,succeeded)
    values(p_ride_id,p_driver_id,true);
    v_new_status:='in_progress';
  elsif p_action='cancel' then
    if v_ride.status not in ('accepted','driver_arriving','arrived') then
      return jsonb_build_object('ok',false,'code','INVALID_STATE');
    end if;
    update public.rides
    set status='cancelled',cancelled_at=now(),cancellation_reason='driver_cancelled'
    where id=p_ride_id;
    update public.driver_profiles set availability_status='online' where user_id=p_driver_id;
    insert into public.ride_events(ride_id,actor_user_id,event_type,previous_status,new_status)
    values(p_ride_id,p_driver_id,'driver_cancelled',v_ride.status,'cancelled');
    return jsonb_build_object('ok',true,'status','cancelled');
  else
    return jsonb_build_object('ok',false,'code','UNSUPPORTED_ACTION');
  end if;

  update public.rides
  set status=v_new_status,
      accepted_at=case when v_new_status='accepted' then coalesce(accepted_at,now()) else accepted_at end,
      started_at=case when v_new_status='in_progress' then now() else started_at end
  where id=p_ride_id;

  insert into public.ride_events(ride_id,actor_user_id,event_type,previous_status,new_status)
  values(p_ride_id,p_driver_id,'ride_status_changed',v_ride.status,v_new_status);

  return jsonb_build_object('ok',true,'ride_id',p_ride_id,'status',v_new_status);
end;
$$;

create or replace function public.get_driver_ride_completion_context(
  p_ride_id uuid,
  p_driver_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.rides%rowtype;
  v_fare public.fare_configs%rowtype;
begin
  select * into v_ride from public.rides
  where id=p_ride_id and driver_id=p_driver_id and status='in_progress';
  if not found then raise exception 'Active ride assigned to this driver not found' using errcode='P0002'; end if;

  select * into v_fare from public.fare_configs where id=v_ride.fare_config_id;
  if not found then raise exception 'Fare snapshot is unavailable' using errcode='P0001'; end if;

  return jsonb_build_object(
    'ride_id',v_ride.id,
    'pickup_ewkt',extensions.st_asewkt(v_ride.pickup_location::extensions.geometry),
    'destination_ewkt',extensions.st_asewkt(v_ride.destination_location::extensions.geometry),
    'fare_config',jsonb_build_object(
      'base_fare',v_fare.base_fare,'per_km_rate',v_fare.per_km_rate,
      'per_minute_rate',v_fare.per_minute_rate,'minimum_fare',v_fare.minimum_fare,
      'booking_fee',v_fare.booking_fee,'multiplier',v_fare.multiplier,'currency',v_fare.currency
    )
  );
end;
$$;

revoke all on function public.driver_ride_transition(uuid,uuid,text,text) from public,anon,authenticated;
revoke all on function public.get_driver_ride_completion_context(uuid,uuid) from public,anon,authenticated;
grant execute on function public.driver_ride_transition(uuid,uuid,text,text) to service_role;
grant execute on function public.get_driver_ride_completion_context(uuid,uuid) to service_role;

