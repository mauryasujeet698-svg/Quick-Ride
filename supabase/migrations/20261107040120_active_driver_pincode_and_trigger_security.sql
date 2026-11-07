do $$
declare v_def text;
begin
  v_def:=pg_get_functiondef('public.find_nearby_drivers(uuid,text,bigint,bigint,integer,integer)'::regprocedure);
  if position('dp.active_pincode_id=p_pincode_id' in v_def)=0 then
    v_def:=replace(v_def,'and dp.availability_status=''online''',
      'and dp.availability_status=''online'' and dp.active_pincode_id=p_pincode_id');
  end if;
  execute v_def;

  v_def:=pg_get_functiondef('public.find_ride_chain_candidates(uuid)'::regprocedure);
  if position('dp.active_pincode_id=v_next.pincode_id' in v_def)=0 then
    v_def:=replace(v_def,'and dp.availability_status=''busy''',
      'and dp.availability_status=''busy'' and dp.active_pincode_id=v_next.pincode_id');
  end if;
  execute v_def;

  v_def:=pg_get_functiondef('public.accept_ride_offer(uuid,uuid)'::regprocedure);
  if position('v_driver.active_pincode_id' in v_def)=0 then
    v_def:=replace(v_def,'or v_driver.vehicle_category_id<>v_ride.vehicle_category_id then',
      'or v_driver.vehicle_category_id<>v_ride.vehicle_category_id
     or v_driver.active_pincode_id is distinct from v_ride.pincode_id then');
  end if;
  execute v_def;
end $$;

revoke all on function public.snapshot_ride_fare_config() from public,anon,authenticated;

