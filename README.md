# Quick-Ride

Independent on-demand ride-hailing platform for India. Designed around real-time driver discovery, reliable dispatch, configurable fares, trip safety and independent driver-partners.

> **Status:** Foundation stage. Initial Supabase schema and security baseline are deployed. Flutter apps, dispatch services, admin tooling and production integrations are not yet implemented.

## Product principles
- On-demand rides, not scheduled carpooling.
- Original requirements, schema, APIs and implementation.
- Configurable service areas, vehicle categories, fare rules and driver business models.
- Google sign-in through Supabase Auth; privileged roles and driver approval are server-controlled.
- Guest browsing is supported; sign-in is required for booking and protected actions.
- Start with a modular backend; split services only when measured scale requires it.

## Planned apps
| App | Responsibilities |
| --- | --- |
| Customer | Pickup/destination, fare estimate, ride request, driver details, live tracking, trip OTP, history, support and safety |
| Driver | Onboarding, verification, online/offline, GPS, offers, navigation, trip lifecycle and earnings |
| Admin / operations | Driver verification, service areas, categories, fares, ride monitoring, support and reports |

## Technology
Flutter, feature-first Clean Architecture, Riverpod, go_router, Supabase Auth/Postgres/PostGIS/Realtime/Edge Functions, Mapbox and Firebase Cloud Messaging.

## Deployed backend foundation
- Supabase project Quick ride, Mumbai region; PostgreSQL 17.
- PostGIS installed in the extensions schema.
- Ten tables: profiles, user_roles, driver_profiles, service_areas, vehicle_categories, fare_configs, rides, ride_offers, driver_locations and ride_events.
- RLS enabled on all ten tables.
- Role assignment, driver approval, ride assignment and ride-state transitions are not client-controlled.
- Active service configuration can be read without login.
- Driver location access is limited to the driver and customers with an active assigned ride.

See [Google Sign-In Setup](docs/GOOGLE_AUTH_SETUP.md) for the OAuth configuration that must be completed in the owner accounts. Database migrations are stored under supabase/migrations and are aligned to the remote Supabase migration versions.\n\n## Next milestones
1. Confirm pilot city, vehicle categories, fare policy, cancellation rules, driver commercial model and payment/settlement responsibilities.
2. Configure Google OAuth in Google Cloud and Supabase Auth.
3. Build customer and driver Flutter apps with guest browsing.
4. Implement server-side pricing, dispatch, expiring offers, atomic assignment and ride transitions.
5. Add operations tooling, verification, maps, push, safety workflows and production testing.

Never commit Supabase service-role/secret keys, Google client secrets, signing keystores or FCM service-account files. No open-source license has been selected; all rights are reserved until one is added.
