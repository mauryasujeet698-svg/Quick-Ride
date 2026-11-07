# Quick-Ride

Independent on-demand ride-hailing platform designed for India, with real-time driver discovery, smart dispatch, configurable commercial rules, trip tracking and operations controls.

> Current status: backend foundations and three functional Flutter app flows are in active development on `feature/platform-core`. This is not a production release or a tested device release.

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
| Customer | Service-area lookup, pickup/destination, fare quote, booking, driver tracking, OTP, history, support and safety |
| Driver | Onboarding, service-area applications, availability, GPS, offers, navigation, ride lifecycle and earnings |
| Admin | Service areas and pincodes, commercial model, geographic boundaries, driver verification, operations and reporting |

## Technology

Flutter workspace, Riverpod 3, go_router, shared domain/auth/design packages, Supabase Auth/PostgreSQL/PostGIS/Realtime/Edge Functions, Mapbox and Firebase Cloud Messaging.

## Backend foundation

The connected Supabase project is in Mumbai (ap-south-1) on PostgreSQL 17 with PostGIS in the extensions schema.

The schema currently contains 26 public tables with RLS enabled. Major modules include:
- Pincode service-area catalog and geographic coverage boundaries.
- Effective-dated subscription/commission/hybrid configurations.
- Fare rules and snapshots.
- Driver document and service-pincode verification.
- Nearby-driver dispatch, expiring offers and ride chaining.
- GPS trace, pickup OTP, ride lifecycle and audit trail.
- Payment records, commission records and ledger entries.

Deployed Edge Functions (JWT verification enabled):
- `admin-service-areas` (v8)
- `ride-booking` (v2)
- `driver-ride-actions` (v2)

Critical booking, driver eligibility, dispatch acceptance and trip transitions are server-authoritative. Deployed function source is in supabase/functions; generated database types are in supabase/types.

## Development

Active platform integration branch: feature/platform-core.

See the development status, architecture, security, Google sign-in setup and owner setup documents in docs/.

No service areas, fare rules, pincode boundaries, admin account or production credentials have been seeded yet. Mapbox server secrets, OAuth, FCM, payment provider and release signing remain owner setup steps.

Never commit Supabase service-role keys, database passwords, OAuth client secrets, signing keystores or FCM service-account keys. No open-source license has been selected; all rights are reserved unless a license is added.
