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

## Live location and privacy

Driver location is accepted only for verified drivers with an approved availability state. Ride GPS points are stored while a ride is in progress. Customer access to precise driver location is restricted to an assigned active ride. Realtime is used for live state; push notifications will complement it.

## External setup

Supabase URL and publishable key may be supplied to clients. Supabase service-role key remains in server secrets. Mapbox Directions server token is separate from the public mobile token and native SDK download token. Google OAuth settings, FCM credentials, payment provider integration and release signing require owner configuration.
