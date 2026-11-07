-- Deny client access to the audit log and cover foreign-key lookups.
create policy ride_events_no_client_access on public.ride_events
for all to anon, authenticated using(false) with check(false);
create index driver_profiles_vehicle_category_idx on public.driver_profiles(vehicle_category_id);
create index fare_configs_vehicle_category_idx on public.fare_configs(vehicle_category_id);
create index ride_events_actor_user_idx on public.ride_events(actor_user_id);
create index rides_service_area_idx on public.rides(service_area_id);
create index rides_vehicle_category_idx on public.rides(vehicle_category_id);
create index user_roles_assigned_by_idx on public.user_roles(assigned_by);
