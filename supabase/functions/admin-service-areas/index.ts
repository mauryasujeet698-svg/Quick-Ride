import { createClient } from "npm:@supabase/supabase-js@2.57.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Json = Record<string, unknown>;

function response(status: number, body: Json) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function fail(status: number, message: string) {
  return response(status, { error: message });
}

function isPincode(value: unknown): value is string {
  return typeof value === "string" && /^[1-9][0-9]{5}$/.test(value);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "Method not allowed");

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return fail(401, "Authentication required");

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return fail(500, "Server configuration is incomplete");
  }

  const authClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await authClient.auth.getUser();
  const user = userData.user;
  if (userError || !user) return fail(401, "Invalid or expired session");

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const [{ data: roles, error: roleError }, { data: profile, error: profileError }] = await Promise.all([
    admin.from("user_roles").select("role").eq("user_id", user.id).in("role", ["admin", "operations"]),
    admin.from("profiles").select("account_status").eq("id", user.id).maybeSingle(),
  ]);
  if (roleError || profileError) return fail(500, "Unable to verify administrator permissions");
  if (profile?.account_status !== "active" || !roles?.length) return fail(403, "Administrator access is required");

  let body: Json;
  try {
    body = await req.json();
  } catch {
    return fail(400, "Request body must be valid JSON");
  }

  const action = body.action;
  const audit = async (actionName: string, table: string, targetId: string | null, before: unknown, after: unknown) => {
    const { error } = await admin.from("admin_audit_logs").insert({
      actor_user_id: user.id,
      action: actionName,
      target_table: table,
      target_id: targetId,
      before_data: before ?? null,
      after_data: after ?? null,
    });
    if (error) throw new Error("Change completed but audit record could not be written");
  };

  try {
    if (action === "list") {
      const { data, error } = await admin
        .from("service_areas")
        .select("id,name,city,state,country_code,timezone,is_active,service_area_pincodes(id,pincode,label,is_active,service_area_commercial_configs(id,business_model,subscription_amount,subscription_period,commission_percent,currency,valid_from,valid_until,is_active),service_area_dispatch_configs(id,initial_radius_m,max_radius_m,radius_step_m,offer_batch_size,offer_ttl_seconds,location_max_age_seconds,chain_pickup_distance_m,chain_offer_ttl_seconds))")
        .order("city", { ascending: true });
      if (error) return fail(500, "Unable to load service areas");
      return response(200, { service_areas: data ?? [] });
    }

    if (action === "create_service_area") {
      const name = typeof body.name === "string" ? body.name.trim() : "";
      const city = typeof body.city === "string" ? body.city.trim() : "";
      const state = typeof body.state === "string" ? body.state.trim() : "";
      const timezone = typeof body.timezone === "string" ? body.timezone.trim() : "Asia/Kolkata";
      if (!name || !city || !state) return fail(400, "Name, city and state are required");
      const { data, error } = await admin.from("service_areas")
        .insert({ name, city, state, timezone, country_code: "IN", is_active: false })
        .select("*").single();
      if (error) return fail(400, error.message);
      await audit("service_area.created", "service_areas", String(data.id), null, data);
      return response(201, { service_area: data });
    }

    if (action === "set_service_area_active") {
      const id = Number(body.serviceAreaId);
      const isActive = body.isActive;
      if (!Number.isSafeInteger(id) || typeof isActive !== "boolean") return fail(400, "Valid serviceAreaId and isActive are required");
      const { data: before } = await admin.from("service_areas").select("*").eq("id", id).maybeSingle();
      if (!before) return fail(404, "Service area not found");
      const { data, error } = await admin.from("service_areas").update({ is_active: isActive }).eq("id", id).select("*").single();
      if (error) return fail(400, error.message);
      await audit("service_area.activation_changed", "service_areas", String(id), before, data);
      return response(200, { service_area: data });
    }

    if (action === "create_pincode") {
      const pincode = body.pincode;
      const serviceAreaId = Number(body.serviceAreaId);
      const label = typeof body.label === "string" ? body.label.trim() : null;
      if (!isPincode(pincode) || !Number.isSafeInteger(serviceAreaId)) return fail(400, "A valid six-digit Indian pincode and serviceAreaId are required");
      const { data: area, error: areaError } = await admin.from("service_areas").select("id").eq("id", serviceAreaId).maybeSingle();
      if (areaError || !area) return fail(404, "Service area not found");
      const { data: before } = await admin.from("service_area_pincodes").select("*").eq("pincode", pincode).maybeSingle();
      const { data, error } = await admin.from("service_area_pincodes")
        .upsert({ pincode, service_area_id: serviceAreaId, label, is_active: before?.is_active ?? false }, { onConflict: "pincode" })
        .select("*").single();
      if (error) return fail(400, error.message);
      if (!data) return fail(500, "Pincode was not saved");
      const { error: dispatchError } = await admin.from("service_area_dispatch_configs")
        .upsert({ pincode_id: data.id }, { onConflict: "pincode_id", ignoreDuplicates: true });
      if (dispatchError) return fail(500, "Pincode saved but dispatch defaults could not be prepared");
      await audit(before ? "pincode.updated" : "pincode.created", "service_area_pincodes", String(data.id), before, data);
      return response(before ? 200 : 201, { pincode: data, requires_commercial_configuration: true });
    }

    if (action === "set_pincode_boundary") {
      const pincodeId = Number(body.pincodeId);
      const boundary = body.geojson;
      if (!Number.isSafeInteger(pincodeId) || !boundary || typeof boundary !== "object") {
        return fail(400, "A valid pincodeId and GeoJSON Polygon or MultiPolygon are required");
      }
      const { data, error } = await admin.rpc("admin_set_pincode_boundary", {
        p_actor: user.id,
        p_pincode_id: pincodeId,
        p_geojson: boundary,
      });
      if (error) return fail(400, error.message);
      return response(200, { pincode_boundary: data });
    }

    if (action === "set_pincode_active") {
      const pincodeId = Number(body.pincodeId);
      const isActive = body.isActive;
      if (!Number.isSafeInteger(pincodeId) || typeof isActive !== "boolean") return fail(400, "Valid pincodeId and isActive are required");
      const { data: before } = await admin.from("service_area_pincodes").select("*").eq("id", pincodeId).maybeSingle();
      if (!before) return fail(404, "Pincode not found");
      if (isActive) {
        const { data: pin } = await admin.from("service_area_pincodes")
          .select("id,boundary,service_areas!inner(is_active)")
          .eq("id", pincodeId).maybeSingle();
        if (!pin?.boundary) return fail(409, "Set an operations-verified GeoJSON boundary before activating this pincode");
        const area = pin.service_areas as unknown as { is_active?: boolean } | null;
        if (area?.is_active !== true) return fail(409, "Activate the parent service area before activating this pincode");
        const now = new Date().toISOString();
        const { data: config } = await admin.from("service_area_commercial_configs")
          .select("id").eq("pincode_id", pincodeId).eq("is_active", true).lte("valid_from", now)
          .or(`valid_until.is.null,valid_until.gt.${now}`).limit(1).maybeSingle();
        if (!config) return fail(409, "Configure a current commercial model before activating this pincode");
      }
      const { data, error } = await admin.from("service_area_pincodes")
        .update({ is_active: isActive }).eq("id", pincodeId).select("*").single();
      if (error) return fail(400, error.message);
      await audit("pincode.activation_changed", "service_area_pincodes", String(pincodeId), before, data);
      return response(200, { pincode: data });
    }

    if (action === "configure_commercial") {
      const pincodeId = Number(body.pincodeId);
      const model = body.businessModel;
      const amount = body.subscriptionAmount;
      const period = body.subscriptionPeriod;
      const percent = body.commissionPercent;
      const validFrom = typeof body.validFrom === "string" ? body.validFrom : new Date().toISOString();
      const validUntil = typeof body.validUntil === "string" ? body.validUntil : null;
      if (!Number.isSafeInteger(pincodeId) || !["subscription", "commission", "hybrid"].includes(String(model))) {
        return fail(400, "Valid pincodeId and businessModel are required");
      }
      const needsSubscription = model === "subscription" || model === "hybrid";
      const needsCommission = model === "commission" || model === "hybrid";
      if (needsSubscription && (typeof amount !== "number" || !Number.isFinite(amount) || amount < 0 ||
          !["day", "week", "month", "year"].includes(String(period)))) {
        return fail(400, "Subscription models require a non-negative amount and billing period");
      }
      if (needsCommission && (typeof percent !== "number" || !Number.isFinite(percent) || percent < 0 || percent > 100)) {
        return fail(400, "Commission models require a percentage between 0 and 100");
      }
      if (validUntil !== null && (!Number.isFinite(Date.parse(validUntil)) || Date.parse(validUntil) <= Date.parse(validFrom))) {
        return fail(400, "validUntil must be later than validFrom");
      }
      const { data, error } = await admin.rpc("admin_set_pincode_commercial_config", {
        p_actor: user.id,
        p_pincode_id: pincodeId,
        p_business_model: model,
        p_subscription_amount: needsSubscription ? amount : null,
        p_subscription_period: needsSubscription ? period : null,
        p_commission_percent: needsCommission ? percent : null,
        p_valid_from: validFrom,
        p_valid_until: validUntil,
      });
      if (error) return fail(400, error.message);
      return response(201, data as Json);
    }

    if (action === "set_dispatch_config") {
      const pincodeId = Number(body.pincodeId);
      if (!Number.isSafeInteger(pincodeId)) return fail(400, "Valid pincodeId is required");
      const allowed = [
        "initial_radius_m", "max_radius_m", "radius_step_m", "offer_batch_size",
        "offer_ttl_seconds", "location_max_age_seconds", "chain_pickup_distance_m",
        "chain_offer_ttl_seconds",
      ];
      const updates: Record<string, number> = {};
      for (const key of allowed) {
        if (body[key] !== undefined) {
          if (typeof body[key] !== "number" || !Number.isInteger(body[key])) return fail(400, `${key} must be an integer`);
          updates[key] = body[key] as number;
        }
      }
      if (!Object.keys(updates).length) return fail(400, "At least one dispatch setting is required");
      const { data: before } = await admin.from("service_area_dispatch_configs").select("*").eq("pincode_id", pincodeId).maybeSingle();
      const { data, error } = await admin.from("service_area_dispatch_configs")
        .upsert({ pincode_id: pincodeId, ...updates }, { onConflict: "pincode_id" }).select("*").single();
      if (error) return fail(400, error.message);
      await audit("dispatch_config.updated", "service_area_dispatch_configs", String(data.id), before, data);
      return response(200, { dispatch_config: data });
    }

    if (action === "list_driver_applications") {
      const { data, error } = await admin.from("driver_profiles")
        .select("user_id,verification_status,availability_status,vehicle_category_id,vehicle_registration,vehicle_make,vehicle_model,vehicle_color,created_at,updated_at,vehicle_categories(id,code,name),driver_documents(id,document_type,verification_status,expires_at,created_at),driver_service_pincodes(id,pincode_id,status,is_primary,requested_at,service_area_pincodes(pincode,label))")
        .order("created_at", { ascending: false });
      if (error) return fail(500, "Unable to load driver applications");
      return response(200, { applications: data ?? [] });
    }

    if (action === "review_driver_application") {
      const driverId = String(body.driverId ?? "");
      const decision = body.decision;
      const note = typeof body.note === "string" ? body.note.trim().slice(0, 1000) : null;
      if (!driverId || !["approved", "rejected"].includes(String(decision))) {
        return fail(400, "driverId and an approved/rejected decision are required");
      }
      const { data: before } = await admin.from("driver_profiles")
        .select("user_id,verification_status,availability_status,vehicle_category_id,vehicle_registration")
        .eq("user_id", driverId).maybeSingle();
      if (!before) return fail(404, "Driver application not found");
      if (before.verification_status === "approved" && decision === "rejected") {
        return fail(409, "Use the driver suspension process for an already-approved driver");
      }
      const { data, error } = await admin.from("driver_profiles").update({
        verification_status: decision,
        availability_status: "offline",
        active_pincode_id: null,
      }).eq("user_id", driverId).select("user_id,verification_status,availability_status,vehicle_category_id,vehicle_registration").single();
      if (error) return fail(400, error.message);
      if (decision === "approved") {
        const { error: roleError } = await admin.from("user_roles").upsert({
          user_id: driverId, role: "driver", assigned_by: user.id,
        }, { onConflict: "user_id,role", ignoreDuplicates: true });
        if (roleError) return fail(500, "Driver approved but driver access could not be provisioned");
      } else {
        await admin.from("user_roles").delete().eq("user_id", driverId).eq("role", "driver");
      }
      await audit("driver_application." + decision, "driver_profiles", driverId, before, { ...data, review_note: note });
      return response(200, { driver_application: data, driver_role_granted: decision === "approved" });
    }

    if (action === "list_driver_pincode_requests") {
      const status = typeof body.status === "string" ? body.status : null;
      let query = admin.from("driver_service_pincodes")
        .select("id,driver_id,pincode_id,status,is_primary,requested_at,reviewed_at,review_note,service_area_pincodes(pincode,label,service_area_id)")
        .order("requested_at", { ascending: false });
      if (status && ["pending", "active", "rejected", "suspended"].includes(status)) query = query.eq("status", status);
      const { data, error } = await query;
      if (error) return fail(500, "Unable to load driver service pincode requests");
      return response(200, { requests: data ?? [] });
    }

    if (action === "review_driver_pincode") {
      const requestId = String(body.requestId ?? "");
      const decision = body.decision;
      const note = typeof body.note === "string" ? body.note.trim().slice(0, 1000) : null;
      if (!requestId || !["active", "rejected", "suspended"].includes(String(decision))) {
        return fail(400, "requestId and an active/rejected/suspended decision are required");
      }
      const { data, error } = await admin.rpc("admin_review_driver_pincode", {
        p_actor: user.id,
        p_request_id: requestId,
        p_decision: decision,
        p_note: note,
      });
      if (error) return fail(400, error.message);
      return response(200, { service_pincode: data });
    }

    return fail(400, "Unsupported action");
  } catch (error) {
    console.error("admin-service-areas failed", error);
    return fail(500, error instanceof Error ? error.message : "Unexpected server error");
  }
});
