# Quick-Ride development status

Last updated: 2026-11-07

## Current state

- Platform backend foundation is deployed in Supabase and source migrations are tracked on `feature/platform-core`.
- The schema has 26 public application tables with RLS enabled. Security and health advisors returned no findings after the latest tracking and driver-document policy changes. Automated advisor output is not a substitute for a full security audit.
- Three Edge Functions are deployed: `admin-service-areas`, `ride-booking`, and `driver-ride-actions`. The branch now contains updated source for driver document registration and Admin document review; redeployment of these updated function versions is the next backend-code deployment step.
- Customer app: guest service-area lookup, vehicle categories, pickup/destination selection, fare quote and booking, pickup OTP, active-ride tracking map, driver and vehicle details, ride history, early-stage cancellation, ride-specific support requests and profile/navigation screens.
- Driver app: Google sign-in, vehicle application, service-pincode requests, private PDF/JPG/PNG KYC upload, document status, availability, GPS updates, ride/chain offers and trip lifecycle.
- Admin app: service-area/pincode setup, boundaries and pincode-level commercial configuration, driver application review, time-limited private document previews, individual document approval/rejection and service-pincode review.
- Flutter formatting, static analysis and smoke tests have passed for the document-upload source commit. The following commit, which tightens Storage upload policy to require a pending driver application, is in its CI run.
- Android QA workflow builds Customer, Driver and Admin debug APKs when the required GitHub Actions configuration is present. APKs have not been produced yet because those values are still missing.

## Backend safeguards

- Ride booking remains server-authoritative; authenticated clients cannot directly create rides.
- Fare and commercial terms are snapshotted on each ride; subscription, commission and hybrid models are independently configured by service pincode.
- Dispatch eligibility checks driver approval, service-pincode approval, fresh GPS, vehicle class and any applicable active subscription.
- Ride chaining remains provisional until the current ride completes.
- Pickup OTP hashes are stored server-side and attempts are rate-limited.
- Customer tracking data is returned by a SECURITY INVOKER RPC that checks authenticated customer ownership. Driver location is returned only for an active ride and only when the GPS fix is recent.
- Driver KYC files live in a private Storage bucket, limited to PDF/JPG/PNG and 5 MB. Upload is restricted to the signed-in owner's folder and a pending driver profile. Metadata is registered server-side. Admin receives short-lived signed URLs, and driver approval is blocked until a valid driving licence, vehicle RC and insurance are approved.

## Still needed before a real pilot

- No service areas, verified pincode polygons, fare rules, Admin account, approved driver accounts or approved driver service-pincode memberships have been seeded.
- `MAPBOX_ACCESS_TOKEN` must be set as a Supabase Edge Function secret. Mobile Mapbox public token and native SDK download token are owner-supplied.
- Google OAuth provider settings and native deep-link registrations still require owner configuration.
- Updated Edge Function versions need deployment and verification against configured test users.
- FCM push delivery and payment-provider integration/webhooks have not been implemented.
- Android QA APKs remain blocked by missing GitHub Actions variable/secrets; no APK artifact has been produced.
- Physical-device background GPS, battery, location permission and poor-network recovery testing, load testing, operational analytics and production signing remain outstanding.

See `docs/SECRETS_AND_OWNER_SETUP.md` and `docs/KYC_AND_DRIVER_ONBOARDING.md`.
