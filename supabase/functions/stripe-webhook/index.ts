// Supabase Edge Function: stripe-webhook
// Stripe tells us what happened on every TEAM's Stripe account (a Connect webhook endpoint, "events on connected
// accounts"). This is the only place card payments are written to the database — never the success page.
// Events handled: checkout.session.completed, checkout.session.async_payment_succeeded, checkout.session.async_payment_failed,
//                 invoice.paid, invoice.payment_failed, customer.subscription.deleted, charge.refunded
// Deploy: npx supabase functions deploy stripe-webhook --no-verify-jwt --use-api --agent no
// Then in the VYC platform Stripe dashboard: Developers → Webhooks → add endpoint, "Events on Connected accounts",
// URL https://<project>.supabase.co/functions/v1/stripe-webhook, pick the events above, and save its signing secret
// as STRIPE_WEBHOOK_SECRET.
import Stripe from "npm:stripe@22.4.0";
import { adminDb, dollars, stripeClient } from "../_shared/stripe.ts";

const cryptoProvider = Stripe.createSubtleCryptoProvider();
const today = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Los_Angeles" });
const isoDate = (unix: number) => new Date(unix * 1000).toLocaleDateString("en-CA", { timeZone: "America/Los_Angeles" });
const subOf = (inv: any): string | null => inv?.parent?.subscription_details?.subscription ?? (typeof inv?.subscription === "string" ? inv.subscription : inv?.subscription?.id) ?? null;
const piOf = (x: any): string | null => typeof x === "string" ? x : x?.id ?? null;

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature") || "";
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret) return new Response("STRIPE_WEBHOOK_SECRET not set", { status: 500 });
  const raw = await req.text();
  let event: Stripe.Event;
  try { event = await Stripe.webhooks.constructEventAsync(raw, sig, secret, undefined, cryptoProvider); }
  catch (e) { return new Response(`Bad signature: ${(e as Error).message}`, { status: 400 }); }

  const acctId = (event as any).account as string | undefined; // the connected (team) account the event happened on
  const db = adminDb();
  const stripe = stripeClient();
  const opts = acctId ? { stripeAccount: acctId } : undefined;

  try {
    switch (event.type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded": {
        const s = event.data.object as Stripe.Checkout.Session;
        if (s.mode === "setup") { await handleNewCard(s); break; }
        if (s.payment_status === "unpaid") break; // bank-debit style methods: wait for async_payment_succeeded
        await handlePaid(s);
        break;
      }
      case "checkout.session.async_payment_failed": {
        const s = event.data.object as Stripe.Checkout.Session;
        const feeId = s.metadata?.fee_id; if (!feeId) break;
        await db.from("fee_payments").insert({ fee_id: feeId, team_code: s.metadata?.team_code, method: "card", kind: s.metadata?.kind === "deposit" ? "deposit" : "full",
          amount: dollars(s.amount_total || 0), status: "failed", reference: s.id, reported_by: s.customer_email || null, note: "Card payment did not go through" });
        break;
      }
      case "invoice.paid": {
        const inv = event.data.object as Stripe.Invoice;
        const subId = subOf(inv); if (!subId) break;
        if (inv.billing_reason === "subscription_create" && (inv.amount_paid || 0) === 0) break; // trial start, nothing charged
        const { data: fee } = await db.from("athlete_fees").select("*").eq("stripe_subscription_id", subId).maybeSingle();
        if (!fee) break;
        const ins = await db.from("fee_payments").upsert({ fee_id: fee.id, team_code: fee.team_code, method: "card", kind: "installment", amount: dollars(inv.amount_paid || 0), status: "received",
          stripe_invoice_id: inv.id, stripe_payment_intent_id: piOf((inv as any).payment_intent) || null, received_on: today(), recorded_by: "stripe", reported_by: "stripe",
          note: `Installment ${Math.min((fee.plan_paid || 0) + 1, fee.plan_installments || 0)} of ${fee.plan_installments || 0}` }, { onConflict: "stripe_invoice_id", ignoreDuplicates: true }).select("id");
        if (!ins.data?.length) break; // already recorded
        const paid = (fee.plan_paid || 0) + 1;
        const done = paid >= (fee.plan_installments || 0);
        const nextOn = done ? null : (inv.lines?.data?.[0]?.period?.end ? isoDate(inv.lines.data[0].period.end) : null);
        await db.from("athlete_fees").update({ plan_paid: paid, plan_next_on: nextOn, plan_failed: false, updated_at: new Date().toISOString() }).eq("id", fee.id);
        if (done) { try { await stripe.subscriptions.cancel(subId, {}, opts); } catch { /* may already be ending via cancel_at */ } }
        await db.rpc("refresh_fee_status", { p_fee: fee.id });
        break;
      }
      case "invoice.payment_failed": {
        const inv = event.data.object as Stripe.Invoice;
        const subId = subOf(inv); if (!subId) break;
        const { data: fee } = await db.from("athlete_fees").select("id,team_code,plan_paid,plan_installments").eq("stripe_subscription_id", subId).maybeSingle();
        if (!fee) break;
        await db.from("athlete_fees").update({ plan_failed: true, updated_at: new Date().toISOString() }).eq("id", fee.id);
        await db.from("fee_payments").insert({ fee_id: fee.id, team_code: fee.team_code, method: "card", kind: "installment", amount: dollars(inv.amount_due || 0), status: "failed",
          reference: inv.id, recorded_by: "stripe", reported_by: "stripe", note: `Installment ${(fee.plan_paid || 0) + 1} of ${fee.plan_installments || 0} failed — card declined or expired` });
        break;
      }
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        const { data: fee } = await db.from("athlete_fees").select("id,plan_paid,plan_installments,note").eq("stripe_subscription_id", sub.id).maybeSingle();
        if (!fee) break;
        if ((fee.plan_paid || 0) < (fee.plan_installments || 0)) {
          await db.from("athlete_fees").update({ plan_installments: fee.plan_paid || 0, plan_next_on: null, plan_failed: false, updated_at: new Date().toISOString(),
            note: [fee.note, `Card plan ended early after ${fee.plan_paid || 0} of ${fee.plan_installments || 0} payments`].filter(Boolean).join(" · ") }).eq("id", fee.id);
          await db.rpc("refresh_fee_status", { p_fee: fee.id });
        }
        break;
      }
      case "charge.refunded": {
        const ch = event.data.object as Stripe.Charge;
        const pi = piOf((ch as any).payment_intent); if (!pi) break;
        const { data: pay } = await db.from("fee_payments").select("id,fee_id,team_code,amount").eq("stripe_payment_intent_id", pi).maybeSingle();
        if (!pay) break;
        const { data: prior } = await db.from("fee_payments").select("amount").eq("fee_id", pay.fee_id).eq("kind", "refund").eq("reference", pi);
        const already = (prior || []).reduce((s: number, r: any) => s + Number(r.amount), 0);
        const delta = dollars(ch.amount_refunded || 0) - already;
        if (delta > 0) await db.from("fee_payments").insert({ fee_id: pay.fee_id, team_code: pay.team_code, method: "card", kind: "refund", amount: delta, status: "refunded",
          reference: pi, received_on: today(), recorded_by: "stripe", reported_by: "stripe", note: "Refunded in Stripe" });
        break;
      }
    }
  } catch (e) {
    console.error(event.type, (e as Error).message);
    return new Response(`Handler error: ${(e as Error).message}`, { status: 500 }); // Stripe retries
  }
  return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });

  // ---- a Checkout payment went through: full / partial / deposit ----
  async function handlePaid(s: Stripe.Checkout.Session) {
    const m = s.metadata || {}; const feeId = m.fee_id; if (!feeId) return;
    const { data: fee } = await db.from("athlete_fees").select("*").eq("id", feeId).maybeSingle(); if (!fee) return;
    const kind = m.kind === "deposit" ? "deposit" : m.kind === "partial" ? "partial" : "full";
    const ins = await db.from("fee_payments").upsert({ fee_id: fee.id, team_code: fee.team_code, method: "card", kind, amount: dollars(s.amount_total || 0), status: "received",
      stripe_checkout_session_id: s.id, stripe_payment_intent_id: piOf((s as any).payment_intent) || null, received_on: today(), recorded_by: "stripe", reported_by: s.customer_email || null,
      note: kind === "deposit" ? "Deposit (card payment plan)" : null }, { onConflict: "stripe_checkout_session_id", ignoreDuplicates: true }).select("id");
    if (!ins.data?.length) return; // duplicate delivery

    if (kind === "deposit" && !fee.stripe_subscription_id) await startPlan(s, fee);

    // Paid in full while a plan was still running? End the plan.
    const { data: paidTotal } = await db.rpc("fee_paid_total", { p_fee: fee.id });
    if (fee.stripe_subscription_id && Number(paidTotal || 0) >= Number(fee.amount_due)) {
      try { await stripe.subscriptions.cancel(fee.stripe_subscription_id, {}, opts); } catch { /* already gone */ }
      await db.from("athlete_fees").update({ plan_installments: fee.plan_paid || 0, plan_next_on: null, plan_failed: false, updated_at: new Date().toISOString() }).eq("id", fee.id);
    }
    await db.rpc("refresh_fee_status", { p_fee: fee.id });
  }

  // ---- the deposit is in: start the monthly installments on the team's account with the card that was just saved ----
  async function startPlan(s: Stripe.Checkout.Session, fee: any) {
    const m = s.metadata || {};
    const n = Math.max(1, Number(m.plan_installments || 1));
    const instC = Number(m.plan_amount_cents || 0);
    const customer = typeof s.customer === "string" ? s.customer : s.customer?.id;
    const piId = piOf((s as any).payment_intent);
    if (!customer || !piId || instC <= 0) throw new Error("Deposit session is missing the customer, payment or plan amount");
    const pi = await stripe.paymentIntents.retrieve(piId, {}, opts);
    const pm = typeof pi.payment_method === "string" ? pi.payment_method : pi.payment_method?.id;
    if (!pm) throw new Error("No saved card on the deposit payment");
    await stripe.customers.update(customer, { invoice_settings: { default_payment_method: pm } }, opts);

    // First installment on the team's chosen date (noon Pacific), then monthly; the subscription cancels itself 3 days after the last one.
    const [y, mo, d] = String(m.plan_first_date || today()).split("-").map(Number);
    const first = Math.floor(Date.UTC(y, mo - 1, d, 19) / 1000);
    const now = Math.floor(Date.now() / 1000);
    const startsLater = first > now + 300;
    const anchor = startsLater ? first : now;
    const lastDate = new Date(anchor * 1000); lastDate.setUTCMonth(lastDate.getUTCMonth() + (n - 1));
    const cancelAt = Math.floor(lastDate.getTime() / 1000) + 3 * 86400;
    const product = await stripe.products.create({ name: `${m.team_name || fee.team_code} ${m.season || fee.season_year} team fee — monthly payment for ${m.athlete || "athlete"}` }, opts);
    const sub = await stripe.subscriptions.create({
      customer, default_payment_method: pm, off_session: true, proration_behavior: "none",
      items: [{ quantity: 1, price_data: { currency: "usd", product: product.id, unit_amount: instC, recurring: { interval: "month" } } }],
      ...(startsLater ? { trial_end: first } : {}),
      cancel_at: cancelAt,
      description: `${m.team_name || fee.team_code} ${m.season || fee.season_year} team fee — ${n} monthly payment${n > 1 ? "s" : ""} for ${m.athlete || "athlete"}`,
      metadata: { fee_id: fee.id, registration_id: fee.registration_id, team_code: fee.team_code, installments: String(n), app: "vyc-track" },
      payment_settings: { save_default_payment_method: "on_subscription" },
    }, opts);
    await db.from("athlete_fees").update({ stripe_customer_id: customer, stripe_subscription_id: sub.id, plan_installments: n, plan_amount: dollars(instC), plan_paid: 0,
      plan_next_on: isoDate(anchor), plan_failed: false, updated_at: new Date().toISOString() }).eq("id", fee.id);
    // If the plan starts today, Stripe charges the first installment right away and invoice.paid records it.
  }

  // ---- parent put a new card on a failing plan: use it for the subscription and retry what's owed ----
  async function handleNewCard(s: Stripe.Checkout.Session) {
    const feeId = s.metadata?.fee_id; if (!feeId) return;
    const { data: fee } = await db.from("athlete_fees").select("*").eq("id", feeId).maybeSingle();
    if (!fee?.stripe_subscription_id) return;
    const siId = typeof s.setup_intent === "string" ? s.setup_intent : s.setup_intent?.id; if (!siId) return;
    const si = await stripe.setupIntents.retrieve(siId, {}, opts);
    const pm = typeof si.payment_method === "string" ? si.payment_method : si.payment_method?.id; if (!pm) return;
    const customer = typeof s.customer === "string" ? s.customer : s.customer?.id || fee.stripe_customer_id;
    if (customer) await stripe.customers.update(customer, { invoice_settings: { default_payment_method: pm } }, opts);
    await stripe.subscriptions.update(fee.stripe_subscription_id, { default_payment_method: pm }, opts);
    const open = await stripe.invoices.list({ subscription: fee.stripe_subscription_id, status: "open", limit: 10 }, opts);
    for (const inv of open.data) { try { await stripe.invoices.pay(inv.id, { payment_method: pm }, opts); } catch (e) { console.error("retry invoice", inv.id, (e as Error).message); } }
    // invoice.paid (if the retry works) clears plan_failed and records the installment.
  }
});
