do $$
declare
  v_def text;
begin
  v_def:=pg_get_functiondef('public.find_nearby_drivers(uuid,text,bigint,bigint,integer,integer)'::regprocedure);
  v_def:=replace(v_def,
    'and dsp.driver_id=dp.user_id and dsp.pincode_id=p_pincode_id and dsp.status=''active''',
    'and dsp.driver_id=dp.user_id and dsp.pincode_id=p_pincode_id and dsp.status=''active''');
  v_def:=replace(v_def,
    'and dp.availability_status=''online''',
    'and dp.availability_status=''online'' and dp.active_pincode_id=p_pincode_id');
  execute v_def;

  v_def:=pg_get_functiondef('public.find_ride_chain_candidates(uuid)'::regprocedure);
  v_def:=replace(v_def,
    'and dp.availability_status=''busy''',
    'and dp.availability_status=''busy'' and dp.active_pincode_id=v_next.pincode_id');
  execute v_def;

  v_def:=pg_get_functiondef('public.accept_ride_offer(uuid,uuid)'::regprocedure);
  v_def:=replace(v_def,
    'or v_driver.vehicle_category_id<>v_ride.vehicle_category_id then',
    'or v_driver.vehicle_category_id<>v_ride.vehicle_category_id
     or v_driver.active_pincode_id is distinct from v_ride.pincode_id then');
  execute v_def;

  v_def:=pg_get_functiondef('public.create_ride_chain_offer_batch(uuid)'::regprocedure);
  v_def:=replace(v_def,
    'select * from public.find_ride_chain_candidates(p_next_ride_id)
    limit v_batch_size',
    'select candidates.* from public.find_ride_chain_candidates(p_next_ride_id) candidates
    where not exists (
      select 1 from public.ride_chain_offers previous
      where previous.next_ride_id=p_next_ride_id and previous.driver_id=candidates.driver_id
    )
    order by candidates.estimated_seconds_to_destination nulls last,
      candidates.distance_to_next_pickup_m
    limit v_batch_size');
  execute v_def;
end $$;

create or replace function public.rotate_ride_pickup_otp(
  p_customer_id uuid,
  p_ride_id uuid,
  p_otp_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.rides%rowtype;
begin
  if p_otp_sha256 is null or length(p_otp_sha256)<>64 then
    raise exception 'Invalid pickup OTP token' using errcode='22023';
  end if;
  select * into v_ride from public.rides
  where id=p_ride_id and customer_id=p_customer_id
  for update;
  if not found then raise exception 'Ride not found' using errcode='P0002'; end if;
  if v_ride.status not in ('requested','searching','offered') then
    raise exception 'Pickup OTP can no longer be changed for this ride' using errcode='P0001';
  end if;

  update public.rides
  set pickup_otp_hash=extensions.crypt(p_otp_sha256,extensions.gen_salt('bf',10))
  where id=p_ride_id;

  return jsonb_build_object('ride_id',p_ride_id,'otp_rotated',true);
end;
$$;

create or replace function public.customer_cancel_ride(
  p_customer_id uuid,
  p_ride_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.rides%rowtype;
begin
  select * into v_ride from public.rides
  where id=p_ride_id and customer_id=p_customer_id
  for update;
  if not found then raise exception 'Ride not found' using errcode='P0002'; end if;
  if v_ride.status not in ('requested','searching','offered','accepted','driver_arriving','arrived') then
    raise exception 'Ride can no longer be cancelled' using errcode='P0001';
  end if;

  update public.rides
  set status='cancelled',
      cancelled_at=now(),
      cancellation_reason=left(coalesce(nullif(btrim(p_reason),''),'customer_cancelled'),250)
  where id=p_ride_id;

  update public.ride_offers
  set status='withdrawn',responded_at=now()
  where ride_id=p_ride_id and status='pending';

  update public.ride_chain_offers
  set status='withdrawn',responded_at=now()
  where next_ride_id=p_ride_id and status in ('offered','preaccepted');

  if v_ride.driver_id is not null then
    update public.driver_profiles
    set availability_status='online'
    where user_id=v_ride.driver_id and availability_status='busy';
  end if;

  insert into public.ride_events(ride_id,actor_user_id,event_type,previous_status,new_status,details)
  values(p_ride_id,p_customer_id,'customer_cancelled',v_ride.status,'cancelled',
    jsonb_build_object('reason',left(coalesce(p_reason,''),250)));

  return jsonb_build_object('ride_id',p_ride_id,'status','cancelled','cancellation_fee',0);
end;
$$;

revoke all on function public.rotate_ride_pickup_otp(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.customer_cancel_ride(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.rotate_ride_pickup_otp(uuid,uuid,text) to service_role;
grant execute on function public.customer_cancel_ride(uuid,uuid,text) to service_role;

