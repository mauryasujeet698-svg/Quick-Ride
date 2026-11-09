import { createClient } from "npm:@supabase/supabase-js@2.57.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function response(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return response(405, { error: "METHOD_NOT_ALLOWED" });

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return response(401, { error: "AUTHENTICATION_REQUIRED" });

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return response(503, { error: "ACCOUNT_SERVICE_NOT_CONFIGURED" });

  const authClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await authClient.auth.getUser();
  const user = data.user;
  if (error || !user) return response(401, { error: "INVALID_SESSION" });

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // These relations deliberately restrict hard deletion to retain ride,
  // payment, ledger, safety and support history with referential integrity.
  const checks = await Promise.all([
    admin.from("rides").select("id", { count: "exact", head: true }).eq("customer_id", user.id),
    admin.from("rides").select("id", { count: "exact", head: true }).eq("driver_id", user.id),
    admin.from("driver_subscriptions").select("id", { count: "exact", head: true }).eq("driver_id", user.id),
    admin.from("ledger_entries").select("id", { count: "exact", head: true }).eq("owner_user_id", user.id),
    admin.from("payment_records").select("id", { count: "exact", head: true }).or("payer_user_id.eq." + user.id + ",payee_user_id.eq." + user.id),
    admin.from("ride_commissions").select("id", { count: "exact", head: true }).eq("driver_id", user.id),
    admin.from("ride_safety_events").select("id", { count: "exact", head: true }).eq("actor_user_id", user.id),
    admin.from("ride_support_tickets").select("id", { count: "exact", head: true }).eq("submitted_by", user.id),
  ]);

  if (checks.some((item) => item.error)) return response(503, { error: "ACCOUNT_RETENTION_CHECK_FAILED" });
  const retainedRecordCount = checks.reduce((sum, item) => sum + (item.count ?? 0), 0);

  if (retainedRecordCount === 0) {
    const { error: deletionError } = await admin.auth.admin.deleteUser(user.id, false);
    if (!deletionError) return response(200, { mode: "permanently_deleted" });
    console.error("Permanent account deletion fell back to anonymization", deletionError.message);
  }

  // Preserve referential integrity: block sign-in and anonymize the profile.
  const { error: banError } = await admin.auth.admin.updateUserById(user.id, {
    ban_duration: "876000h",
    user_metadata: {},
  });
  if (banError) {
    console.error("Unable to block account sign-in", banError.message);
    return response(503, { error: "ACCOUNT_SIGN_IN_COULD_NOT_BE_BLOCKED" });
  }

  const [{ error: profileError }, { error: tokenError }] = await Promise.all([
    admin.from("profiles").update({
      full_name: null,
      avatar_url: null,
      phone_e164: null,
      account_status: "deleted",
      updated_at: new Date().toISOString(),
    }).eq("id", user.id),
    admin.from("device_push_tokens").delete().eq("user_id", user.id),
  ]);
  if (profileError || tokenError) {
    console.error("Account blocked but anonymization incomplete", {
      profile: profileError?.message,
      tokens: tokenError?.message,
    });
    return response(503, { error: "ACCOUNT_BLOCKED_BUT_CLEANUP_INCOMPLETE" });
  }
  return response(200, { mode: "anonymized_retained_records", retained_record_count: retainedRecordCount });
});