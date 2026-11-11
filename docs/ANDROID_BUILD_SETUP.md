# Quick-Ride Android build configuration

The Android workflow builds optimized Flutter Customer, Driver and Admin release APKs for `armeabi-v7a` and `arm64-v8a`. Every APK is checked against a strict 25,000,000-byte maximum.

Customer and Driver maps are rendered directly by Flutter using `flutter_map` and Mapbox Streets raster tiles. There is no WebView or native Mapbox Maps SDK binary. Mapbox also provides Search Box, reverse geocoding and driving directions.

## GitHub Actions configuration

Configure these repository Actions secrets and variables before building:

| Name | Type | Purpose |
| --- | --- | --- |
| `MAPBOX_ACCESS_TOKEN` | Secret or variable | Public Mapbox runtime token beginning with `pk.`; validated against Search Box and Directions before the build |
| `MAPBOX_STYLE_ID` | Variable (optional) | Mapbox style ID. Defaults to `mapbox/streets-v12`. |
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

The map uses Mapbox Streets raster tiles with the public token supplied through `MAPBOX_ACCESS_TOKEN`. The style can be changed with `MAPBOX_STYLE_ID`; the default is `mapbox/streets-v12`. The app displays Mapbox and OpenStreetMap attribution. CI checks that the configured token can access Streets tiles.

## Google sign-in

Create a Google OAuth Web application client ID and configure Android OAuth clients for all three application IDs:

- `in.quickride.customer`
- `in.quickride.driver`
- `in.quickride.admin`

Register the SHA-1 signing certificate fingerprints used by the installed APKs in Google Cloud/Firebase. The Web client ID is supplied as `GOOGLE_WEB_CLIENT_ID`; native sign-in exchanges the Google ID token with Supabase Auth inside the app.

## Supabase

Apply the repository migrations and deploy the Edge Functions required by ride booking, driver ride actions, account deletion and push notifications. Configure Google as an enabled Supabase Auth provider and add the same Web client ID and client secret in the Supabase provider settings. Do not place the Supabase service-role key in any mobile build secret or Dart define.

## Validation and device acceptance

GitHub Actions runs Flutter analysis/tests, Edge Function type checks, shared Auto route-planner tests and the three Android builds. The build checks the Mapbox Search Box and Directions services before compiling. Automated CI does not replace physical-device acceptance testing for Google sign-in, GPS permissions, Mapbox tile rendering, place search/navigation, push notifications or driver/customer realtime tracking.

The current CI APK artifacts are unsigned QA/test builds unless a release signing configuration and keystore have been supplied. Do not publish the QA APKs to Play Store as production builds.
