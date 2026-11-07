import { createClient } from "npm:@supabase/supabase-js@2.57.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Json = Record<string, unknown>;
type PointInput = { longitude: number; latitude: number; address: string };

function reply(status: number, body: Json) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
function error(status: number, code: string, message: string) {
  return reply(status, { error: { code, message } });
}
function validPoint(value: unknown): value is PointInput {
  if (!value || typeof value !== "object") return false;
  const p = value as Record<string, unknown>;
  return typeof p.longitude === "number" && Number.isFinite(p.longitude) &&
    typeof p.latitude === "number" && Number.isFinite(p.latitude) &&
    p.longitude >= 68 && p.longitude <= 98 && p.latitude >= 6 && p.latitude <= 38 &&
    typeof p.address === "string" && p.address.trim().length > 2 && p.address.length <= 500;
}
function secureOtp(): string {
  const bytes = new Uint32Array(1);
  crypto.getRandomValues(bytes);
  return String(bytes[0] % 1_000_000).padStart(6, "0");
}
async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}


async function notifyUsers(
  url: string,
  serviceKey: string,
  userIds: string[],
  appRole: "customer" | "driver" | "admin",
  title: string,
  message: string,
  data: Record<string, string>,
) {
  const recipients = [...new Set(userIds)].filter((id) => /^[0-9a-f-]{36}$/i.test(id));
  if (!recipients.length) return;
  try {
    const result = await fetch(`${url}/functions/v1/send-push`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${serviceKey}`,
        "apikey": serviceKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        userIds: recipients,
        appRole,
        title,
        body: message,
        data,
      }),
      signal: AbortSignal.timeout(10000),
    });
    if (!result.ok) console.warn("Push notification was not delivered", result.status);
  } catch (cause) {
    console.warn("Push notification request failed", String(cause));
  }
}

async function notifyOfferedDrivers(db: any, url: string, serviceKey: string, rideId: string) {
  const { data: offers } = await db.from("ride_offers")
    .select("driver_id").eq("ride_id", rideId).eq("status", "offered");
  const { data: chainOffers } = await db.from("ride_chain_offers")
    .select("driver_id").eq("next_ride_id", rideId).eq("status", "offered");
  const recipients = [
    ...(offers ?? []).map((row: { driver_id: string }) => row.driver_id),
    ...(chainOffers ?? []).map((row: { driver_id: string }) => row.driver_id),
  ];
  await notifyUsers(
    url,
    serviceKey,
    recipients,
    "driver",
    "New Quick-Ride request",
    "A nearby trip is available. Open Quick-Ride to review and respond.",
    { type: "ride_offer", ride_id: rideId },
  );
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return error(405, "METHOD_NOT_ALLOWED", "Use POST");

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return error(401, "AUTH_REQUIRED", "Sign in before requesting a ride");

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return error(500, "SERVER_CONFIG", "Supabase server configuration is incomplete");

  const authClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser();
  const user = authData.user;
  if (authError || !user) return error(401, "INVALID_SESSION", "Your session is invalid or expired");

  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const [{ data: roleRows, error: roleError }, { data: profile, error: profileError }] = await Promise.all([
    db.from("user_roles").select("role").eq("user_id", user.id).eq("role", "customer"),
    db.from("profiles").select("account_status").eq("id", user.id).maybeSingle(),
  ]);
  if (roleError || profileError) return error(500, "ACCOUNT_LOOKUP", "Unable to verify your account");
  if (!roleRows?.length || profile?.account_status !== "active") {
    return error(403, "CUSTOMER_REQUIRED", "An active customer account is required");
  }

  let body: Json;
  try { body = await req.json(); } catch { return error(400, "INVALID_JSON", "Request body must be valid JSON"); }

  const action = body.action;
  if (action === "cancel") {
    const rideId = String(body.rideId ?? "");
    const reason = typeof body.reason === "string" ? body.reason.slice(0, 250) : "customer_cancelled";
    if (!rideId) return error(400, "RIDE_REQUIRED", "rideId is required");
    const { data: rideBefore } = await db.from("rides").select("driver_id")
      .eq("id", rideId).eq("customer_id", user.id).maybeSingle();
    const { data, error: cancelError } = await db.rpc("customer_cancel_ride", {
      p_customer_id: user.id,
      p_ride_id: rideId,
      p_reason: reason,
    });
    if (cancelError) return error(409, "CANCELLATION_REJECTED", cancelError.message);
    if (rideBefore?.driver_id) await notifyUsers(
      url, serviceKey, [String(rideBefore.driver_id)], "driver",
      "Ride cancelled by customer",
      "The customer cancelled this Quick-Ride request.",
      { type: "ride_cancelled", ride_id: rideId },
    );
    return reply(200, { result: data });
  }

  if (action === "revoke_share_links") {
    const rideId = String(body.rideId ?? "");
    if (!rideId) return error(400, "RIDE_REQUIRED", "rideId is required");
    const { data: ride, error: rideError } = await db.from("rides")
      .select("id,customer_id")
      .eq("id", rideId).eq("customer_id", user.id).maybeSingle();
    if (rideError) return error(500, "RIDE_LOOKUP_FAILED", "Unable to verify this ride");
    if (!ride) return error(404, "RIDE_NOT_FOUND", "Ride not found");
    const { data, error: revokeError } = await db.from("ride_share_links")
      .update({ revoked_at: new Date().toISOString() })
      .eq("ride_id", rideId).eq("created_by", user.id)
      .is("revoked_at", null).select("id");
    if (revokeError) return error(500, "SHARE_LINK_REVOKE_FAILED", "Unable to revoke trip-share links");
    return reply(200, { revoked_count: data?.length ?? 0 });
  }

  if (action === "create_share_link") {
    const rideId = String(body.rideId ?? "");
    if (!rideId) return error(400, "RIDE_REQUIRED", "rideId is required");
    const { data: ride, error: rideError } = await db.from("rides")
      .select("id,status,customer_id")
      .eq("id", rideId).eq("customer_id", user.id).maybeSingle();
    if (rideError) return error(500, "RIDE_LOOKUP_FAILED", "Unable to verify this ride");
    if (!ride || !["accepted", "driver_arriving", "arrived", "in_progress"].includes(String(ride.status))) {
      return error(409, "RIDE_NOT_ACTIVE", "A share link can only be created for an active assigned ride");
    }

    const tokenBytes = new Uint8Array(32);
    crypto.getRandomValues(tokenBytes);
    const token = btoa(String.fromCharCode(...tokenBytes))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
    const tokenHash = await sha256Hex(token);
    const now = new Date();
    const expiresAt = new Date(now.getTime() + 12 * 60 * 60 * 1000).toISOString();

    const { data: createdLink, error: insertError } = await db.from("ride_share_links")
      .insert({
        ride_id: rideId,
        created_by: user.id,
        token_hash: tokenHash,
        expires_at: expiresAt,
      })
      .select("id").single();
    if (insertError || !createdLink) {
      return error(500, "SHARE_LINK_CREATE_FAILED", "Unable to create a trip-share link");
    }

    // Create the new link before revoking the old one. If rotation fails,
    // remove the newly issued token so the previous link remains usable.
    const { error: revokeError } = await db.from("ride_share_links")
      .update({ revoked_at: now.toISOString() })
      .eq("ride_id", rideId).eq("created_by", user.id)
      .neq("id", createdLink.id)
      .is("revoked_at", null).gt("expires_at", now.toISOString());
    if (revokeError) {
      await db.from("ride_share_links").delete().eq("id", createdLink.id);
      return error(500, "SHARE_LINK_REVOKE_FAILED", "Unable to rotate the previous trip-share link");
    }

    const baseUrl = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
    if (!baseUrl) return error(500, "SERVER_CONFIG", "Supabase URL is not configured");
    const shareUrl = baseUrl + "/functions/v1/ride-share?token=" + encodeURIComponent(token);
    const { error: auditError } = await db.from("ride_safety_events").insert({
      ride_id: rideId,
      actor_user_id: user.id,
      event_type: "trip_shared",
      details: {
        source: "customer_app",
        expires_at: expiresAt,
        token_hash_prefix: tokenHash.slice(0, 8),
      },
    });
    if (auditError) console.error("Unable to record trip_shared event", auditError);
    return reply(201, {
      share_url: shareUrl,
      expires_at: expiresAt,
      previous_links_revoked: true,
      note: "Anyone with this link can view the active ride status, route addresses, driver and vehicle details, and fresh driver location until the link expires. Creating another link revokes the previous link.",
    });
  }

  if (action === "safety_event") {
    const rideId = String(body.rideId ?? "");
    if (!rideId) return error(400, "RIDE_REQUIRED", "rideId is required");
    const { data: ride, error: rideError } = await db.from("rides")
      .select("id,status,customer_id")
      .eq("id", rideId).eq("customer_id", user.id).maybeSingle();
    if (rideError) return error(500, "RIDE_LOOKUP_FAILED", "Unable to verify this ride");
    if (!ride || !["accepted", "driver_arriving", "arrived", "in_progress"].includes(String(ride.status))) {
      return error(409, "RIDE_NOT_ACTIVE", "Safety events can only be recorded for an active assigned ride");
    }
    const { data: event, error: eventError } = await db.from("ride_safety_events").insert({
      ride_id: rideId,
      actor_user_id: user.id,
      event_type: "sos_triggered",
      details: {
        source: "customer_app",
        action: "open_india_emergency_dialer",
        recorded_at: new Date().toISOString(),
      },
    }).select("id,event_type,created_at").single();
    if (eventError) return error(500, "SAFETY_EVENT_FAILED", "The SOS event could not be recorded");
    return reply(201, {
      safety_event: event,
      emergency_number: "112",
      note: "The emergency number must still be dialled by the customer. Quick-Ride does not directly dispatch public emergency services.",
    });
  }

  const mapboxToken = Deno.env.get("MAPBOX_ACCESS_TOKEN");
  if (!mapboxToken) {
    return error(503, "MAPS_NOT_CONFIGURED", "Ride quotes and bookings are disabled until the Mapbox server token is configured in Supabase Edge Function secrets");
  }
  const pincode = body.pincode;
  const categoryId = Number(body.vehicleCategoryId);
  const pickup = body.pickup;
  const destination = body.destination;
  if (!["quote", "book"].includes(String(action))) return error(400, "INVALID_ACTION", "Action must be quote or book");
  if (typeof pincode !== "string" || !/^[1-9][0-9]{5}$/.test(pincode)) return error(400, "INVALID_PINCODE", "Enter a valid six-digit Indian pincode");
  if (!Number.isSafeInteger(categoryId) || categoryId <= 0) return error(400, "INVALID_VEHICLE_CATEGORY", "Choose an available vehicle category");
  if (!validPoint(pickup) || !validPoint(destination)) return error(400, "INVALID_COORDINATES", "Select valid pickup and destination locations within India");

  try {
    const { data: context, error: contextError } = await db.rpc("get_ride_quote_context", {
      p_pincode: pincode,
      p_vehicle_category_id: categoryId,
      p_pickup_longitude: pickup.longitude,
      p_pickup_latitude: pickup.latitude,
    });
    if (contextError || !context) {
      const message = contextError?.message ?? "Service configuration could not be found";
      const code = message.toLowerCase().includes("boundary") ? "PICKUP_BOUNDARY_MISSING" :
        message.toLowerCase().includes("outside") ? "OUTSIDE_SERVICE_AREA" :
        message.toLowerCase().includes("fare") ? "FARE_NOT_CONFIGURED" : "SERVICE_NOT_AVAILABLE";
      return error(409, code, message);
    }

    const coords = `${pickup.longitude},${pickup.latitude};${destination.longitude},${destination.latitude}`;
    const routeUrl = new URL(`https://api.mapbox.com/directions/v5/mapbox/driving/${coords}`);
    routeUrl.searchParams.set("access_token", mapboxToken);
    routeUrl.searchParams.set("overview", "simplified");
    routeUrl.searchParams.set("geometries", "geojson");
    routeUrl.searchParams.set("steps", "false");

    const routeResponse = await fetch(routeUrl, { signal: AbortSignal.timeout(12_000) });
    if (!routeResponse.ok) return error(502, "ROUTE_PROVIDER_ERROR", "The route service could not calculate this trip");
    const routePayload = await routeResponse.json();
    const route = routePayload?.routes?.[0];
    if (!route || typeof route.distance !== "number" || typeof route.duration !== "number") {
      return error(422, "NO_ROUTE", "No drivable route was found between these locations");
    }

    const fare = context.fare_config as Record<string, number | string>;
    const distanceM = Math.ceil(route.distance);
    const durationS = Math.ceil(route.duration);
    const distanceKm = distanceM / 1000;
    const durationMinutes = durationS / 60;
    const base = Number(fare.base_fare);
    const distanceCharge = distanceKm * Number(fare.per_km_rate);
    const timeCharge = durationMinutes * Number(fare.per_minute_rate);
    const bookingFee = Number(fare.booking_fee);
    const multiplier = Number(fare.multiplier);
    const beforeMinimum = (base + distanceCharge + timeCharge + bookingFee) * multiplier;
    const minimum = Number(fare.minimum_fare);
    const estimatedFare = Math.round(Math.max(minimum, beforeMinimum) * 100) / 100;
    const breakdown = {
      provider: "mapbox-directions",
      distance_m: distanceM,
      duration_s: durationS,
      base_fare: base,
      distance_charge: Math.round(distanceCharge * 100) / 100,
      time_charge: Math.round(timeCharge * 100) / 100,
      booking_fee: bookingFee,
      multiplier,
      minimum_fare_applied: beforeMinimum < minimum,
      estimated_fare: estimatedFare,
      currency: String(fare.currency ?? "INR"),
    };

    if (action === "quote") {
      return reply(200, {
        quote: {
          pincode,
          vehicle_category: context.vehicle_category,
          distance_m: distanceM,
          duration_s: durationS,
          estimated_fare: estimatedFare,
          currency: breakdown.currency,
          fare_breakdown: breakdown,
          route_geometry: route.geometry,
          commercial_model: (context.commercial_config as Record<string, unknown>).business_model,
        },
      });
    }

    const idempotencyKey = body.idempotencyKey;
    if (typeof idempotencyKey !== "string" || idempotencyKey.length < 8 || idempotencyKey.length > 128) {
      return error(400, "IDEMPOTENCY_REQUIRED", "A unique idempotency key between 8 and 128 characters is required");
    }

    const otp = secureOtp();
    const otpHash = await sha256Hex(otp);
    const { data: bookingResult, error: bookingError } = await db.rpc("create_ride_booking", {
      p_customer_id: user.id,
      p_pincode: pincode,
      p_vehicle_category_id: categoryId,
      p_pickup_longitude: pickup.longitude,
      p_pickup_latitude: pickup.latitude,
      p_destination_longitude: destination.longitude,
      p_destination_latitude: destination.latitude,
      p_pickup_address: pickup.address,
      p_destination_address: destination.address,
      p_distance_m: distanceM,
      p_duration_s: durationS,
      p_estimated_fare: estimatedFare,
      p_fare_breakdown: breakdown,
      p_booking_idempotency_key: idempotencyKey,
      p_pickup_otp_hash: otpHash,
    });
    if (bookingError || !bookingResult?.ride) {
      const message = bookingError?.message ?? "Booking could not be created";
      return error(409, "BOOKING_REJECTED", message);
    }

    const ride = bookingResult.ride as Record<string, unknown>;
    let dispatch: Json = { status: "not_started" };
    if (bookingResult.created === true) {
      const { data: dispatchContext, error: dispatchContextError } = await db.rpc("get_ride_dispatch_context", {
        p_ride_id: ride.id,
      });
      if (!dispatchContextError && dispatchContext) {
        const settings = dispatchContext.dispatch as Record<string, number>;
        const initial = Number(settings.initial_radius_m ?? 2000);
        const max = Number(settings.max_radius_m ?? 15000);
        const step = Number(settings.radius_step_m ?? 2000);
        let radius = initial;
        let outcome: Json = { status: "no_drivers" };
        while (radius <= max) {
          const { data, error: dispatchError } = await db.rpc("create_ride_offer_batch", {
            p_ride_id: ride.id,
            p_radius_m: radius,
          });
          if (dispatchError) {
            outcome = { status: "dispatch_error" };
            break;
          }
          outcome = data as Json;
          if (data?.status === "offers_created" || data?.status === "waiting_for_responses" ||
              data?.status === "ride_assigned" || data?.status === "ride_closed") break;
          radius += step;
        }
        const { data: chained, error: chainError } = await db.rpc("create_ride_chain_offer_batch", {
          p_next_ride_id: ride.id,
        });
        dispatch = {
          ...outcome,
          chain_dispatch: chainError ? { status: "unavailable" } : chained,
        };
      }
    }

    let otpForCustomer: string | undefined;
    if (bookingResult.created === true) {
      await notifyOfferedDrivers(db, url, serviceKey, String(ride.id));
      otpForCustomer = otp;
    } else if (["requested", "searching", "offered"].includes(String(ride.status))) {
      const { error: rotateError } = await db.rpc("rotate_ride_pickup_otp", {
        p_customer_id: user.id,
        p_ride_id: ride.id,
        p_otp_sha256: otpHash,
      });
      if (!rotateError) otpForCustomer = otp;
    }

    return reply(bookingResult.created === true ? 201 : 200, {
      ride: {
        id: ride.id,
        status: ride.status,
        estimated_fare: estimatedFare,
        currency: breakdown.currency,
        estimated_distance_m: distanceM,
        estimated_duration_s: durationS,
        pickup_address: pickup.address,
        destination_address: destination.address,
      },
      created: bookingResult.created === true,
      pickup_otp: otpForCustomer,
      dispatch,
    });
  } catch (cause) {
    console.error("ride-booking failed", cause);
    return error(500, "BOOKING_INTERNAL_ERROR", "An unexpected error occurred while processing the ride");
  }
});
