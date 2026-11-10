# Quick-Ride — Technical Architecture

## Approach

Start with a modular backend: three Flutter applications, shared client packages, Supabase Auth, PostgreSQL/PostGIS and server-side Edge Functions. Keep module boundaries explicit; separate services only when measured load or operational ownership justifies it.

## Repository structure

    apps/
      customer_app/
      driver_app/
      admin_app/
    packages/
      quick_ride_core/
      quick_ride_backend/
      quick_ride_auth/
      quick_ride_design_system/
      quick_ride_maps/
      quick_ride_domain/
      quick_ride_notifications/
    supabase/
      config.toml
      functions/
      migrations/
      types/
    docs/

Each app will evolve into feature-first Clean Architecture with app bootstrap/router/theme, core config/errors/networking and feature data/domain/presentation layers.

## Commercial configuration

Commercial terms are stored per service pincode and are effective-dated:
- Subscription: amount and billing period.
- Commission: percentage of completed ride fare.
- Hybrid: subscription plus commission.

The selected model and terms are snapshotted on each ride when booked. Later Admin changes must not alter an existing ride's terms.

## Geospatial and dispatch

PostGIS geography and spatial indexes are authoritative for radius matching; a generated geohash is available for location-cell grouping and diagnostics. Nearby driver search applies service-pincode membership, active-pincode selection, verification, online state, location freshness, vehicle class, active ride/offer exclusions and subscription eligibility.

Dispatch creates expiring offers in batches and can expand search radius. Ride-chain discovery finds drivers on an in-progress ride whose destination is near a new pickup. A driver may preaccept, but a next ride is only assigned after the current ride is completed and the candidate ride is still available.

## Backend transaction rules

Server functions validate the JWT and derive user identity from it. PostgreSQL routines own booking, commercial snapshots, driver eligibility, assignment, ride status, OTP checks, completion and commission ledger entries. Row locks and unique constraints prevent double assignments. Client apps must not write assignment, fare, status or admin role fields directly.

## Backend modules

The data model includes profiles and roles, driver profiles/documents/service-pincode memberships, service areas/pincodes/commercial and dispatch configuration, vehicle and fare configuration, rides/offers/events, driver locations and ride GPS traces, chain offers, payment/commission/ledger records, safety/support and admin audit logs.

Current Edge Functions:
- admin-service-areas: pincode and commercial management, boundary management, driver approvals.
- ride-booking: quote, booking, cancellation and initial dispatch.
- driver-ride-actions: onboarding, pincode requests, location, offers, ride transitions and completion.
- ride-share: public read-only trip page protected by a random 256-bit bearer token; the database stores only a SHA-256 token hash, links expire after 12 hours, and the customer can revoke or replace them.
- send-push: service-role-only Firebase Cloud Messaging HTTP v1 sender for authenticated customer, driver and admin devices; device tokens are scoped to the owning user by RLS.

## Live location and privacy

Driver location is accepted only for verified drivers with an approved availability state. Ride GPS points are stored while a ride is in progress. Customer access to precise driver location is restricted to an assigned active ride. Realtime is used for in-app live state; Firebase Cloud Messaging complements it for background/terminated app alerts and foreground in-app notices. Trip-share access is a separate bearer-link path with expiration and revocation, and returns no customer phone number or profile data.

## External setup

Supabase URL and publishable key may be supplied to clients. Supabase service-role key remains in server secrets. Maps are rendered natively with `flutter_map` using OpenStreetMap-compatible raster tiles; Mapbox Search Box, reverse geocoding and Directions remain REST-only services. No WebView, Mapbox native Maps SDK or Mapbox Maven download credential is needed. Configure `OSM_TILE_URL` to a suitably licensed hosted or self-hosted tile service before commercial production traffic; the public OSM standard tile server is best-effort and is not a production SLA. Google OAuth settings, FCM credentials, payment provider integration and release signing require owner configuration.
