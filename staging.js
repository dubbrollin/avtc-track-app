// Meet Day Staging (2026-11-26). Rules come from the VYC 2026 Track & Field Playing Rules:
//   IV.C.1   event limits (enforced again by the database), IV.C.1.a field event order, IV.C.1.b track order,
//   V.B-D    field attempts / high jump heights, VI.A 800m max 18, XI lane seeding charts (6, 8, 9 lanes).
// Event numbers are the league's Meet Manager numbers (the same in regular meets and the VYC Invite; see the heat sheets).
(function(){
const DIVS = ['Sub-Gremlin','Gremlin','Bantam','Juniors','Youth','Intermediates'];
const DIVSHORT = {'Sub-Gremlin':'Sub Gremlin','Gremlin':'Gremlin','Bantam':'Bantam','Juniors':'Junior','Youth':'Youth','Intermediates':'15-18'};
const gName = (div,g) => div==='Intermediates' ? (g==='Girl'?'15-18 Women':'15-18 Men') : `${DIVSHORT[div]} ${g==='Girl'?'Girls':'Boys'}`;
const DIVNUM = {'Sub-Gremlin':1,'Gremlin':2,'Bantam':3,'Juniors':4,'Youth':5,'Intermediates':8};   // Meet Manager division numbers (same as meets-admin)
const G = (div,gender) => ({division:div, gender});
const both = divs => divs.flatMap(d => [G(d,'Girl'),G(d,'Boy')]);          // girls run first in every division
const range = (from,to) => DIVS.slice(DIVS.indexOf(from), DIVS.indexOf(to)+1);

// Track events in the order they are run (IV.C.1.b / the heat sheet). base = Meet Manager event # of Sub-Gremlin Girls; +2 per division, +1 boys.
// chart: which lane chart (XI): short = 100 & hurdles, long = 200/400/relays, water = 800 and longer (waterfall start, no lanes).
const TRACK = [
  {code:'3000', name:'3000m Run',    groups:both(range('Juniors','Intermediates')), base:4,   chart:'water'},
  {code:'H',    name:'Hurdles',      groups:[G('Juniors','Girl'),G('Juniors','Boy'),G('Youth','Girl'),G('Youth','Boy'),G('Intermediates','Girl'),G('Intermediates','Boy')], base:12, chart:'short',
   codeFor:g => g.division==='Juniors' ? '80H' : (g.division==='Intermediates'&&g.gender==='Boy' ? '110H' : '100H'),
   nameFor:g => g.division==='Juniors' ? '80m Hurdles' : (g.division==='Intermediates'&&g.gender==='Boy' ? '110m Hurdles' : '100m Hurdles')},
  {code:'400',  name:'4x100m Relay', groups:both(DIVS), base:26, chart:'long', relay:true},
  {code:'1500', name:'1500m Run',    groups:both(range('Gremlin','Intermediates')), base:40, chart:'water'},
  {code:'400',  name:'400m Dash',    groups:both(DIVS), base:54, chart:'long'},
  {code:'100',  name:'100m Dash',    groups:both(DIVS), base:68, chart:'short'},
  {code:'800',  name:'800m Run',     groups:both(DIVS), base:82, chart:'water', max:18},
  {code:'200',  name:'200m Dash',    groups:both(DIVS), base:96, chart:'long'},
  {code:'1600', name:'4x400m Relay', groups:both(range('Gremlin','Intermediates')), base:106, chart:'long', relay:true},
];
TRACK.forEach((t,i) => t.key = (t.relay?'R':'') + (t.code==='H'?'H':t.code));
const evNum = (t,g) => t.base + 2*DIVS.indexOf(g.division) + (g.gender==='Boy'?1:0);
const codeOf = (t,g) => t.codeFor ? t.codeFor(g) : t.code;
const nameOf = (t,g) => t.nameFor ? t.nameFor(g) : t.name;

// Lane seeding charts (rule XI). Index 0 = fastest seed.
const CHART = {
  6: {short:[4,3,5,2,6,1], long:[3,4,2,5,6,1]},
  8: {short:[4,5,3,6,2,7,1,8], long:[3,4,5,2,6,1,7,8]},
  9: {short:[5,6,4,7,3,8,2,9,1], long:[4,5,6,3,7,2,8,1,9]},
};

// Field events (IV.C.1.a order; event numbers from the heat sheet). attempts per rule V.C (LJ), V.D (SP), V.C Javelin.
const FIELD = [
  {code:'HJ', name:'High Jump', base:116, hj:true,
   flights:[[G('Bantam','Girl')],[G('Bantam','Boy')],[G('Juniors','Girl')],[G('Juniors','Boy')],[G('Youth','Girl')],[G('Youth','Boy')],[G('Intermediates','Girl')],[G('Intermediates','Boy')]]},
  {code:'LJ', name:'Long Jump', base:130,
   flights:[[G('Sub-Gremlin','Girl')],[G('Gremlin','Girl')],[G('Sub-Gremlin','Boy')],[G('Gremlin','Boy')],[G('Intermediates','Boy')],[G('Intermediates','Girl')],
            [G('Juniors','Girl')],[G('Juniors','Boy')],[G('Youth','Girl')],[G('Youth','Boy')],[G('Bantam','Girl')],[G('Bantam','Boy')]]},
  {code:'SP', name:'Shot Put', base:140,
   flights:[[G('Youth','Boy')],[G('Youth','Girl')],[G('Intermediates','Girl')],[G('Intermediates','Boy')],[G('Bantam','Girl')],[G('Bantam','Boy')],[G('Juniors','Girl')],[G('Juniors','Boy')]]},
  {code:'JT', name:'Javelin Throw', base:150,
   flights:[[G('Juniors','Girl')],[G('Juniors','Boy')],[G('Bantam','Girl')],[G('Bantam','Boy')],[G('Gremlin','Girl')],[G('Gremlin','Boy')],
            [G('Youth','Girl'),G('Intermediates','Girl')],[G('Youth','Boy'),G('Intermediates','Boy')]]},
];
const attemptsFor = (code, div) => code==='LJ' ? (['Sub-Gremlin','Gremlin'].includes(div)?3:4) : code==='SP' ? 4 : code==='JT' ? 3 : 0;
// High jump opening heights (V.B.1), in inches. Bar goes up 2" (V.B.6).
const HJ_START = {'Bantam|Girl':36,'Bantam|Boy':36,'Juniors|Girl':38,'Juniors|Boy':40,'Youth|Girl':40,'Intermediates|Girl':40,'Youth|Boy':44,'Intermediates|Boy':44};

// ---------- marks ----------
const timeVal = m => { m=String(m||'').trim(); if(!m) return null; const p=m.split(':').map(Number); if(p.some(isNaN)) return null; return p.reduce((a,x)=>a*60+x,0); };
// Feet-inches as typed by a field judge: 12-04.25, 12'4.25", 12 4.25, 12-4 -> {inches, mm:"12-04.25" (Meet Manager English mark)}
function parseFeet(s){
  s=String(s||'').trim().replace(/[”"]/g,'').replace(/[’']/g,'-'); if(!s) return null;
  const x=/^(\d{1,3})\s*[-\s]\s*(\d{1,2}(?:\.\d{1,2})?)?$/.exec(s) || /^(\d{1,3})$/.exec(s); if(!x) return null;
  const ft=+x[1], inch=x[2]!=null?+x[2]:0; if(inch>=12) return null;
  const q=Math.round(inch*4)/4;                                         // nearest 1/4 inch (V.A.1)
  const ip=Math.floor(q), fr=Math.round((q-ip)*100);
  return {inches:ft*12+q, mm:`${ft}-${String(ip).padStart(2,'0')}${fr?'.'+String(fr).padStart(2,'0'):''}`};
}
const feetLabel = inches => { const ft=Math.floor(inches/12), i=inches-ft*12; return `${ft}-${String(Math.floor(i)).padStart(2,'0')}${i%1?'.'+String(Math.round((i%1)*100)).padStart(2,'0'):''}`; };
const inchToM = i => +(i*0.0254).toFixed(3);

window.STAGE = { DIVS, DIVSHORT, DIVNUM, gName, TRACK, FIELD, CHART, evNum, codeOf, nameOf, attemptsFor, HJ_START, timeVal, parseFeet, feetLabel, inchToM };

// ---------- seeding ----------
// rows: [{...athlete, seed_value|null}] -> heats [[{...row, lane}]]. Fastest heat first; the fastest heat is filled first (IV.C.3).
window.STAGE.seedHeats = function(rows, track, lanes){
  const sorted=[...rows].sort((a,b)=>(a.seed_value==null)-(b.seed_value==null) || (a.seed_value-b.seed_value) || String(a.sortName||'').localeCompare(String(b.sortName||'')));
  const water=track.chart==='water', cap=water?(track.max||18):lanes;
  const heats=[]; for(let i=0;i<sorted.length;i+=cap) heats.push(sorted.slice(i,i+cap));
  return heats.map(h => h.map((r,i) => ({...r, lane: water ? i+1 : CHART[lanes][track.chart][i]})));
};
// First empty lane in an existing heat, in chart order (for a late arrival).
window.STAGE.emptyLane = function(heat, track){
  const used=new Set((heat.lanes||[]).map(l=>l.lane));
  if(track.chart==='water'){ const cap=track.max||18; for(let i=1;i<=cap;i++) if(!used.has(i)) return i; return null; }
  for(const l of CHART[heat.lanes_total][track.chart]) if(!used.has(l)) return l; return null;
};

// ---------- Field marks to Meet Manager: FieldLynx result files (.lff) ----------
// Meet Manager's Field Event Interface ("FieldLynx File Sharing") reads <event#>-1-<flight>.lff from its shared folder when the
// operator presses F3 (Get Marks). Format from the FieldLynx release notes; verified by import into Meet Manager 6.0 on
// 2026-11-26: English marks 12-04.25, foul F, pass -, blank wind; high jump header SH,<heights>,EH and O/X/P per height.
// Lines end CRLF (LF-only files are rejected). Athlete ID = competition number (it must match Meet Manager's).
// rows: field_marks rows; ath: id -> athlete; returns [{name, text, event, label, skipped:[names without a comp #]}]
window.STAGE.fieldLynxFiles = function(rows, ath, teamName){
  const out=[], c=s=>String(s??'').replace(/[,\r\n]/g,' ').trim();
  for(const ev of FIELD){
    const groups={};
    rows.filter(r=>r.event_code===ev.code&&r.checked_in&&(r.attempts||[]).length).forEach(r=>(groups[r.division+'|'+r.gender]??=[]).push(r));
    for(const [k,list] of Object.entries(groups)){
      const [division,gender]=k.split('|'), evno=ev.base+2*DIVS.indexOf(division)+(gender==='Boy'?1:0);
      if(DIVS.indexOf(division)<0) continue;
      const label=`${gender==='Girl'?'Girls':'Boys'} ${ev.name} ${DIVSHORT[division]}`;
      const skipped=[]; const ok=list.filter(r=>{ const a=ath[r.registration_id]; if(!a||a.comp_number==null){ skipped.push(a?a.first_name+' '+a.last_name:'?'); return false; } return true; });
      // places: best mark first; ties share a place; no mark = no place
      const ranked=[...ok].sort((a,b)=>(b.best_value??-1)-(a.best_value??-1)); const place={}; let last=null, p=0;
      ranked.forEach((r,i)=>{ if(r.best_value==null){ place[r.registration_id]=''; return; } if(r.best_value!==last){ p=i+1; last=r.best_value; } place[r.registration_id]=p; });
      const lines=[];
      if(ev.hj){
        const hs=[...new Set(ok.flatMap(r=>(r.attempts||[]).map(x=>+x.h)))].sort((a,b)=>a-b);
        lines.push([evno,1,1,label,'English','SH',...hs.map(feetLabel),'EH'].join(','));
        ok.forEach((r,i)=>{ const a=ath[r.registration_id], at={}; (r.attempts||[]).forEach(x=>at[+x.h]=String(x.r||'').toUpperCase());
          lines.push([place[r.registration_id],a.comp_number,i+1,place[r.registration_id],c(a.last_name),c(a.first_name),c(teamName(a.team_code)),...hs.map(h=>at[h]||'')].join(',')); });
      } else {
        lines.push([evno,1,1,label,'English'].join(','));
        ok.forEach((r,i)=>{ const a=ath[r.registration_id];
          const marks=(r.attempts||[]).flatMap(m=>{ const v=String(m||'').toUpperCase(); return [v==='P'?'-':v==='F'?'F':v, '']; });
          lines.push([place[r.registration_id],a.comp_number,i+1,place[r.registration_id],c(a.last_name),c(a.first_name),c(teamName(a.team_code)),...marks].join(',')); });
      }
      out.push({name:`${evno}-1-1.lff`, text:lines.join('\r\n')+'\r\n', event:evno, label, count:ok.length, skipped});
    }
  }
  return out.sort((a,b)=>a.event-b.event);
};

// ---------- Meet Manager file (Hy-Tek semicolon entries; same format meets-admin.html already imports) ----------
window.STAGE.hytekFile = function(rows){
  const c=(s,n)=>String(s??'').replace(/[;\r\n]/g,' ').trim().slice(0,n);
  const tname=code=>{ const t=(window.VYC_TEAMS||[]).find(x=>x.code===code); return c(t?t.name:code,30); };
  const dob=d=>d&&window.fmtDate?window.fmtDate(d):'';
  const out=[];
  for(const r of rows){
    if(!r.is_relay && r.athlete){
      const a=r.athlete;
      out.push(['D',c(a.last_name,20),c(a.first_name,20),'',a.gender==='Girl'?'F':'M',dob(a.dob),c(a.team_code,4).toUpperCase(),tname(a.team_code),String(a.age_on_dec31??''),'',
        c(r.event_code,10),c(r.seed_mark||'',11),'M',DIVNUM[a.division]??'',a.comp_number??'','','','','',''].join(';'));
    } else if(r.is_relay && r.runners && r.runners.length){
      const f=r.runners[0], age=(window.DIVISIONS||[]).find(d=>d.name===f.division)?.max??'';
      const runners=r.runners.flatMap(a=>[c(a.last_name,20),c(a.first_name,20),'',a.gender==='Girl'?'F':'M',dob(a.dob),String(a.age_on_dec31??''),'',a.comp_number??'']);
      out.push(['Q',c(r.team_code,4).toUpperCase(),tname(r.team_code),r.relay_letter,f.gender==='Girl'?'F':'M',String(age),c(r.event_code,10),c(r.seed_mark||'',11),'M',DIVNUM[f.division]??'','','','','','',...runners].join(';'));
    }
  }
  return out.join('\r\n')+(out.length?'\r\n':'');
};
})();
