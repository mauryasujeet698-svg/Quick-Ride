do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'rides',
    'ride_offers',
    'ride_chain_offers',
    'driver_locations',
    'ride_location_points',
    'ride_events',
    'driver_profiles',
    'driver_service_pincodes'
  ] loop
    if to_regclass('public.' || v_table) is not null
       and not exists (
         select 1 from pg_publication_tables
         where pubname='supabase_realtime'
           and schemaname='public'
           and tablename=v_table
       ) then
      execute format('alter publication supabase_realtime add table public.%I',v_table);
    end if;
  end loop;
end $$;

alter table public.rides replica identity full;
alter table public.ride_offers replica identity full;
alter table public.ride_chain_offers replica identity full;
alter table public.driver_locations replica identity full;
alter table public.ride_location_points replica identity full;
