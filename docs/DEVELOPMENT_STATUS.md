# Quick-Ride development status

Last updated: 2026-11-07

## Current state

- Platform backend foundation is deployed in Supabase and source migrations are tracked in `feature/platform-core`.
- The schema contains 26 public tables with RLS enabled; the Supabase security and health advisors returned no findings in the last recorded check. This is an automated advisory result, not a complete security audit.
- Three server-side Edge Functions are deployed: `admin-service-areas`, `ride-booking`, and `driver-ride-actions`.
- Customer app: ride-first home screen, guest service-area lookup, vehicle categories from Supabase, Google sign-in entry points, pickup/destination and quote/booking flow, booking pickup OTP, live ride-status subscription, ride history, early-stage cancellation, support requests tied to a selected ride, and profile/navigation screens.
- Driver app: Google sign-in, driver application, service-pincode requests, approval state, availability, GPS updates, ride/chain offers and trip lifecycle controls.
- Admin app: service-area and pincode setup, boundary and commercial configuration, driver review and service-pincode operations.
- Flutter static analysis has passed for all three apps on a recent CI run. The latest smoke-test run is being rechecked after correcting a scroll-dependent customer test.
- Android QA workflow is present and creates Customer, Driver and Admin debug APK artifacts when its required GitHub Actions values are configured.

## Backend safeguards retained

- Authenticated clients cannot create rides directly; booking is routed through the server-side Edge Function and database function.
- Commercial configuration is pincode-scoped and effective-dated; the ride stores a snapshot of the fare and commercial terms used at booking.
- Dispatch eligibility includes approved drivers, approved pincode membership, fresh GPS, matching vehicle class and any applicable active subscription.
- Ride-chain acceptance remains provisional until the current ride completes.
- Pickup OTP hashes are stored server-side and attempts are rate-limited.
- Final fare reconciliation is server-side, using the recorded GPS trace when sufficient points exist and the saved route estimate otherwise.
- Customer driver-location reads are restricted by RLS to an active ride between that customer and driver.

## Not yet ready for live pilot

- No active service areas, verified pincode polygons, fare rules, admin account, approved driver accounts or driver pincode memberships have been seeded.
- The `MAPBOX_ACCESS_TOKEN` Edge Function secret is not configured. The public Mapbox token and native SDK download token are not available in the GitHub Actions environment.
- Google OAuth provider settings and native deep-link registrations still require owner configuration.
- FCM push notifications and payment provider integration/webhooks have not been implemented/configured.
- Android QA APKs have not yet been produced: the last build attempt stopped at preflight because the required GitHub Actions variable/secrets were empty.
- Background GPS and poor-network recovery have not been verified on physical devices. Load testing, full operational support tooling, analytics and production signing remain outstanding.

See `docs/SECRETS_AND_OWNER_SETUP.md` for required owner actions before building and testing on a phone.
