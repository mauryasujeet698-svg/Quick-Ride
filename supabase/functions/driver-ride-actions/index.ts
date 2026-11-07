import { createClient } from "npm:@supabase/supabase-js@2.57.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
type Json = Record<string, unknown>;
function respond(status: number, body: Json) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
function fail(status: number, code: string, message: string) {
  return respond(status, { error: { code, message } });
}
function isPincode(value: unknown): value is string {
  return typeof value === "string" && /^[1-9][0-9]{5}$/.test(value);
}
async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((v) => v.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "METHOD_NOT_ALLOWED", "Use POST");

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return fail(401, "AUTH_REQUIRED", "Sign in first");
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return fail(500, "SERVER_CONFIG", "Server configuration is incomplete");

  const auth = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await auth.auth.getUser();
  const user = authData.user;
  if (authError || !user) return fail(401, "INVALID_SESSION", "Your session is invalid or expired");

  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const [{ data: roles, error: roleError }, { data: profile, error: profileError }, { data: driver, error: driverError }] =
    await Promise.all([
      db.from("user_roles").select("role").eq("user_id", user.id),
      db.from("profiles").select("account_status").eq("id", user.id).maybeSingle(),
      db.from("driver_profiles").select("user_id,verification_status,availability_status,active_pincode_id").eq("user_id", user.id).maybeSingle(),
    ]);
  if (roleError || profileError || driverError) return fail(500, "ACCOUNT_LOOKUP", "Unable to verify your account");
  if (profile?.account_status !== "active") return fail(403, "ACCOUNT_INACTIVE", "Your account is not active");

  let body: Json;
  try { body = await req.json(); } catch { return fail(400, "INVALID_JSON", "Request body must be valid JSON"); }
  const action = body.action;

  if (action === "safety_event") {
    if (!driver || driver.verification_status !== "approved") {
      return fail(403, "APPROVED_DRIVER_REQUIRED", "An approved driver account is required");
    }
    const rideId = String(body.rideId ?? "");
    if (!rideId) return fail(400, "RIDE_REQUIRED", "rideId is required");
    const { data: ride, error: rideError } = await db.from("rides")
      .select("id,status,driver_id")
      .eq("id", rideId).eq("driver_id", user.id).maybeSingle();
    if (rideError) return fail(500, "RIDE_LOOKUP_FAILED", "Unable to verify this assigned ride");
    if (!ride || !["accepted", "driver_arriving", "arrived", "in_progress"].includes(String(ride.status))) {
      return fail(409, "RIDE_NOT_ACTIVE", "Safety events can only be recorded for an active assigned ride");
    }
    const { data: event, error: eventError } = await db.from("ride_safety_events").insert({
      ride_id: rideId,
      actor_user_id: user.id,
      event_type: "sos_triggered",
      details: {
        source: "driver_app",
        action: "open_india_emergency_dialer",
        recorded_at: new Date().toISOString(),
      },
    }).select("id,event_type,created_at").single();
    if (eventError) return fail(500, "SAFETY_EVENT_FAILED", "The SOS event could not be recorded");
    return respond(201, {
      safety_event: event,
      emergency_number: "112",
      note: "The emergency number must still be dialled by the driver. Quick-Ride does not directly dispatch public emergency services.",
    });
  }

  if (action === "get_earnings") {
    if (!driver || driver.verification_status !== "approved") {
      return fail(403, "APPROVED_DRIVER_REQUIRED", "Earnings are available after driver approval");
    }
    const [
      { data: commissions, error: commissionError },
      { data: completedRides, error: ridesError, count: completedRideCount },
      { data: subscriptions, error: subscriptionError },
      { data: payments, error: paymentError },
      { data: ledger, error: ledgerError },
    ] = await Promise.all([
      db.from("ride_commissions")
        .select("ride_id,fare_amount,commission_amount,currency,settlement_status,created_at")
        .eq("driver_id", user.id).order("created_at", { ascending: false }).limit(50),
      db.from("rides")
        .select("id,completed_at,final_fare,estimated_fare,actual_distance_m,actual_duration_s,currency", { count: "exact" })
        .eq("driver_id", user.id).eq("status", "completed")
        .order("completed_at", { ascending: false }).limit(30),
      db.from("driver_subscriptions")
        .select("id,status,period_start,period_end,amount,currency,pincode_id,created_at")
        .eq("driver_id", user.id).order("created_at", { ascending: false }).limit(12),
      db.from("payment_records")
        .select("id,payment_purpose,payment_method,status,amount,currency,captured_at,created_at")
        .or(`payer_user_id.eq.${user.id},payee_user_id.eq.${user.id}`)
        .order("created_at", { ascending: false }).limit(20),
      db.from("ledger_entries")
        .select("id,entry_type,direction,amount,currency,status,description,created_at")
        .eq("owner_user_id", user.id).order("created_at", { ascending: false }).limit(30),
    ]);
    if (commissionError || ridesError || subscriptionError || paymentError || ledgerError) {
      return fail(500, "EARNINGS_LOOKUP_FAILED", "Unable to load driver earnings and settlement records");
    }

    // Summarize the same recent completed-ride window for every commercial
    // model. Subscription-only rides have no ride_commissions row, so gross
    // fare must come from completed rides and commission defaults to zero.
    const commissionByRide = new Map((commissions ?? []).map((row) => [
      String(row.ride_id),
      {
        amount: Number(row.commission_amount ?? 0),
        currency: String(row.currency ?? "INR"),
      },
    ]));
    const totals: Record<string, {
      completed_rides: number;
      gross_fare: number;
      platform_commission: number;
      after_commission: number;
    }> = {};
    for (const ride of completedRides ?? []) {
      const currency = String(ride.currency ?? "INR");
      const commission = commissionByRide.get(String(ride.id));
      const gross = Number(ride.final_fare ?? 0);
      const fee = commission?.currency === currency ? commission.amount : 0;
      const value = totals[currency] ?? {
        completed_rides: 0,
        gross_fare: 0,
        platform_commission: 0,
        after_commission: 0,
      };
      value.completed_rides += 1;
      value.gross_fare += gross;
      value.platform_commission += fee;
      value.after_commission += gross - fee;
      totals[currency] = value;
    }

    return respond(200, {
      totals,
      summary_window: "latest_30_completed_rides",
      recent_window_ride_count: (completedRides ?? []).length,
      completed_ride_count: completedRideCount ?? (completedRides ?? []).length,
      recent_completed_rides: completedRides ?? [],
      commissions: commissions ?? [],
      subscriptions: subscriptions ?? [],
      payments: payments ?? [],
      ledger: ledger ?? [],
      settlement_note: "Fare and commission totals summarize the latest 30 completed rides. They are accounting records, not confirmation of a bank payout.",
    });
  }

  if (action === "apply_driver") {
    const categoryId = Number(body.vehicleCategoryId);
    const registration = typeof body.vehicleRegistration === "string" ? body.vehicleRegistration.trim().toUpperCase() : "";
    const make = typeof body.vehicleMake === "string" ? body.vehicleMake.trim() : "";
    const model = typeof body.vehicleModel === "string" ? body.vehicleModel.trim() : "";
    const color = typeof body.vehicleColor === "string" ? body.vehicleColor.trim() : "";
    if (!Number.isSafeInteger(categoryId) || !registration || !make || !model) {
      return fail(400, "APPLICATION_FIELDS_REQUIRED", "Vehicle category, registration, make and model are required");
    }
    const { data: category } = await db.from("vehicle_categories").select("id").eq("id", categoryId).eq("is_active", true).maybeSingle();
    if (!category) return fail(400, "INVALID_VEHICLE_CATEGORY", "Choose an active vehicle category");
    if (driver?.verification_status === "approved") return fail(409, "ALREADY_APPROVED", "This account already has an approved driver profile");
    const { data, error } = await db.from("driver_profiles").upsert({
      user_id: user.id,
      vehicle_category_id: categoryId,
      vehicle_registration: registration,
      vehicle_make: make,
      vehicle_model: model,
      vehicle_color: color || null,
      verification_status: "pending",
      availability_status: "offline",
    }, { onConflict: "user_id" }).select("user_id,verification_status,vehicle_category_id,vehicle_registration,vehicle_make,vehicle_model,vehicle_color").single();
    if (error) return fail(400, "APPLICATION_FAILED", error.message);
    return respond(201, { driver_application: data, next_step: "request_service_pincode" });
  }

  if (action === "list_documents") {
    if (!driver) return respond(200, { documents: [] });
    const { data, error } = await db.from("driver_documents")
      .select("id,document_type,verification_status,document_number_last4,issued_at,expires_at,review_note,reviewed_at,created_at")
      .eq("driver_id", user.id)
      .order("created_at", { ascending: false });
    if (error) return fail(500, "DOCUMENT_LIST_FAILED", "Unable to load your uploaded documents");
    return respond(200, { documents: data ?? [] });
  }

  if (action === "register_document") {
    if (!driver || !["pending", "under_review"].includes(String(driver.verification_status))) {
      return fail(409, "DRIVER_PROFILE_REQUIRED", "A pending driver application is required to upload documents");
    }
    const documentType = String(body.documentType ?? "");
    const allowedTypes = new Set([
      "driving_license", "vehicle_rc", "insurance", "permit",
      "identity", "address_proof", "profile_photo", "other",
    ]);
    const objectPath = typeof body.objectPath === "string" ? body.objectPath : "";
    const contentType = String(body.contentType ?? "");
    const byteSize = Number(body.byteSize);
    const last4 = typeof body.documentNumberLast4 === "string" ? body.documentNumberLast4.trim() : "";
    const issuedAt = typeof body.issuedAt === "string" ? body.issuedAt.slice(0, 10) : null;
    const expiresAt = typeof body.expiresAt === "string" ? body.expiresAt.slice(0, 10) : null;
    const pathParts = objectPath.split("/");
    if (!allowedTypes.has(documentType)) return fail(400, "INVALID_DOCUMENT_TYPE", "Choose a supported driver document type");
    if (pathParts.length !== 3 || pathParts[0] !== user.id || pathParts[1] !== documentType ||
        !/^[A-Za-z0-9._-]{1,140}$/.test(pathParts[2])) {
      return fail(400, "INVALID_OBJECT_PATH", "The uploaded document path is invalid");
    }
    if (!["application/pdf", "image/jpeg", "image/png"].includes(contentType) ||
        !Number.isInteger(byteSize) || byteSize < 1 || byteSize > 5 * 1024 * 1024) {
      return fail(400, "INVALID_DOCUMENT_FILE", "Documents must be PDF, JPG or PNG and no larger than 5 MB");
    }
    if (last4 && !/^\d{4}$/.test(last4)) return fail(400, "INVALID_DOCUMENT_NUMBER", "Only the final four document-number digits may be saved");
    if ((issuedAt && !/^\d{4}-\d{2}-\d{2}$/.test(issuedAt)) ||
        (expiresAt && !/^\d{4}-\d{2}-\d{2}$/.test(expiresAt))) {
      return fail(400, "INVALID_DOCUMENT_DATE", "Document dates must use YYYY-MM-DD");
    }
    const { data: signedFile, error: fileError } = await db.storage
      .from("driver-documents")
      .createSignedUrl(objectPath, 60);
    if (fileError || !signedFile?.signedUrl) {
      return fail(400, "DOCUMENT_OBJECT_NOT_FOUND", "The uploaded file could not be verified in private storage");
    }
    const { data, error } = await db.from("driver_documents").insert({
      driver_id: user.id,
      document_type: documentType,
      storage_bucket: "driver-documents",
      object_path: objectPath,
      document_number_last4: last4 || null,
      issued_at: issuedAt,
      expires_at: expiresAt,
      verification_status: "pending",
    }).select("id,document_type,verification_status,created_at").single();
    if (error) return fail(400, "DOCUMENT_REGISTER_FAILED", error.message);
    return respond(201, { document: data });
  }

  if (action === "request_service_pincode") {
    if (!driver) return fail(409, "DRIVER_PROFILE_REQUIRED", "Submit a driver application first");
    const pincode = body.pincode;
    if (!isPincode(pincode)) return fail(400, "INVALID_PINCODE", "Enter a valid six-digit Indian pincode");
    const { data, error } = await db.rpc("request_driver_service_pincode", {
      p_driver_id: user.id,
      p_pincode: pincode,
      p_is_primary: body.isPrimary === true,
    });
    if (error) return fail(400, "PINCODE_REQUEST_FAILED", error.message);
    return respond(201, { service_pincode_request: data });
  }

  const isDriver = roles?.some((row: { role: string }) => row.role === "driver") === true;
  if (!isDriver || !driver) return fail(403, "DRIVER_ROLE_REQUIRED", "Driver access has not been approved");
  if (driver.verification_status !== "approved" && !["update_location"].includes(String(action))) {
    return fail(403, "DRIVER_NOT_APPROVED", "Your driver documents and profile must be approved first");
  }

  try {
    if (action === "set_online" || action === "set_offline") {
      const pincode = action === "set_online" ? body.pincode : null;
      if (action === "set_online" && !isPincode(pincode)) return fail(400, "INVALID_PINCODE", "Choose an approved service pincode");
      const { data, error } = await db.rpc("set_driver_availability", {
        p_driver_id: user.id,
        p_pincode: pincode,
        p_online: action === "set_online",
      });
      if (error) return fail(409, "AVAILABILITY_UPDATE_FAILED", error.message);
      return respond(200, { availability: data });
    }

    if (action === "update_location") {
      const longitude = body.longitude;
      const latitude = body.latitude;
      const accuracy = body.accuracyM ?? null;
      const speed = body.speedMps ?? null;
      const heading = body.headingDegrees ?? null;
      const recordedAt = typeof body.recordedAt === "string" ? body.recordedAt : new Date().toISOString();
      if (typeof longitude !== "number" || !Number.isFinite(longitude) ||
          typeof latitude !== "number" || !Number.isFinite(latitude)) {
        return fail(400, "INVALID_LOCATION", "Valid longitude and latitude are required");
      }
      const { data, error } = await db.rpc("record_driver_ride_location", {
        p_driver_id: user.id,
        p_longitude: longitude,
        p_latitude: latitude,
        p_accuracy_m: accuracy,
        p_speed_mps: speed,
        p_heading_degrees: heading,
        p_recorded_at: recordedAt,
      });
      if (error) return fail(400, "LOCATION_REJECTED", error.message);
      return respond(200, { location: data });
    }

    if (action === "accept_offer") {
      const offerId = String(body.offerId ?? "");
      if (!offerId) return fail(400, "OFFER_REQUIRED", "offerId is required");
      const { data, error } = await db.rpc("accept_ride_offer", { p_offer_id: offerId, p_driver_id: user.id });
      if (error) return fail(409, "OFFER_NOT_ACCEPTED", error.message);
      return respond(200, { result: data });
    }

    if (action === "reject_offer") {
      const offerId = String(body.offerId ?? "");
      if (!offerId) return fail(400, "OFFER_REQUIRED", "offerId is required");
      const { data: offer } = await db.from("ride_offers").select("ride_id").eq("id", offerId).eq("driver_id", user.id).maybeSingle();
      if (!offer) return fail(404, "OFFER_NOT_FOUND", "Ride offer was not found");
      const { data, error } = await db.rpc("reject_ride_offer", { p_offer_id: offerId, p_driver_id: user.id });
      if (error) return fail(409, "OFFER_NOT_REJECTED", error.message);
      const dispatch = await dispatchNext(db, String(offer.ride_id));
      return respond(200, { result: data, dispatch });
    }

    if (action === "preaccept_chain") {
      const chainOfferId = String(body.chainOfferId ?? "");
      if (!chainOfferId) return fail(400, "CHAIN_OFFER_REQUIRED", "chainOfferId is required");
      const { data, error } = await db.rpc("preaccept_ride_chain_offer", {
        p_chain_offer_id: chainOfferId,
        p_driver_id: user.id,
      });
      if (error) return fail(409, "CHAIN_OFFER_NOT_ACCEPTED", error.message);
      return respond(200, { result: data });
    }

    if (action === "reject_chain") {
      const chainOfferId = String(body.chainOfferId ?? "");
      if (!chainOfferId) return fail(400, "CHAIN_OFFER_REQUIRED", "chainOfferId is required");
      const { data: offer } = await db.from("ride_chain_offers").select("next_ride_id").eq("id", chainOfferId).eq("driver_id", user.id).maybeSingle();
      if (!offer) return fail(404, "CHAIN_OFFER_NOT_FOUND", "Ride-chain offer was not found");
      const { data, error } = await db.from("ride_chain_offers").update({
        status: "rejected", responded_at: new Date().toISOString(),
      }).eq("id", chainOfferId).eq("driver_id", user.id).eq("status", "offered").select("id").maybeSingle();
      if (error || !data) return fail(409, "CHAIN_OFFER_NOT_REJECTED", error?.message ?? "Offer is no longer available");
      const { data: next, error: nextError } = await db.rpc("create_ride_chain_offer_batch", { p_next_ride_id: offer.next_ride_id });
      return respond(200, { status: "rejected", next_chain_dispatch: nextError ? { status: "unavailable" } : next });
    }

    if (["arriving", "arrived", "start", "cancel"].includes(String(action))) {
      const rideId = String(body.rideId ?? "");
      if (!rideId) return fail(400, "RIDE_REQUIRED", "rideId is required");
      let otpHash: string | null = null;
      if (action === "start") {
        const otp = typeof body.pickupOtp === "string" ? body.pickupOtp.trim() : "";
        if (!/^\d{6}$/.test(otp)) return fail(400, "INVALID_OTP", "Enter the six-digit pickup OTP");
        otpHash = await sha256(otp);
      }
      const { data, error } = await db.rpc("driver_ride_transition", {
        p_ride_id: rideId,
        p_driver_id: user.id,
        p_action: action,
        p_otp_sha256: otpHash,
      });
      if (error) return fail(409, "RIDE_TRANSITION_FAILED", error.message);
      if (data?.ok !== true) return fail(409, String(data?.code ?? "RIDE_TRANSITION_REJECTED"), "The ride cannot move to this status");
      return respond(200, { result: data });
    }

    if (action === "complete") {
      const rideId = String(body.rideId ?? "");
      if (!rideId) return fail(400, "RIDE_REQUIRED", "rideId is required");
      const { data, error } = await db.rpc("finish_ride_from_track", {
        p_ride_id: rideId,
        p_driver_id: user.id,
      });
      if (error) return fail(409, "RIDE_COMPLETION_FAILED", error.message);
      return respond(200, { result: data });
    }

    return fail(400, "UNSUPPORTED_ACTION", "Unsupported driver action");
  } catch (cause) {
    console.error("driver-ride-actions failed", cause);
    return fail(500, "DRIVER_ACTION_ERROR", "Unexpected error while processing the driver action");
  }
});

