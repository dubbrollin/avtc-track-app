// Supabase Edge Function: fee-checkout
// A parent pays their team's fee by card through the TEAM's Stripe account (direct charge on the connected account).
// Works before the parent has a login: the registration id + the email on the registration is the proof.
//   { action: "pay",         registration_id, email }  → Checkout for the remaining balance (one payment)
//   { action: "plan",        registration_id, email }  → Checkout for the deposit; the card is saved and the webhook
//                                                        starts the monthly installments (a Stripe subscription that
//                                                        ends by itself after the last installment)
//   { action: "update_card", registration_id, email }  → Checkout (setup) to put a new card on a failing plan
// Every outcome is recorded by the stripe-webhook function, never by the success page.
// Deploy: npx supabase functions deploy fee-checkout --no-verify-jwt --use-api --agent no
import { adminDb, callerDb, cents, cors, dollars, json, randomTag, stripeClient, APP_URL } from "../_shared/stripe.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const action = String(body.action || "pay");
    const regId = String(body.registration_id || "");
    const email = String(body.email || "").trim().toLowerCase();
    if (!regId) return json({ error: "Missing registration." }, 400);

    // Who's asking? A signed-in user whose email matches, or the email typed on the pay page.
    let me = "";
    const authHeader = req.headers.get("Authorization") ?? "";
    if (authHeader.startsWith("Bearer ")) { try { const { data: u } = await callerDb(authHeader).auth.getUser(); me = (u?.user?.email || "").toLowerCase(); } catch { /* anon */ } }

    const db = adminDb();
    const { data: reg } = await db.from("registrations").select("id,first_name,last_name,email,team_code,season_year,status").eq("id", regId).maybeSingle();
    if (!reg) return json({ error: "Registration not found." }, 404);
    const regEmail = String(reg.email || "").toLowerCase();
    if (regEmail !== email && regEmail !== me) return json({ error: "That email doesn't match this registration." }, 403);

    const [{ data: fee }, { data: settings }, { data: acct }, { data: teamRow }] = await Promise.all([
      db.from("athlete_fees").select("*").eq("registration_id", reg.id).maybeSingle(),
      db.from("team_payment_settings").select("*").eq("team_code", reg.team_code).eq("season_year", reg.season_year).maybeSingle(),
      db.from("team_stripe_accounts").select("*").eq("team_code", reg.team_code).maybeSingle(),
      db.from("league_teams").select("name").eq("code", reg.team_code).maybeSingle(),
    ]);
    if (!fee) return json({ error: "No fee is set up for this athlete yet. Ask your team." }, 400);
    if (!settings?.accept_card) return json({ error: "This team isn't taking card payments." }, 400);
    if (!acct || acct.status !== "active") return json({ error: "This team's card payments aren't switched on yet. Choose another way to pay, or check back soon." }, 400);
    if (["paid", "waived", "void"].includes(fee.status)) return json({ error: "Nothing is owed for this athlete." }, 400);

    const { data: paidTotal } = await db.rpc("fee_paid_total", { p_fee: fee.id });
    const balance = Math.max(Number(fee.amount_due) - Number(paidTotal || 0), 0);
    const teamName = teamRow?.name || reg.team_code;
    const athlete = `${reg.first_name} ${reg.last_name}`;
    const stripe = stripeClient();
    const opts = { stripeAccount: acct.stripe_account_id };
    const payUrl = `${APP_URL}/pay.html?reg=${encodeURIComponent(reg.id)}&email=${encodeURIComponent(regEmail)}`;
    const common = {
      customer_email: regEmail,
      success_url: payUrl + "&done=1",
      cancel_url: payUrl,
      integration_identifier: `vyc_team_fee_${randomTag()}`,
    };

    if (action === "pay") {
      if (balance <= 0) return json({ error: "Nothing is owed for this athlete." }, 400);
      const session = await stripe.checkout.sessions.create({
        ...common,
        mode: "payment",
        line_items: [{ quantity: 1, price_data: { currency: "usd", unit_amount: cents(balance),
          product_data: { name: `${teamName} ${reg.season_year} team fee — ${athlete}` } } }],
        payment_intent_data: { description: `${teamName} ${reg.season_year} team fee — ${athlete}`, metadata: { fee_id: fee.id, registration_id: reg.id, kind: fee.stripe_subscription_id ? "partial" : "full" } },
        metadata: { fee_id: fee.id, registration_id: reg.id, kind: fee.stripe_subscription_id ? "partial" : "full", team_code: reg.team_code },
      }, opts);
      return json({ url: session.url });
    }

    if (action === "plan") {
      if (!settings.plan_enabled) return json({ error: "This team doesn't offer a payment plan." }, 400);
      if (fee.stripe_subscription_id) return json({ error: "A payment plan is already running for this athlete." }, 400);
      if (Number(paidTotal || 0) > 0) return json({ error: "A payment plan is only available before any payment has been made. Use 'Pay the balance' instead." }, 400);
      const n = Math.max(1, Number(settings.plan_installments || 1));
      const depositSet = Number(settings.plan_deposit || 0);
      if (depositSet >= balance) return json({ error: "The deposit covers the whole fee — just pay in full." }, 400);
      // Monthly installment = equal share (whole cents); any leftover cents ride on the deposit, which is charged first.
      const instC = Math.floor((cents(balance) - cents(depositSet)) / n);
      const depositC = cents(balance) - instC * n;
      if (instC <= 0) return json({ error: "The payment plan amounts don't add up — ask your team to check the plan settings." }, 400);
      const session = await stripe.checkout.sessions.create({
        ...common,
        mode: "payment",
        customer_creation: "always",
        line_items: [{ quantity: 1, price_data: { currency: "usd", unit_amount: depositC,
          product_data: { name: `${teamName} ${reg.season_year} team fee — deposit for ${athlete}`,
            description: `Then ${n} monthly payment${n > 1 ? "s" : ""} of $${dollars(instC).toFixed(2)} starting ${settings.plan_first_date}` } } }],
        payment_intent_data: { setup_future_usage: "off_session", description: `${teamName} ${reg.season_year} team fee — deposit for ${athlete}`,
          metadata: { fee_id: fee.id, registration_id: reg.id, kind: "deposit" } },
        metadata: { fee_id: fee.id, registration_id: reg.id, kind: "deposit", team_code: reg.team_code,
          plan_installments: String(n), plan_amount_cents: String(instC), plan_first_date: String(settings.plan_first_date), athlete, team_name: teamName, season: String(reg.season_year) },
      }, opts);
      return json({ url: session.url, deposit: dollars(depositC), installment: dollars(instC), installments: n });
    }

    if (action === "update_card") {
      if (!fee.stripe_subscription_id || !fee.stripe_customer_id) return json({ error: "There's no card payment plan to update." }, 400);
      const session = await stripe.checkout.sessions.create({
        ...common,
        mode: "setup",
        customer: fee.stripe_customer_id,
        customer_email: undefined,
        metadata: { fee_id: fee.id, registration_id: reg.id, kind: "update_card", team_code: reg.team_code },
      }, opts);
      return json({ url: session.url });
    }

    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    return json({ error: (e as Error).message || String(e) }, 500);
  }
});
