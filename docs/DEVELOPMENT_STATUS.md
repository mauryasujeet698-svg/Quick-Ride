# Quick-Ride development status

Last updated: 2026-11-07

## Current state

- The original repository foundation and security baseline are retained.
- Platform work is isolated on `feature/platform-core`.
- Supabase has pincode-scoped commercial rules, geographic pickup boundaries, driver service-area approvals, dispatch batches, provisional ride-chain offers, financial records, GPS points, OTP attempts and audit records.
- Three server-side Edge Functions are deployed: `admin-service-areas`, `ride-booking`, and `driver-ride-actions`.
- Customer and Driver Flutter foundations are committed; Admin configuration screen is being added. These are starter integrations, not release-complete apps.

## Verified safeguards

- RLS is enabled on public application tables.
- Security and health advisors returned no findings after hardening.
- Authenticated clients cannot insert rides directly.
- Commercial configuration changes use a transactional effective-dated database function.
- Dispatch requires driver approval, pincode approval, fresh GPS, vehicle-class match and any active subscription requirement.
- Ride-chain acceptance is provisional until the current ride completes.
- Pickup OTP hashes use bcrypt and attempts are rate-limited.
- Final fare is calculated server-side using GPS trace when sufficient reliable points exist, otherwise saved route estimates.

## Not yet production-complete

- No service areas, pincode polygons, fare rules, approved drivers, driver memberships or admin accounts have been seeded.
- Mapbox server/public credentials and native SDK download token remain owner setup steps.
- Google OAuth settings and native deep-link registrations are not configured.
- FCM and payment provider credentials/webhooks are not configured.
- Background GPS, poor-network recovery, physical-device testing, cancellation-fee policy, support workflows, analytics and load testing remain outstanding.
- Android release signing and production APK delivery are not configured.

See `docs/SECRETS_AND_OWNER_SETUP.md` for required owner actions.
