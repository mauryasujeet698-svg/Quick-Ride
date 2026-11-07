# Quick-Ride

Independent on-demand ride-hailing platform designed for India, with real-time driver discovery, smart dispatch, configurable commercial rules, live trip tracking and operations controls.

> Current status: the three Flutter app flows and Supabase backend are in active development on `feature/platform-core`. This is not a production release or a device-validated build.

## Product principles

- On-demand rides with customer and driver experiences.
- Subscription, commission or hybrid model configurable independently per service pincode.
- India-wide architecture; service areas are activated independently.
- Google sign-in through Supabase Auth; authentication does not grant driver or administrator privileges.
- Guest users can explore; sign-in is required for booking and protected actions.
- Modular backend; avoid premature microservices.

## Applications

| App | Responsibility |
| --- | --- |
| Customer | Service-area lookup, pickup/destination map, server fare quote, booking, live driver tracking, OTP, ride history, cancellation reasons, support, SOS dialer and revocable trip sharing |
| Driver | Onboarding, service-area applications, availability, GPS, offers, in-app navigation, OTP ride lifecycle, earnings and SOS dialer |
| Admin | Service areas and pincodes, commercial/fare/dispatch configuration, driver verification, operational support, safety-event review and reporting |

## Technology

Flutter workspace, Riverpod 3, go_router, shared domain/auth/design/notification packages, Supabase Auth/PostgreSQL/PostGIS/Realtime/Edge Functions, Mapbox and Firebase Cloud Messaging.

## Backend foundation

The connected Supabase project is in Mumbai (ap-south-1) on PostgreSQL 17 with PostGIS in the extensions schema.

The schema contains 28 public application tables with RLS enabled. Supabase security and health advisors report no current findings; performance advisories are limited to duplicate permissive profile SELECT policies and unused indexes on an empty pre-pilot database. Major modules include:
- Pincode service-area catalog and geographic coverage boundaries.
- Effective-dated subscription/commission/hybrid configurations and fare rules.
- Driver document and service-pincode verification.
- Nearby-driver dispatch, expiring offers and ride chaining.
- GPS trace, pickup OTP, ride lifecycle and audit trail.
- Payment records, commission records and ledger entries.
- Hash-only, revocable and expiring trip-share links.

Deployed Supabase Edge Functions:
- `admin-service-areas` (v11, JWT verified)
- `ride-booking` (v6, JWT verified)
- `driver-ride-actions` (v6, JWT verified)
- `ride-share` (v1, JWT disabled; every request must present a valid high-entropy share token)
- `send-push` (v3, JWT disabled; requires the exact Supabase service-role bearer token and uses the server-side Firebase service account)

Critical booking, fare, driver eligibility, dispatch acceptance and trip transitions are server-authoritative. The ride-share endpoint validates the token hash, expiration and revocation state before returning its restricted live-trip snapshot. The `send-push` endpoint requires the Supabase service-role bearer token and sends Firebase Cloud Messaging notifications to authenticated devices. Function source is in `supabase/functions`; database migrations are in `supabase/migrations`.

The app can record an SOS event, notify registered Admin devices through FCM when Firebase is configured, and open the Indian 112 emergency dialer, but Quick-Ride does not directly contact emergency responders. The Operations safety queue refreshes only while the screen is open; do not treat the app as a 24/7 emergency response service. FCM delivery requires Firebase app identifiers and the server-side `FCM_SERVICE_ACCOUNT_JSON` secret.

## Development

Active platform integration branch: `feature/platform-core`.

See the development status, architecture, security, Google sign-in setup and owner setup documents in `docs/`.

The live database has not been seeded with service areas, approved pincodes, fare/category configuration, admin account or driver accounts. Owner-supplied Mapbox downloads/public tokens, Google OAuth, Firebase/FCM credentials, payment-provider settings and release signing remain setup/integration tasks. Android APKs are blocked until `MAPBOX_DOWNLOADS_TOKEN` is added as a GitHub Actions secret; source CI does not substitute for native device testing.

Never commit Supabase service-role keys, database passwords, OAuth client secrets, signing keystores or FCM service-account keys. No open-source license has been selected; all rights are reserved unless a license is added.
