-- Allow safe self-service profile fields without account or role escalation.
grant update (full_name, avatar_url, phone_e164) on public.profiles to authenticated;
create policy profiles_update_own on public.profiles
for update to authenticated using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

-- Drivers may edit vehicle details during onboarding, but not approval or availability.
grant update (vehicle_registration, vehicle_make, vehicle_model, vehicle_color)
on public.driver_profiles to authenticated;
create policy driver_profiles_update_own_onboarding on public.driver_profiles
for update to authenticated
using ((select auth.uid()) = user_id and verification_status in ('pending','under_review'))
with check ((select auth.uid()) = user_id and verification_status in ('pending','under_review') and availability_status = 'offline');
