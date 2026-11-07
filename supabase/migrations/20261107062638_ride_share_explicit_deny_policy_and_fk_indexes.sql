create policy ride_share_links_no_client_access
on public.ride_share_links
for all
to anon, authenticated
using (false)
with check (false);

create index if not exists ride_share_links_created_by_idx
  on public.ride_share_links (created_by);

create index if not exists driver_profiles_active_pincode_id_idx
  on public.driver_profiles (active_pincode_id);

create index if not exists driver_service_pincodes_reviewed_by_idx
  on public.driver_service_pincodes (reviewed_by);

create index if not exists ride_otp_attempts_driver_idx
  on public.ride_otp_attempts (driver_id);
