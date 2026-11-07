# Quick-Ride owner setup requirements

Never commit service-role credentials to GitHub or include them in Flutter applications.

## Supabase and authentication

- Supabase project URL: `https://czbelhtemzklcmssumpc.supabase.co`.
- The repository includes the project's public Supabase URL and publishable key as defaults for QA builds. They can be overridden with build-time defines or GitHub Actions variable/secret when rotated. These are client keys protected by RLS; never use the service-role key in a mobile application.
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
- Add repository **secret** `MAPBOX_DOWNLOADS_TOKEN` (required for native SDK dependency download). Add `MAPBOX_PUBLIC_TOKEN` to enable maps at runtime; it is optional for a compile-only QA build. Supabase public settings have safe in-repository defaults and can be overridden when rotated.
- Do not paste keys into source files, commits or chat messages.

Then open **Actions → Build Quick-Ride Android QA APKs → Run workflow** on `feature/platform-core`. A successful run uploads the Customer, Driver and Admin debug APKs as `quick-ride-android-qa-apks`. These are QA/debug builds, not Play Store release APKs.

## Driver KYC storage

- The private `driver-documents` bucket is configured by database migrations, with a 5 MB limit and PDF/JPG/PNG MIME allow-list. No public bucket or public object URL is needed.
- Driver uploads are restricted to the driver's own user-ID folder and require a pending/under-review driver profile.
- The driver Edge Function registers metadata after verifying the uploaded object. Admin document previews use short-lived signed URLs.
- Required documents before Admin can approve a driver: driving licence, vehicle RC and vehicle insurance.
- Do not manually make this bucket public or grant broad Storage object access.

## Firebase Cloud Messaging

- Create three Android apps in the Firebase project using `in.quickride.customer`, `in.quickride.driver` and `in.quickride.admin` as application IDs.
- Add repository Actions secrets `FIREBASE_API_KEY`, `FIREBASE_CUSTOMER_APP_ID`, `FIREBASE_DRIVER_APP_ID` and `FIREBASE_ADMIN_APP_ID`, plus Actions variables `FIREBASE_PROJECT_ID` and `FIREBASE_MESSAGING_SENDER_ID`. These values enable the client registration in each app; push remains inactive when they are absent.
- In Supabase Edge Function secrets, add `FCM_SERVICE_ACCOUNT_JSON` containing the complete Firebase service-account JSON. Enable the Firebase Cloud Messaging API for the project and grant the service account permission to send messages.
- The apps register FCM tokens after authenticated sign-in and remove the current token on sign-out. Ride offers, driver status changes, ride completion, customer cancellation and driver SOS events invoke the private `send-push` function. The function accepts only the Supabase service-role bearer token and sends through the FCM HTTP v1 API.
- Keep the Firebase service-account JSON only in Supabase secrets. Never put it in GitHub source, a Flutter build define, the mobile bundle or chat.
- Test notification permission, foreground delivery, background delivery, notification taps and token refresh on physical Android devices. Realtime continues to provide in-app live updates; push is the wake-up/alert channel.

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
