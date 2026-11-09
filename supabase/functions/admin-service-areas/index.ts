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

    if (action === "send_notification") {
      const appRole = typeof body.appRole === "string" ? body.appRole : "";
      const recipientMode = typeof body.recipientMode === "string" ? body.recipientMode : "";
      const title = typeof body.title === "string" ? body.title.trim().slice(0, 100) : "";
      const messageBody = typeof body.body === "string" ? body.body.trim().slice(0, 250) : "";
      if (!["customer", "driver", "admin", "all"].includes(appRole)) {
        return fail(400, "Select a valid application audience");
      }
      if (!["self", "selected", "app_users"].includes(recipientMode)) {
        return fail(400, "Select a valid recipient mode");
      }
      if (!title || !messageBody) {
        return fail(400, "A notification title and message are required");
      }

      let userIds: string[] = [];
      let truncated = false;
      if (recipientMode === "self") {
        userIds = [user.id];
      } else if (recipientMode === "selected") {
        const requested = Array.isArray(body.userIds) ? body.userIds : [];
        userIds = [...new Set(requested.filter((value): value is string =>
          typeof value === "string" &&
          /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
        ))].slice(0, 100);
        if (userIds.length === 0) return fail(400, "Enter at least one valid user UUID");
      } else {
        let deviceQuery = admin.from("device_push_tokens").select("user_id");
        if (appRole !== "all") deviceQuery = deviceQuery.eq("app_role", appRole);
        const { data: deviceRows, error: deviceError } = await deviceQuery
          .order("created_at", { ascending: false })
          .limit(1000);
        if (deviceError) return fail(500, "Unable to find registered notification devices");
        const uniqueIds = [...new Set((deviceRows ?? []).map((row) => String(row.user_id)))];
        truncated = uniqueIds.length > 100;
        userIds = uniqueIds.slice(0, 100);
      }

      if (userIds.length === 0) {
        return response(200, {
          attempted: 0,
          sent: 0,
          message: "No registered notification devices matched this audience",
          truncated: false,
        });
      }

      const pushResponse = await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${serviceRoleKey}`,
          "apikey": serviceRoleKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          userIds,
          ...(appRole === "all" ? {} : { appRole }),
          title,
          body: messageBody,
          data: { notification_source: "admin_console" },
        }),
        signal: AbortSignal.timeout(20000),
      });
      let delivery: Json = {};
      try {
        delivery = await pushResponse.json() as Json;
      } catch {
        return fail(502, "Push service returned an unreadable response");
      }
      if (!pushResponse.ok) {
        console.error("Admin notification send failed", pushResponse.status);
        return fail(502, "Push delivery service could not send the notification");
      }
      await audit(
        "notification.sent",
        "device_push_tokens",
        null,
        null,
        {
          app_role: appRole,
          recipient_mode: recipientMode,
          recipient_users: userIds.length,
          title,
          attempted: delivery.attempted ?? 0,
          sent: delivery.sent ?? 0,
          truncated,
        },
      );
      return response(200, { ...delivery, recipient_users: userIds.length, truncated });
    }

    if (action === "list") {
      const { data, error } = await admin
        .from("service_areas")
        .select("id,name,city,state,country_code,timezone,is_active,service_area_pincodes(id,pincode,label,is_active,service_area_commercial_configs(id,business_model,subscription_amount,subscription_period,commission_percent,currency,valid_from,valid_until,is_active),service_area_dispatch_configs(id,initial_radius_m,max_radius_m,radius_step_m,offer_batch_size,offer_ttl_seconds,location_max_age_seconds,chain_pickup_distance_m,chain_offer_ttl_seconds))")
        .order("city", { ascending: true });
      if (error) return fail(500, "Unable to load service areas");
      return response(200, { service_areas: data ?? [] });
    }

    if (action === "list_vehicle_categories") {
      const { data, error } = await admin.from("vehicle_categories")
        .select("id,code,name,description,is_active,sort_order,created_at")
        .order("sort_order", { ascending: true }).order("name", { ascending: true });
      if (error) return fail(500, "Unable to load vehicle categories");
      return response(200, { vehicle_categories: data ?? [] });
    }

    if (action === "create_vehicle_category") {
      const code = typeof body.code === "string" ? body.code.trim().toLowerCase() : "";
      const name = typeof body.name === "string" ? body.name.trim() : "";
      const description = typeof body.description === "string" ? body.description.trim().slice(0, 500) : null;
      const sortOrder = body.sortOrder === undefined ? 0 : Number(body.sortOrder);
      if (!/^[a-z][a-z0-9_]{1,31}$/.test(code) || name.length < 2 || name.length > 60 ||
          !Number.isSafeInteger(sortOrder) || sortOrder < 0 || sortOrder > 10000) {
        return fail(400, "Use a short lowercase category code, a 2–60 character name and a valid sort order");
      }
      const { data, error } = await admin.from("vehicle_categories")
        .insert({ code, name, description: description || null, is_active: false, sort_order: sortOrder })
        .select("id,code,name,description,is_active,sort_order,created_at").single();
      if (error) return fail(400, error.message);
      await audit("vehicle_category.created", "vehicle_categories", String(data.id), null, data);
      return response(201, { vehicle_category: data });
    }

    if (action === "set_vehicle_category_active") {
      const id = Number(body.categoryId);
      const active = body.isActive;
      if (!Number.isSafeInteger(id) || typeof active !== "boolean") {
        return fail(400, "Valid categoryId and isActive are required");
      }
      const { data: before, error: readError } = await admin.from("vehicle_categories")
        .select("id,code,name,is_active").eq("id", id).maybeSingle();
      if (readError || !before) return fail(404, "Vehicle category not found");
      const { data, error } = await admin.from("vehicle_categories")
        .update({ is_active: active }).eq("id", id)
        .select("id,code,name,description,is_active,sort_order,created_at").single();
      if (error) return fail(400, error.message);
      await audit("vehicle_category.activation_changed", "vehicle_categories", String(id), before, data);
      return response(200, { vehicle_category: data });
    }

    if (action === "list_fare_configs") {
      const { data, error } = await admin.from("fare_configs")
        .select("id,service_area_id,vehicle_category_id,currency,base_fare,per_km_rate,per_minute_rate,minimum_fare,booking_fee,multiplier,valid_from,valid_until,is_active,service_areas(id,name,city,state),vehicle_categories(id,code,name)")
        .order("valid_from", { ascending: false });
      if (error) return fail(500, "Unable to load fare configurations");
      return response(200, { fare_configs: data ?? [] });
    }

    if (action === "create_fare_config") {
      const serviceAreaId = Number(body.serviceAreaId);
      const categoryId = Number(body.vehicleCategoryId);
      const numericFields = ["baseFare", "perKmRate", "perMinuteRate", "minimumFare", "bookingFee", "multiplier"] as const;
      const values = Object.fromEntries(numericFields.map((key) => [key, Number(body[key])])) as Record<string, number>;
      if (!Number.isSafeInteger(serviceAreaId) || !Number.isSafeInteger(categoryId) ||
          numericFields.some((key) => typeof body[key] !== "number" || !Number.isFinite(values[key]))) {
        return fail(400, "Select a service area and vehicle category and enter all fare values");
      }
      if (values.baseFare < 0 || values.perKmRate < 0 || values.perMinuteRate < 0 ||
          values.minimumFare < 0 || values.bookingFee < 0 ||
          values.multiplier < 0.1 || values.multiplier > 10) {
        return fail(400, "Fare amounts must be non-negative and multiplier must be between 0.1 and 10");
      }
      const [{ data: area, error: areaError }, { data: category, error: categoryError }] = await Promise.all([
        admin.from("service_areas").select("id,name").eq("id", serviceAreaId).maybeSingle(),
        admin.from("vehicle_categories").select("id,name,is_active").eq("id", categoryId).maybeSingle(),
      ]);
      if (areaError || !area) return fail(404, "Service area not found");
      if (categoryError || !category || category.is_active !== true) return fail(409, "Choose an active vehicle category");

      const validFrom = new Date().toISOString();
      const { data: existing, error: existingError } = await admin.from("fare_configs")
        .select("id,valid_from,is_active").eq("service_area_id", serviceAreaId)
        .eq("vehicle_category_id", categoryId).eq("is_active", true);
      if (existingError) return fail(500, "Unable to check the current fare configuration");
      const overlappingFuture = (existing ?? []).some((item) => Date.parse(String(item.valid_from)) >= Date.now());
      if (overlappingFuture) return fail(409, "A future fare configuration already exists for this service area and vehicle category");
      const { error: closeError } = await admin.from("fare_configs")
        .update({ is_active: false, valid_until: validFrom })
        .eq("service_area_id", serviceAreaId).eq("vehicle_category_id", categoryId)
        .eq("is_active", true).lt("valid_from", validFrom);
      if (closeError) return fail(500, "Unable to close the previous fare configuration");

      const { data, error } = await admin.from("fare_configs").insert({
        service_area_id: serviceAreaId,
        vehicle_category_id: categoryId,
        currency: "INR",
        base_fare: values.baseFare,
        per_km_rate: values.perKmRate,
        per_minute_rate: values.perMinuteRate,
        minimum_fare: values.minimumFare,
        booking_fee: values.bookingFee,
        multiplier: values.multiplier,
        valid_from: validFrom,
        is_active: true,
      }).select("id,service_area_id,vehicle_category_id,currency,base_fare,per_km_rate,per_minute_rate,minimum_fare,booking_fee,multiplier,valid_from,valid_until,is_active").single();
      if (error) return fail(400, error.message);
      await audit("fare_config.created", "fare_configs", String(data.id), existing ?? null, data);
      return response(201, { fare_config: data });
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
      const ranges: Record<string, [number, number]> = {
        initial_radius_m: [100, 50000],
        max_radius_m: [100, 100000],
        radius_step_m: [100, 25000],
        offer_batch_size: [1, 50],
        offer_ttl_seconds: [5, 180],
        location_max_age_seconds: [5, 600],
        chain_pickup_distance_m: [100, 15000],
        chain_offer_ttl_seconds: [10, 600],
      };
      for (const key of allowed) {
        if (body[key] !== undefined) {
          if (typeof body[key] !== "number" || !Number.isSafeInteger(body[key])) {
            return fail(400, `${key} must be a whole number`);
          }
          const [minimum, maximum] = ranges[key];
          if ((body[key] as number) < minimum || (body[key] as number) > maximum) {
            return fail(400, `${key} must be between ${minimum} and ${maximum}`);
          }
          updates[key] = body[key] as number;
        }
      }
      if (!Object.keys(updates).length) return fail(400, "At least one dispatch setting is required");
      const { data: before, error: beforeError } = await admin.from("service_area_dispatch_configs")
        .select("*").eq("pincode_id", pincodeId).maybeSingle();
      if (beforeError) return fail(500, "Unable to read current dispatch settings");
      const merged = {
        initial_radius_m: Number(before?.initial_radius_m ?? 2000),
        max_radius_m: Number(before?.max_radius_m ?? 15000),
        ...updates,
      };
      if (merged.max_radius_m < merged.initial_radius_m) {
        return fail(400, "Maximum search radius must be greater than or equal to initial search radius");
      }
      const { data, error } = await admin.from("service_area_dispatch_configs")
        .upsert({ pincode_id: pincodeId, ...updates }, { onConflict: "pincode_id" }).select("*").single();
      if (error) return fail(400, error.message);
      await audit("dispatch_config.updated", "service_area_dispatch_configs", String(data.id), before, data);
      return response(200, { dispatch_config: data });
    }

    if (action === "list_driver_applications") {
      const { data, error } = await admin.from("driver_profiles")
        .select("user_id,verification_status,availability_status,vehicle_category_id,vehicle_registration,vehicle_make,vehicle_model,vehicle_color,created_at,updated_at,vehicle_categories(id,code,name),driver_documents(id,document_type,verification_status,document_number_last4,issued_at,expires_at,review_note,reviewed_at,created_at,storage_bucket,object_path),driver_service_pincodes(id,pincode_id,status,is_primary,requested_at,service_area_pincodes(pincode,label))")
        .order("created_at", { ascending: false });
      if (error) return fail(500, "Unable to load driver applications");
      const applications = await Promise.all((data ?? []).map(async (item) => {
        const documents = await Promise.all((item.driver_documents ?? []).map(async (document) => {
          const { data: signed, error: signedError } = await admin.storage
            .from(String(document.storage_bucket ?? "driver-documents"))
            .createSignedUrl(String(document.object_path), 600);
          return { ...document, signed_url: signedError ? null : signed?.signedUrl ?? null };
        }));
        return { ...item, driver_documents: documents };
      }));
      return response(200, { applications });
    }

    if (action === "review_driver_document") {
      const documentId = String(body.documentId ?? "");
      const decision = body.decision;
      const note = typeof body.note === "string" ? body.note.trim().slice(0, 1000) : null;
      if (!documentId || !["approved", "rejected"].includes(String(decision))) {
        return fail(400, "documentId and an approved/rejected decision are required");
      }
      const { data: before, error: beforeError } = await admin.from("driver_documents")
        .select("id,driver_id,document_type,verification_status,expires_at")
        .eq("id", documentId)
        .maybeSingle();
      if (beforeError || !before) return fail(404, "Driver document not found");
      if (decision === "approved" && before.expires_at && Date.parse(String(before.expires_at)) < Date.now()) {
        return fail(409, "An expired document cannot be approved");
      }
      const { data, error } = await admin.from("driver_documents").update({
        verification_status: decision,
        reviewed_by: user.id,
        reviewed_at: new Date().toISOString(),
        review_note: note,
      }).eq("id", documentId)
        .select("id,driver_id,document_type,verification_status,reviewed_by,reviewed_at,review_note")
        .single();
      if (error) return fail(400, "Unable to review driver document");
      await audit("driver_document." + decision, "driver_documents", documentId, before, data);
      return response(200, { document: data });
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
      if (decision === "approved") {
        const { data: documents, error: documentsError } = await admin.from("driver_documents")
          .select("document_type,verification_status,expires_at")
          .eq("driver_id", driverId);
        if (documentsError) return fail(500, "Unable to verify required driver documents");
        const requiredTypes = ["driving_license", "vehicle_rc", "insurance"];
        const missingTypes = requiredTypes.filter((type) => !(documents ?? []).some((document) =>
          document.document_type === type &&
          document.verification_status === "approved" &&
          (!document.expires_at || Date.parse(String(document.expires_at)) >= Date.now())
        ));
        if (missingTypes.length) {
          return fail(409, "Approve the driver's driving license, vehicle RC and insurance before approving this driver. Missing or unapproved: " + missingTypes.join(", "));
        }
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

    if (action === "list_safety_events") {
      const { data, error } = await admin.from("ride_safety_events")
        .select("id,ride_id,actor_user_id,event_type,location,details,created_at,rides(id,status,pickup_address,destination_address)")
        .in("event_type", ["sos_triggered", "incident_reported"])
        .order("created_at", { ascending: false }).limit(200);
      if (error) return fail(500, "Unable to load ride safety events");
      const events = data ?? [];
      const eventIds = events.map((item) => String(item.id));
      const { data: resolutions, error: resolutionError } = eventIds.length
        ? await admin.from("ride_safety_events")
            .select("details")
            .eq("event_type", "safety_resolved")
            .in("ride_id", [...new Set(events.map((item) => String(item.ride_id)))])
        : { data: [], error: null };
      if (resolutionError) return fail(500, "Unable to load safety-event review status");
      const resolvedIds = new Set((resolutions ?? [])
        .map((item) => String((item.details as Record<string, unknown> | null)?.resolved_event_id ?? ""))
        .filter(Boolean));
      const actorIds = [...new Set(events.map((item) => String(item.actor_user_id)))];
      const { data: profiles, error: profileError } = actorIds.length
        ? await admin.from("profiles").select("id,full_name").in("id", actorIds)
        : { data: [], error: null };
      if (profileError) return fail(500, "Unable to load safety-event actor details");
      const names = new Map((profiles ?? []).map((profile) => [String(profile.id), profile.full_name]));
      const unresolved = events
        .filter((item) => !resolvedIds.has(String(item.id)))
        .map((item) => ({
          ...item,
          actor_name: names.get(String(item.actor_user_id)) ?? "Quick-Ride user",
        }));
      return response(200, { safety_events: unresolved });
    }

    if (action === "resolve_safety_event") {
      const eventId = String(body.eventId ?? "");
      const note = typeof body.note === "string" ? body.note.trim().slice(0, 1000) : null;
      if (!eventId) return fail(400, "eventId is required");
      const { data: original, error: originalError } = await admin.from("ride_safety_events")
        .select("id,ride_id,actor_user_id,event_type,created_at")
        .eq("id", eventId).maybeSingle();
      if (originalError || !original) return fail(404, "Safety event not found");
      if (!["sos_triggered", "incident_reported"].includes(String(original.event_type))) {
        return fail(409, "This event type cannot be resolved from the operations queue");
      }
      const { data: existingResolution, error: existingError } = await admin.from("ride_safety_events")
        .select("id").eq("ride_id", original.ride_id).eq("event_type", "safety_resolved")
        .contains("details", { resolved_event_id: eventId }).limit(1).maybeSingle();
      if (existingError) return fail(500, "Unable to verify safety-event review status");
      if (existingResolution) return response(200, { already_resolved: true });
      const { data, error } = await admin.from("ride_safety_events").insert({
        ride_id: original.ride_id,
        actor_user_id: user.id,
        event_type: "safety_resolved",
        details: {
          resolved_event_id: eventId,
          review_note: note,
          reviewed_at: new Date().toISOString(),
        },
      }).select("id,ride_id,event_type,created_at,details").single();
      if (error) return fail(500, "Unable to record safety-event resolution");
      await audit("safety_event.reviewed", "ride_safety_events", eventId, original, data);
      return response(201, { resolution: data });
    }

    if (action === "list_support_tickets") {
      const requestedStatus = typeof body.status === "string" ? body.status : "active";
      let request = admin.from("ride_support_tickets")
        .select("id,ride_id,submitted_by,category,subject,description,status,priority,assigned_to,created_at,updated_at,rides(id,status,pickup_address,destination_address)")
        .order("created_at", { ascending: false }).limit(100);
      if (requestedStatus === "active") {
        request = request.in("status", ["open", "in_progress", "waiting_for_customer"]);
      } else if (requestedStatus !== "all") {
        if (!["open", "in_progress", "waiting_for_customer", "resolved", "closed"].includes(requestedStatus)) {
          return fail(400, "Invalid support-ticket status filter");
        }
        request = request.eq("status", requestedStatus);
      }
      const { data, error } = await request;
      if (error) return fail(500, "Unable to load support tickets");
      const userIds = [...new Set((data ?? []).map((ticket) => String(ticket.submitted_by)))];
      const { data: profiles, error: profilesError } = userIds.length
        ? await admin.from("profiles").select("id,full_name").in("id", userIds)
        : { data: [], error: null };
      if (profilesError) return fail(500, "Unable to load support customer details");
      const names = new Map((profiles ?? []).map((profile) => [String(profile.id), profile.full_name]));
      const tickets = (data ?? []).map((ticket) => ({
        ...ticket,
        customer_name: names.get(String(ticket.submitted_by)) ?? "Quick-Ride customer",
      }));
      return response(200, { tickets });
    }

    if (action === "update_support_ticket") {
      const ticketId = String(body.ticketId ?? "");
      const status = body.status;
      const priority = body.priority;
      const allowedStatuses = ["open", "in_progress", "waiting_for_customer", "resolved", "closed"];
      const allowedPriorities = ["low", "normal", "high", "urgent"];
      if (!ticketId || !allowedStatuses.includes(String(status)) ||
          (priority !== undefined && !allowedPriorities.includes(String(priority)))) {
        return fail(400, "A valid ticketId, status and optional priority are required");
      }
      const { data: before, error: readError } = await admin.from("ride_support_tickets")
        .select("*").eq("id", ticketId).maybeSingle();
      if (readError || !before) return fail(404, "Support ticket not found");
      const updates: Record<string, unknown> = {
        status,
        ...(priority === undefined ? {} : { priority }),
      };
      const { data, error } = await admin.from("ride_support_tickets")
        .update(updates).eq("id", ticketId).select("*").single();
      if (error) return fail(400, "Unable to update support ticket");
      await audit("support_ticket.updated", "ride_support_tickets", ticketId, before, data);
      return response(200, { ticket: data });
    }

    if (action === "dashboard_summary") {
      const [rides, activeRides, completedRides, drivers, pendingDrivers, activePincodes, commissions] = await Promise.all([
        admin.from("rides").select("id", { count: "exact", head: true }),
        admin.from("rides").select("id", { count: "exact", head: true }).in("status", ["accepted", "driver_arriving", "arrived", "in_progress"]),
        admin.from("rides").select("id", { count: "exact", head: true }).eq("status", "completed"),
        admin.from("driver_profiles").select("user_id", { count: "exact", head: true }),
        admin.from("driver_profiles").select("user_id", { count: "exact", head: true }).eq("verification_status", "pending"),
        admin.from("service_area_pincodes").select("id", { count: "exact", head: true }).eq("is_active", true),
        admin.from("ride_commissions").select("commission_amount,currency"),
      ]);
      if (rides.error || activeRides.error || completedRides.error || drivers.error ||
          pendingDrivers.error || activePincodes.error || commissions.error) {
        return fail(500, "Unable to load operations summary");
      }
      const totals: Record<string, number> = {};
      for (const row of commissions.data ?? []) {
        const currency = String(row.currency ?? "INR");
        totals[currency] = (totals[currency] ?? 0) + Number(row.commission_amount ?? 0);
      }
      return response(200, {
        rides_total: rides.count ?? 0,
        rides_active: activeRides.count ?? 0,
        rides_completed: completedRides.count ?? 0,
        drivers_total: drivers.count ?? 0,
        drivers_pending_review: pendingDrivers.count ?? 0,
        pincodes_active: activePincodes.count ?? 0,
        commission_totals: totals,
      });
    }

    return fail(400, "Unsupported action");
  } catch (error) {
    console.error("admin-service-areas failed", error);
    return fail(500, error instanceof Error ? error.message : "Unexpected server error");
  }
});
