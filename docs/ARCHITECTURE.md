# Quick-Ride — Technical Architecture

## Approach
Begin with a modular monolith: Flutter clients, Supabase Auth, PostgreSQL/PostGIS and a small set of server-side Edge Functions. Keep boundaries clear so dispatch, pricing or notifications can be separated later if measured scale requires it. Avoid premature microservices.

## Planned repository structure
~~~
apps/
  customer_app/
  driver_app/
  admin_app/
packages/
  core/
  design_system/
  auth/
  maps/
  ride_domain/
  supabase_client/
  notifications/
supabase/
  migrations/
  functions/
docs/
~~~

Each Flutter app uses feature-first Clean Architecture:
~~~
lib/
  app/          # bootstrap, router, theme
  core/         # config, errors, network, utilities
  features/
    feature_name/
      data/
      domain/
      presentation/
~~~

## Client stack
Flutter/Dart, Riverpod, go_router, Supabase Flutter SDK, Mapbox and Firebase Cloud Messaging. Keep business logic out of widgets; repositories expose domain interfaces and domain use cases do not depend on Flutter widgets or Supabase transport models.

## Backend modules
- **Identity:** Supabase Auth; profiles; server-managed roles; operations-controlled driver approval.
- **Configuration:** service areas/boundaries, vehicle categories, effective-dated fare rules.
- **Booking/dispatch:** server validates area and coordinates, calculates fare, creates request, discovers drivers, creates expiring offers and atomically assigns a driver.
- **Live location:** PostGIS nearby queries; carefully scoped Realtime; no location disclosure to unrelated users.
- **Notifications:** FCM for push; Realtime for in-app updates. Push is never the source of truth.

## Transaction rules
Backend owns all ride transitions, uses row locking/atomic SQL for acceptance, enforces expiry using server time, makes retries idempotent, rejects invalid transitions, snapshots fare inputs and writes audit events. Mobile apps must not directly update ride status, assignment, fare or timestamps.

## Data model
Deployed tables: profiles, user_roles, driver_profiles, service_areas, vehicle_categories, fare_configs, rides, ride_offers, driver_locations and ride_events. PostGIS is in the extensions schema; geography points use SRID 4326.

## Secrets and deployment
Client may contain Supabase URL/publishable key, public Mapbox token and public OAuth client IDs. Never include service-role/secret keys, Google client secrets, private signing keys or FCM service-account JSON in mobile source or public artifacts. Separate dev/prod credentials. Commit migrations, verify them and run Supabase advisors after schema changes. Add CI once Flutter workspace exists.

## Scaling
Tune PostGIS queries/indexes; bound location frequency and retention; subscribe selectively to Realtime; add queue/retry infrastructure as needed; separate workers/services only when measured load justifies it.
