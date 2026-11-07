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
  if p_pickup_longitude not between -180 and 180 or p_pickup_latitude not between -90 and 90 then
    raise exception 'Invalid pickup coordinates' using errcode='22023';
  end if;

  select p.* into v_pincode
  from public.service_area_pincodes p
  join public.service_areas a on a.id=p.service_area_id and a.is_active
  where p.pincode=p_pincode and p.is_active;
  if not found then raise exception 'Service is not active for this pincode' using errcode='P0001'; end if;
  if v_pincode.boundary is null then raise exception 'Pickup boundary has not been configured for this pincode' using errcode='P0001'; end if;

  v_pickup := extensions.st_setsrid(extensions.st_makepoint(p_pickup_longitude,p_pickup_latitude),4326)::extensions.geography;
  if not extensions.st_covers(v_pincode.boundary::extensions.geometry,v_pickup::extensions.geometry) then
    raise exception 'Pickup coordinate is outside the selected service pincode' using errcode='22023';
  end if;

  select * into v_commercial
  from public.service_area_commercial_configs c
  where c.pincode_id=v_pincode.id and c.is_active and c.valid_from<=now()
    and (c.valid_until is null or c.valid_until>now())
  order by c.valid_from desc limit 1;
  if not found then raise exception 'No active commercial model is configured for this pincode' using errcode='P0001'; end if;

  select * into v_category from public.vehicle_categories
  where id=p_vehicle_category_id and is_active;
  if not found then raise exception 'Vehicle category is not available' using errcode='P0001'; end if;

  select * into v_fare from public.fare_configs f
  where f.service_area_id=v_pincode.service_area_id and f.vehicle_category_id=p_vehicle_category_id
    and f.is_active and f.valid_from<=now() and (f.valid_until is null or f.valid_until>now())
  order by f.valid_from desc limit 1;
  if not found then raise exception 'Fare configuration is not available for this pincode and vehicle category' using errcode='P0001'; end if;

  return jsonb_build_object(
    'pincode_id',v_pincode.id,
    'service_area_id',v_pincode.service_area_id,
    'pincode',v_pincode.pincode,
    'vehicle_category',jsonb_build_object('id',v_category.id,'code',v_category.code,'name',v_category.name),
    'commercial_config',jsonb_build_object(
      'id',v_commercial.id,'business_model',v_commercial.business_model,
      'subscription_amount',v_commercial.subscription_amount,
      'subscription_period',v_commercial.subscription_period,
      'commission_percent',v_commercial.commission_percent,'currency',v_commercial.currency
    ),
    'fare_config',jsonb_build_object(
      'id',v_fare.id,'currency',v_fare.currency,'base_fare',v_fare.base_fare,
      'per_km_rate',v_fare.per_km_rate,'per_minute_rate',v_fare.per_minute_rate,
      'minimum_fare',v_fare.minimum_fare,'booking_fee',v_fare.booking_fee,
      'multiplier',v_fare.multiplier
    )
  );
end;
$$;

revoke all on function public.get_ride_quote_context(text,bigint,double precision,double precision)
from public,anon,authenticated;
grant execute on function public.get_ride_quote_context(text,bigint,double precision,double precision)
to service_role;

create or replace function public.admin_set_pincode_boundary(
  p_actor uuid,
  p_pincode_id bigint,
  p_geojson jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_geom extensions.geometry;
  v_pincode public.service_area_pincodes%rowtype;
  v_before jsonb;
  v_after jsonb;
begin
  if not exists (
    select 1 from public.user_roles ur
    join public.profiles pr on pr.id=ur.user_id
    where ur.user_id=p_actor and ur.role in ('admin','operations')
      and pr.account_status='active'
  ) then
    raise exception 'Administrator access is required' using errcode='42501';
  end if;
  if p_geojson is null or jsonb_typeof(p_geojson)<>'object' then
    raise exception 'A GeoJSON Polygon or MultiPolygon is required' using errcode='22023';
  end if;

  v_geom := extensions.st_geomfromgeojson(p_geojson::text);
  if extensions.st_srid(v_geom)=0 then
    v_geom := extensions.st_setsrid(v_geom,4326);
  end if;
  if extensions.st_srid(v_geom)<>4326
     or extensions.st_geometrytype(v_geom) not in ('ST_Polygon','ST_MultiPolygon')
     or not extensions.st_isvalid(v_geom)
     or extensions.st_isempty(v_geom) then
    raise exception 'Boundary must be a valid, non-empty WGS84 Polygon or MultiPolygon' using errcode='22023';
  end if;

  select * into v_pincode from public.service_area_pincodes where id=p_pincode_id for update;
  if not found then raise exception 'Pincode not found' using errcode='P0002'; end if;

  v_before := jsonb_build_object(
    'pincode',v_pincode.pincode,
    'boundary_set',v_pincode.boundary is not null
  );

  update public.service_area_pincodes
  set boundary=extensions.st_multi(v_geom)::extensions.geography,
      updated_at=now()
  where id=p_pincode_id
  returning jsonb_build_object('id',id,'pincode',pincode,'boundary_set',true,'updated_at',updated_at)
  into v_after;

  insert into public.admin_audit_logs(actor_user_id,action,target_table,target_id,before_data,after_data)
  values(p_actor,'pincode.boundary_updated','service_area_pincodes',p_pincode_id::text,v_before,v_after);

  return v_after;
end;
$$;

revoke all on function public.admin_set_pincode_boundary(uuid,bigint,jsonb)
from public,anon,authenticated;
grant execute on function public.admin_set_pincode_boundary(uuid,bigint,jsonb)
to service_role;

