-- Quick-Ride server-authoritative dispatch and ride-chaining functions.
-- Every function in this migration is callable only by service_role; Edge Functions
-- must authenticate the caller and derive actor IDs from Supabase Auth, never request JSON.

create or replace function public.find_nearby_drivers(
  p_pickup_ewkt text,
  p_pincode_id bigint,
  p_vehicle_category_id bigint,
  p_radius_m integer,
  p_limit integer default 25
)
returns table (
  driver_id uuid,
  distance_m numeric,
  geohash_7 text,
  location_recorded_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pickup extensions.geography;
  v_location_max_age integer;
  v_business_model text;
begin
  if p_radius_m is null or p_radius_m < 100 or p_radius_m > 100000 then
    raise exception 'Invalid search radius' using errcode = '22023';
  end if;
  if p_vehicle_category_id is null or p_pincode_id is null then
    raise exception 'Pincode and vehicle category are required' using errcode = '22023';
  end if;

  v_pickup := extensions.st_geogfromtext(p_pickup_ewkt);

  select c.business_model
    into v_business_model
  from public.service_area_pincodes p
  join public.service_areas a on a.id = p.service_area_id and a.is_active
  join lateral (
    select cc.business_model
    from public.service_area_commercial_configs cc
    where cc.pincode_id = p.id
      and cc.is_active
      and cc.valid_from <= now()
      and (cc.valid_until is null or cc.valid_until > now())
    order by cc.valid_from desc
    limit 1
  ) c on true
  where p.id = p_pincode_id and p.is_active;

  if v_business_model is null then
    raise exception 'Pincode is inactive or has no current commercial configuration'
      using errcode = 'P0001';
  end if;

  select coalesce(dc.location_max_age_seconds, 45)
    into v_location_max_age
  from (select 1) seed
  left join public.service_area_dispatch_configs dc on dc.pincode_id = p_pincode_id;

  return query
  select
    dp.user_id,
    extensions.st_distance(dl.location, v_pickup)::numeric,
    dl.geohash_7,
    dl.recorded_at
  from public.driver_profiles dp
  join public.driver_locations dl on dl.driver_id = dp.user_id
  where dp.verification_status = 'approved'
    and dp.availability_status = 'online'
    and dp.vehicle_category_id = p_vehicle_category_id
    and dl.recorded_at >= now() - make_interval(secs => v_location_max_age)
    and extensions.st_dwithin(dl.location, v_pickup, p_radius_m)
    and not exists (
      select 1 from public.rides r
      where r.driver_id = dp.user_id
        and r.status in ('accepted','driver_arriving','arrived','in_progress')
    )
    and (
      v_business_model = 'commission'
      or exists (
        select 1 from public.driver_subscriptions ds
        where ds.driver_id = dp.user_id
          and ds.pincode_id = p_pincode_id
          and ds.status = 'active'
          and ds.period_start <= now()
          and ds.period_end > now()
      )
    )
  order by extensions.st_distance(dl.location, v_pickup)
  limit greatest(1, least(coalesce(p_limit, 25), 100));
end;
$$;

create or replace function public.find_ride_chain_candidates(p_next_ride_id uuid)
returns table (
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
  v_next_ride public.rides%rowtype;
  v_max_pickup_distance integer;
  v_location_max_age integer;
  v_offer_ttl integer;
  v_business_model text;
begin
  select * into v_next_ride
  from public.rides
  where id = p_next_ride_id
  for share;

  if not found or v_next_ride.driver_id is not null
     or v_next_ride.status not in ('requested','searching','offered') then
    raise exception 'Next ride is not available for chaining' using errcode = 'P0001';
  end if;

  select
    coalesce(dc.chain_pickup_distance_m, 1500),
    coalesce(dc.location_max_age_seconds, 45),
    coalesce(dc.chain_offer_ttl_seconds, 90),
    cc.business_model
  into v_max_pickup_distance, v_location_max_age, v_offer_ttl, v_business_model
  from public.service_area_pincodes p
  join public.service_areas a on a.id = p.service_area_id and a.is_active
  join lateral (
    select c.business_model
    from public.service_area_commercial_configs c
    where c.pincode_id = p.id and c.is_active
      and c.valid_from <= now()
      and (c.valid_until is null or c.valid_until > now())
    order by c.valid_from desc limit 1
  ) cc on true
  left join public.service_area_dispatch_configs dc on dc.pincode_id = p.id
  where p.id = v_next_ride.pincode_id and p.is_active;

  if v_business_model is null then
    raise exception 'Next ride pincode has no active commercial configuration' using errcode = 'P0001';
  end if;

  return query
  select
    dp.user_id,
    current_trip.id,
    extensions.st_distance(current_trip.destination_location, v_next_ride.pickup_location)::numeric,
    extensions.st_distance(dl.location, current_trip.destination_location)::numeric,
    case
      when dl.speed_mps is not null and dl.speed_mps > 0.5
      then ceil(extensions.st_distance(dl.location, current_trip.destination_location) / dl.speed_mps)::integer
      else null
    end,
    v_offer_ttl
  from public.rides current_trip
  join public.driver_profiles dp on dp.user_id = current_trip.driver_id
  join public.driver_locations dl on dl.driver_id = dp.user_id
  where current_trip.status = 'in_progress'
    and current_trip.driver_id is not null
    and current_trip.vehicle_category_id = v_next_ride.vehicle_category_id
    and dp.verification_status = 'approved'
    and dp.availability_status = 'busy'
    and dl.recorded_at >= now() - make_interval(secs => v_location_max_age)
    and extensions.st_dwithin(current_trip.destination_location, v_next_ride.pickup_location, v_max_pickup_distance)
    and not exists (
      select 1 from public.ride_chain_offers existing
      where existing.next_ride_id = v_next_ride.id
        and existing.driver_id = dp.user_id
        and existing.status in ('offered','preaccepted')
        and existing.expires_at > now()
    )
    and (
      v_business_model = 'commission'
      or exists (
        select 1 from public.driver_subscriptions ds
        where ds.driver_id = dp.user_id
          and ds.pincode_id = v_next_ride.pincode_id
          and ds.status = 'active'
          and ds.period_start <= now()
          and ds.period_end > now()
      )
    )
  order by
    case when dl.speed_mps is not null and dl.speed_mps > 0.5
      then extensions.st_distance(dl.location, current_trip.destination_location) / dl.speed_mps
      else null end nulls last,
    extensions.st_distance(current_trip.destination_location, v_next_ride.pickup_location);
end;
$$;

create or replace function public.accept_ride_offer(
  p_offer_id uuid,
  p_driver_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_offer public.ride_offers%rowtype;
  v_ride public.rides%rowtype;
  v_driver public.driver_profiles%rowtype;
  v_business_model text;
begin
  select * into v_offer
  from public.ride_offers
  where id = p_offer_id
  for update;

  if not found or v_offer.driver_id <> p_driver_id
     or v_offer.status <> 'pending' or v_offer.expires_at <= now() then
    raise exception 'Ride offer is unavailable or expired' using errcode = 'P0001';
  end if;

  select * into v_ride from public.rides where id = v_offer.ride_id for update;
  if not found or v_ride.driver_id is not null
     or v_ride.status not in ('requested','searching','offered') then
    raise exception 'Ride has already been assigned or is no longer available' using errcode = 'P0001';
  end if;

  select * into v_driver
  from public.driver_profiles
  where user_id = p_driver_id
  for update;

  if not found or v_driver.verification_status <> 'approved'
     or v_driver.availability_status <> 'online'
     or v_driver.vehicle_category_id <> v_ride.vehicle_category_id then
    raise exception 'Driver is not eligible for this ride' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.rides r
    where r.driver_id = p_driver_id
      and r.status in ('accepted','driver_arriving','arrived','in_progress')
  ) then
    raise exception 'Driver already has an active ride' using errcode = 'P0001';
  end if;

  select cc.business_model into v_business_model
  from public.service_area_commercial_configs cc
  where cc.id = v_ride.commercial_config_id
    and cc.is_active = true
  limit 1;

  if v_business_model in ('subscription','hybrid') and not exists (
    select 1 from public.driver_subscriptions ds
    where ds.driver_id = p_driver_id
      and ds.pincode_id = v_ride.pincode_id
      and ds.status = 'active'
      and ds.period_start <= now()
      and ds.period_end > now()
  ) then
    raise exception 'Driver subscription is not active for this service pincode' using errcode = 'P0001';
  end if;

  update public.rides
  set driver_id = p_driver_id, status = 'accepted', accepted_at = now()
  where id = v_ride.id and driver_id is null
  returning * into v_ride;

  if v_ride.driver_id is distinct from p_driver_id then
    raise exception 'Ride assignment lost a concurrency race' using errcode = '40001';
  end if;

  update public.ride_offers
  set status = case when id = p_offer_id then 'accepted' else 'withdrawn' end,
      responded_at = now()
  where ride_id = v_ride.id and status = 'pending';

  update public.driver_profiles
  set availability_status = 'busy'
  where user_id = p_driver_id;

  insert into public.ride_events(ride_id, actor_user_id, event_type, previous_status, new_status)
  values (v_ride.id, p_driver_id, 'driver_accepted', v_ride.status, 'accepted');

  return jsonb_build_object('ride_id', v_ride.id, 'driver_id', p_driver_id, 'status', 'accepted');
end;
$$;

create or replace function public.preaccept_ride_chain_offer(
  p_chain_offer_id uuid,
  p_driver_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_offer public.ride_chain_offers%rowtype;
  v_current public.rides%rowtype;
  v_next public.rides%rowtype;
begin
  select * into v_offer from public.ride_chain_offers
  where id = p_chain_offer_id for update;

  if not found or v_offer.driver_id <> p_driver_id
     or v_offer.status <> 'offered' or v_offer.expires_at <= now() then
    raise exception 'Ride-chain offer is unavailable or expired' using errcode = 'P0001';
  end if;

  select * into v_current from public.rides where id = v_offer.current_ride_id for update;
  select * into v_next from public.rides where id = v_offer.next_ride_id for update;

  if v_current.status <> 'in_progress' or v_current.driver_id <> p_driver_id
     or v_next.driver_id is not null or v_next.status not in ('requested','searching','offered') then
    raise exception 'Ride-chain conditions are no longer valid' using errcode = 'P0001';
  end if;

  update public.ride_chain_offers
  set status = 'preaccepted', responded_at = now()
  where id = v_offer.id;

  return jsonb_build_object(
    'chain_offer_id', v_offer.id,
    'current_ride_id', v_current.id,
    'next_ride_id', v_next.id,
    'status', 'preaccepted',
    'assignment_deferred_until_current_ride_completes', true
  );
end;
$$;

create or replace function public.finish_ride(
  p_ride_id uuid,
  p_driver_id uuid,
  p_final_fare numeric
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.rides%rowtype;
  v_config public.service_area_commercial_configs%rowtype;
  v_commission numeric(12,2);
  v_chain_offer public.ride_chain_offers%rowtype;
  v_next public.rides%rowtype;
  v_chained_ride_id uuid;
begin
  if p_final_fare is null or p_final_fare < 0 then
    raise exception 'Final fare must be a non-negative server-calculated amount' using errcode = '22023';
  end if;

  select * into v_ride from public.rides
  where id = p_ride_id for update;

  if not found or v_ride.driver_id <> p_driver_id or v_ride.status <> 'in_progress' then
    raise exception 'Ride cannot be completed by this driver' using errcode = 'P0001';
  end if;

  update public.rides
  set status = 'completed', final_fare = p_final_fare, completed_at = now()
  where id = p_ride_id
  returning * into v_ride;

  insert into public.ride_events(ride_id, actor_user_id, event_type, previous_status, new_status)
  values (v_ride.id, p_driver_id, 'ride_completed', 'in_progress', 'completed');

  select * into v_config from public.service_area_commercial_configs
  where id = v_ride.commercial_config_id;

  if found and v_config.commission_percent is not null then
    v_commission := round((p_final_fare * v_config.commission_percent / 100.0)::numeric, 2);

    insert into public.ride_commissions(
      ride_id, driver_id, pincode_id, commercial_config_id,
      business_model_snapshot, commission_percent_snapshot,
      fare_amount, commission_amount, currency
    )
    values (
      v_ride.id, p_driver_id, v_ride.pincode_id, v_config.id,
      v_ride.commercial_model_snapshot, v_config.commission_percent,
      p_final_fare, v_commission, v_ride.currency
    )
    on conflict (ride_id) do nothing;

    if v_commission > 0 then
      insert into public.ledger_entries(
        owner_user_id, ride_id, entry_type, direction, amount, currency,
        status, idempotency_key, description
      )
      values (
        p_driver_id, v_ride.id, 'commission', 'debit', v_commission, v_ride.currency,
        'posted', 'ride-commission:' || v_ride.id::text,
        'Commission for completed Quick-Ride trip'
      )
      on conflict (idempotency_key) do nothing;
    end if;
  end if;

  update public.driver_profiles set availability_status = 'online'
  where user_id = p_driver_id;

  -- A preaccepted next ride is activated only after the current ride is committed
  -- as completed and only if the next ride is still unassigned.
  for v_chain_offer in
    select * from public.ride_chain_offers
    where current_ride_id = v_ride.id
      and driver_id = p_driver_id
      and status = 'preaccepted'
      and expires_at > now()
    order by estimated_seconds_to_destination nulls last, offered_at
    for update
  loop
    select * into v_next from public.rides
    where id = v_chain_offer.next_ride_id for update;

    if found and v_next.driver_id is null
       and v_next.status in ('requested','searching','offered') then
      update public.rides
      set driver_id = p_driver_id, status = 'accepted', accepted_at = now(),
          chain_from_ride_id = v_ride.id
      where id = v_next.id and driver_id is null
      returning id into v_chained_ride_id;

      if v_chained_ride_id is not null then
        update public.ride_chain_offers
        set status = 'activated', activated_at = now()
        where id = v_chain_offer.id;

        update public.ride_chain_offers
        set status = 'withdrawn', responded_at = now()
        where next_ride_id = v_next.id and id <> v_chain_offer.id
          and status in ('offered','preaccepted');

        update public.ride_offers
        set status = 'withdrawn', responded_at = now()
        where ride_id = v_next.id and status = 'pending';

        update public.driver_profiles set availability_status = 'busy'
        where user_id = p_driver_id;

        insert into public.ride_events(ride_id, actor_user_id, event_type, previous_status, new_status, details)
        values (
          v_next.id, p_driver_id, 'ride_chain_activated', v_next.status, 'accepted',
          jsonb_build_object('previous_ride_id', v_ride.id)
        );
        exit;
      end if;
    end if;

    update public.ride_chain_offers
    set status = 'withdrawn', responded_at = now()
    where id = v_chain_offer.id;
  end loop;

  return jsonb_build_object(
    'ride_id', v_ride.id,
    'status', 'completed',
    'final_fare', p_final_fare,
    'commission_amount', coalesce(v_commission, 0),
    'chained_ride_id', v_chained_ride_id
  );
end;
$$;

create or replace function public.reject_ride_offer(
  p_offer_id uuid,
  p_driver_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_offer public.ride_offers%rowtype;
begin
  select * into v_offer
  from public.ride_offers
  where id = p_offer_id and driver_id = p_driver_id
  for update;

  if not found or v_offer.status <> 'pending' or v_offer.expires_at <= now() then
    raise exception 'Ride offer is unavailable or expired' using errcode = 'P0001';
  end if;

  update public.ride_offers
  set status = 'rejected', responded_at = now()
  where id = p_offer_id;

  return jsonb_build_object('offer_id', p_offer_id, 'status', 'rejected');
end;
$$;

revoke all on function public.find_nearby_drivers(text,bigint,bigint,integer,integer) from public, anon, authenticated;
revoke all on function public.find_ride_chain_candidates(uuid) from public, anon, authenticated;
revoke all on function public.accept_ride_offer(uuid,uuid) from public, anon, authenticated;
revoke all on function public.preaccept_ride_chain_offer(uuid,uuid) from public, anon, authenticated;
revoke all on function public.finish_ride(uuid,uuid,numeric) from public, anon, authenticated;
revoke all on function public.reject_ride_offer(uuid,uuid) from public, anon, authenticated;

grant execute on function public.find_nearby_drivers(text,bigint,bigint,integer,integer) to service_role;
grant execute on function public.find_ride_chain_candidates(uuid) to service_role;
grant execute on function public.accept_ride_offer(uuid,uuid) to service_role;
grant execute on function public.preaccept_ride_chain_offer(uuid,uuid) to service_role;
grant execute on function public.finish_ride(uuid,uuid,numeric) to service_role;
grant execute on function public.reject_ride_offer(uuid,uuid) to service_role;

comment on function public.find_nearby_drivers(text,bigint,bigint,integer,integer) is 'Server-only PostGIS and geohash-backed discovery of nearby eligible online drivers.';
comment on function public.find_ride_chain_candidates(uuid) is 'Server-only discovery of busy drivers whose current ride destination is close to a new pickup.';
comment on function public.preaccept_ride_chain_offer(uuid,uuid) is 'Records provisional driver acceptance without assigning a new ride before the current trip ends.';
comment on function public.finish_ride(uuid,uuid,numeric) is 'Completes a ride, posts configured commission and atomically activates one valid preaccepted chained ride.';

