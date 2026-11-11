import { createClient } from "npm:@supabase/supabase-js@2.57.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://localhost",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
type Json = Record<string, unknown>;
let cachedAccessToken: string | null = null;
let cachedAccessTokenExpiresAt = 0;

function respond(status: number, body: Json) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
function encodeJson(value: Json): string {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}
function decodePrivateKey(pem: string): ArrayBuffer {
  const clean = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const binary = atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes.buffer;
}

async function googleAccessToken(account: {
  client_email: string;
  private_key: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedAccessToken && cachedAccessTokenExpiresAt > now + 60) return cachedAccessToken as string;

  const header = encodeJson({ alg: "RS256", typ: "JWT" });
  const claims = encodeJson({
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  });
  const unsigned = header + "." + claims;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    decodePrivateKey(account.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const assertion = unsigned + "." + base64Url(new Uint8Array(signature));
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
    signal: AbortSignal.timeout(12000),
  });
  if (!tokenResponse.ok) {
    console.error("FCM OAuth token request failed", tokenResponse.status);
    throw new Error("FCM_AUTH_FAILED");
  }
  const payload = await tokenResponse.json();
  if (typeof payload.access_token !== "string") throw new Error("FCM_AUTH_FAILED");
  cachedAccessToken = payload.access_token;
  cachedAccessTokenExpiresAt = now + Number(payload.expires_in ?? 3600);
  return payload.access_token as string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond(405, { error: "METHOD_NOT_ALLOWED" });

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = req.headers.get("Authorization");
  if (!serviceKey || authorization !== `Bearer ${serviceKey}`) {
    return respond(401, { error: "SERVICE_AUTH_REQUIRED" });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceAccountJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!url || !serviceAccountJson) {
    return respond(503, { error: "FCM_NOT_CONFIGURED" });
  }

  let account: { project_id: string; client_email: string; private_key: string };
  try {
    account = JSON.parse(serviceAccountJson);
    if (!account.project_id || !account.client_email || !account.private_key) {
      return respond(503, { error: "FCM_SERVICE_ACCOUNT_INVALID" });
    }
  } catch {
    return respond(503, { error: "FCM_SERVICE_ACCOUNT_INVALID" });
  }

  let body: Json;
  try {
    body = await req.json();
  } catch {
    return respond(400, { error: "INVALID_JSON" });
  }
  const userIds = Array.isArray(body.userIds)
    ? [...new Set(body.userIds.filter((value): value is string => typeof value === "string" && /^[0-9a-f-]{36}$/i.test(value)))]
      .slice(0, 100)
    : [];
  const appRole = typeof body.appRole === "string" && ["customer", "driver", "admin"].includes(body.appRole)
    ? body.appRole
    : null;
  const title = typeof body.title === "string" ? body.title.trim().slice(0, 100) : "";
  const messageBody = typeof body.body === "string" ? body.body.trim().slice(0, 250) : "";
  const rawData = body.data && typeof body.data === "object" && !Array.isArray(body.data)
    ? body.data as Record<string, unknown>
    : {};
  const data: Record<string, string> = {};
  for (const [key, value] of Object.entries(rawData)) {
    if (/^[a-zA-Z0-9_]{1,40}$/.test(key) && ["string", "number", "boolean"].includes(typeof value)) {
      data[key] = String(value).slice(0, 500);
    }
  }
  if (userIds.length === 0 || !title || !messageBody) {
    return respond(400, { error: "RECIPIENTS_AND_MESSAGE_REQUIRED" });
  }

  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  let query = db.from("device_push_tokens").select("id,token,user_id").in("user_id", userIds);
  if (appRole) query = query.eq("app_role", appRole);
  const { data: devices, error: lookupError } = await query;
  if (lookupError) {
    console.error("FCM token lookup failed", lookupError.message);
    return respond(500, { error: "PUSH_RECIPIENT_LOOKUP_FAILED" });
  }
  if (!devices?.length) return respond(200, { attempted: 0, sent: 0, stale_tokens_removed: 0 });

  let accessToken: string;
  try {
    accessToken = await googleAccessToken(account);
  } catch (error) {
    console.error("FCM authorization failed", String(error));
    return respond(502, { error: "FCM_AUTH_FAILED" });
  }

  const results = await Promise.all(devices.map(async (device: { id: string; token: string }) => {
    try {
      const response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(account.project_id)}/messages:send`,
        {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              fid: device.token,
              notification: { title, body: messageBody },
              data,
              android: {
                priority: "HIGH",
                notification: { sound: "default" },
              },
              apns: {
                payload: {
                  aps: { sound: "default" },
                },
              },
            },
          }),
          signal: AbortSignal.timeout(12000),
        },
      );
      if (response.ok) return { sent: true, stale: false };
      const resultText = await response.text();
      const stale = response.status === 404 || resultText.includes("UNREGISTERED");
      if (!stale) console.error("FCM send failed", response.status, resultText.slice(0, 400));
      return { sent: false, stale };
    } catch (error) {
      console.error("FCM send request failed", String(error));
      return { sent: false, stale: false };
    }
  }));

  const staleIds = devices.filter((_: unknown, index: number) => results[index].stale).map((device: { id: string }) => device.id);
  if (staleIds.length) {
    const { error } = await db.from("device_push_tokens").delete().in("id", staleIds);
    if (error) console.error("Unable to remove stale FCM tokens", error.message);
  }
  return respond(200, {
    attempted: devices.length,
    sent: results.filter((result: { sent: boolean }) => result.sent).length,
    stale_tokens_removed: staleIds.length,
  });
});
