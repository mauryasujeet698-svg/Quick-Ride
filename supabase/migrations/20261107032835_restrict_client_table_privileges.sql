-- Replace broad default client grants with a strict allow-list.
revoke all privileges on all tables in schema public from anon, authenticated;
revoke all privileges on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
grant select on public.service_areas, public.vehicle_categories, public.fare_configs to anon, authenticated;
grant select, insert on public.profiles to authenticated;
grant select on public.user_roles to authenticated;
grant select, insert on public.driver_profiles to authenticated;
grant select, insert on public.rides to authenticated;
grant select on public.ride_offers to authenticated;
grant select, insert, update on public.driver_locations to authenticated;
