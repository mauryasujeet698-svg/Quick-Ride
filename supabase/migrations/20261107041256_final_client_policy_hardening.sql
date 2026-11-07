drop policy if exists ride_dispatch_attempts_deny_client_access on public.ride_dispatch_attempts;
create policy ride_dispatch_attempts_deny_client_access
on public.ride_dispatch_attempts for all to anon,authenticated
using(false) with check(false);

drop policy if exists ride_otp_attempts_deny_client_access on public.ride_otp_attempts;
create policy ride_otp_attempts_deny_client_access
on public.ride_otp_attempts for all to anon,authenticated
using(false) with check(false);

revoke all on function public.snapshot_ride_fare_config() from public,anon,authenticated;

