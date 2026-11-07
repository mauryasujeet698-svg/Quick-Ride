# Quick-Ride — Security Baseline

## Identity and authorization

Google sign-in authenticates a user; it does not grant privileged access. New users receive the customer role through a trusted auth trigger. Driver role is granted only after Admin approval. Admin/operations roles are assigned through an out-of-band trusted owner process. Never authorize from user-editable profile metadata or request-body user IDs.

## Current database safeguards

- RLS is enabled on all 26 current public tables.
- Client roles cannot insert rides directly; booking is handled by the server-side booking function.
- Client roles cannot directly assign rides, update authoritative ride states, set fares or write commission/ledger entries.
- Admin configuration and driver approvals are routed through role-checked server functions.
- Commercial-model changes use an effective-dated transaction and write audit records.
- Dispatch requires driver approval, pincode approval, active pincode selection, fresh GPS, matching vehicle class and any active subscription requirement.
- Ride offers are expiring records; assignment is performed under row locking.
- Ride-chain acceptance is provisional until the active trip completes.
- Pickup OTPs are stored as bcrypt hashes; failed attempts are rate-limited.
- Security and health advisors returned no findings at the latest check.

## Location privacy

Driver current location is not public. Customer access is limited to the driver assigned to an active ride. Ride GPS trace is available only to ride participants through RLS. Retention and deletion policies must be defined before production launch.

## Server requirements

All critical operations must validate the authenticated JWT, derive actor ID from the token, enforce authorization, validate inputs and use transactions/idempotency. Admin actions must be audited. Rate-limit high-risk actions and redact sensitive data from logs.

## Secrets

Never commit Supabase service-role keys, database passwords, Google OAuth client secrets, signing keystores/passwords, FCM service-account private keys or Mapbox secret tokens. The mobile app may contain only the Supabase publishable/anon key and restricted public Mapbox token. RLS remains mandatory.

## Outstanding controls before public launch

Configure private storage buckets and signed document access, account deletion, cancellation-fee policy, fraud controls, payment webhooks/reconciliation, SOS operations, data-retention schedules, operational alerting and production security review.
