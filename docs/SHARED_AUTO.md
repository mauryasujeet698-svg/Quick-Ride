# Quick-Ride Shared Auto — Initial Scope

## Scope

The first shared-rides release is **Auto Rickshaw only**. It is not a general ride-sharing, carpooling, bike-sharing or taxi-sharing product.

- Shared Auto is a booking mode alongside private Auto.
- The total vehicle capacity configured for this feature can never exceed three passengers.
- A customer may reserve one, two or three passengers, subject to the configured pincode capacity.
- Each customer/group keeps an independent booking, fare quote, pickup/drop-off, OTP, cancellation and support history.
- Compatible bookings share one Auto, one assigned driver and one ordered combined pickup/drop-off route.
- Private rides and all non-Auto categories retain their existing booking flow.
- Shared Auto is disabled by default for every pincode and must be explicitly enabled by Admin.

## Customer flow

1. Select Auto.
2. Choose Private Auto or Shared Auto.
3. For Shared Auto, choose one, two or three passengers.
4. Select pickup and destination and request a fare quote.
5. The server confirms the pincode's Shared Auto setting and passenger capacity.
6. The quoted price belongs to that booking and is not recalculated when another booking joins.
7. After booking, the customer sees their own ride status, pickup/drop-off and pickup OTP.

If the selected passenger count exceeds the capacity configured for the pincode, the quote response tells the app the configured maximum so the customer can correct the selection. Booking is rejected server-side if the passenger count is still too high.

## Matching rules

The server considers only open Shared Auto trips in the same service pincode and Auto category.

A new booking can join only when:
- The trip has not started and is still accepting bookings.
- The remaining seats are sufficient for the new booking.
- Every passenger's pickup occurs before their own drop-off.
- The combined route stays inside the pincode's maximum passenger detour and extra-time limits.
- The database confirms capacity again while locking the trip row.

The first version accepts new bookings while the group is matching or assigned but before a passenger's trip has started. Joining an Auto that is already in progress is **not enabled in this first version**; it requires a later stop-aware route update and device testing.

## Route planning

The Edge Function asks the routing service for a distance/duration matrix for the pickup and drop-off points, then evaluates valid stop orders. With at most three bookings there are at most six stops.

A valid route:
- Includes one pickup and one drop-off for each booking.
- Places each booking's pickup before its own drop-off.
- Respects the configured maximum detour percentage and extra minutes for every passenger.
- Stores one ordered stop list for the assigned driver.

The route is calculated server-side. The client cannot choose the database stop order or override capacity.

## Fare model

Each booking receives its own fare. The initial implementation calculates a shared fare as:

**Private route fare × configured per-passenger percentage × passenger count**

The default per-passenger percentage is 35%, and Admin can adjust it per pincode. This is a configurable starting rule, not a final commercial decision. The final pricing must be reviewed against local costs, driver earnings and customer expectations before a real pilot.

Another booking joining does not change an earlier customer's quoted fare. At completion, the shared booking remains locked to its confirmed estimate; actual GPS distance and duration are retained separately for audit/review rather than increasing the passenger's agreed price.

## Driver flow

- Only the lead booking is initially dispatched to nearby Auto drivers.
- When a driver accepts it, the database assigns the same driver to every booking in that shared Auto trip.
- The Driver app displays one shared-trip card, passenger count and the server-ordered pickup/drop-off list.
- Each pickup uses that customer's own six-digit OTP.
- Each drop-off completes that customer's booking independently.
- The driver cannot move to a later stop until the previous route stop is completed.
- When one passenger finishes, the driver remains busy while other shared bookings are still active.

## Admin controls

Admin can configure Shared Auto per service pincode:

- Enable/disable.
- Capacity, between one and three.
- Maximum passenger detour percentage.
- Maximum additional travel time.
- Fare percentage per passenger.

Enabling Shared Auto requires an active service area, active pincode, active Auto category and current Auto fare configuration. Changes are audited. Turning the feature off prevents new shared bookings; it does not change the existing private booking path.

## Safety and correctness controls

- Database transaction locks a shared trip before adding a booking and recounts reserved passengers.
- Capacity is independently checked by the Edge Function and database function.
- Each ride remains a separate customer record and retains its own pickup OTP.
- Route stops are associated with a booking and unique per pickup/drop-off.
- Customer row-level security exposes only that customer's booking and stops; the assigned driver can see the complete group route.
- Cancelled bookings' unfinished stops are skipped and their seats released before the trip starts.
- The initial feature does not allow joining after the route has started.

## Current implementation and outstanding validation

The code and migration are committed to the `feature/mapbox-three-app-redesign` branch. The migration has **not** been applied to the connected live Supabase project, and the Edge Functions have **not** been deployed. No Play Store release is part of this work.

Before any pilot, validate:
- SQL migration and RLS in a disposable/test Supabase environment.
- 1+1+1, 2+1, 1+2, full capacity and over-capacity attempts.
- Simultaneous attempts for the final seat.
- Incompatible direction, detour and extra-time cases.
- Lead-driver assignment and all member ride assignment.
- Each passenger's OTP, pickup and drop-off order.
- Customer and driver cancellations and notification behavior.
- Weak network, app resume, Realtime recovery and duplicate request/idempotency.
- Physical Android GPS/navigation/notification behavior.
- Routing-provider quotas, response times and load-test limits.

The shared route matcher currently uses the configured OSRM routing endpoint. The public OSRM demo endpoint is suitable only for limited development/QA; production requires an appropriately hosted or contracted routing service.
