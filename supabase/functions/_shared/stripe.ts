// Shared helpers for the payment edge functions (team-stripe, fee-checkout, stripe-webhook).
// Secrets (set with `supabase secrets set`): STRIPE_SECRET_KEY (the VYC platform account's restricted key),
// STRIPE_WEBHOOK_SECRET (signing secret of the Connect webhook endpoint), APP_URL (where the app lives).
import Stripe from "npm:stripe@22.4.0";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

export const API_VERSION = Deno.env.get("STRIPE_API_VERSION") || "2026-07-29.dahlia";
export const APP_URL = (Deno.env.get("APP_URL") || "https://dubbrollin.github.io/avtc-track-app").replace(/\/$/, "");

export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

export function stripeClient() {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) throw new Error("STRIPE_SECRET_KEY is not set");
  return new Stripe(key, { apiVersion: API_VERSION as Stripe.LatestApiVersion, httpClient: Stripe.createFetchHttpClient() });
}

// Accounts v2 (connected accounts) — called straight over HTTP so we don't depend on SDK naming for the v2 surface.
export async function stripeV2(path: string, body?: Record<string, unknown>, method = "POST") {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  const r = await fetch(`https://api.stripe.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${key}`, "Stripe-Version": API_VERSION, "Content-Type": "application/json" },
    body: body && method !== "GET" ? JSON.stringify(body) : undefined,
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message || `Stripe ${path} answered ${r.status}`);
  return j;
}

export function adminDb() {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
}
export function callerDb(authHeader: string) {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } }, auth: { persistSession: false },
  });
}

export const cents = (n: number | string) => Math.round(Number(n) * 100);
export const dollars = (c: number) => Math.round(c) / 100;
export const randomTag = () => Array.from({ length: 8 }, () => "abcdefghijklmnopqrstuvwxyz"[Math.floor(Math.random() * 26)]).join("");

// Is the team's connected account ready to take card payments? (Accounts v2 capability status)
export function cardStatus(acct: any): { status: "active" | "onboarding" | "restricted"; detail: string } {
  const cap = acct?.configuration?.merchant?.capabilities?.card_payments;
  const st = cap?.status;
  if (st === "active") return { status: "active", detail: "Card payments are on." };
  const reqs = acct?.requirements?.entries || acct?.requirements?.summary || null;
  const pastDue = Array.isArray(reqs) && reqs.some((e: any) => e?.minimum_deadline?.status === "past_due");
  if (pastDue || st === "inactive" || st === "restricted") return { status: "restricted", detail: "Stripe needs more information before this team can take payments. Open setup to finish." };
  return { status: "onboarding", detail: "Stripe setup isn't finished yet." };
}
