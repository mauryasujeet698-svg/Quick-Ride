-- GPS trace, immutable fare snapshot, driver service-area selection and online controls.

alter table public.driver_profiles
  add column if not exists active_pincode_id bigint references public.service_area_pincodes(id) on delete set null;

alter table public.rides
  add column if not exists fare_config_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists actual_distance_m integer,
  add column if not exists actual_duration_s integer,
  add column if not exists final_fare_breakdown jsonb not null default '{}'::jsonb;

create table if not exists public.ride_location_points (
  id bigint generated always as identity primary key,
  ride_id uuid not null references public.rides(id) on delete cascade,
  driver_id uuid not null references auth.users(id) on delete cascade,
  location extensions.geography(Point,4326) not null,
  accuracy_m numeric,
  speed_mps numeric,
  heading_degrees numeric,
  geohash_7 text generated always as (extensions.st_geohash(location::extensions.geometry,7)) stored,
  recorded_at timestamptz not null default now(),
  constraint ride_location_accuracy_valid check(accuracy_m is null or accuracy_m between 0 and 1000),
  constraint ride_location_speed_valid check(speed_mps is null or speed_mps between 0 and 150),
  constraint ride_location_heading_valid check(heading_degrees is null or heading_degrees between 0 and 360)
);
create index if not exists ride_location_points_ride_time_idx
  on public.ride_location_points(ride_id,recorded_at);
create index if not exists ride_location_points_driver_time_idx
  on public.ride_location_points(driver_id,recorded_at desc);
create index if not exists ride_location_points_location_gix
  on public.ride_location_points using gist(location);
alter table public.ride_location_points enable row level security;
create policy ride_location_points_participants_read
  on public.ride_location_points for select to authenticated
  using (exists (
    select 1 from public.rides r
    where r.id=ride_id and
      (r.customer_id=(select auth.uid()) or r.driver_id=(select auth.uid()))
  ));
revoke all on public.ride_location_points from anon,authenticated;
grant select on public.ride_location_points to authenticated;

create or replace function public.snapshot_ride_fare_config()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.fare_config_id is not null and (new.fare_config_snapshot is null or new.fare_config_snapshot='{}'::jsonb) then
    select jsonb_build_object(
      'currency',f.currency,
      'base_fare',f.base_fare,
      'per_km_rate',f.per_km_rate,
      'per_minute_rate',f.per_minute_rate,
      'minimum_fare',f.minimum_fare,
      'booking_fee',f.booking_fee,
      'multiplier',f.multiplier
    )
    into new.fare_config_snapshot
    from public.fare_configs f where f.id=new.fare_config_id;
  end if;
  return new;
end;
$$;

drop trigger if exists snapshot_ride_fare_config_before_insert on public.rides;
create trigger snapshot_ride_fare_config_before_insert
before insert on public.rides
for each row execute function public.snapshot_ride_fare_config();

