// Livestream — part of the team's Paid extras (same switch as the Team Messenger).
// A coach or team admin streams a meet to YouTube Live (free), pastes the link here, and the team's
// coaches and parents watch it right on their dashboard. Who may add / watch is checked in the database
// (supabase/2026-11-06-livestream.sql).
//
//   window.Livestream.mount(el, { sb, team })  -> 'on' | 'none'
//     team given (Coach Dashboard): just that team.  No team (Parent Dashboard): every team the person
//     is on that has the Paid extras. Returns 'none' when there's nothing to show, so the page can keep
//     the card hidden (like the messenger).
//
// The private in-app option (Cloudflare Stream) is built but off until a Cloudflare account exists:
// set LIVESTREAM_PRIVATE: true in config.js and deploy supabase/functions/livestream to turn it on.
(function () {
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const CFG = () => window.APP_CONFIG || {};
  const privateOn = () => !!CFG().LIVESTREAM_PRIVATE;
  const fnUrl = () => String(CFG().SUPABASE_URL || "").replace(/\/$/, "") + "/functions/v1/livestream";
  const teamName = (code) => ((window.VYC_TEAMS || []).find((t) => t.code === code) || {}).name || code;
  const ELEVEN = /^[A-Za-z0-9_-]{11}$/;

  // The 11-char video id from a YouTube link (watch?v=, youtu.be/, /live/, /embed/, /shorts/) or a bare id.
  // Anything that isn't a YouTube address is refused.
  function ytId(input) {
    const s = String(input || "").trim();
    if (!s) return null;
    if (ELEVEN.test(s)) return s;
    let u;
    try { u = new URL(s.includes("://") ? s : "https://" + s); } catch (e) { return null; }
    const host = u.hostname.replace(/^www\./, "").toLowerCase();
    const yt = host === "youtube.com" || host.endsWith(".youtube.com") || host === "youtu.be" || host === "youtube-nocookie.com";
    if (!yt) return null;
    if (host === "youtu.be") { const m = u.pathname.match(/^\/([A-Za-z0-9_-]{11})/); return m ? m[1] : null; }
    const v = u.searchParams.get("v");
    if (v && ELEVEN.test(v)) return v;
    const m = u.pathname.match(/^\/(?:live|embed|shorts|v)\/([A-Za-z0-9_-]{11})/);
    return m ? m[1] : null;
  }

  async function callFn(sb, action, stream, method = "GET") {
    const { data: s } = await sb.auth.getSession();
    const u = `${fnUrl()}?action=${encodeURIComponent(action)}${stream ? "&stream=" + encodeURIComponent(stream) : ""}`;
    const r = await fetch(u, {
      method,
      headers: { Authorization: `Bearer ${s?.session?.access_token}`, "Content-Type": "application/json", apikey: CFG().SUPABASE_ANON_KEY },
      body: method === "POST" ? JSON.stringify({ stream }) : undefined,
    });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || "HTTP " + r.status);
    return body;
  }

  const STYLE = `<style>
.ls-row{display:flex;align-items:center;gap:.5rem;padding:.55rem .25rem;border-bottom:1px solid #eee}
.ls-row:last-child{border-bottom:0}
.ls-title{flex:1;min-width:0;font-weight:600;overflow:hidden;text-overflow:ellipsis}
.ls-live{color:#b91c1c;font-weight:700;font-size:.8rem;white-space:nowrap}
.ls-muted{color:#6b7280;font-size:.8rem;white-space:nowrap}
.ls-b{border:1px solid #d1d5db;background:#fff;border-radius:8px;padding:.35rem .7rem;font-size:.85rem;font-weight:600;cursor:pointer;white-space:nowrap}
.ls-b.pri{background:#111827;color:#fff;border-color:#111827}
.ls-b.red{color:#b91c1c}
.ls-in{width:100%;border:1px solid #d1d5db;border-radius:8px;padding:.5rem .6rem;font-size:.95rem}
.ls-form{border:1px solid #e5e7eb;background:#f9fafb;border-radius:10px;padding:.75rem;margin:.5rem 0}
.ls-player{position:relative;padding-top:56.25%;margin:.5rem 0;background:#000;border-radius:10px;overflow:hidden}
.ls-player iframe,.ls-player video{position:absolute;inset:0;width:100%;height:100%;border:0}
.ls-team{font-weight:700;font-size:.8rem;text-transform:uppercase;letter-spacing:.04em;color:#6b7280;margin-top:.75rem}
</style>`;

  async function playHls(video, url) {
    if (!window.Hls && !video.canPlayType("application/vnd.apple.mpegurl")) {
      await new Promise((ok) => { const s = document.createElement("script"); s.src = "https://cdn.jsdelivr.net/npm/hls.js@1.5.15/dist/hls.min.js"; s.onload = s.onerror = ok; document.head.appendChild(s); });
    }
    if (window.Hls && window.Hls.isSupported()) { const h = new window.Hls({ lowLatencyMode: true }); h.loadSource(url); h.attachMedia(video); }
    else video.src = url;
    video.play().catch(() => {});
  }

  async function renderTeam(box, sb, t, multi) {
    const { data, error } = await sb.rpc("live_list", { p_team: t.team_code });
    const streams = error ? [] : data || [];
    const rows = streams.map((s) => {
      const badge = s.status === "live" ? `<span class="ls-live">● LIVE</span>`
        : s.status === "ended" ? `<span class="ls-muted">${s.provider === "youtube" || s.recording_url ? "Replay" : "Ended"}</span>`
        : `<span class="ls-muted">Not started</span>`;
      const when = s.started_at || s.created_at;
      const date = when ? new Date(when).toLocaleDateString(undefined, { month: "short", day: "numeric" }) : "";
      const mgmt = t.can_broadcast
        ? (s.status !== "ended" ? `<button class="ls-b" data-end="${s.id}">End</button>` : "") + `<button class="ls-b red" data-del="${s.id}" title="Delete">✕</button>`
        : "";
      return `<div class="ls-row"><span class="ls-title">${esc(s.title)} <span class="ls-muted">${esc(date)}</span></span>${badge}
        <button class="ls-b pri" data-watch="${s.id}" data-provider="${esc(s.provider)}" data-pid="${esc(s.playback_id || "")}">Watch</button>${mgmt}</div>`;
    }).join("");

    box.innerHTML = `${multi ? `<div class="ls-team">${esc(teamName(t.team_code))}</div>` : ""}
      <div data-k="player"></div>
      ${t.can_broadcast ? `<div><button class="ls-b" data-k="new">＋ Add a livestream</button></div><div data-k="form"></div>` : ""}
      ${rows || `<p class="text-sm text-gray-500" style="padding:.4rem 0">No livestreams yet.${t.can_broadcast ? "" : " When a coach goes live at a meet, it shows up here."}</p>`}`;

    const player = box.querySelector('[data-k="player"]');
    box.querySelectorAll("[data-watch]").forEach((b) => b.onclick = async () => {
      try {
        if (b.dataset.provider === "youtube") {
          player.innerHTML = `<div class="ls-player"><iframe src="https://www.youtube.com/embed/${encodeURIComponent(b.dataset.pid)}?autoplay=1&playsinline=1&rel=0" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe></div>`;
        } else {
          const r = await callFn(sb, "token", b.dataset.watch);
          const src = r.status === "ended" && r.recording ? r.recording : r.hls;
          if (!src) { alert("This livestream isn't ready to watch yet."); return; }
          player.innerHTML = `<div class="ls-player"><video controls playsinline></video></div>`;
          playHls(player.querySelector("video"), src);
        }
        player.scrollIntoView({ behavior: "smooth", block: "nearest" });
      } catch (e) { alert(e.message || e); }
    });
    box.querySelectorAll("[data-end]").forEach((b) => b.onclick = async () => {
      if (!confirm("End this livestream? It stays in the list as a replay.")) return;
      const { error } = await sb.rpc("live_set_status", { p_stream: b.dataset.end, p_status: "ended" });
      if (error) { alert(error.message); return; }
      renderTeam(box, sb, t, multi);
    });
    box.querySelectorAll("[data-del]").forEach((b) => b.onclick = async () => {
      if (!confirm("Delete this livestream from the list? (The video on YouTube is not touched.)")) return;
      const { error } = await sb.rpc("live_delete", { p_stream: b.dataset.del });
      if (error) { alert(error.message); return; }
      renderTeam(box, sb, t, multi);
    });

    const nb = box.querySelector('[data-k="new"]');
    if (nb) nb.onclick = () => {
      const form = box.querySelector('[data-k="form"]');
      if (form.innerHTML) { form.innerHTML = ""; return; }
      form.innerHTML = `<div class="ls-form">
        <p class="text-sm" style="margin:0 0 .5rem"><b>1.</b> Start a live stream in the <b>YouTube</b> app (tap ＋ then <b>Go live</b>) and set it to <b>Unlisted</b>.<br>
        <b>2.</b> Tap <b>Share</b> in YouTube, copy the link, and paste it below. Your team can watch it here; nobody else is sent the link.</p>
        <label class="text-sm font-semibold">Name<input class="ls-in" data-k="title" placeholder="e.g. Week 3 meet — relays" maxlength="80"></label>
        <label class="text-sm font-semibold" style="display:block;margin-top:.5rem">YouTube link<input class="ls-in" data-k="link" placeholder="https://youtube.com/live/…" inputmode="url"></label>
        ${privateOn() ? `<label class="text-sm" style="display:flex;gap:.4rem;align-items:center;margin-top:.5rem"><input type="checkbox" data-k="priv"> Private in-app stream instead (no YouTube; you'll get a stream key for OBS / Larix)</label>` : ""}
        <div style="display:flex;gap:.5rem;margin-top:.6rem;align-items:center"><button class="ls-b pri" data-k="go">Add livestream</button><button class="ls-b" data-k="cancel">Cancel</button><span class="text-sm" data-k="msg"></span></div></div>`;
      const g = (k) => form.querySelector(`[data-k="${k}"]`);
      g("cancel").onclick = () => { form.innerHTML = ""; };
      g("go").onclick = async () => {
        const title = g("title").value.trim() || "Live";
        g("go").disabled = true;
        try {
          if (g("priv") && g("priv").checked) {
            const { data: id, error } = await sb.rpc("live_create", { p_team: t.team_code, p_title: title });
            if (error) throw error;
            const res = await callFn(sb, "create", id, "POST");
            const ing = res.ingest || {};
            form.innerHTML = `<div class="ls-form"><b>Ready.</b> Put these in OBS or the Larix app, start streaming, then press Go Live.
              <div class="text-xs" style="margin-top:.4rem"><b>Server:</b><br><code>${esc(ing.rtmps_url || "")}</code></div>
              <div class="text-xs" style="margin-top:.3rem"><b>Stream key (keep private):</b><br><code>${esc(ing.rtmps_key || "")}</code></div>
              <div style="margin-top:.5rem"><button class="ls-b pri" data-k="golive">Go Live</button></div></div>`;
            form.querySelector('[data-k="golive"]').onclick = async () => {
              const { error: e2 } = await sb.rpc("live_set_status", { p_stream: id, p_status: "live" });
              if (e2) { alert(e2.message); return; }
              renderTeam(box, sb, t, multi);
            };
            return;
          }
          const id = ytId(g("link").value);
          if (!id) { g("msg").textContent = "That isn't a YouTube link."; g("msg").style.color = "#b91c1c"; g("go").disabled = false; return; }
          const { error } = await sb.rpc("live_create_youtube", { p_team: t.team_code, p_title: title, p_youtube_id: id });
          if (error) throw error;
          renderTeam(box, sb, t, multi);
        } catch (e) { g("msg").textContent = e.message || String(e); g("msg").style.color = "#b91c1c"; g("go").disabled = false; }
      };
    };
  }

  const Livestream = {
    ytId,
    async mount(el, { sb, team } = {}) {
      sb = sb || window.sb;
      if (!el || !sb) return "none";
      let teams = [];
      try { const { data, error } = await sb.rpc("live_my_teams"); if (!error) teams = (data || []).filter((t) => t.enabled); } catch (e) {}
      if (team) teams = teams.filter((t) => t.team_code === team);
      if (!teams.length) { el.innerHTML = ""; return "none"; }
      el.innerHTML = STYLE + teams.map((t, i) => `<div data-team="${i}"><p class="text-sm text-gray-500">Loading…</p></div>`).join("");
      await Promise.all(teams.map((t, i) => renderTeam(el.querySelector(`[data-team="${i}"]`), sb, t, teams.length > 1)));
      return "on";
    },
  };
  window.Livestream = Livestream;
})();
