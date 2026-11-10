-- Pincode-specific vehicle catalogue and fare support for Quick Ride.
-- Public clients may read enabled categories for an active pincode, but all changes
-- remain behind the admin-service-areas Edge Function.

alter table public.fare_configs
  add column if not exists pincode_id bigint
  references public.service_area_pincodes(id) on delete restrict;

create index if not exists fare_configs_pincode_lookup_idx
  on public.fare_configs(pincode_id, vehicle_category_id, is_active, valid_from desc);

create table if not exists public.service_area_pincode_vehicles (
  id bigint generated always as identity primary key,
  pincode_id bigint not null references public.service_area_pincodes(id) on delete cascade,
  vehicle_category_id bigint not null references public.vehicle_categories(id) on delete restrict,
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pincode_id, vehicle_category_id)
);

create index if not exists service_area_pincode_vehicles_enabled_idx
  on public.service_area_pincode_vehicles(pincode_id, is_enabled, vehicle_category_id);

alter table public.service_area_pincode_vehicles enable row level security;

drop policy if exists service_area_pincode_vehicles_read_enabled on public.service_area_pincode_vehicles;
create policy service_area_pincode_vehicles_read_enabled
  on public.service_area_pincode_vehicles
  for select to anon, authenticated
  using (
    is_enabled
    and exists (
      select 1
      from public.service_area_pincodes p
      join public.service_areas a on a.id = p.service_area_id
      where p.id = service_area_pincode_vehicles.pincode_id
        and p.is_active = true
        and a.is_active = true
    )
    and exists (
      select 1 from public.vehicle_categories c
      where c.id = service_area_pincode_vehicles.vehicle_category_id
        and c.is_active = true
    )
  );

revoke all on public.service_area_pincode_vehicles from anon, authenticated;
grant select on public.service_area_pincode_vehicles to anon, authenticated;
grant all on public.service_area_pincode_vehicles to service_role;

drop trigger if exists service_area_pincode_vehicles_set_updated_at
  on public.service_area_pincode_vehicles;
create trigger service_area_pincode_vehicles_set_updated_at
  before update on public.service_area_pincode_vehicles
  for each row execute function public.set_updated_at();

create or replace function public.get_ride_quote_context(
  p_pincode text,
  p_vehicle_category_id bigint,
  p_pickup_longitude double precision,
  p_pickup_latitude double precision
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pincode public.service_area_pincodes%rowtype;
  v_commercial public.service_area_commercial_configs%rowtype;
  v_category public.vehicle_categories%rowtype;
  v_fare public.fare_configs%rowtype;
  v_pickup extensions.geography;
begin
  if p_pincode !~ '^[1-9][0-9]{5}$' then
    raise exception 'Invalid Indian pincode' using errcode='22023';
  end if;
  if p_pickup_longitude not between 68 and 98
     or p_pickup_latitude not between 6 and 38 then
    raise exception 'Invalid pickup coordinates' using errcode='22023';
  end if;

  select p.* into v_pincode
  from public.service_area_pincodes p
  join public.service_areas a on a.id=p.service_area_id and a.is_active
  where p.pincode=p_pincode and p.is_active;
  if not found then
    raise exception 'Service is not active for this pincode' using errcode='P0001';
  end if;
  if v_pincode.boundary is null then
    raise exception 'Pickup boundary has not been configured for this pincode' using errcode='P0001';
  end if;

  v_pickup := extensions.st_setsrid(
    extensions.st_makepoint(p_pickup_longitude,p_pickup_latitude),4326
  )::extensions.geography;
  if not extensions.st_covers(
    v_pincode.boundary::extensions.geometry,
    v_pickup::extensions.geometry
  ) then
    raise exception 'Pickup coordinate is outside the selected service pincode' using errcode='22023';
  end if;

  select * into v_commercial
  from public.service_area_commercial_configs c
  where c.pincode_id=v_pincode.id and c.is_active and c.valid_from<=now()
    and (c.valid_until is null or c.valid_until>now())
  order by c.valid_from desc limit 1;
  if not found then
    raise exception 'No active commercial model is configured for this pincode' using errcode='P0001';
  end if;

  select * into v_category from public.vehicle_categories
  where id=p_vehicle_category_id and is_active;
  if not found then
    raise exception 'Vehicle category is not available' using errcode='P0001';
  end if;

  if not exists (
    select 1 from public.service_area_pincode_vehicles pv
    where pv.pincode_id=v_pincode.id
      and pv.vehicle_category_id=p_vehicle_category_id
      and pv.is_enabled
  ) then
    raise exception 'This vehicle type is not enabled in the selected pickup area' using errcode='P0001';
  end if;

  select * into v_fare
  from public.fare_configs f
  where f.service_area_id=v_pincode.service_area_id
    and f.vehicle_category_id=p_vehicle_category_id
    and (f.pincode_id=v_pincode.id or f.pincode_id is null)
    and f.is_active and f.valid_from<=now()
    and (f.valid_until is null or f.valid_until>now())
  order by case when f.pincode_id=v_pincode.id then 0 else 1 end,
           f.valid_from desc
  limit 1;
  if not found then
    raise exception 'Fare configuration is not available for this pincode and vehicle category' using errcode='P0001';
  end if;

  return jsonb_build_object(
    'pincode_id',v_pincode.id,
    'service_area_id',v_pincode.service_area_id,
    'pincode',v_pincode.pincode,
    'vehicle_category',jsonb_build_object(
      'id',v_category.id,'code',v_category.code,'name',v_category.name
    ),
    'commercial_config',jsonb_build_object(
      'id',v_commercial.id,'business_model',v_commercial.business_model,
      'subscription_amount',v_commercial.subscription_amount,
      'subscription_period',v_commercial.subscription_period,
      'commission_percent',v_commercial.commission_percent,'currency',v_commercial.currency
    ),
    'fare_config',jsonb_build_object(
      'id',v_fare.id,'pincode_id',v_fare.pincode_id,
      'currency',v_fare.currency,'base_fare',v_fare.base_fare,
      'per_km_rate',v_fare.per_km_rate,'per_minute_rate',v_fare.per_minute_rate,
      'minimum_fare',v_fare.minimum_fare,'booking_fee',v_fare.booking_fee,
      'multiplier',v_fare.multiplier
    )
  );
end;
$$;

revoke all on function public.get_ride_quote_context(text,bigint,double precision,double precision)
  from public, anon, authenticated;
grant execute on function public.get_ride_quote_context(text,bigint,double precision,double precision)
  to service_role;
