# Google Sign-In Setup — Quick-Ride

Google is the initial sign-in provider. Supabase Auth is the identity provider for all three apps. SMS OTP is deferred until the required provider and India DLT arrangements are completed.

## Implemented direction

- The shared Flutter auth package uses Supabase Google OAuth.
- Each app has a distinct redirect URI:
  - in.quickride.customer://login-callback
  - in.quickride.driver://login-callback
  - in.quickride.admin://login-callback
- New users are assigned the customer role only.
- Driver approval and Admin role assignment are separate trusted operations.

## Owner actions

1. Create/select the Google Cloud project for Quick-Ride.
2. Configure OAuth consent/branding and basic identity scopes.
3. Create required Android and Web OAuth clients after package identifiers and signing fingerprints are finalized.
4. Enable Google in Supabase Auth provider settings.
5. Enter authorized client IDs and the OAuth client secret in the Supabase Dashboard only.
6. Register the Supabase callback URI shown in provider settings with Google Cloud. Do not guess it.
7. Add each app deep-link redirect to Supabase Auth URL Configuration.
8. Test login on physical Android devices using both debug and release/Play signing fingerprints.

## Security

- Never place Google client secrets, Supabase service-role keys or database passwords in source code, GitHub or chat.
- Client IDs are identifiers, not passwords; restrict them to the correct app/platform.
- Do not put admin/driver role claims into user-editable metadata.
- A successful Google login alone does not make a user an Admin or approved driver.
- Keep SMS OTP disabled until the required DLT/provider setup is complete.
