-- Booking prerequisites: per-pincode spatial boundary, automatic customer profile
-- bootstrap, and server-only authoritative ride creation.

alter table public.service_area_pincodes
  add column if not exists boundary extensions.geography(MultiPolygon,4326);

create index if not exists service_area_pincodes_boundary_gix
  on public.service_area_pincodes using gist(boundary);

create or replace function public.handle_new_quick_ride_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles(id,full_name,avatar_url)
  values (
    new.id,
    nullif(btrim(coalesce(new.raw_user_meta_data->>'full_name',new.raw_user_meta_data->>'name','')),''),
    nullif(btrim(coalesce(new.raw_user_meta_data->>'avatar_url',new.raw_user_meta_data->>'picture','')),'')
  )
  on conflict(id) do nothing;

  insert into public.user_roles(user_id,role)
  values(new.id,'customer')
  on conflict(user_id,role) do nothing;

  return new;
end;
$$;

revoke all on function public.handle_new_quick_ride_user() from public,anon,authenticated;

do $$
begin
  if not exists (
    select 1 from pg_trigger
    where tgname='on_auth_user_created_quick_ride'
      and tgrelid='auth.users'::regclass
      and not tgisinternal
  ) then
    create trigger on_auth_user_created_quick_ride
      after insert on auth.users
      for each row execute function public.handle_new_quick_ride_user();
  end if;
end $$;

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
     or length(p_booking_idempotency_key) < 8 or length(p_booking_idempotency_key) > 128 then
    raise exception 'Invalid customer or idempotency key' using errcode='22023';
  end if;
  if p_pincode !~ '^[1-9][0-9]{5}$' then
    raise exception 'Invalid Indian pincode' using errcode='22023';
  end if;
  if p_pickup_longitude not between -180 and 180 or p_destination_longitude not between -180 and 180
     or p_pickup_latitude not between -90 and 90 or p_destination_latitude not between -90 and 90 then
    raise exception 'Invalid coordinate range' using errcode='22023';
  end if;
  if p_pickup_address is null or btrim(p_pickup_address)='' or
     p_destination_address is null or btrim(p_destination_address)='' then
    raise exception 'Pickup and destination addresses are required' using errcode='22023';
  end if;
  if p_distance_m is null or p_distance_m <= 0 or p_duration_s is null or p_duration_s <= 0
     or p_estimated_fare is null or p_estimated_fare < 0 or p_fare_breakdown is null
     or p_pickup_otp_hash is null or length(p_pickup_otp_hash) < 32 then
    raise exception 'Invalid route or fare quote' using errcode='22023';
  end if;

  select * into v_profile from public.profiles where id=p_customer_id for share;
  if not found or v_profile.account_status<>'active'
     or not exists(select 1 from public.user_roles ur where ur.user_id=p_customer_id and ur.role='customer') then
    raise exception 'Active customer account is required' using errcode='42501';
  end if;

  select * into v_ride
  from public.rides
  where customer_id=p_customer_id and booking_idempotency_key=p_booking_idempotency_key;
  if found then
    return jsonb_build_object('ride',to_jsonb(v_ride),'created',false);
  end if;

  select p.* into v_pincode
  from public.service_area_pincodes p
  join public.service_areas a on a.id=p.service_area_id and a.is_active
  where p.pincode=p_pincode and p.is_active
  for share of p;

  if not found then
    raise exception 'Service is not active for this pincode' using errcode='P0001';
  end if;
  if v_pincode.boundary is null then
    raise exception 'Pickup boundary has not been configured for this pincode' using errcode='P0001';
  end if;

  v_pickup := extensions.st_setsrid(extensions.st_makepoint(p_pickup_longitude,p_pickup_latitude),4326)::extensions.geography;
  v_destination := extensions.st_setsrid(extensions.st_makepoint(p_destination_longitude,p_destination_latitude),4326)::extensions.geography;

  if not extensions.st_covers(v_pincode.boundary::extensions.geometry,v_pickup::extensions.geometry) then
    raise exception 'Pickup coordinate is outside the selected service pincode' using errcode='22023';
  end if;

  select * into v_commercial
  from public.service_area_commercial_configs c
  where c.pincode_id=v_pincode.id and c.is_active
    and c.valid_from<=now() and (c.valid_until is null or c.valid_until>now())
  order by c.valid_from desc limit 1;
  if not found then
    raise exception 'No active commercial model is configured for this pincode' using errcode='P0001';
  end if;

  select * into v_category
  from public.vehicle_categories
  where id=p_vehicle_category_id and is_active;
  if not found then
    raise exception 'Vehicle category is not available' using errcode='P0001';
  end if;

  select * into v_fare
  from public.fare_configs f
  where f.service_area_id=v_pincode.service_area_id
    and f.vehicle_category_id=p_vehicle_category_id
    and f.is_active and f.valid_from<=now()
    and (f.valid_until is null or f.valid_until>now())
  order by f.valid_from desc limit 1;
  if not found then
    raise exception 'Fare configuration is not available for this pincode and vehicle category' using errcode='P0001';
  end if;

  insert into public.rides(
    customer_id,service_area_id,vehicle_category_id,status,
    pickup_location,destination_location,pickup_address,destination_address,
    estimated_distance_m,estimated_duration_s,estimated_fare,currency,
    pincode_id,commercial_config_id,commercial_model_snapshot,commercial_terms_snapshot,
    fare_config_id,fare_breakdown,booking_idempotency_key,pickup_otp_hash
  )
  values(
    p_customer_id,v_pincode.service_area_id,p_vehicle_category_id,'requested',
    v_pickup,v_destination,btrim(p_pickup_address),btrim(p_destination_address),
    p_distance_m,p_duration_s,p_estimated_fare,v_fare.currency,
    v_pincode.id,v_commercial.id,v_commercial.business_model,
    jsonb_build_object(
      'business_model',v_commercial.business_model,
      'subscription_amount',v_commercial.subscription_amount,
      'subscription_period',v_commercial.subscription_period,
      'commission_percent',v_commercial.commission_percent,
      'currency',v_commercial.currency,
      'valid_from',v_commercial.valid_from,
      'valid_until',v_commercial.valid_until
    ),
    v_fare.id,p_fare_breakdown,p_booking_idempotency_key,p_pickup_otp_hash
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

comment on column public.service_area_pincodes.boundary is 'Required pickup coverage polygon for booking validation; supplied and reviewed by operations.';
comment on function public.create_ride_booking(uuid,text,bigint,double precision,double precision,double precision,double precision,text,text,integer,integer,numeric,jsonb,text,text) is 'Creates an idempotent booking using server-calculated Mapbox route and fare inputs; validates account, active pincode, pickup polygon, commercial model and fare configuration.';

