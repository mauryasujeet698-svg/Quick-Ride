# Quick-Ride Android build configuration

The Android workflow builds optimized Flutter Customer, Driver and Admin release APKs for `armeabi-v7a` and `arm64-v8a`. Every APK is checked against a strict 25,000,000-byte maximum.

Customer and Driver maps are rendered directly by Flutter using `flutter_map` and OpenStreetMap-compatible raster tiles. There is no WebView, native Mapbox Maps SDK or Mapbox Maven download credential. Mapbox remains the REST provider for Search Box, reverse geocoding and driving directions.

## GitHub Actions configuration

Configure these repository Actions secrets and variables before building:

| Name | Type | Purpose |
| --- | --- | --- |
| `MAPBOX_ACCESS_TOKEN` | Secret or variable | Public Mapbox runtime token beginning with `pk.`; validated against Search Box and Directions before the build |
| `OSM_TILE_URL` | Variable (optional) | OSM-compatible raster tile URL template. Defaults to the public OSM standard tile endpoint for development/QA only. |
| `GOOGLE_WEB_CLIENT_ID` | Secret or variable | Google OAuth Web application client ID used by native Google sign-in |
| `SUPABASE_PUBLISHABLE_KEY` | Secret | Supabase publishable/anon client key; never use a service-role key here |
| `SUPABASE_URL` | Variable | Supabase project URL |
| `FIREBASE_API_KEY` | Secret | Firebase client API key |
| `FIREBASE_PROJECT_ID` | Variable | Firebase project ID |
| `FIREBASE_MESSAGING_SENDER_ID` | Variable | Firebase messaging sender ID |
| `FIREBASE_CUSTOMER_APP_ID` | Secret | Firebase Android app ID for Customer |
| `FIREBASE_DRIVER_APP_ID` | Secret | Firebase Android app ID for Driver/Captain |
| `FIREBASE_ADMIN_APP_ID` | Secret | Firebase Android app ID for Admin |

The Mapbox public token is used only by REST endpoints for place search, address lookup and route calculation. It is not a native map-rendering credential. Never use a secret `sk.*` token as the runtime token.

The tile URL is configurable at build time with `OSM_TILE_URL`, so a production OSM-compatible provider or self-hosted tile service can be selected without changing Dart source. The public OpenStreetMap standard tile server is a best-effort community resource, has no service-level guarantee and must not be treated as the production tile backend for a commercial ride-hailing workload. Configure a suitable, licensed tile provider with a production support commitment before launch. Follow the provider's request-identification, attribution and caching requirements. The app displays OpenStreetMap contributor attribution.

## Google sign-in

Create a Google OAuth Web application client ID and configure Android OAuth clients for all three application IDs:

- `in.quickride.customer`
- `in.quickride.driver`
- `in.quickride.admin`

Register the SHA-1 signing certificate fingerprints used by the installed APKs in Google Cloud/Firebase. The Web client ID is supplied as `GOOGLE_WEB_CLIENT_ID`; native sign-in exchanges the Google ID token with Supabase Auth inside the app.

## Supabase

Apply the repository migrations and deploy the Edge Functions required by ride booking, driver ride actions, account deletion and push notifications. Configure Google as an enabled Supabase Auth provider and add the same Web client ID and client secret in the Supabase provider settings. Do not place the Supabase service-role key in any mobile build secret or Dart define.

## Validation and device acceptance

GitHub Actions runs Flutter analysis/tests, Edge Function type checks, shared Auto route-planner tests and the three Android builds. The build checks the Mapbox Search Box and Directions services before compiling. Automated CI does not replace physical-device acceptance testing for Google sign-in, GPS permissions, OSM tile rendering, place search/navigation, push notifications or driver/customer realtime tracking.

The current CI APK artifacts are unsigned QA/test builds unless a release signing configuration and keystore have been supplied. Do not publish the QA APKs to Play Store as production builds.
