// Livestream Edge Function — the ONLY component that talks to the video provider (Cloudflare Stream).
// It holds the provider API token (as a Supabase secret) and bridges the app <-> Cloudflare:
//
//   POST ?action=create   { stream }  (caller JWT; must be able to broadcast)
//        -> creates a Cloudflare live input, stores ids + ingest key via live_attach_provider (service role),
//           returns the RTMPS/SRT ingest details to the broadcaster.
//   GET  ?action=ingest   { stream }  (caller JWT; must be able to broadcast)
//        -> returns the stored ingest details again (via live_get_ingest, which checks permission).
//   GET  ?action=token    { stream }  (caller JWT; must be able to watch)
//        -> checks live_playback_target, mints a short-lived Cloudflare signed token,
//           returns { hls, dash, recording, status, exp }.
//   POST ?action=webhook              (Cloudflare -> us; verified by a shared secret in the path)
//        -> on "live_input.disconnected" / recording ready, stores the recording URL and ends the stream.
//
// Secrets (supabase secrets set ...):
//   CF_ACCOUNT_ID, CF_API_TOKEN, CF_SUBDOMAIN  (e.g. customer-abc123.cloudflarestream.com),
//   WEBHOOK_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
//
// NOTE: built without a live Cloudflare account to test against. The Cloudflare endpoints and field
// names below follow Cloudflare Stream's documented API as of 2026-10; confirm them against the current
// docs when you wire your account (the two spots that matter are marked CONFIRM).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const CF_ACCOUNT_ID = Deno.env.get("CF_ACCOUNT_ID")!;
const CF_API_TOKEN  = Deno.env.get("CF_API_TOKEN")!;
const CF_SUBDOMAIN  = Deno.env.get("CF_SUBDOMAIN")!;               // customer-xxxx.cloudflarestream.com
const WEBHOOK_SECRET = Deno.env.get("WEBHOOK_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CF_BASE = `https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/stream`;
const cfHeaders = { "Authorization": `Bearer ${CF_API_TOKEN}`, "Content-Type": "application/json" };

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// A supabase client that runs AS THE CALLER (so live_me()/RLS see the signed-in user).
function userClient(req: Request) {
  const auth = req.headers.get("Authorization") ?? "";
  return createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY") ?? SERVICE_ROLE, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });
}
// A supabase client with service role (for writes the app is not allowed to do).
const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

async function cf(path: string, init?: RequestInit) {
  const r = await fetch(`${CF_BASE}${path}`, { ...init, headers: { ...cfHeaders, ...(init?.headers ?? {}) } });
  const body = await r.json().catch(() => ({}));
  if (!r.ok || body?.success === false) {
    throw new Error(`Cloudflare ${path} failed: ${r.status} ${JSON.stringify(body?.errors ?? body)}`);
  }
  return body.result;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);
  const action = url.searchParams.get("action");

  try {
    // ---- webhook: Cloudflare -> us. Verified by a secret query param, not a user JWT. ----
    if (action === "webhook") {
      if (url.searchParams.get("secret") !== WEBHOOK_SECRET || !WEBHOOK_SECRET) return json({ error: "bad secret" }, 401);
      const evt = await req.json().catch(() => ({}));
      // CONFIRM: Cloudflare live webhook shape. We look for a live input id and a ready recording video.
      const inputUid = evt?.data?.live_input ?? evt?.live_input ?? evt?.data?.uid ?? evt?.uid;
      const recordingUid = evt?.data?.uid ?? evt?.uid;         // the recorded video's id
      const a = admin();
      if (inputUid && (evt?.eventType ?? evt?.name ?? "").toString().includes("disconnect")) {
        const { data: row } = await a.from("live_streams").select("id").eq("provider_uid", inputUid).maybeSingle();
        if (row?.id) await a.rpc("live_set_status", { p_stream: row.id, p_status: "ended" }).catch(() => {});
      }
      if (inputUid && recordingUid) {
        const hls = `https://${CF_SUBDOMAIN}/${recordingUid}/manifest/video.m3u8`;
        await a.rpc("live_set_recording", { p_provider_uid: inputUid, p_url: hls });
      }
      return json({ ok: true });
    }

    // ---- everything else needs a signed-in caller ----
    const sb = userClient(req);
    const { data: who } = await sb.auth.getUser();
    if (!who?.user) return json({ error: "not signed in" }, 401);

    const stream = url.searchParams.get("stream") ?? (req.method === "POST" ? (await req.clone().json().catch(() => ({})))?.stream : null);
    if (!stream) return json({ error: "missing stream id" }, 400);

    if (action === "create") {
      // Read the stream row (service role) to get team + title; authorize the caller via a checked RPC.
      const a = admin();
      const { data: row } = await a.from("live_streams").select("id,team_code,title,provider_uid").eq("id", stream).maybeSingle();
      if (!row) return json({ error: "no such stream" }, 404);
      const { data: canBroadcast } = await sb.rpc("live_can_broadcast", { t: row.team_code });
      if (!canBroadcast) return json({ error: "not allowed to broadcast this team" }, 403);
      if (row.provider_uid) {
        // already provisioned — just hand back the ingest
        const { data: ing } = await sb.rpc("live_get_ingest", { p_stream: stream });
        return json({ ingest: ing?.[0] ?? null, alreadyProvisioned: true });
      }
      // CONFIRM: live_inputs create body + response fields (rtmps.url/streamKey, srt, webRTC, uid).
      const li = await cf(`/live_inputs`, {
        method: "POST",
        body: JSON.stringify({
          meta: { name: row.title ?? "Live" },
          recording: { mode: "automatic", requireSignedURLs: true },
          requireSignedURLs: true,
        }),
      });
      const uid = li.uid;
      await a.rpc("live_attach_provider", {
        p_stream: stream, p_provider: "cloudflare", p_provider_uid: uid, p_playback_id: uid,
        p_rtmps_url: li.rtmps?.url ?? null, p_rtmps_key: li.rtmps?.streamKey ?? null,
        p_srt_url: li.srt?.url ?? null, p_webrtc_url: li.webRTC?.url ?? null,
      });
      return json({
        ingest: { rtmps_url: li.rtmps?.url, rtmps_key: li.rtmps?.streamKey, srt_url: li.srt?.url, webrtc_url: li.webRTC?.url },
      });
    }

    if (action === "ingest") {
      const { data: ing, error } = await sb.rpc("live_get_ingest", { p_stream: stream });
      if (error) return json({ error: error.message }, 403);
      return json({ ingest: ing?.[0] ?? null });
    }

    if (action === "token") {
      const { data: t } = await sb.rpc("live_playback_target", { p_stream: stream });
      const target = t?.[0];
      if (!target?.playback_id) return json({ error: "not allowed or not ready" }, 403);
      // Mint a short-lived signed token server-side (Cloudflare does the signing for us).
      const signed = await cf(`/${target.playback_id}/token`, {
        method: "POST",
        body: JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 3600 }),
      });
      const token = signed?.token;
      const base = `https://${CF_SUBDOMAIN}/${target.playback_id}`;
      return json({
        status: target.status,
        hls: `${base}/manifest/video.m3u8?token=${token}`,
        dash: `${base}/manifest/video.mpd?token=${token}`,
        recording: target.recording_url ?? null,
        exp: Math.floor(Date.now() / 1000) + 3600,
      });
    }

    return json({ error: "unknown action" }, 400);
  } catch (e) {
    return json({ error: String(e?.message ?? e) }, 500);
  }
});