create or replace function public.request_driver_service_pincode(
  p_driver_id uuid,
  p_pincode text,
  p_is_primary boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_driver public.driver_profiles%rowtype;
  v_pincode public.service_area_pincodes%rowtype;
  v_result public.driver_service_pincodes%rowtype;
begin
  select * into v_driver from public.driver_profiles where user_id=p_driver_id;
  if not found then raise exception 'Complete driver registration before selecting a service pincode' using errcode='P0001'; end if;
  if p_pincode !~ '^[1-9][0-9]{5}$' then raise exception 'Invalid Indian pincode' using errcode='22023'; end if;

  select p.* into v_pincode
  from public.service_area_pincodes p
  join public.service_areas a on a.id=p.service_area_id and a.is_active
  where p.pincode=p_pincode and p.is_active;
  if not found then raise exception 'Quick-Ride is not active in this pincode' using errcode='P0001'; end if;

  insert into public.driver_service_pincodes(driver_id,pincode_id,status,is_primary)
  values(p_driver_id,v_pincode.id,'pending',p_is_primary)
  on conflict(driver_id,pincode_id) do update
    set is_primary=excluded.is_primary,
        status=case when public.driver_service_pincodes.status='rejected' then 'pending'
          else public.driver_service_pincodes.status end
  returning * into v_result;

  return jsonb_build_object('id',v_result.id,'pincode',v_pincode.pincode,'status',v_result.status,'is_primary',v_result.is_primary);
end;
$$;

create or replace function public.admin_review_driver_pincode(
  p_actor uuid,
  p_request_id uuid,
  p_decision text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.driver_service_pincodes%rowtype;
begin
  if not exists (
    select 1 from public.user_roles ur join public.profiles pr on pr.id=ur.user_id
    where ur.user_id=p_actor and ur.role in ('admin','operations') and pr.account_status='active'
  ) then raise exception 'Administrator access is required' using errcode='42501'; end if;
  if p_decision not in ('active','rejected','suspended') then
    raise exception 'Invalid decision' using errcode='22023';
  end if;

  select * into v_request from public.driver_service_pincodes where id=p_request_id for update;
  if not found then raise exception 'Driver service pincode request not found' using errcode='P0002'; end if;

  update public.driver_service_pincodes
  set status=p_decision,reviewed_by=p_actor,reviewed_at=now(),review_note=p_note
  where id=p_request_id returning * into v_request;

  insert into public.admin_audit_logs(actor_user_id,action,target_table,target_id,after_data)
  values(p_actor,'driver_service_pincode.'||p_decision,'driver_service_pincodes',p_request_id::text,to_jsonb(v_request));

  return jsonb_build_object('id',v_request.id,'driver_id',v_request.driver_id,'pincode_id',v_request.pincode_id,'status',v_request.status);
end;
$$;

create or replace function public.set_driver_availability(
  p_driver_id uuid,
  p_pincode text,
  p_online boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_driver public.driver_profiles%rowtype;
  v_pincode public.service_area_pincodes%rowtype;
  v_commercial public.service_area_commercial_configs%rowtype;
begin
  select * into v_driver from public.driver_profiles where user_id=p_driver_id for update;
  if not found or v_driver.verification_status<>'approved' then
    raise exception 'An approved driver account is required' using errcode='42501';
  end if;

  if not p_online then
    if exists(select 1 from public.rides r where r.driver_id=p_driver_id
      and r.status in ('accepted','driver_arriving','arrived','in_progress')) then
      raise exception 'Complete or cancel the active ride before going offline' using errcode='P0001';
    end if;
    update public.driver_profiles set availability_status='offline',active_pincode_id=null
    where user_id=p_driver_id;
    return jsonb_build_object('availability_status','offline');
  end if;

  if p_pincode !~ '^[1-9][0-9]{5}$' then raise exception 'Invalid Indian pincode' using errcode='22023'; end if;

  select p.* into v_pincode
  from public.service_area_pincodes p
  join public.service_areas a on a.id=p.service_area_id and a.is_active
  join public.driver_service_pincodes dsp
    on dsp.pincode_id=p.id and dsp.driver_id=p_driver_id and dsp.status='active'
  where p.pincode=p_pincode and p.is_active;
  if not found then raise exception 'This driver is not approved to operate in the selected pincode' using errcode='42501'; end if;

  select * into v_commercial from public.service_area_commercial_configs c
  where c.pincode_id=v_pincode.id and c.is_active and c.valid_from<=now()
    and (c.valid_until is null or c.valid_until>now())
  order by c.valid_from desc limit 1;
  if not found then raise exception 'No current business model is configured for this pincode' using errcode='P0001'; end if;

  if v_commercial.business_model in ('subscription','hybrid') and not exists(
    select 1 from public.driver_subscriptions ds
    where ds.driver_id=p_driver_id and ds.pincode_id=v_pincode.id
      and ds.status='active' and ds.period_start<=now() and ds.period_end>now()
  ) then
    raise exception 'An active driver subscription is required for this pincode' using errcode='P0001';
  end if;

  if v_driver.availability_status='busy' then
    raise exception 'Driver is currently completing another ride' using errcode='P0001';
  end if;

  update public.driver_profiles
  set availability_status='online',active_pincode_id=v_pincode.id
  where user_id=p_driver_id;

  return jsonb_build_object('availability_status','online','pincode',v_pincode.pincode);
end;
$$;

create or replace function public.record_driver_ride_location(
  p_driver_id uuid,
  p_longitude double precision,
  p_latitude double precision,
  p_accuracy_m numeric,
  p_speed_mps numeric,
  p_heading_degrees numeric,
  p_recorded_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_driver public.driver_profiles%rowtype;
  v_active_ride uuid;
  v_point extensions.geography;
  v_recorded_at timestamptz;
begin
  if p_longitude not between -180 and 180 or p_latitude not between -90 and 90 then
    raise exception 'Invalid GPS coordinate' using errcode='22023';
  end if;
  if p_accuracy_m is not null and (p_accuracy_m<0 or p_accuracy_m>1000) then
    raise exception 'Invalid GPS accuracy' using errcode='22023';
  end if;
  if p_speed_mps is not null and (p_speed_mps<0 or p_speed_mps>150) then
    raise exception 'Invalid GPS speed' using errcode='22023';
  end if;
  v_recorded_at:=coalesce(p_recorded_at,now());
  if v_recorded_at>now()+interval '30 seconds' or v_recorded_at<now()-interval '10 minutes' then
    raise exception 'GPS timestamp is outside the accepted time window' using errcode='22023';
  end if;

  select * into v_driver from public.driver_profiles where user_id=p_driver_id;
  if not found or v_driver.verification_status<>'approved'
     or v_driver.availability_status not in ('online','busy') then
    raise exception 'Approved online driver required' using errcode='42501';
  end if;

  v_point:=extensions.st_setsrid(extensions.st_makepoint(p_longitude,p_latitude),4326)::extensions.geography;

  insert into public.driver_locations(
    driver_id,location,accuracy_m,speed_mps,heading_degrees,recorded_at,updated_at
  )
  values(p_driver_id,v_point,p_accuracy_m,p_speed_mps,p_heading_degrees,v_recorded_at,now())
  on conflict(driver_id) do update set
    location=excluded.location,accuracy_m=excluded.accuracy_m,
    speed_mps=excluded.speed_mps,heading_degrees=excluded.heading_degrees,
    recorded_at=excluded.recorded_at,updated_at=now()
  where public.driver_locations.recorded_at<=excluded.recorded_at;

  select r.id into v_active_ride from public.rides r
  where r.driver_id=p_driver_id and r.status='in_progress'
  order by r.started_at desc limit 1;

  if v_active_ride is not null and (p_accuracy_m is null or p_accuracy_m<=50) then
    insert into public.ride_location_points(
      ride_id,driver_id,location,accuracy_m,speed_mps,heading_degrees,recorded_at
    )
    values(v_active_ride,p_driver_id,v_point,p_accuracy_m,p_speed_mps,p_heading_degrees,v_recorded_at);
  end if;

  return jsonb_build_object('recorded',true,'active_ride_id',v_active_ride,'recorded_at',v_recorded_at);
end;
$$;

create or replace function public.finish_ride_from_track(
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
  v_point_count integer;
  v_track_distance_m integer;
  v_duration_s integer;
  v_distance_m integer;
  v_fare_config jsonb;
  v_base numeric;
  v_per_km numeric;
  v_per_minute numeric;
  v_minimum numeric;
  v_booking numeric;
  v_multiplier numeric;
  v_distance_charge numeric;
  v_time_charge numeric;
  v_before_minimum numeric;
  v_final_fare numeric;
  v_mode text;
  v_result jsonb;
begin
  select * into v_ride from public.rides
  where id=p_ride_id and driver_id=p_driver_id and status='in_progress'
  for update;
  if not found then raise exception 'Active ride assigned to this driver not found' using errcode='P0002'; end if;

  select count(*)::integer,
    greatest(1,round(extensions.st_length(
      extensions.st_makeline(location::extensions.geometry order by recorded_at)::extensions.geography
    )))::integer
  into v_point_count,v_track_distance_m
  from public.ride_location_points
  where ride_id=p_ride_id and driver_id=p_driver_id;

  if v_point_count>=2 and v_track_distance_m>0 then
    v_distance_m:=v_track_distance_m;
    v_duration_s:=greatest(1,ceil(extract(epoch from (now()-v_ride.started_at)))::integer);
    v_mode:='gps_track';
  else
    v_distance_m:=coalesce(v_ride.estimated_distance_m,1);
    v_duration_s:=coalesce(v_ride.estimated_duration_s,1);
    v_mode:='route_estimate_fallback';
  end if;

  v_fare_config:=v_ride.fare_config_snapshot;
  v_base:=coalesce((v_fare_config->>'base_fare')::numeric,0);
  v_per_km:=coalesce((v_fare_config->>'per_km_rate')::numeric,0);
  v_per_minute:=coalesce((v_fare_config->>'per_minute_rate')::numeric,0);
  v_minimum:=coalesce((v_fare_config->>'minimum_fare')::numeric,0);
  v_booking:=coalesce((v_fare_config->>'booking_fee')::numeric,0);
  v_multiplier:=coalesce((v_fare_config->>'multiplier')::numeric,1);

  v_distance_charge:=round((v_distance_m/1000.0*v_per_km)::numeric,2);
  v_time_charge:=round((v_duration_s/60.0*v_per_minute)::numeric,2);
  v_before_minimum:=(v_base+v_distance_charge+v_time_charge+v_booking)*v_multiplier;
  v_final_fare:=round(greatest(v_minimum,v_before_minimum),2);

  v_result:=public.finish_ride(p_ride_id,p_driver_id,v_final_fare);

  update public.rides
  set actual_distance_m=v_distance_m,
      actual_duration_s=v_duration_s,
      final_fare_breakdown=jsonb_build_object(
        'calculation_source',v_mode,
        'gps_points_count',v_point_count,
        'distance_m',v_distance_m,
        'duration_s',v_duration_s,
        'base_fare',v_base,
        'distance_charge',v_distance_charge,
        'time_charge',v_time_charge,
        'booking_fee',v_booking,
        'multiplier',v_multiplier,
        'minimum_fare_applied',v_before_minimum<v_minimum,
        'final_fare',v_final_fare,
        'currency',coalesce(v_fare_config->>'currency','INR')
      )
  where id=p_ride_id;

  return v_result || jsonb_build_object(
    'actual_distance_m',v_distance_m,
    'actual_duration_s',v_duration_s,
    'fare_calculation_source',v_mode,
    'gps_points_count',v_point_count
  );
end;
$$;

revoke all on function public.request_driver_service_pincode(uuid,text,boolean) from public,anon,authenticated;
revoke all on function public.admin_review_driver_pincode(uuid,uuid,text,text) from public,anon,authenticated;
revoke all on function public.set_driver_availability(uuid,text,boolean) from public,anon,authenticated;
revoke all on function public.record_driver_ride_location(uuid,double precision,double precision,numeric,numeric,numeric,timestamptz) from public,anon,authenticated;
revoke all on function public.finish_ride_from_track(uuid,uuid) from public,anon,authenticated;
grant execute on function public.request_driver_service_pincode(uuid,text,boolean) to service_role;
grant execute on function public.admin_review_driver_pincode(uuid,uuid,text,text) to service_role;
grant execute on function public.set_driver_availability(uuid,text,boolean) to service_role;
grant execute on function public.record_driver_ride_location(uuid,double precision,double precision,numeric,numeric,numeric,timestamptz) to service_role;
grant execute on function public.finish_ride_from_track(uuid,uuid) to service_role;

