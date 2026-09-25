// Shared helpers used by both pages
// The 16 real Valley Youth Conference (VYC) member teams, with their Hy-Tek team codes.
// Pulled from the league's own roster (tcl01-01.tcl) and results (reslt002.csv) exports.
window.VYC_TEAMS = [
  {code:"AVTC", name:"Antelope Valley Track Club", conference:"East"},
  {code:"BV",   name:"Burbank Vikings", conference:"East"},
  {code:"CAL",  name:"Calabasas", conference:"West"},
  {code:"WVE",  name:"Eagles (WVE)", conference:"East"},
  {code:"FP",   name:"Flying Phoenix", conference:"East"},
  {code:"LRR",  name:"Lancaster Runnin Rebels", conference:"West"},
  {code:"L5",   name:"Lane 5", conference:"West"},
  {code:"LAF",  name:"Los Angeles Falcons", conference:"West"},
  {code:"NPTC", name:"Northridge Pacers", conference:"East"},
  {code:"PB",   name:"Palmdale Bullets", conference:"East"},
  {code:"SFR",  name:"Rush", conference:"West"},
  {code:"SCTC", name:"Storm", conference:"West"},
  {code:"TT",   name:"Thimsha", conference:"East"},
  {code:"VRTC", name:"Valley Raiders", conference:"West"},
  {code:"VC",   name:"Village Christian Schools", conference:"East"},
  {code:"SCW",  name:"Warriors", conference:"East"}
];
// Backward-compatible plain-name list, kept in case anything still expects window.TEAMS.
window.conferenceForTeamCode = function(code){
  const t = window.VYC_TEAMS.find(t=>t.code===code);
  return t ? t.conference : null;
};
window.TEAMS = window.VYC_TEAMS.map(t=>t.name);
window.DIVISIONS = [
  {name:"Sub-Gremlin", min:5, max:6},{name:"Gremlin", min:7, max:8},{name:"Bantam", min:9, max:10},
  {name:"Juniors", min:11, max:12},{name:"Youth", min:13, max:14},{name:"Intermediates", min:15, max:18}
];
// Age as of Dec 31 of the season year
window.ageOnDec31 = function(dobStr, seasonYear){
  if(!dobStr) return null;
  const y = parseInt(dobStr.slice(0,4),10);
  if(isNaN(y)) return null;
  return seasonYear - y;
};
window.divisionFor = function(age){
  const d = window.DIVISIONS.find(d=>age>=d.min && age<=d.max);
  return d ? d.name : null;
};
// ---- Qualifying standards lookup (Team Manager's standards use ages 0-99 for the oldest division) ----
window.STD = {
  AGES:{'Gremlin':[7,8],'Bantam':[9,10],'Juniors':[11,12],'Youth':[13,14],'Intermediates':[0,99]},
  find(stds,r){ if(!r||r.is_relay||r.mark_value==null) return null; const a=this.AGES[r.division]; if(!a) return null;
    return (stds||[]).find(s=>s.gender===r.gender&&s.event_code===r.event_code&&!s.is_relay&&s.age_low===a[0]&&s.age_high===a[1])||null; },
  met(r,s){ return !!s&&r.mark_value!=null&&(r.mark_value===s.mark_value||(r.is_time?r.mark_value<s.mark_value:r.mark_value>s.mark_value)); },
  fmt(s,r){ const v=s.mark_value;
    if(r.is_time){ if(v>=60){ const m=Math.floor(v/60); return m+':'+(v-m*60).toFixed(2).padStart(5,'0'); } return v.toFixed(2); }
    const inch=v/0.0254, ft=Math.floor(inch/12+1e-9), i=inch-ft*12; return ft+'-'+(Math.round(i*4)/4).toFixed(2).replace(/\.00$/,'').padStart(2,'0'); }
};
window.fmtDate = function(iso){
  if(!iso) return "";
  const [y,m,d] = iso.slice(0,10).split("-");
  return `${m}/${d}/${y}`;
};

// ---- Hy-Tek Meet Manager roster export (semi-colon delimited "I" records) ----
// Spec: File > Import > Semi-Colon Delimited Rosters/Entries. One I record per athlete, 25 fields.
window.hytekRoster = function(rows, cfg){
  const clean = (s, max) => String(s ?? "").replace(/[;\r\n]/g, " ").trim().slice(0, max);
  const phone = p => clean(p, 20);
  const lines = rows.map(r => [
    "I",
    clean(r.last_name, 20),
    clean(r.first_name, 20),
    "",                                              // initial
    r.gender === "Girl" ? "F" : "M",
    window.fmtDate(r.dob),                           // MM/DD/YYYY
    clean(cfg.TEAM_CODE || "UNA", 4).toUpperCase(),
    clean(cfg.CLUB_NAME || "Unattached", 30),
    String(r.age_on_dec31 ?? ""),
    "",                                              // school year
    clean(r.address, 30),
    clean("c/o " + r.parent_name, 30),               // parent/guardian name (address line 2)
    clean(r.city, 30),
    clean(cfg.STATE || "", 3),
    clean(r.zip, 10),
    "USA",
    "USA",
    phone(r.phone),                                  // home phone (parent)
    phone(r.emergency_phone),                        // office phone slot = emergency phone
    "",                                              // fax
    "",                                              // shirt size
    "",                                              // registration #
    "",                                              // competitor #
    clean(r.email, 30),
    ""                                               // disabled classification
  ].join(";"));
  return lines.join("\r\n") + "\r\n";
};

