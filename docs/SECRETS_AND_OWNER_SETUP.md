# Quick-Ride owner setup requirements

Never commit service-role credentials to GitHub or include them in Flutter applications.

## Supabase and authentication

- Supabase project URL: `https://czbelhtemzklcmssumpc.supabase.co`.
- Supply `SUPABASE_URL` and `SUPABASE_ANON_KEY` as mobile build-time defines. The anon key is a client key protected by RLS; never use the service-role key in a mobile application.
- Keep `SUPABASE_SERVICE_ROLE_KEY` only in server-side Supabase secrets.
- Enable Google as a Supabase Auth provider. Register the app deep links:
  - `in.quickride.customer://login-callback`
  - `in.quickride.driver://login-callback`
  - `in.quickride.admin://login-callback`
- Assign the initial Admin role manually to a trusted user UUID. New Google users receive only the customer role.

## Mapbox

- Configure `MAPBOX_ACCESS_TOKEN` as a Supabase Edge Function secret for server-side Directions API calls.
- Supply `MAPBOX_PUBLIC_TOKEN` as a build-time define for native map rendering.
- Configure a restricted `MAPBOX_DOWNLOADS_TOKEN` with Mapbox native SDK downloads read scope in GitHub Actions. Do not expose this download token inside the app bundle.

## GitHub Actions Android QA APKs

Open repository **Settings → Secrets and variables → Actions**:

- Add repository **variable** `SUPABASE_URL` with value `https://czbelhtemzklcmssumpc.supabase.co`.
- Add repository **secrets** `SUPABASE_ANON_KEY`, `MAPBOX_PUBLIC_TOKEN`, and `MAPBOX_DOWNLOADS_TOKEN`.
- Do not paste keys into source files, commits or chat messages.

Then open **Actions → Build Quick-Ride Android QA APKs → Run workflow** on `feature/platform-core`. A successful run uploads the Customer, Driver and Admin debug APKs as `quick-ride-android-qa-apks`. These are QA/debug builds, not Play Store release APKs.

## Driver KYC storage

- The private `driver-documents` bucket is configured by database migrations, with a 5 MB limit and PDF/JPG/PNG MIME allow-list. No separate public bucket or public URL is needed.
- Driver uploads are restricted to the driver's own user-ID folder and require a pending/under-review driver profile.
- The driver Edge Function registers metadata after verifying the uploaded object. Admin document previews use short-lived signed URLs.
- Required documents before Admin can approve a driver: driving licence, vehicle RC and vehicle insurance.
- Do not manually make this bucket public or grant broad Storage object access.

## Firebase Cloud Messaging

- Configure Firebase for all three Android application IDs and store FCM server credentials outside the app bundle. Realtime subscriptions are the current live-event mechanism; push notifications are not implemented yet.

## Service-area operations

- Create service areas and Indian PIN codes in Admin.
- Supply an operations-verified WGS84 GeoJSON Polygon or MultiPolygon for each pincode before activation.
- Configure fare rules and subscription/commission/hybrid models per pincode.
- Approve driver KYC documents, driver profile and service-pincode membership.
- Subscription and hybrid drivers require an active subscription before going online.

## Release

- Configure Android package signing and keep signing keystores/passwords in GitHub Actions secrets.
- Use separate restricted Mapbox server and public tokens.
- Complete physical-device location, background operation, notification, battery and network recovery tests before public release.
