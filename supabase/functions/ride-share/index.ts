import { createClient } from "@supabase/supabase-js";

const encoder = new TextEncoder();
const noStoreHeaders = {
  "Cache-Control": "no-store, private",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...noStoreHeaders,
      "Access-Control-Allow-Origin": "*",
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function sharePage(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Quick-Ride · Shared trip</title>
<style>
:root{color-scheme:light;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f4f6f8;color:#17212b}
*{box-sizing:border-box}
body{margin:0;padding:24px 14px}
main{max-width:620px;margin:0 auto}
header{display:flex;align-items:center;gap:12px;margin:8px 0 20px}
.logo{width:42px;height:42px;border-radius:13px;background:#155eef;color:#fff;display:grid;place-items:center;font-size:21px;font-weight:800}
h1{font-size:21px;margin:0}
.sub{color:#64748b;font-size:13px;margin-top:2px}
.card{background:#fff;border:1px solid #e2e8f0;border-radius:18px;padding:18px;margin:12px 0;box-shadow:0 5px 20px #17212b0a}
.status{display:inline-block;background:#eaf2ff;color:#174ea6;padding:6px 10px;border-radius:999px;font-size:12px;font-weight:800;text-transform:capitalize}
h2{font-size:15px;margin:0 0 12px}
.label{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:#64748b;font-weight:700;margin:14px 0 4px}
.value{font-size:14px;line-height:1.45;overflow-wrap:anywhere}
.route{display:grid;grid-template-columns:18px 1fr;gap:10px}
.dot{width:10px;height:10px;border-radius:50%;margin:4px}
.green{background:#16a34a}.red{background:#dc2626}
.driver{display:flex;align-items:center;gap:12px}
.driverIcon{width:44px;height:44px;border-radius:50%;background:#eef2ff;display:grid;place-items:center;font-size:21px}
.muted{color:#64748b;font-size:12px;line-height:1.5}
a.link{display:inline-block;margin-top:10px;color:#155eef;font-weight:700;text-decoration:none}
footer{font-size:12px;color:#64748b;line-height:1.5;margin:18px 4px}
.hidden{display:none}
#error{color:#b91c1c}
</style>
</head>
<body>
<main>
<header><div class="logo">Q</div><div><h1>Quick-Ride · Shared trip</h1><div class="sub">Live ride information shared by a customer</div></div></header>
<section class="card">
<div id="status" class="status">Loading trip…</div>
<div class="label">Ride reference</div><div id="rideId" class="value">—</div>
<div class="muted" id="updated">Loading the latest ride details…</div>
</section>
<section class="card">
<h2>Trip route</h2>
<div class="route">
<div><div class="dot green"></div></div>
<div><div class="label">Pickup</div><div id="pickup" class="value">—</div></div>
<div><div class="dot red"></div></div>
<div><div class="label">Destination</div><div id="destination" class="value">—</div></div>
</div>
</section>
<section class="card" id="driverCard">
<h2>Driver and vehicle</h2>
<div class="driver"><div class="driverIcon">🚘</div><div><div id="driverName" class="value">Waiting for driver assignment</div><div id="vehicle" class="muted"></div></div></div>
<div class="label">Driver location</div><div id="locationStatus" class="value">Waiting for a fresh location</div>
<a id="mapLink" class="link hidden" target="_blank" rel="noopener noreferrer">Open driver location in Maps</a>
</section>
<section class="card">
<h2>Trip information</h2>
<div class="label">Estimated / final fare</div><div id="fare" class="value">—</div>
<div class="label">Share link expires</div><div id="expiry" class="value">—</div>
<p id="error" class="muted hidden"></p>
</section>
<footer>
This page is available to anyone who has the private share link. Do not forward it to people you do not trust. The link expires automatically and is revoked when the customer creates a replacement link. Driver location updates are shown only when the platform has a recent GPS fix. Quick-Ride is not an emergency dispatch service.
</footer>
</main>
<script>
const feedUrl = new URL(window.location.href);
feedUrl.searchParams.set("format","json");
const statusNode=document.getElementById("status");
const errorNode=document.getElementById("error");
function setText(id,value){document.getElementById(id).textContent=value??"—";}
function human(value){return String(value??"unknown").replaceAll("_"," ");}
async function refresh(){
  try{
    const response=await fetch(feedUrl.toString(),{cache:"no-store",credentials:"omit"});
    const payload=await response.json();
    if(!response.ok) throw new Error(payload.error??"This trip link is no longer available.");
    const snap=payload.snapshot??{};
    const ride=snap.ride??{};
    const driver=snap.driver??null;
    const point=snap.driver_location??null;
    statusNode.textContent=human(ride.status);
    setText("rideId",String(ride.id??"").slice(0,8).toUpperCase());
    setText("pickup",ride.pickup_address);
    setText("destination",ride.destination_address);
    setText("fare",ride.final_fare!=null?new Intl.NumberFormat("en-IN",{style:"currency",currency:ride.currency??"INR"}).format(Number(ride.final_fare)):ride.estimated_fare!=null?"Estimated "+new Intl.NumberFormat("en-IN",{style:"currency",currency:ride.currency??"INR"}).format(Number(ride.estimated_fare)):"Pending");
    setText("expiry",new Date(payload.expires_at).toLocaleString());
    setText("driverName",driver?.name??"Waiting for driver assignment");
    const vehicle=[driver?.vehicle_category,driver?.vehicle_make,driver?.vehicle_model,driver?.vehicle_color,driver?.vehicle_registration].filter(Boolean).join(" · ");
    setText("vehicle",vehicle);
    if(point?.latitude!=null&&point?.longitude!=null){
      setText("locationStatus","Latest GPS fix · "+new Date(point.recorded_at).toLocaleTimeString());
      const link=document.getElementById("mapLink");
      link.href="https://www.google.com/maps/search/?api=1&query="+encodeURIComponent(point.latitude+","+point.longitude);
      link.classList.remove("hidden");
    }else{
      setText("locationStatus","A recent driver location is not available right now.");
      document.getElementById("mapLink").classList.add("hidden");
    }
    setText("updated","Last refreshed "+new Date().toLocaleTimeString()+" · refreshes every 15 seconds");
    errorNode.classList.add("hidden");
  }catch(error){
    statusNode.textContent="Link unavailable";
    errorNode.textContent=error.message;
    errorNode.classList.remove("hidden");
    if(String(error.message).toLowerCase().includes("expired")||String(error.message).toLowerCase().includes("revoked")||String(error.message).toLowerCase().includes("no longer")){
      clearInterval(timer);
    }
  }
}
refresh();
const timer=setInterval(refresh,15000);
</script>
</body>
</html>`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET") {
    return json(405, { error: "Use GET" });
  }
  const url = new URL(req.url);
  const token = url.searchParams.get("token") ?? "";
  if (!/^[A-Za-z0-9_-]{40,60}$/.test(token)) {
    return json(404, { error: "This trip link is invalid or has expired." });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return json(503, { error: "Trip sharing is temporarily unavailable." });
  }
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const tokenHash = await sha256Hex(token);
  const now = new Date().toISOString();
  const { data: link, error: linkError } = await admin.from("ride_share_links")
    .select("id,ride_id,expires_at")
    .eq("token_hash", tokenHash)
    .is("revoked_at", null)
    .gt("expires_at", now)
    .maybeSingle();
  if (linkError || !link) {
    return json(404, { error: "This trip link is invalid, revoked or has expired." });
  }

  const { data: snapshot, error: snapshotError } = await admin.rpc(
    "get_ride_share_snapshot",
    { p_ride_id: link.ride_id },
  );
  if (snapshotError || !snapshot) {
    return json(404, { error: "The shared ride is no longer available." });
  }
  await admin.from("ride_share_links")
    .update({ last_accessed_at: now })
    .eq("id", link.id);

  if (url.searchParams.get("format") === "json") {
    return json(200, {
      snapshot,
      expires_at: link.expires_at,
    });
  }

  return new Response(sharePage(), {
    status: 200,
    headers: {
      ...noStoreHeaders,
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self' https:; img-src 'self' data: https:",
    },
  });
});
