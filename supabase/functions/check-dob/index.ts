// Supabase Edge Function: check-dob
// Called by the coach dashboard. Downloads the uploaded proof-of-birth, asks Claude to read the
// name and date of birth, compares to the registration, and records match / mismatch.
// Secrets needed (set in Supabase > Edge Functions > Secrets): ANTHROPIC_API_KEY
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const anonClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });
    // Only a logged-in coach may run this (is_coach uses their token)
    const { data: isCoach } = await anonClient.rpc("is_coach");
    if (!isCoach) return json({ error: "Not authorized" }, 403);

    const { registration_id } = await req.json();
    if (!registration_id) return json({ error: "registration_id required" }, 400);

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: reg, error } = await admin.from("registrations").select("id,first_name,last_name,dob,proof_path").eq("id", registration_id).single();
    if (error || !reg) return json({ error: "Registration not found" }, 404);

    const { data: file, error: dlErr } = await admin.storage.from("proof-of-birth").download(reg.proof_path);
    if (dlErr || !file) return json({ error: "Could not download proof file" }, 500);
    const bytes = new Uint8Array(await file.arrayBuffer());
    let b64 = ""; for (let i = 0; i < bytes.length; i += 0x8000) b64 += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000) as unknown as number[]);
    b64 = btoa(b64);
    const isPdf = reg.proof_path.toLowerCase().endsWith(".pdf");
    const mediaType = isPdf ? "application/pdf" : (reg.proof_path.match(/\.png$/i) ? "image/png" : reg.proof_path.match(/\.webp$/i) ? "image/webp" : "image/jpeg");
    const block = isPdf
      ? { type: "document", source: { type: "base64", media_type: mediaType, data: b64 } }
      : { type: "image", source: { type: "base64", media_type: mediaType, data: b64 } };

    const prompt = `This is a proof-of-birth document (birth certificate, passport, or ID) for a youth sports registration. Read the person's full name and date of birth. Respond ONLY with JSON, no markdown: {"name": "<full name or null>", "dob": "<YYYY-MM-DD or null>", "document_type": "<birth certificate|passport|id|other|unreadable>", "confidence": "<high|medium|low>"}`;
    const ai = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": Deno.env.get("ANTHROPIC_API_KEY")!, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({ model: "claude-sonnet-4-6", max_tokens: 300, messages: [{ role: "user", content: [block, { type: "text", text: prompt }] }] }),
    });
    const aiJson = await ai.json();
    const text = (aiJson.content ?? []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("").replace(/```json|```/g, "").trim();
    let parsed: any = {};
    try { parsed = JSON.parse(text); } catch { parsed = {}; }

    let status = "unreadable", note = "";
    if (parsed.dob && /^\d{4}-\d{2}-\d{2}$/.test(parsed.dob)) {
      status = parsed.dob === reg.dob ? "match" : "mismatch";
      note = status === "match" ? `Document DOB ${parsed.dob} matches the form.` : `Form says ${reg.dob}, document reads ${parsed.dob}.`;
    } else {
      note = "Could not read a date of birth from the document.";
    }
    const regName = `${reg.first_name} ${reg.last_name}`.toLowerCase();
    if (parsed.name && !parsed.name.toLowerCase().includes(reg.last_name.toLowerCase())) note += ` Name on document ("${parsed.name}") may not match "${regName}".`;
    if (parsed.confidence === "low") note += " (Low confidence read — please check by eye.)";

    await admin.from("registrations").update({
      dob_check_status: status, dob_extracted: status === "unreadable" ? null : parsed.dob,
      name_extracted: parsed.name ?? null, dob_check_note: note, dob_checked_at: new Date().toISOString(),
    }).eq("id", reg.id);

    return json({ status, note, extracted: parsed });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });
}
