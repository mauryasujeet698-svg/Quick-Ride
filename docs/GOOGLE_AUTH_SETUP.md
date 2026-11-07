# Google Sign-In Setup — Quick-Ride

Google Sign-In is the only planned sign-in method for the first release. Phone OTP is deferred. Supabase Auth remains the identity provider for all apps.

## What is already prepared
- Supabase project is active.
- The database role model is designed so Google authentication does not grant driver/admin privileges.
- Customer guest browsing is part of the product requirements.

## Owner actions required

1. Open Google Cloud Console and create/select the Google Cloud project for Quick-Ride.
2. Configure Google Auth Platform branding, audience and data access. Request only the basic identity scopes: openid, email and profile.
3. Create an Android OAuth client after the Android application package ID is finalized. Add the SHA-1 fingerprints for the local debug signing certificate and the eventual Play App Signing certificate.
4. Create a Web application OAuth client as required by the native Flutter/Supabase ID-token flow. Keep its client secret private.
5. Open the Supabase Google provider settings:
   https://supabase.com/dashboard/project/czbelhtemzklcmssumpc/auth/providers?provider=Google
6. Enable Google and enter the authorized client IDs. Enter the Google client secret only in the Supabase Dashboard, never in this repository or a Flutter app.
7. In Google Cloud, set the Supabase callback URI shown on that provider settings page as an authorized redirect URI. Do not guess the callback URI.
8. Add the app's custom redirect/deep-link URI to Supabase Auth URL Configuration once the Flutter app identifier and callback scheme are finalized.
9. Test sign-in on a physical Android device using both debug and release signing fingerprints.

## Flutter integration direction

For native Flutter sign-in, use the Google Sign-In package to obtain the Google ID token and access token, then exchange them with Supabase Auth using signInWithIdToken. The Web OAuth client ID is used as the server client ID in the native flow. Pin compatible package versions and follow the current Supabase Flutter documentation when implementation begins.

## Important security rules

- Never paste the Google client secret, Supabase service-role key or database password into chat, source code or GitHub.
- Client IDs are identifiers, not passwords; still configure them only for the correct app and platform.
- Do not put admin/driver role claims into user-editable Google profile metadata.
- New users start as customers. Driver accounts remain pending until approved. Admin/operations roles are assigned out-of-band by the trusted owner process.
- Keep phone OTP disabled until the required SMS/DLT and provider arrangements are complete.

## Details needed when implementation begins

The app package ID, debug SHA-1, release/Play App Signing SHA-1 and final deep-link scheme are not known yet. These should be generated from the Flutter/Android project rather than invented in advance.
