// Supabase Edge Function: usatf-verify
// For a coach who says they're USA Track & Field certified, searches USATF's public lists by name
// (California first, then nationwide) and records the result on the coach's record:
//   1. 3-Step Safe Sport Compliance List (usatf.sport80.com/public/widget/1, linked from usatf.org > Safe Sport >
//      Safe Sport Compliant List): "all USATF members that also hold current Safe Sport Training and a valid
//      Background Screening". On this list = background check VERIFIED.
//   2. Coaches Registry (usatf.sport80.com/public/widget/3): coaching certification level + Current status (extra info).
// Who may run it: the coach themself, a site admin, or a team admin of that coach's team.
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are provided automatically.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const SAFESPORT_LIST = "https://usatf.sport80.com/api/public/widget/data/new/1";
const REGISTRY = "https://usatf.sport80.com/api/public/widget/data/new/3";
const CALIFORNIA = "66"; // the lists' State filter value for California
const norm = (s: string) => (s || "").toLowerCase().replace(/[^a-z]/g, "");

async function search(list: string, name: string, region: string | null) {
  const form = new FormData();
  if (region) form.set("region", region);
  const url = `${list}?p=0&i=50&s=${encodeURIComponent(name)}&l=&d=0&f=`;
  const r = await fetch(url, { method: "POST", body: form, headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`USATF registry answered ${r.status}`);
  const j = await r.json();
  return (j.data || []) as Array<{ id: string; name: string; info?: Array<{ title: string; value: unknown }> }>;
}

function summarize(entry: { id: string; name: string; info?: Array<{ title: string; value: any }> }) {
  const items = (entry.info || []).map((i) => ({
    title: i.title,
    value: typeof i.value === "object" && i.value !== null ? (i.value.text ?? "") : String(i.value ?? ""),
    current: typeof i.value === "object" && i.value !== null && /current/i.test(i.value.text ?? "") && i.value.style === "success",
  }));
  return { registry_id: entry.id, name: entry.name, items, current: items.some((x) => x.current) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const caller = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: u } = await caller.auth.getUser();
    const me = (u?.user?.email || "").toLowerCase();
    if (!me) return json({ error: "Please sign in." }, 401);

    const { email } = await req.json().catch(() => ({}));
    const target = String(email || me).toLowerCase();
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: coach } = await admin.from("coaches")
      .select("email,first_name,last_name,name,team_code,usatf_certified").ilike("email", target).maybeSingle();
    if (!coach) return json({ error: "Coach not found" }, 404);

    if (target !== me) {
      const [{ data: site }, { data: team }] = await Promise.all([
        caller.rpc("is_site_admin"), caller.rpc("is_team_admin_of", { t: coach.team_code }),
      ]);
      if (!site && !team) return json({ error: "Not authorized" }, 403);
    }
    if (!coach.usatf_certified) return json({ status: "not_applicable" });

    const full = [coach.first_name, coach.last_name].filter(Boolean).join(" ").trim() || (coach.name || "").trim();
    if (!full) return json({ error: "Coach has no name on file" }, 400);

    // Exact first + last name, California first, then nationwide.
    const find = async (list: string) => {
      let exact = (await search(list, full, CALIFORNIA)).filter((r) => norm(r.name) === norm(full)), scope = "California";
      if (!exact.length) { scope = "nationwide"; exact = (await search(list, full, null)).filter((r) => norm(r.name) === norm(full)); }
      return { scope, matches: exact.map(summarize) };
    };
    let status = "not_found", safesport = { scope: "", matches: [] as ReturnType<typeof summarize>[] }, registry = { scope: "", matches: [] as ReturnType<typeof summarize>[] }, err = "";
    try {
      safesport = await find(SAFESPORT_LIST);
      registry = await find(REGISTRY);
      // On the Safe Sport Compliance list = current USATF background screen (and SafeSport training) verified.
      status = safesport.matches.length ? "verified" : registry.matches.length ? "not_current" : "not_found";
    } catch (e) { status = "error"; err = String((e as Error).message || e); }
    const detail = {
      searched: full, checked_by: me, error: err || undefined,
      safesport_list: { found: safesport.matches.length > 0, scope: safesport.scope, names: safesport.matches.map((m) => m.name) },
      coaches_registry: { found: registry.matches.length > 0, scope: registry.scope, matches: registry.matches },
    };
    await admin.from("coaches").update({
      usatf_registry_status: status, usatf_registry_checked_at: new Date().toISOString(), usatf_registry_detail: detail,
    }).ilike("email", target);
    return json({ status, detail });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}
