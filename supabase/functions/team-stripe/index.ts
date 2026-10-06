// Supabase Edge Function: team-stripe
// A team admin (or site admin) sets up / checks their team's own Stripe account (Stripe Connect, Accounts v2).
// The team is the merchant: parents' card payments go straight to the team's bank account; the team pays Stripe's
// fees; VYC's platform account never holds the money.
//   { action: "connect", team_code }  → creates the connected account if the team has none, returns a hosted
//                                        onboarding link (one-time URL; Stripe sends them back to the admin page).
//   { action: "status",  team_code }  → re-checks whether card payments are active and saves it.
// Deploy: npx supabase functions deploy team-stripe --use-api --agent no   (JWT required — default)
import { adminDb, callerDb, cardStatus, cors, json, stripeV2, APP_URL } from "../_shared/stripe.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const caller = callerDb(authHeader);
    const { data: u } = await caller.auth.getUser();
    const me = (u?.user?.email || "").toLowerCase();
    if (!me) return json({ error: "Please sign in." }, 401);

    const { action, team_code } = await req.json().catch(() => ({}));
    const team = String(team_code || "").toUpperCase();
    if (!team) return json({ error: "Which team?" }, 400);
    const { data: allowed } = await caller.rpc("is_team_money_admin", { t: team });
    if (!allowed) return json({ error: "Only this team's team admin (or a site admin) can set up payments." }, 403);

    const db = adminDb();
    const { data: teamRow } = await db.from("league_teams").select("code,name").eq("code", team).maybeSingle();
    const teamName = teamRow?.name || team;
    let { data: acctRow } = await db.from("team_stripe_accounts").select("*").eq("team_code", team).maybeSingle();

    if (action === "connect") {
      if (!acctRow) {
        // SaaS-style connected account: full Stripe dashboard, Stripe collects its own fees and owns loss liability.
        const acct = await stripeV2("/v2/core/accounts", {
          display_name: teamName,
          contact_email: me,
          dashboard: "full",
          identity: { country: "us" },
          configuration: { merchant: { capabilities: { card_payments: { requested: true } } } },
          defaults: { currency: "usd", responsibilities: { fees_collector: "stripe", losses_collector: "stripe" }, locales: ["en-US"] },
          metadata: { team_code: team, app: "vyc-track" },
          include: ["configuration.merchant", "requirements"],
        });
        const st = cardStatus(acct);
        const ins = await db.from("team_stripe_accounts").insert({
          team_code: team, stripe_account_id: acct.id, status: st.status, status_detail: st.detail, checked_at: new Date().toISOString(), created_by: me,
        }).select("*").single();
        if (ins.error) throw ins.error;
        acctRow = ins.data;
      }
      const back = `${APP_URL}/coach.html?view=roster&tab=payments&stripe=${encodeURIComponent(team)}`;
      const link = await stripeV2("/v2/core/account_links", {
        account: acctRow!.stripe_account_id,
        use_case: { type: "account_onboarding", account_onboarding: { collection_options: { fields: "eventually_due" }, return_url: back, refresh_url: back + "&refresh=1" } },
      });
      return json({ url: link.url, account_id: acctRow!.stripe_account_id, status: acctRow!.status });
    }

    if (action === "status") {
      if (!acctRow) return json({ status: "none" });
      const acct = await stripeV2(`/v2/core/accounts/${acctRow.stripe_account_id}?include=configuration.merchant&include=requirements`, undefined, "GET");
      const st = cardStatus(acct);
      await db.from("team_stripe_accounts").update({ status: st.status, status_detail: st.detail, checked_at: new Date().toISOString() }).eq("team_code", team);
      return json({ status: st.status, detail: st.detail, account_id: acctRow.stripe_account_id });
    }

    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    return json({ error: (e as Error).message || String(e) }, 500);
  }
});
