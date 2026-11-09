import {
  calculateSharedAutoRoute,
  type SharedAutoLeg,
} from "./shared-auto-routing.ts";

function createLeg(id: string, index: number): SharedAutoLeg {
  return {
    ride_id: id,
    passenger_count: 1,
    pickup_longitude: 80 + index * 0.01,
    pickup_latitude: 25 + index * 0.01,
    pickup_address: `Pickup ${id}`,
    destination_longitude: 80 + index * 0.01 + 0.02,
    destination_latitude: 25 + index * 0.01 + 0.02,
    destination_address: `Drop-off ${id}`,
    estimated_duration_s: 60,
  };
}

function mockTableFetcher(size: number, segmentSeconds: number): typeof fetch {
  return async (_input, _init) => {
    const durations = Array.from({ length: size }, (_, row) =>
      Array.from({ length: size }, (_, column) => row === column ? 0 : segmentSeconds)
    );
    const distances = Array.from({ length: size }, (_, row) =>
      Array.from({ length: size }, (_, column) => row === column ? 0 : 1000)
    );
    return new Response(JSON.stringify({
      code: "Ok",
      durations,
      distances,
    }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };
}

Deno.test("shared Auto planner creates six ordered stops for three bookings", async () => {
  const legs = [createLeg("ride-a", 0), createLeg("ride-b", 1), createLeg("ride-c", 2)];
  const route = await calculateSharedAutoRoute(
    legs,
    "https://router.example.test",
    1000,
    60,
    mockTableFetcher(6, 60),
  );

  if (!route) throw new Error("Expected a valid three-booking route");
  if (route.stops.length !== 6) throw new Error("Expected six stops");
  route.stops.forEach((stop, index) => {
    if (stop.sequence_index !== index + 1) throw new Error("Stop sequence is not contiguous");
  });
  for (const leg of legs) {
    const pickup = route.stops.findIndex((stop) =>
      stop.ride_id === leg.ride_id && stop.stop_type === "pickup"
    );
    const dropoff = route.stops.findIndex((stop) =>
      stop.ride_id === leg.ride_id && stop.stop_type === "dropoff"
    );
    if (pickup < 0 || dropoff < 0 || pickup >= dropoff) {
      throw new Error(`Pickup must precede drop-off for ${leg.ride_id}`);
    }
  }
});

Deno.test("shared Auto planner rejects a route exceeding detour and extra-time limits", async () => {
  const legs = [createLeg("ride-a", 0), createLeg("ride-b", 1)];
  const route = await calculateSharedAutoRoute(
    legs,
    "https://router.example.test",
    10,
    1,
    mockTableFetcher(4, 120),
  );
  if (route !== null) throw new Error("Expected an incompatible route to be rejected");
});

Deno.test("shared Auto planner does not try to match a single booking", async () => {
  const route = await calculateSharedAutoRoute(
    [createLeg("ride-a", 0)],
    "https://router.example.test",
    40,
    15,
    async () => {
      throw new Error("A single booking should not call the routing service");
    },
  );
  if (route !== null) throw new Error("A single booking should start its own shared Auto trip");
});
