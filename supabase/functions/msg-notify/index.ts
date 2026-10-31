// Supabase Edge Function: msg-notify
// Sends the "you have a new team message" alerts for one Team Messenger message: app notification (web push) to each
// of the person's devices, email when they have no device (or asked for "email me as well"), and a text if they opted in.
// The messenger calls it right after a message is posted:   { message_id }
// Only the person who sent the message can trigger its alerts, and each message is alerted once.
// Who gets alerted (muted chats, whole-team chats they didn't opt into, the "one alert per group until they open it"
// rule) is decided in the database function msg_notify_targets(); this function only does the sending.
//
// Secrets (set with: npx supabase secrets set NAME=value --agent no):
//   VAPID_PUBLIC_KEY + VAPID_PRIVATE_KEY + VAPID_SUBJECT ("mailto:someone@your-domain")           → app notifications
//     (the public key is also in config.js as VAPID_PUBLIC_KEY; generate a pair with: npx web-push generate-vapid-keys)
//   RESEND_API_KEY   + MSG_FROM_EMAIL  ("VYC Track & Field <messages@your-domain>")  → email alerts
//   TWILIO_ACCOUNT_SID + TWILIO_AUTH_TOKEN + TWILIO_FROM (a +1 number or a Messaging Service SID "MG…") → text alerts
// Any of the three can be missing: that kind of alert is simply skipped (no push keys → email as before).
// Deploy: npx supabase functions deploy msg-notify --use-api --agent no   (JWT required — default)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const APP_URL = (Deno.env.get("APP_URL") || "https://dubbrollin.github.io/avtc-track-app").replace(/\/$/, "");
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

type Sub = { endpoint: string; p256dh: string; auth: string };
type Target = { to_email: string; send_email: boolean; email_always: boolean; to_phone: string | null; push: Sub[] | null;
  team_name: string; group_name: string; sender_name: string; preview: string; is_direct: boolean };

const vapidReady = (() => {
  const pub = Deno.env.get("VAPID_PUBLIC_KEY"), priv = Deno.env.get("VAPID_PRIVATE_KEY"), subject = Deno.env.get("VAPID_SUBJECT");
  if (!pub || !priv || !subject) return false;
  try { webpush.setVapidDetails(subject, pub, priv); return true; } catch (_) { return false; }
})();

// Push to one device. Returns "ok", "gone" (the device unsubscribed — drop it) or "fail" (keep it, try next time).
async function sendPush(t: Target, s: Sub): Promise<"ok" | "gone" | "fail"> {
  if (!vapidReady) return "fail";
  const payload = JSON.stringify({
    title: t.is_direct ? `${t.sender_name} · ${t.team_name}` : `${t.group_name} · ${t.team_name}`,
    body: t.is_direct ? t.preview : `${t.sender_name}: ${t.preview}`,
    url: `${APP_URL}/messages.html`,
    tag: "vyc-msg-" + t.group_name.replace(/\W+/g, "-").toLowerCase(),
  });
  try {
    await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 24 * 3600, urgency: "normal" });
    return "ok";
  } catch (e) {
    const code = (e as { statusCode?: number })?.statusCode;
    return code === 404 || code === 410 ? "gone" : "fail";
  }
}

async function sendEmail(t: Target): Promise<boolean> {
  const key = Deno.env.get("RESEND_API_KEY"), from = Deno.env.get("MSG_FROM_EMAIL");
  if (!key || !from) return false;
  const where = t.is_direct ? "sent you a direct message" : `posted in ${t.group_name}`;
  const link = `${APP_URL}/messages.html`;
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from, to: [t.to_email],
      subject: `${t.team_name}: new message from ${t.sender_name}`,
      text: `${t.sender_name} ${where} (${t.team_name}):\n\n${t.preview}\n\nRead and reply: ${link}\n\nYou get one alert per group until you open it. Change or stop these alerts: ${link} → "My alerts".`,
      html: `<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;color:#0F1B2D;max-width:520px">
<p style="margin:0 0 6px"><b>${esc(t.sender_name)}</b> ${esc(where)} <span style="color:#5B6878">· ${esc(t.team_name)}</span></p>
<div style="border-left:3px solid #1764C8;background:#F4F6F9;padding:10px 12px;border-radius:6px;white-space:pre-wrap">${esc(t.preview)}</div>
<p style="margin:14px 0"><a href="${link}" style="background:#1764C8;color:#fff;text-decoration:none;padding:10px 16px;border-radius:8px;font-weight:bold">Open Team Messenger</a></p>
<p style="font-size:12px;color:#5B6878">You get one alert per group until you open it. To change or stop these alerts, open Team Messenger and tap “My alerts”.</p></div>`,
    }),
  });
  return r.ok;
}

async function sendText(t: Target): Promise<boolean> {
  const sid = Deno.env.get("TWILIO_ACCOUNT_SID"), token = Deno.env.get("TWILIO_AUTH_TOKEN"), from = Deno.env.get("TWILIO_FROM");
  if (!sid || !token || !from || !t.to_phone) return false;
  const body = new URLSearchParams({
    To: t.to_phone,
    Body: `${t.team_name}: new message from ${t.sender_name}${t.is_direct ? "" : ` in ${t.group_name}`}. Read it: ${APP_URL}/messages.html  Reply STOP to stop.`,
  });
  body.set(from.startsWith("MG") ? "MessagingServiceSid" : "From", from);
  const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
    method: "POST",
    headers: { Authorization: "Basic " + btoa(`${sid}:${token}`), "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  return r.ok;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!, authHeader = req.headers.get("Authorization") ?? "";
    const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authHeader } } });
    const { message_id } = await req.json().catch(() => ({}));
    if (!message_id) return json({ error: "Which message?" }, 400);
    const { data: mine, error: e1 } = await caller.rpc("msg_is_my_message", { p_message: message_id });
    if (e1 || !mine) return json({ error: "Only the sender can send a message's alerts." }, 403);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data: targets, error } = await admin.rpc("msg_notify_targets", { p_message: message_id });
    if (error) return json({ error: error.message }, 500);

    let pushes = 0, emails = 0, texts = 0;
    await Promise.all(((targets || []) as Target[]).map(async (t) => {
      // 1. app notifications to every device this person turned them on for
      let delivered = 0;
      for (const s of t.push || []) {
        const r = await sendPush(t, s);
        if (r === "ok") delivered++;
        if (r !== "fail") { try { await admin.rpc("msg_push_result", { p_endpoint: s.endpoint, p_ok: r === "ok" }); } catch (_) { /* fine */ } }
      }
      pushes += delivered;
      // 2. email when no device got it (or they asked for email as well)
      try { if (t.send_email && (delivered === 0 || t.email_always) && await sendEmail(t)) emails++; } catch (_) { /* keep going */ }
      // 3. a text, only if they opted in
      try { if (t.to_phone && await sendText(t)) texts++; } catch (_) { /* keep going */ }
    }));
    return json({ people: (targets || []).length, pushes, emails, texts, push_configured: vapidReady });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
