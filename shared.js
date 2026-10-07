// Shared helpers used by both pages
// The 16 real Valley Youth Conference (VYC) member teams, with their Hy-Tek team codes.
// Pulled from the league's own roster (tcl01-01.tcl) and results (reslt002.csv) exports.
window.VYC_TEAMS = [
  {code:"AVTC", name:"Antelope Valley Track Club", conference:"East"},
  {code:"BV",   name:"Burbank Vikings", conference:"East"},
  {code:"CAL",  name:"Calabasas Cheetahs", conference:"West"},
  {code:"WVE",  name:"West Valley Eagles", conference:"East"},
  {code:"FP",   name:"Flying Phoenix", conference:"East"},
  {code:"LRR",  name:"Lancaster Runnin Rebels", conference:"West"},
  {code:"L5",   name:"Lane 5", conference:"West"},
  {code:"LAF",  name:"Los Angeles Falcons", conference:"West"},
  {code:"NPTC", name:"Northridge Pacers", conference:"East"},
  {code:"PB",   name:"Palmdale Bullets", conference:"East"},
  {code:"SFR",  name:"San Fernando Valley Rush", conference:"West"},
  {code:"SCTC", name:"Santa Clarita Storm", conference:"West"},
  {code:"TT",   name:"Thimsha Tigers", conference:"East"},
  {code:"VRTC", name:"Valley Raiders", conference:"West"},
  {code:"VC",   name:"Village Christian Schools", conference:"East"},
  {code:"SCW",  name:"Santa Clarita Warriors", conference:"West"}
];
// Backward-compatible plain-name list, kept in case anything still expects window.TEAMS.
// Some Hy-Tek files use a different code for the same team (e.g. RUSH for San Fernando Valley Rush = SFR); map them to the official code.
window.TEAM_CODE_ALIASES = { RUSH:'SFR' };
window.normTeamCode = function(code){ const c=String(code||'').trim().toUpperCase(); return window.TEAM_CODE_ALIASES[c]||c; };
window.conferenceForTeamCode = function(code){
  code = window.normTeamCode(code);
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
    String(r.comp_number ?? ""),                     // competitor # (VYC competition number)
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

// ---- Live team list & season year (edited on the Site Admin page). The teams above are the fallback; this replaces them in place. ----
window.leagueReady = (async function(){
  try{
    const C=window.APP_CONFIG; if(!C||!C.SUPABASE_URL) return;
    const h={apikey:C.SUPABASE_ANON_KEY,Authorization:'Bearer '+C.SUPABASE_ANON_KEY};
    const [t,st]=await Promise.all([
      fetch(C.SUPABASE_URL+'/rest/v1/league_teams?select=*&order=sort_order,name',{headers:h}).then(r=>r.ok?r.json():null),
      fetch(C.SUPABASE_URL+'/rest/v1/app_settings?select=*',{headers:h}).then(r=>r.ok?r.json():null)]);
    if(Array.isArray(t)&&t.length){
      window.VYC_TEAMS.splice(0,window.VYC_TEAMS.length,...t.map(x=>({code:x.code,name:x.name,conference:x.conference,active:x.active!==false})));
      window.TEAMS.splice(0,window.TEAMS.length,...window.VYC_TEAMS.filter(x=>x.active).map(x=>x.name));
    }
    if(Array.isArray(st)){ const y=st.find(x=>x.key==='season_year'); if(y&&+y.value) C.SEASON_YEAR=+y.value; }
  }catch(e){}
})();
// ---- VYC background screening: the league's official link (valleyconference.org > Background Screening, provider TCLogiQ) ----
window.VYC_BG_CHECK_URL = 'https://www.tclogiq.com/valleyyouth';
window.bgCheckLinkHtml = function(lead){
  return `<div class="mt-2 rounded-lg border-2 border-amber-400 bg-amber-50 p-3 text-sm text-gray-800">${lead||'You need a current background check to coach in the VYC.'}
    <a href="${window.VYC_BG_CHECK_URL}" target="_blank" rel="noopener" class="inline-block mt-2 px-4 py-2 rounded-lg bg-amber-600 text-white font-semibold no-underline">Start your VYC background check →</a>
    <span class="block text-xs text-gray-600 mt-1">Opens TCLogiQ, the league's official background-screening partner (the same link as valleyconference.org → Background Screening).</span></div>`;
};
// ---- Current season (from Site Admin > League Setup). Working meet lists show only this season's meets;
// past seasons are locked history (results still show on the Results page). ----
// "Is your athlete coming?" deadline: the Thursday before the meet at 8:00 PM. Late after that = late add, runs at the end of each heat.
window.attendanceDeadline = function(meetDate){ if(!meetDate) return null; const [y,m,d]=String(meetDate).slice(0,10).split('-').map(Number); const dt=new Date(y,m-1,d,20,0,0);
  let back=(dt.getDay()-4+7)%7; if(back===0) back=7; dt.setDate(dt.getDate()-back); return dt; };
window.fmtDeadline = function(dt){ return dt?dt.toLocaleDateString('en-US',{weekday:'long',month:'long',day:'numeric'})+' at 8:00 PM':''; };
window.LATE_ADD_RULE = 'If your team is not told by then and your athlete shows up on meet day, they are a late add and will run at the end of each heat.';
// Which teams compete at a meet: meets.team_codes (empty = every team).
window.meetHasTeam = function(m, code){ const L=(m&&m.team_codes)||[]; return !L.length || L.includes(code); };
window.meetTeamsLabel = function(m){ const L=(m&&m.team_codes)||[]; if(!L.length) return 'All teams'; return L.map(c=>(window.VYC_TEAMS.find(t=>t.code===c)||{}).name||c).join(', '); };
window.currentSeason = async function(){ try{ if(window.leagueReady) await window.leagueReady; }catch(e){} return (window.APP_CONFIG||{}).SEASON_YEAR; };
// ---- Role-based menu items, only for people who have that access (flags are set when they sign in on the Coach Dashboard
//      or Site Admin page, and cleared when they sign out): "Team Admin" for team admins, "Timer" for timers, "Site Admin" for admins ----
document.addEventListener('DOMContentLoaded',function(){ try{
  const nav=document.querySelector('.topnav nav'); if(!nav) return;
  const flag=k=>localStorage.getItem(k)==='1';
  const coachLink=nav.querySelector('a[href="coach.html"]');
  const addAfter=(ref,href,text)=>{ if(nav.querySelector('a[href="'+href+'"]')) return; const a=document.createElement('a'); a.href=href; a.textContent=text; if(ref&&ref.nextSibling) nav.insertBefore(a,ref.nextSibling); else nav.appendChild(a); return a; };
  let last=coachLink;
  if(flag('vyc_team_admin')) last=addAfter(last,'coach.html?view=roster','Team Admin')||last;
  if(flag('vyc_timer')) last=addAfter(last,'meets-admin.html','Timer')||last;
  if(flag('vyc_admin')) addAfter(null,'admin.html','Site Admin');
}catch(e){} });
window.setRoleFlags=function(c){ try{ localStorage.setItem('vyc_admin',(c&&(c.is_admin||c.team_admin))?'1':'0'); localStorage.setItem('vyc_team_admin',(c&&(c.is_admin||c.team_admin))?'1':'0'); localStorage.setItem('vyc_timer',(c&&c.role_type==='timer')?'1':'0'); }catch(e){} };
window.clearRoleFlags=function(){ try{ ['vyc_admin','vyc_team_admin','vyc_timer'].forEach(k=>localStorage.removeItem(k)); }catch(e){} };
