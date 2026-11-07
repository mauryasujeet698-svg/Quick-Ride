-- Explicit Data API grants for Supabase's no-auto-exposure default.
grant usage on schema public to anon, authenticated;
grant select on public.service_areas, public.vehicle_categories, public.fare_configs to anon, authenticated;
grant select, insert on public.profiles to authenticated;
grant select on public.user_roles to authenticated;
grant select, insert on public.driver_profiles to authenticated;
grant select, insert on public.rides to authenticated;
grant select on public.ride_offers to authenticated;
grant select, insert, update on public.driver_locations to authenticated;
-- No client access is granted to ride_events or role-management writes.
