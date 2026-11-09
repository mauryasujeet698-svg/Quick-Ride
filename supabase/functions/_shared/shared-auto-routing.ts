// Server-side shared Auto stop ordering and detour checks.

export type SharedAutoLeg = {
  ride_id: string;
  passenger_count: number;
  pickup_longitude: number;
  pickup_latitude: number;
  pickup_address: string;
  destination_longitude: number;
  destination_latitude: number;
  destination_address: string;
  estimated_duration_s: number;
};
type SharedAutoStop = {
  ride_id: string;
  stop_type: "pickup" | "dropoff";
  sequence_index: number;
  longitude: number;
  latitude: number;
  address: string;
};
export type SharedAutoRoute = {
  stops: SharedAutoStop[];
  distance_m: number;
  duration_s: number;
  detour_percent: number;
  extra_minutes: number;
};

export async function calculateSharedAutoRoute(
  legs: SharedAutoLeg[],
  routingBaseUrl: string,
  maxDetourPercent: number,
  maxExtraMinutes: number,
  fetcher: typeof fetch = fetch,
): Promise<SharedAutoRoute | null> {
  if (legs.length < 2 || legs.length > 3) return null;
  const nodes = legs.flatMap((leg) => [
    {
      ride_id: leg.ride_id,
      stop_type: "pickup" as const,
      longitude: leg.pickup_longitude,
      latitude: leg.pickup_latitude,
      address: leg.pickup_address,
    },
    {
      ride_id: leg.ride_id,
      stop_type: "dropoff" as const,
      longitude: leg.destination_longitude,
      latitude: leg.destination_latitude,
      address: leg.destination_address,
    },
  ]);
  const coordinateString = nodes.map((node) => `${node.longitude},${node.latitude}`).join(";");
  const tableUrl = new URL(`${routingBaseUrl}/table/v1/driving/${coordinateString}`);
  tableUrl.searchParams.set("annotations", "distance,duration");
  const response = await fetcher(tableUrl, {
    headers: { "User-Agent": "Quick-Ride/0.1", "Accept": "application/json" },
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) return null;
  const matrix = await response.json();
  const durations = matrix?.durations as (number | null)[][] | undefined;
  const distances = matrix?.distances as (number | null)[][] | undefined;
  if (!Array.isArray(durations) || !Array.isArray(distances) ||
      durations.length !== nodes.length || distances.length !== nodes.length) return null;
  if (durations.some((row) => !Array.isArray(row) || row.length !== nodes.length) ||
      distances.some((row) => !Array.isArray(row) || row.length !== nodes.length)) return null;

  const candidates: {
    order: number[];
    distance: number;
    duration: number;
    detour: number;
    extra: number;
  }[] = [];
  const used = new Array(nodes.length).fill(false);
  const order: number[] = [];
  const picked = new Set<string>();

  const evaluate = (candidateOrder: number[], totalDuration: number, totalDistance: number) => {
    const positions = new Map<number, number>();
    candidateOrder.forEach((nodeIndex, position) => positions.set(nodeIndex, position));
    let worstDetour = 0;
    let worstExtraSeconds = 0;
    for (const leg of legs) {
      const pickupIndex = nodes.findIndex((node) => node.ride_id === leg.ride_id && node.stop_type === "pickup");
      const dropoffIndex = nodes.findIndex((node) => node.ride_id === leg.ride_id && node.stop_type === "dropoff");
      const pickupPosition = positions.get(pickupIndex);
      const dropoffPosition = positions.get(dropoffIndex);
      if (pickupPosition === undefined || dropoffPosition === undefined || pickupPosition >= dropoffPosition) return;
      let rideDuration = 0;
      for (let i = pickupPosition; i < dropoffPosition; i++) {
        const segment = durations[candidateOrder[i]][candidateOrder[i + 1]];
        if (typeof segment !== "number" || !Number.isFinite(segment)) return;
        rideDuration += segment;
      }
      const baseline = Math.max(1, leg.estimated_duration_s);
      const extra = Math.max(0, rideDuration - baseline);
      const detour = Math.max(0, (extra / baseline) * 100);
      worstExtraSeconds = Math.max(worstExtraSeconds, extra);
      worstDetour = Math.max(worstDetour, detour);
    }
    if (worstDetour > maxDetourPercent || worstExtraSeconds / 60 > maxExtraMinutes) return;
    candidates.push({
      order: [...candidateOrder],
      distance: totalDistance,
      duration: totalDuration,
      detour: worstDetour,
      extra: worstExtraSeconds / 60,
    });
  };

  const walk = (totalDuration: number, totalDistance: number) => {
    if (order.length === nodes.length) {
      evaluate(order, totalDuration, totalDistance);
      return;
    }
    for (let i = 0; i < nodes.length; i++) {
      if (used[i]) continue;
      const node = nodes[i];
      if (node.stop_type === "dropoff" && !picked.has(node.ride_id)) continue;
      const previous = order.length ? order[order.length - 1] : null;
      const segmentDuration = previous === null ? 0 : durations[previous][i];
      const segmentDistance = previous === null ? 0 : distances[previous][i];
      if (previous !== null &&
          (typeof segmentDuration !== "number" || !Number.isFinite(segmentDuration) ||
           typeof segmentDistance !== "number" || !Number.isFinite(segmentDistance))) continue;
      used[i] = true;
      order.push(i);
      if (node.stop_type === "pickup") picked.add(node.ride_id);
      walk(totalDuration + Number(segmentDuration ?? 0), totalDistance + Number(segmentDistance ?? 0));
      if (node.stop_type === "pickup") picked.delete(node.ride_id);
      order.pop();
      used[i] = false;
    }
  };
  walk(0, 0);
  candidates.sort((a, b) => a.duration - b.duration);
  const chosen = candidates[0];
  if (!chosen) return null;
  return {
    stops: chosen.order.map((nodeIndex, index) => ({
      ride_id: nodes[nodeIndex].ride_id,
      stop_type: nodes[nodeIndex].stop_type,
      sequence_index: index + 1,
      longitude: nodes[nodeIndex].longitude,
      latitude: nodes[nodeIndex].latitude,
      address: nodes[nodeIndex].address,
    })),
    distance_m: Math.ceil(chosen.distance),
    duration_s: Math.ceil(chosen.duration),
    detour_percent: Math.round(chosen.detour * 100) / 100,
    extra_minutes: Math.round(chosen.extra * 100) / 100,
  };
}
