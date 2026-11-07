# Quick-Ride — Product Requirements

**Status:** Working baseline. Commercial, regulatory, safety, payment and launch decisions require owner approval before production.

## Product definition
An on-demand ride-hailing service. Customer enters pickup and destination, sees a server-calculated estimate and requests a ride. Backend discovers eligible nearby drivers, sends time-limited offers and safely assigns one driver. This is not scheduled carpooling.

## User types
- **Guest:** browse public service information and categories without sign-in; authenticate before booking or viewing personal data.
- **Customer:** Google sign-in, own profile and rides, fare estimate, booking, assigned-driver details, active-ride location, history, support and safety.
- **Driver:** Google sign-in, onboarding, pending verification, online/offline, location sharing, ride offers, accept/reject, trip progression and own earnings.
- **Admin/operations:** explicitly assigned server-side role; verify drivers/documents, configure service areas/categories/fares, monitor rides, support and reports. Google sign-in never grants privileged roles.

## Customer journey
1. Browse as guest; set pickup and destination.
2. See route distance, duration and server-calculated estimate.
3. Choose an active vehicle category.
4. Sign in if needed; confirm booking.
5. Follow searching, driver assigned, driver arriving, arrived, in progress and completed states.
6. Verify pickup with short-lived OTP; access trip summary and support.

## Driver journey
1. Sign in; complete profile and vehicle onboarding.
2. Wait for verification approval.
3. Go online when eligible and share location under an explicit privacy policy.
4. Receive an expiring offer; accept or reject.
5. Navigate to pickup; mark arrival through backend validation.
6. Verify passenger OTP before trip start; complete trip and view earnings/settlement details.

## Ride lifecycle
requested → searching → offered → accepted → driver_arriving → arrived → in_progress → completed. Terminal alternatives: cancelled and no_driver_found. Backend alone validates transitions, assignment, fare and trip timestamps.

## Dispatch
- PostGIS nearby-driver discovery inside active service areas.
- Filter approved/online drivers by vehicle category, location freshness and eligibility.
- Configurable offer batches, expiry, retry and reassignment.
- Atomic assignment so only one driver can win.
- Prevent conflicting active trips/offers; record all offer outcomes.
- Never trust client-supplied fare, distance, duration, driver ID or ride status.

## Fare and business model
Location/category-aware base fare, per-kilometre, per-minute, minimum fare, booking fee and multiplier. INR is the initial currency default. Backend calculates and snapshots fare. Driver subscription, commission, direct driver settlement, platform collection, taxes and invoicing remain owner-approved choices; do not hardcode a single model.

## Safety and privacy
Production must include trip OTP, SOS/emergency workflow, share-trip, cancellation reasons, abuse monitoring, ride-linked support, driver/vehicle verification, location access limits, retention limits and account deletion.

## Non-functional
Weak-network correctness, idempotent operations, atomic assignment, server-authoritative pricing, rate limits, auditability, bounded precise-location retention and observability.

## Owner decisions needed
Pilot city/boundaries; vehicle categories; driver eligibility; commercial model and settlement; cancellation/no-show rules; payments/refunds; insurance, permits, transport compliance and tax; driver document checklist/retention; emergency response ownership.
