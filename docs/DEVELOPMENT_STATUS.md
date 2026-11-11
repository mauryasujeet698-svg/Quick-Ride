# Quick-Ride development status

Last updated: 2026-11-10

## Current state

- Active development branch: `feature/platform-core`.
- The connected Supabase project is healthy in `ap-south-1` (Mumbai), PostgreSQL 17.
- The public schema contains 28 application tables. Row-level security is enabled on all 28 tables. Supabase security and health advisors report no current findings. Performance advisories remain limited to duplicate permissive SELECT policies on the profile tables and unused indexes on this empty pre-pilot database; no unindexed foreign keys remain.
- A new private `ride_share_links` table stores only SHA-256 token hashes. Direct `anon` and `authenticated` table access is revoked; the share snapshot SQL function is SECURITY INVOKER and executable only by `service_role`.
- Five Supabase Edge Functions are ACTIVE:
  - `admin-service-areas` version 11 — JWT verification enabled.
  - `ride-booking` version 6 — JWT verification enabled.
  - `driver-ride-actions` version 6 — JWT verification enabled.
  - `ride-share` version 1 — JWT verification disabled only because it validates a high-entropy, expiring bearer token itself. No ride data is returned without a valid link token.
  - `send-push` version 3 — JWT verification disabled only because it requires an exact Supabase service-role bearer token; sends FCM HTTP v1 messages to registered devices.
- Customer app source includes service-area lookup, pickup/destination map selection and markers, server-calculated fare quote with route line, ride booking, pickup OTP, active-ride Realtime tracking, driver/vehicle details, route distance and ETA, ride history, cancellation reasons, ride-linked support, emergency dialer and revocable live-trip sharing.
- Driver app source includes Google sign-in, vehicle application, service-pincode requests, private KYC uploads, document status, online/offline controls, GPS sharing, ride and chain offers, pickup/destination Mapbox Streets tile rendering with Mapbox REST route guidance, OTP-based ride lifecycle, earnings/commission summary, payment/ledger status and emergency dialer.
- Admin app source includes service-area and pincode setup, boundary activation, pincode commercial models, vehicle category management, effective-dated fare rules, per-pincode dispatch controls, driver/document/pincode review, operational dashboard, support-ticket handling and a safety-event review queue.
- Operations polls only the safety-event queue every 30 seconds while that screen is open; it does not poll when signed out or closed.
- Flutter CI includes Dart formatting, static analysis, Flutter smoke tests and Deno type-checking for all five Supabase Edge Functions. Latest runs are tracked in [Quick-Ride CI](https://github.com/mauryasujeet698-svg/Quick-Ride/actions/workflows/ci.yml).
- Android QA workflow builds ABI-specific Customer, Driver and Admin APKs and checks each output against the strict 25 MB cap. The map source uses `flutter_map` with Mapbox Streets raster tiles and Mapbox REST for search/reverse geocoding/directions; the latest workflow run must validate tile access, dependency resolution, native Android compilation and actual APK sizes. Source CI alone does not substitute for physical-device testing.

## Backend safeguards

- Ride booking and fare calculation are server-authoritative; authenticated clients cannot directly create rides.
- Fare and commercial terms are snapshotted on each ride. Subscription, commission and hybrid models can be configured independently per service pincode.
- Dispatch eligibility checks driver approval, service-pincode approval, fresh GPS, vehicle class and any applicable active subscription.
- Dispatch settings are configurable by pincode, including search radii, offer batch size/TTL, GPS age and ride-chain settings. Server-side validation enforces supported ranges.
- Ride chaining remains provisional until the current trip completes.
- Pickup OTP hashes are stored server-side and attempts are rate-limited.
- Customer tracking RPC checks authenticated customer ownership. Driver navigation RPC checks the assigned driver. Driver locations are exposed to the customer only for an active ride.
- Ride-share links use 256-bit random tokens; only the SHA-256 hash is stored. Each link expires after 12 hours, creating a replacement revokes the previous link, and the owner can revoke all active links for the ride. The public page refreshes status/location every 15 seconds and hides GPS fixes older than two minutes. It does not expose customer phone number or profile.
- Customer and driver SOS actions record a ride safety event when the platform connection is available, then open the Indian emergency dialer for 112. The user must confirm the call. Quick-Ride does not itself contact public emergency responders.
- KYC files live in a private Storage bucket, limited to PDF/JPG/PNG and 5 MB. Upload is restricted to the signed-in owner's folder and a pending driver profile. Admin receives short-lived signed URLs, and driver approval is blocked until a valid driving licence, vehicle RC and insurance are approved.
- Admin configuration and review operations are written to the audit log.

## Still needed before a real pilot

- The live database is intentionally not seeded: there are no Admin users, service areas, verified pincode polygons, vehicle categories, fare rules, approved driver accounts or approved driver service-pincode memberships.
- The first Google-authenticated owner must be assigned the Admin role through a trusted Supabase procedure after the account exists. Google OAuth provider settings and native deep-link registrations remain owner configuration.
- The repository includes public Supabase URL and publishable-key defaults for QA builds. Map tiles are served by Mapbox Streets and rendered through the lightweight `flutter_map` canvas; Mapbox REST access also powers search, reverse geocoding and directions. The CI workflow checks tile access. The app avoids a country-wide fallback and centres on the detected pickup/current location. Firebase app configuration values are optional for compiling but required to activate push registration. Keep private tokens out of chat and source control.
- Supabase Edge Function secrets must include the existing server-side Supabase settings. The `ride-booking` function optionally reads `OSRM_BASE_URL`; the default is the public OSRM demo server and should be replaced for production.
- FCM client registration and server-side event delivery are implemented in source and deployed through `send-push`. Actual delivery remains inactive until Firebase app identifiers and `FCM_SERVICE_ACCOUNT_JSON` are supplied and tested. Payment-provider integration/webhooks and a 24/7 human safety-response service are not implemented. The Operations safety queue is visible only while the screen is open; do not treat it as a 24/7 emergency monitoring service.
- Account deletion/retention policy, operational emergency SOP, abuse monitoring, release signing, physical-device background GPS/battery/permission tests, weak-network recovery tests, load testing and production acceptance remain outstanding.
- The driver navigation UI and background GPS flow still require physical-device validation. Source-level CI is not proof of native navigation or background-GPS behaviour.

See `docs/SECRETS_AND_OWNER_SETUP.md`, `docs/KYC_AND_DRIVER_ONBOARDING.md`, `docs/SECURITY.md` and `docs/ARCHITECTURE.md`.
