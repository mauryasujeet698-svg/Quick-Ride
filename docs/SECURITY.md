# Quick-Ride — Security Baseline

## Identity and authorization
Google sign-in authenticates a user; it does not grant privileged access. Driver role and verification require trusted server-side approval. Admin/operations roles are server-assigned. Never use user-editable Auth metadata for authorization. Clients cannot write user_roles, driver verification, ride assignment/state, fare totals or audit events.

## Deployed database controls
- RLS enabled on all ten application tables.
- Profiles and roles are readable only by their owner.
- Driver onboarding inserts are restricted to pending/offline.
- Customer ride inserts must be requested, unassigned and have no final fare.
- Ride reads are limited to customer and assigned driver.
- Drivers read only their own offers.
- Drivers write their own location only after approval.
- Customer reads of driver location require an active ride assigned to that driver.
- ride_events has an explicit deny-all client policy.
- Explicit table grants use an allow-list: public service configuration is readable; customer/driver access is granted only where required. Broad default client grants were revoked, including write access to roles, rides and audit events. RLS remains mandatory.

## Backend requirements before pilot
Implement booking, pricing, dispatch, offer acceptance, transitions, cancellation and OTP server-side. Validate JWT identity; do not trust user IDs in request bodies. Use transactions/row locks, idempotency, rate limits, validation and audit logging. Validate coordinates and service boundaries. Return raw driver location only to the assigned customer during permitted states.

## Secrets
Never commit Supabase service-role/secret keys, database passwords, Google OAuth client secrets, signing keystores/passwords, FCM service-account private keys or Mapbox secret tokens. Use the publishable key in mobile clients; RLS remains mandatory.

## Data protection
Request location only when needed and explain why. Stop collection when drivers go offline subject to approved active-trip policy. Define retention/deletion before launch. Keep documents in private storage with short-lived signed access. Provide account deletion and support escalation.

## Repository visibility
The repository was observed as public. Private visibility is recommended during active development. No visibility change was made through the available GitHub integration. Add an open-source license only if the owner intends to grant reuse rights.