// The service-role client calls dynamically selected SQL RPCs and tables that are
// intentionally not generated into a static Supabase Database type in this Edge Function.
async function dispatchNext(db: any, rideId: string): Promise<Json> {
  const { data: context, error: contextError } = await db.rpc("get_ride_dispatch_context", { p_ride_id: rideId });
  if (contextError || !context) return { status: "unavailable" };
  const settings = context.dispatch as Record<string, number>;
  const initial = Number(settings.initial_radius_m ?? 2000);
  const max = Number(settings.max_radius_m ?? 15000);
  const step = Number(settings.radius_step_m ?? 2000);
  const { data: last } = await db.from("ride_dispatch_attempts").select("search_radius_m")
    .eq("ride_id", rideId).order("attempted_at", { ascending: false }).limit(1).maybeSingle();
  let radius = last ? Math.min(max, Number(last.search_radius_m) + step) : initial;
  let outcome: Json = { status: "no_drivers" };
  while (radius <= max) {
    const { data, error } = await db.rpc("create_ride_offer_batch", { p_ride_id: rideId, p_radius_m: radius });
    if (error) { outcome = { status: "dispatch_error" }; break; }
    outcome = data as Json;
    if (data?.status !== "no_drivers") break;
    if (radius >= max) break;
    radius = Math.min(max, radius + step);
  }
  const { data: chain, error: chainError } = await db.rpc("create_ride_chain_offer_batch", { p_next_ride_id: rideId });
  return { ...outcome, chain_dispatch: chainError ? { status: "unavailable" } : chain };
}