// ---- shared login widget: email+password sign-in/sign-up, plus "Continue with Google" ----
// Replaces the old magic-link (OTP) flow everywhere. Mount into any container element;
// calls opts.onAuth(session) once signed in (also fires automatically after a Google redirect).
window.mountLoginWidget = function(sb, container, opts){
  opts = opts || {};
  const hint = opts.hint || "Sign in with your email and password.";
  container.innerHTML = `
    <p class="text-sm text-gray-600 mb-2">${hint}</p>
    <input type="email" id="authEmail" class="w-full border rounded p-2 mb-2" placeholder="you@example.com" autocomplete="email">
    <input type="password" id="authPass" class="w-full border rounded p-2 mb-2" placeholder="Password" autocomplete="current-password">
    <div class="flex gap-2 mb-2">
      <button type="button" id="authSignIn" class="btn bg-blue-600 text-white flex-1">Sign in</button>
      <button type="button" id="authSignUp" class="btn bg-gray-200 flex-1">First time? Create password</button>
    </div>
    <div class="flex items-center gap-2 my-2 text-xs text-gray-400"><div class="flex-1 border-t"></div>or<div class="flex-1 border-t"></div></div>
    <button type="button" id="authGoogle" class="btn bg-white border w-full flex items-center justify-center gap-2">
      <svg width="18" height="18" viewBox="0 0 48 48"><path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9 3.6l6.7-6.7C35.9 2.5 30.4 0 24 0 14.6 0 6.5 5.4 2.6 13.2l7.8 6.1C12.2 13.1 17.6 9.5 24 9.5z"/><path fill="#4285F4" d="M46.5 24.5c0-1.6-.1-3.1-.4-4.5H24v9h12.6c-.5 3-2.2 5.5-4.7 7.2l7.3 5.7C43.8 37.9 46.5 31.8 46.5 24.5z"/><path fill="#FBBC05" d="M10.4 19.3C9.8 21 9.5 22.9 9.5 24.9s.3 3.9.9 5.6l-7.8 6.1C1 32.9 0 29 0 24.9s1-8 2.6-11.7l7.8 6.1z"/><path fill="#34A853" d="M24 49c6.4 0 11.8-2.1 15.7-5.7l-7.3-5.7c-2 1.4-4.6 2.2-8.4 2.2-6.4 0-11.8-3.6-13.7-8.8l-7.8 6.1C6.5 43.6 14.6 49 24 49z"/></svg>
      Continue with Google
    </button>
    <p id="authMsg" class="text-sm mt-2"></p>`;
  const g = sel => container.querySelector(sel);
  const emailEl = g('#authEmail'), passEl = g('#authPass'), msgEl = g('#authMsg');
  const setMsg = (t, ok) => { msgEl.textContent = t; msgEl.className = 'text-sm mt-2 ' + (ok ? 'text-green-700' : 'text-red-600'); };
  g('#authSignIn').onclick = async () => {
    const email = emailEl.value.trim(), password = passEl.value;
    if (!email || !password) return setMsg('Enter your email and password.');
    setMsg('Signing in…');
    const { error } = await sb.auth.signInWithPassword({ email, password });
    if (error) setMsg(/Invalid login credentials/i.test(error.message)
      ? "Wrong email/password, or you haven't set a password yet — try \"First time? Create password.\""
      : error.message);
  };
  g('#authSignUp').onclick = async () => {
    const email = emailEl.value.trim(), password = passEl.value;
    if (!email || !password) return setMsg('Enter your email and choose a password.');
    if (password.length < 6) return setMsg('Password must be at least 6 characters.');
    setMsg('Creating your login…');
    const { error } = await sb.auth.signUp({ email, password });
    if (error) setMsg(/already registered|already exists/i.test(error.message)
      ? 'That email already has a password set — use Sign in instead.'
      : error.message);
    else setMsg('Account created — signing you in…', true);
  };
  g('#authGoogle').onclick = async () => {
    const { error } = await sb.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: location.href.split('#')[0] } });
    if (error) setMsg(error.message);
  };
};
