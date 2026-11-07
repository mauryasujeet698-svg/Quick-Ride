# Quick-Ride owner setup requirements

Never commit service-role credentials to GitHub or include them in Flutter applications.

## Supabase and authentication

- Supply `SUPABASE_URL` and `SUPABASE_ANON_KEY` as build-time defines.
- Keep `SUPABASE_SERVICE_ROLE_KEY` only in server-side Supabase secrets.
- Enable Google as a Supabase Auth provider. Register the app deep links:
  - `in.quickride.customer://login-callback`
  - `in.quickride.driver://login-callback`
  - `in.quickride.admin://login-callback`
- Assign the initial Admin role manually to a trusted user UUID. New Google users receive only the customer role.

## Mapbox

- Configure `MAPBOX_ACCESS_TOKEN` as a Supabase Edge Function secret for Directions API calls.
- Supply `MAPBOX_PUBLIC_TOKEN` as a build-time define for native map rendering.
- Configure a restricted `MAPBOX_DOWNLOADS_TOKEN` in GitHub Actions for the native SDK dependency. Do not expose it inside the application bundle.

## Firebase Cloud Messaging

- Configure Firebase for all three Android application IDs and store FCM server credentials outside the app bundle before enabling push delivery.
- Realtime subscriptions are the current live-event mechanism; push notifications have not yet been enabled.

## Service-area operations

- Create service areas and Indian PIN codes in Admin.
- Supply an operations-verified WGS84 GeoJSON Polygon or MultiPolygon for each pincode before activation.
- Configure a fare rule and subscription/commission/hybrid model for each pincode.
- Approve driver documents, driver profile and service-pincode membership.
- Subscription and hybrid drivers require an active subscription before going online.

## Release

- Configure Android package signing and store keystores/passwords in GitHub Actions secrets.
- Use restricted, separate Mapbox server and public tokens.
- Complete physical-device location, background operation, notification, battery and network recovery tests before public release.
