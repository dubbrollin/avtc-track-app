// ---- Live connection to Hy-Tek Meet Manager (the timing laptop) — like Athletic.net's AthleticLIVE ----
// Two ways, both run in Chrome or Edge on the timing laptop, on the Timer page, with nothing to install:
//   A) Real-time folder: Meet Manager (Pro option) writes each event's results to C:\Realtime when the timer presses F12
//      (with "Do not upload" ticked in Run > Web). This page watches that folder and posts every new or changed file.
//      A semicolon-delimited results export saved into the same folder is picked up too.
//   B) Meet Manager database: this page re-reads the meet's .mdb file every 30 seconds and posts every event that
//      changed — no key presses at all (like AthleticLOCAL's database connection).
// Every post goes through replace_meet_results, so re-sending an event replaces it — nothing is ever doubled.

(function(){
const STD = () => window.STANDARD_EVENTS || [];
const nk = (l,f) => (l+'|'+f).toLowerCase().replace(/[^a-z|]/g,'');
const esc = s => String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

// ---------- shared helpers ----------
function divFromText(t){
  const n=String(t||'').toLowerCase().replace(/[^a-z0-9]/g,'');
  if(n.includes('subgremlin')) return 'Sub-Gremlin';
  if(n.includes('gremlin')) return 'Gremlin';
  if(n.includes('bantam')) return 'Bantam';
  if(n.includes('junior')) return 'Juniors';
  if(n.includes('youth')) return 'Youth';
  if(n.includes('intermediate')) return 'Intermediates';
  const a=String(t||'').match(/\b(\d{1,2})\s*(?:-|to|&)\s*(\d{1,2})\b/); if(a) return divFromAges(+a[1],+a[2]);
  if(/15\s*(?:&|and)\s*(?:over|up)|\bopen\b/i.test(t||'')) return 'Intermediates';
  return null;
}
function divFromAges(lo,hi){
  if(lo>=15||(lo===0&&hi>=99)) return 'Intermediates';
  const d=(window.DIVISIONS||[]).find(x=>x.min===lo&&x.max===hi)||(window.DIVISIONS||[]).find(x=>lo>=x.min&&lo<=x.max);
  return d?d.name:null;
}
function genderFrom(v){
  const s=String(v||'').trim().toLowerCase();
  if(/^(f|g|w)|girl|women|female/.test(s)) return 'Girl';
  if(/^(m|b)|boy|\bmen\b|male/.test(s)) return /mix/.test(s)?'Mixed':'Boy';
  if(/^x|mix/.test(s)) return 'Mixed';
  return null;
}
// Event description ("Girls 100 Meter Dash Bantam", "4x100 Meter Relay", "Long Jump") -> {code, relay, name}
function classifyEvent(text){
  const t=String(text||'').toLowerCase();
  const pick=(code,relay)=>{ const e=STD().find(x=>x.code===code&&!!x.relay===relay); return {code,relay,field:!!(e&&e.field),name:e?e.name:null}; };
  const r=t.match(/4\s*x\s*(\d{2,4})/); if(r||/relay/.test(t)){ const leg=r?+r[1]:100; return pick(String(leg*4),true); }
  if(/long\s*jump/.test(t)) return pick('LJ',false);
  if(/high\s*jump/.test(t)) return pick('HJ',false);
  if(/triple\s*jump/.test(t)) return {code:'TJ',relay:false,field:true,name:'Triple Jump'};
  if(/pole\s*vault/.test(t)) return {code:'PV',relay:false,field:true,name:'Pole Vault'};
  if(/shot/.test(t)) return pick('SP',false);
  if(/javelin/.test(t)) return pick('JT',false);
  if(/discus/.test(t)) return {code:'DT',relay:false,field:true,name:'Discus Throw'};
  const d=t.match(/\b(\d{2,5})\s*(?:meter|metre|m\b)/)||t.match(/\b(\d{2,5})\b/);
  if(d){ if(/hurdle/.test(t)) return pick(d[1]+'H',false); return pick(d[1],false); }
  return null;
}
function teamCodeFrom(text){
  const t=String(text||'').replace(/['"]?\b[A-Z]\b['"]?\s*$/,'').trim(), low=t.toLowerCase(); if(!t) return null;
  const teams=window.VYC_TEAMS||[];
  const byCode=teams.find(x=>x.code.toLowerCase()===low)||((window.TEAM_CODE_ALIASES||{})[t.toUpperCase()]&&{code:window.TEAM_CODE_ALIASES[t.toUpperCase()]});
  if(byCode) return byCode.code;
  const hit=teams.find(x=>x.name.toLowerCase()===low)||teams.find(x=>low.length>=6&&(x.name.toLowerCase().startsWith(low)||low.startsWith(x.name.toLowerCase())));
  return hit?hit.code:null;
}
const fmtTime=sec=>{ if(sec>=60){ const m=Math.floor(sec/60); return m+':'+(sec-m*60).toFixed(2).padStart(5,'0'); } return sec.toFixed(2); };
const fmtFeet=m=>{ const inch=m/0.0254; let ft=Math.floor(inch/12+1e-9); let i=Math.round((inch-ft*12)*4)/4; if(i>=12){ ft++; i-=12; } return ft+'-'+(i<10?'0':'')+i.toFixed(2); };

// ---------- A) Meet Manager's printed / real-time results (HTML or text) ----------
const MARK_RE=/(?<![\w.:+\-])(\d{1,2}:\d{2}(?::\d{2})?\.\d{1,3}|\d{1,3}\.\d{1,3}[hqmc]?|\d{1,3}-\d{1,2}(?:\.\d{1,2})?|DQ|DNF|DNS|NH|NM|FOUL|FS|SCR|NT|ND)(?![\w.:\-])/g;
function htmlToText(s){
  if(!/<\w+[^>]*>/.test(s)) return s;
  return s.replace(/<br\s*\/?>/gi,'\n').replace(/<\/(p|div|tr|h\d|li)>/gi,'\n').replace(/<[^>]+>/g,'')
    .replace(/&nbsp;/g,' ').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&#0*39;|&apos;/g,"'");
}
// Returns {rows, events:[labels], unmatched:[names]}. regs = [{id,first_name,last_name,division,gender}]
window.parseHytekPrintedResults=function(raw, regs){
  const lines=htmlToText(String(raw||'')).split(/\r?\n/);
  const byKey={}; (regs||[]).forEach(r=>{ byKey[nk(r.last_name,r.first_name)]=r; });
  const rows=[], events=[], unmatched=new Set();
  let ev=null, round='F', heat=null, markCol=null, heatCol=false, lastRelay=null;
  for(const line of lines){
    const h=line.match(/^\s*(?:#?\s*)?Event\s+(\d+)\s+(.+?)\s*$/i);
    if(h){
      const desc=h[2].replace(/\(.*?\)/g,' ');
      const g=/\b(girls?|women|female)\b/i.test(desc)?'Girl':/\b(boys?|men|male)\b/i.test(desc)?'Boy':/mixed/i.test(desc)?'Mixed':null;
      const c=classifyEvent(desc);
      ev=c?{...c,gender:g,division:divFromText(desc),label:`Event ${h[1]} ${desc.trim()}`}:null;
      if(ev) events.push(ev.label);
      round=/prelim/i.test(desc)?'P':'F'; heat=null; markCol=null; heatCol=false; lastRelay=null; continue;
    }
    if(/^\s*(Team\s+Scores|Rank\s+Team|Scores\s*-)/i.test(line)){ ev=null; continue; } // team scores at the end are not results
    if(!ev) continue;
    if(/^\s*=+\s*$/.test(line)) continue;
    if(/^\s*(Preliminaries|Prelims)\s*$/i.test(line)){ round='P'; heat=null; continue; }
    if(/^\s*(Finals?|Semi-?Finals?)\s*$/i.test(line)){ round='F'; heat=null; continue; }
    const hs=line.match(/^\s*(?:Heat|Section|Flight)\s+(\d+)\b/i); if(hs){ heat=+hs[1]; continue; }
    // column header: remember where the result column ends (marks are right-aligned under it)
    const hdr=line.match(/^(.*?\b)(Finals|Prelims|Semis|Results?|Mark|Time)\b/);
    if(hdr && /\b(Name|School|Team|Athlete)\b/i.test(line)){ markCol=hdr[1].length+hdr[2].length; heatCol=/\bH#|\bHeat\b/.test(line); if(/Prelims/.test(hdr[2])) round='P'; continue; }
    // relay runners: "1) Smith, Ava 10    2) Jones, Bea 9"
    if(lastRelay && /^\s*\d\)\s*\S/.test(line)){
      for(const m of line.matchAll(/\d\)\s*([^,()]+?),\s*([^()\d]+?)(?:\s+\d{1,2})?(?=\s+\d\)|\s*$)/g)) lastRelay.runners.push(`${m[2].trim()} ${m[1].trim()}`);
      lastRelay.row.relay_runners=lastRelay.runners.join(', '); continue;
    }
    const pm=line.match(/^\s*(\d{1,3}|--|DQ|DNF|DNS)\s+(\S.*)$/); if(!pm) continue;
    const placeRaw=pm[1], rest=pm[2], restStart=line.length-rest.length;
    const marks=[...rest.matchAll(MARK_RE)].map(m=>({v:m[1],start:restStart+m.index,end:restStart+m.index+m[1].length}));
    if(!marks.length) continue;
    const before=rest.slice(0, marks[0].start-restStart);
    let pick=marks[marks.length-1];
    if(markCol!=null){ pick=marks.reduce((b,m)=>Math.abs(m.end-markCol)<Math.abs(b.end-markCol)?m:b, marks[0]); }
    else { const ints=[...rest.matchAll(/(?<=\s)\d{1,2}(?=\s|$)/g)].map(m=>restStart+m.index); const firstInt=ints.find(i=>i>marks[0].end); const ok=marks.filter(m=>firstInt==null||m.start<firstInt); pick=ok[ok.length-1]||pick; }
    const after=line.slice(pick.end);
    const w=after.match(/^\s+([+-]\d{1,2}\.\d|NWI)\b/); const hn=after.replace(/^\s+([+-]\d{1,2}\.\d|NWI)\b/,'').match(/^\s+(\d{1,2})(?=\s|$)/);
    const place=/^\d+$/.test(placeRaw)?+placeRaw:null;
    const isTime=!ev.field;
    const base={ gender:ev.gender||'Mixed', division:ev.division, event_code:ev.code, event_name:ev.name||ev.label.replace(/^Event\s+\d+\s+/,''), is_relay:!!ev.relay,
      round, mark:pick.v.replace(/[qc]$/,''), mark_value:window.markToValue(pick.v.replace(/[qc]$/,''),isTime,/-/.test(pick.v)?'E':'M'), is_time:isTime,
      place, overall_place:null, heat:hn&&heatCol?+hn[1]:heat, wind:w?w[1]:null, source:'hytek-live' };
    if(ev.relay){
      const team=before.replace(/\s+['"]?[A-Z]['"]?\s*$/,'').trim(); const ltr=(before.match(/['"]?([A-Z])['"]?\s*$/)||[])[1];
      const row={...base, registration_id:null, athlete_name:team+(ltr?` '${ltr}'`:''), team_code:teamCodeFrom(team), relay_runners:null};
      rows.push(row); lastRelay={row,runners:[]}; continue;
    }
    lastRelay=null;
    const nm=before.match(/^\s*\*?([^,]+?),\s*(.+?)(?:\s{2,}|\s+(?=\d{1,2}\s)|\s+(?=(?:FR|SO|JR|SR)\b)|$)(.*)$/);
    if(!nm) continue;
    const last=nm[1].trim(), first=nm[2].trim();
    const team=nm[3].replace(/^\s*(\d{1,2}|FR|SO|JR|SR)\s+/,'').trim();
    const reg=byKey[nk(last,first)]; if(!reg) unmatched.add(`${first} ${last}`);
    rows.push({...base, registration_id:reg?.id||null, athlete_name:`${first} ${last}`, team_code:teamCodeFrom(team)||reg?.team_code||null,
      division:base.division||reg?.division||null, gender:ev.gender||reg?.gender||'Mixed', relay_runners:null});
  }
  return {rows, events, unmatched:[...unmatched]};
};

// ---------- B) Meet Manager's database (.mdb) ----------
// The table and column names below are Meet Manager's (Athlete, Team, Event, Entry, Relay, RelayNames, Divisions);
// each column is looked up by several possible names so small differences between Meet Manager versions don't matter.
function tableRows(reader, names){
  const all=reader.getTableNames();
  for(const n of names){ const hit=all.find(t=>t.toLowerCase()===n.toLowerCase()); if(hit) return reader.getTable(hit).getData().map(r=>{ const o={}; for(const k in r) o[k.toLowerCase()]=r[k]; return o; }); }
  return [];
}
const col=(row,names)=>{ for(const n of names){ const v=row[n]; if(v!==undefined&&v!==null&&v!=='') return v; } return null; };
window.readMeetManagerTables=function(reader){
  return { athletes:tableRows(reader,['Athlete']), teams:tableRows(reader,['Team']), events:tableRows(reader,['Event']),
    entries:tableRows(reader,['Entry']), relays:tableRows(reader,['Relay']), relayNames:tableRows(reader,['RelayNames','RelayName']),
    divisions:tableRows(reader,['Divisions','Division']) };
};
// The kind of event an Event row is (one key per distance/type; divisions and genders share it).
window.mmEventKey=function(e){
  const name=col(e,['event_name','event_title','ev_name','event_desc','event_note']);
  return [col(e,['ind_rel'])||'I', col(e,['trk_field','event_type'])||'', col(e,['event_dist','dist'])||'', col(e,['event_stroke','stroke'])||'', name||''].join('|');
};
// Best guess of which of our events an Event row is. Returns {code, relay} or null (the timer picks it once on screen).
window.mmGuessEvent=function(e){
  const name=col(e,['event_name','event_title','ev_name','event_desc','event_note']);
  if(name){ const c=classifyEvent(name); if(c) return {code:c.code,relay:c.relay}; }
  const relay=String(col(e,['ind_rel'])||'').toUpperCase()==='R', dist=+col(e,['event_dist','dist'])||0;
  const tf=String(col(e,['trk_field','event_type'])||'').toUpperCase(), stroke=String(col(e,['event_stroke','stroke'])||'').toUpperCase();
  if(relay&&dist) return {code:String(dist),relay:true};
  if(tf==='F') return null; // field events: which jump/throw can't be told from the numbers — picked once on screen
  if(dist){ const hurdles=+col(e,['num_hurdles','hurdles','hurdle_ht'])>0||stroke==='H'; return {code:dist+(hurdles?'H':''),relay:false}; }
  return null;
};
// tables (from readMeetManagerTables) -> result rows. opts: {regs, eventMap:{key:{code,relay}|'skip'}, fieldUnit:'auto'|'m'|'in'|'cm'}
// Field marks: Meet Manager stores each mark with its own unit — Fin_course/Pre_course 'E' (English) = inches, 'M' (metric) = meters
// (checked in four 2026 VYC meet databases: every field mark is 'E', in inches). 'auto' uses that; the others force one unit.
window.buildRowsFromMeetManager=function(tb, opts){
  opts=opts||{}; const byKey={}; (opts.regs||[]).forEach(r=>{ byKey[nk(r.last_name,r.first_name)]=r; });
  const unit=opts.fieldUnit||'auto';
  const toMeters=(v,course,evMeas)=>{ const u=unit!=='auto'?unit:({E:'in',M:'m'})[String(course||evMeas||'').trim().toUpperCase()]||'in';
    return u==='in'?v*0.0254:u==='cm'?v/100:v; };
  const ath={}; tb.athletes.forEach(a=>{ ath[col(a,['ath_no'])]=a; });
  const team={}; tb.teams.forEach(t=>{ team[col(t,['team_no'])]=t; });
  const divs={}; tb.divisions.forEach(d=>{ divs[col(d,['div_no'])]=col(d,['div_name','div_abbr']); });
  const evs={}, needMap=new Set();
  tb.events.forEach(e=>{
    const key=window.mmEventKey(e); const m=(opts.eventMap||{})[key]; const g=m===undefined?window.mmGuessEvent(e):m;
    if(!g){ needMap.add(key); return; } if(g==='skip') return;
    const std=STD().find(x=>x.code===g.code&&!!x.relay===!!g.relay);
    const lo=col(e,['low_age']), hi=col(e,['high_age']);
    evs[col(e,['event_ptr'])]={ code:g.code, relay:!!g.relay, field:std?!!std.field:/^(LJ|HJ|TJ|PV|SP|JT|DT|HT)$/.test(g.code), name:std?std.name:g.code, meas:col(e,['res_meas']),
      gender:genderFrom(col(e,['event_gender','event_sex'])), division:divFromText(divs[col(e,['div_no'])])||(lo!=null&&hi!=null?divFromAges(+lo,+hi):null) };
  });
  const STAT={D:'DQ',Q:'DQ',N:'DNF',F:'FS'};
  // One row per scored round of an entry: finals from the Fin_* columns, prelims from the Pre_* columns.
  const scored=(x,p,isTime,evMeas)=>{
    const v=+col(x,[p+'_time',p+'_mark',p+'_result',p+'_meas'])||0, st=STAT[String(col(x,[p+'_stat'])||'').toUpperCase()];
    if(!(v>0)&&!st) return null;
    const val=v>0?(isTime?v:toMeters(v,col(x,[p+'_course']),evMeas)):null;
    return { mark:st&&!(v>0)?st:(isTime?fmtTime(val):fmtFeet(val)), mark_value:st?null:val,
      place:+col(x,[p+'_heatplace',p+'_place'])||null, overall_place:+col(x,[p+'_place'])||null, heat:+col(x,[p+'_heat'])||null,
      wind:(w=>w==null||w===''?null:String(w))(col(x,[p+'_wind'])) };
  };
  const rows=[], unmatched=new Set();
  tb.entries.forEach(x=>{
    const e=evs[col(x,['event_ptr'])]; if(!e||e.relay) return; const a=ath[col(x,['ath_no'])]; if(!a) return;
    const last=String(col(a,['last_name'])||'').trim(), first=String(col(a,['first_name'])||'').trim();
    const reg=byKey[nk(last,first)]; if(!reg) unmatched.add(`${first} ${last}`);
    const t=team[col(a,['team_no'])]; const tc=t?window.normTeamCode(col(t,['team_abbr','team_short'])||''):null;
    const age=+col(a,['ath_age','age']); const div=e.division||reg?.division||(age&&window.divisionFor?window.divisionFor(age):null)||null;
    for(const [p,rd] of [['fin','F'],['pre','P']]){ const s=scored(x,p,!e.field,e.meas); if(!s) continue;
      rows.push({ registration_id:reg?.id||null, athlete_name:`${first} ${last}`, gender:e.gender||genderFrom(col(a,['ath_sex']))||reg?.gender||'Mixed', division:div,
        team_code:tc||reg?.team_code||null, event_code:e.code, event_name:e.name, is_relay:false, relay_runners:null, round:rd, ...s, is_time:!e.field, source:'hytek-live' }); }
  });
  const legs={}; tb.relayNames.forEach(n=>{ (legs[col(n,['relay_no'])]??=[]).push(n); });
  tb.relays.forEach(x=>{
    const e=evs[col(x,['event_ptr'])]; if(!e||!e.relay) return;
    const t=team[col(x,['team_no'])]; const tname=t?(col(t,['team_name','team_short','team_abbr'])||''):'Relay'; const ltr=col(x,['team_ltr','relay_ltr'])||'';
    const runners=(legs[col(x,['relay_no'])]||[]).sort((p,q)=>(+col(p,['pos_no','leg_no'])||9)-(+col(q,['pos_no','leg_no'])||9)).filter(n=>(+col(n,['pos_no','leg_no'])||1)<=4)
      .map(n=>ath[col(n,['ath_no'])]).filter(Boolean).map(a=>`${String(col(a,['first_name'])||'').trim()} ${String(col(a,['last_name'])||'').trim()}`);
    for(const [p,rd] of [['fin','F'],['pre','P']]){ const s=scored(x,p,true); if(!s) continue;
      rows.push({ registration_id:null, athlete_name:tname+(ltr?` '${ltr}'`:''), gender:e.gender||'Mixed', division:e.division, team_code:t?window.normTeamCode(col(t,['team_abbr','team_short'])||''):null,
        event_code:e.code, event_name:e.name, is_relay:true, relay_runners:runners.join(', ')||null, round:rd, ...s, is_time:true, source:'hytek-live' }); }
  });
  return {rows, needMap:[...needMap], unmatched:[...unmatched]};
};
// A plain-text report of the database's layout (no athlete names) for when something isn't read right.
window.describeMeetManagerDb=function(reader){
  const out=['Meet Manager database report — '+new Date().toLocaleString(),''];
  for(const n of reader.getTableNames()){ const t=reader.getTable(n); out.push(`${n} (${t.rowCount} rows): ${t.getColumnNames().join(', ')}`); }
  for(const n of ['Event','Entry','Relay','Divisions']){ const hit=reader.getTableNames().find(t=>t.toLowerCase()===n.toLowerCase()); if(!hit) continue;
    out.push('',`-- first rows of ${hit} --`); reader.getTable(hit).getData({rowLimit:5}).forEach(r=>out.push(JSON.stringify(r))); }
  return out.join('\n');
};

// ---------- the Timer-page panel ----------
let mdbLoading=null;
function loadMdbReader(){ return mdbLoading||(mdbLoading=new Promise((ok,bad)=>{ if(window.MDBReader) return ok(); const s=document.createElement('script'); s.src='vendor/mdb-reader.js'; s.onload=ok; s.onerror=()=>bad(new Error('Could not load the database reader')); document.head.appendChild(s); })); }
const groupKey=r=>[r.event_code,r.is_relay,r.division||'',r.gender,r.round||'F'].join('|');
const evMapKey=meetId=>'mmEventMap:'+meetId;
const loadMap=id=>{ try{ return JSON.parse(localStorage.getItem(evMapKey(id))||'{}'); }catch(e){ return {}; } };
const saveMap=(id,m)=>{ try{ localStorage.setItem(evMapKey(id),JSON.stringify(m)); }catch(e){} };

const running={}; // one connection per meet; it keeps running when the results panel is redrawn or closed
window.mountLiveConnect=function(host, ctx){
  const {sb, meet, getRegs}=ctx, id=meet.id;
  if(running[id]){ host.innerHTML=''; host.appendChild(running[id]); return; }
  const el=document.createElement('div'); host.appendChild(el); running[id]=el;
  const can=!!(window.showDirectoryPicker&&window.showOpenFilePicker);
  el.innerHTML=`<div class="border-2 border-red-200 rounded p-3 bg-white mb-3">
    <p class="font-bold text-red-700">🔴 Live connection to Meet Manager</p>
    <p class="text-xs text-gray-600 mb-2">Run this on the timing laptop (the one with Meet Manager), in Chrome or Edge, and leave this page open during the meet. Results go to this meet's results page as they come in — parents see them within 30 seconds.</p>
    ${can?'':'<p class="text-sm text-red-700 font-semibold mb-2">This browser can\'t watch files on the computer. Open this page in Google Chrome or Microsoft Edge on the timing laptop (Windows).</p>'}
    <div class="flex flex-wrap gap-2 mb-2">
      <button type="button" data-k="db" class="btn bg-red-600 text-white text-sm" ${can?'':'disabled'}>Fully automatic: connect to the Meet Manager database</button>
      <button type="button" data-k="folder" class="btn bg-white border text-sm" ${can?'':'disabled'}>One key per event: watch the real-time folder (F12)</button>
    </div>
    <label class="text-xs text-gray-700 flex items-center gap-1"><input type="checkbox" data-k="test"> Test only — show what it reads, don't post anything</label>
    <details class="text-xs text-gray-600 mt-2"><summary class="cursor-pointer font-semibold">How to set it up</summary>
      <p class="mt-1"><b>Fully automatic (database):</b> Meet Manager must have the meet open in <b>multi-user mode</b> — in single-user mode it locks the file and nothing can read it. Then click the red button and pick this meet's database file — in Meet Manager it's the meet's <b>.mdb</b> file (File &gt; Open shows where it is, for example under C:\\tfmeets6). From then on, every result the timer accepts in Meet Manager shows up on the Live tab by itself. The first time, this page may ask you to say which event is which — once per meet.</p>
      <p class="mt-1"><b>One key per event (needs Meet Manager's Pro option):</b> in Meet Manager go to Run &gt; Web &gt; Log-in, tick <b>Do not upload</b>, and make sure F11/F12 are turned on. Then click the white button and pick the <b>C:\\Realtime</b> folder. Each time the timer opens a finished event in Run and presses <b>F12</b>, it goes live. You can also save a semicolon-delimited results export into that folder any time and it's picked up too.</p>
      <p class="mt-1">Either way, sending an event again replaces it — nothing is ever doubled. Tick "Test only" before the first meet to check the results look right.</p>
    </details>
    <div data-k="status" class="text-sm mt-2"></div>
    <div data-k="map" class="mt-2"></div>
    <div data-k="log" class="text-xs text-gray-600 mt-2 max-h-48 overflow-y-auto"></div>
  </div>`;
  const $k=k=>el.querySelector(`[data-k="${k}"]`);
  let timer=null, busy=false, sig={}, lastSeen={}, wake=null, mode=null, handle=null, fieldUnit='auto';
  const log=(msg,cls='')=>{ const d=document.createElement('div'); d.className=cls; d.textContent=`${new Date().toLocaleTimeString([], {hour:'numeric',minute:'2-digit',second:'2-digit'})} — ${msg}`; $k('log').prepend(d); while($k('log').children.length>200) $k('log').lastChild.remove(); };
  const status=html=>{ $k('status').innerHTML=html; };
  async function keepAwake(){ try{ if('wakeLock' in navigator){ wake=await navigator.wakeLock.request('screen'); } }catch(e){} }
  document.addEventListener('visibilitychange',()=>{ if(timer&&!document.hidden) keepAwake(); });
  function stop(){ clearInterval(timer); timer=null; mode=null; handle=null; try{ wake&&wake.release(); }catch(e){} status('Stopped.'); }

  // Post every event group whose results changed since the last post.
  async function post(rows, from){
    const groups={}; rows.forEach(r=>{ (groups[groupKey(r)]??=[]).push(r); });
    const changed=Object.entries(groups).filter(([k,g])=>{ const s=JSON.stringify(g.map(r=>[r.athlete_name,r.mark,r.place,r.heat,r.wind,r.relay_runners])); if(sig[k]===s) return false; g._sig=s; return true; });
    if(!changed.length) return 0;
    const label=([,g])=>`${g[0].division||''} ${g[0].gender==='Boy'?'Boys':g[0].gender==='Girl'?'Girls':g[0].gender} ${g[0].event_name}${g[0].round==='P'?' (prelims)':''}`.trim();
    if($k('test').checked){ changed.forEach(c=>{ log(`TEST — would post ${label(c)}: ${c[1].slice(0,3).map(r=>`${r.place||''} ${r.athlete_name} ${r.mark}`).join(' · ')}${c[1].length>3?' …':''} (${c[1].length} results)`); sig[c[0]]=c[1]._sig; }); return changed.length; }
    const send=changed.flatMap(([,g])=>g.map(({_sig,...r})=>r));
    const {error}=await sb.rpc('replace_meet_results',{p_meet:id,p_rows:send,p_all_teams:true});
    if(error){ log('Could not post: '+(/replace_meet_results/.test(error.message)?'live upload is not switched on in the database yet (supabase/2026-10-14-live-results.sql).':error.message),'text-red-700'); return 0; }
    changed.forEach(c=>{ sig[c[0]]=c[1]._sig; log(`Posted ${label(c)} — ${c[1].length} results${from?` (${from})`:''}`,'text-green-800'); });
    return changed.length;
  }

  // ---- B) database ----
  async function readDb(){
    const f=await handle.getFile();
    if(lastSeen.db===f.lastModified+':'+f.size && Object.keys(sig).length) return; // nothing changed on disk
    await loadMdbReader();
    const reader=new window.MDBReader(window.MDBBuffer.from(await f.arrayBuffer()));
    const tb=window.readMeetManagerTables(reader);
    // Only a file with no Event table at all is the wrong file. A meet whose roster hasn't been imported yet has events
    // but no entries — that is a normal state before a race (entries arrive with File › Import), so stay connected and say so.
    if(!tb.events.length) throw Object.assign(new Error('This file doesn\'t look like a Meet Manager meet database (no events in it). Click the red button again and pick the meet\'s .mdb file.'),{wrongFile:true});
    const noEntries=!(tb.entries.length||tb.relays.length);
    const map=loadMap(id);
    const {rows,needMap,unmatched}=window.buildRowsFromMeetManager(tb,{regs:getRegs(),eventMap:map,fieldUnit});
    lastSeen.db=f.lastModified+':'+f.size;
    showMap(tb, map, needMap);
    const n=await post(rows,'database');
    const entryNote=noEntries?` <b class="text-orange-700">${tb.events.length} event(s) found but no athletes or entries yet — import the roster in Meet Manager (File › Import) and this page picks it up on its own.</b>`:'';
    status(`<span class="text-green-800 font-semibold">● Connected to ${esc(f.name)}</span> — ${rows.length} results read, last checked ${new Date().toLocaleTimeString([], {hour:'numeric',minute:'2-digit',second:'2-digit'})}. ${n?`${n} event(s) updated.`:'No changes.'}${entryNote}${needMap.length?` <b class="text-orange-700">${needMap.length} event type(s) need a name below before they can go live.</b>`:''}${unmatched.length?` <span class="text-gray-500">(${unmatched.length} athletes not matched to a registration — still posted.)</span>`:''}`);
  }
  // Event-type picker: shows every kind of event in the database with our guess; the timer fixes or fills in any that are wrong.
  function showMap(tb, map, needMap){
    const box=$k('map'); const kinds={};
    tb.events.forEach(e=>{ const k=window.mmEventKey(e); (kinds[k]??={e,nums:[]}).nums.push(col(e,['event_no'])); });
    const opts=STD().map(s=>`${s.code}|${s.relay?1:0}`).filter((v,i,a)=>a.indexOf(v)===i);
    const optLabel=v=>{ const [c,r]=v.split('|'); const s=STD().find(x=>x.code===c&&!!x.relay===(r==='1')); return s?s.name:c; };
    const describe=e=>{ const n=col(e,['event_name','event_title','ev_name','event_desc','event_note']); const d=col(e,['event_dist','dist']); const tf=String(col(e,['trk_field','event_type'])||'').toUpperCase();
      return n||`${String(col(e,['ind_rel'])||'').toUpperCase()==='R'?'Relay ':''}${tf==='F'?'Field event ':''}${d?d+'m ':''}${col(e,['event_stroke','stroke'])?'(type '+col(e,['event_stroke','stroke'])+')':''}`.trim(); };
    const html=Object.entries(kinds).map(([k,{e,nums}])=>{
      const cur=map[k]!==undefined?map[k]:window.mmGuessEvent(e); const val=cur==='skip'?'skip':cur?`${cur.code}|${cur.relay?1:0}`:'';
      return `<tr class="border-t ${needMap.includes(k)?'bg-orange-50':''}"><td class="py-1 pr-2">${esc(describe(e))}<div class="text-gray-400">Meet Manager event #${nums.filter(x=>x!=null).slice(0,6).join(', ')}${nums.length>6?'…':''}</div></td>
        <td class="py-1"><select data-map="${esc(k)}" class="border rounded p-1"><option value="">— pick —</option>${opts.map(v=>`<option value="${v}" ${v===val?'selected':''}>${esc(optLabel(v))}</option>`).join('')}<option value="skip" ${val==='skip'?'selected':''}>Don't post this event</option></select></td></tr>`; }).join('');
    box.innerHTML=`<details ${needMap.length?'open':''} class="text-xs"><summary class="cursor-pointer font-semibold">Which event is which (${Object.keys(kinds).length} kinds of events in this meet)</summary>
      <p class="text-gray-600 my-1">Checked automatically — only fix a row if it's wrong. Orange rows couldn't be worked out and won't go live until you pick the event.</p>
      <label class="flex items-center gap-1 mb-1">Field marks: <select data-k="unit" class="border rounded p-1"><option value="auto">Automatic (as Meet Manager recorded them)</option><option value="in">always inches</option><option value="m">always meters</option><option value="cm">always centimeters</option></select> <span class="text-gray-500">(only change this if a mark in Test mode doesn't match Meet Manager)</span></label>
      <table class="w-full">${html}</table></details>`;
    box.querySelector('[data-k="unit"]').value=fieldUnit;
    box.querySelector('[data-k="unit"]').onchange=ev=>{ fieldUnit=ev.target.value; sig={}; lastSeen={}; tick(); };
    box.querySelectorAll('select[data-map]').forEach(s=>s.onchange=()=>{ const m=loadMap(id); const v=s.value; if(!v) delete m[s.dataset.map]; else m[s.dataset.map]=v==='skip'?'skip':{code:v.split('|')[0],relay:v.split('|')[1]==='1'}; saveMap(id,m); lastSeen={}; tick(); });
  }

  // ---- A) real-time folder ----
  async function readFolder(){
    let n=0, files=0;
    for await (const [name, h] of handle.entries()){
      if(h.kind!=='file'||!/\.(htm|html|txt|csv)$/i.test(name)) continue; files++;
      const f=await h.getFile(); const stamp=f.lastModified+':'+f.size; if(lastSeen[name]===stamp) continue;
      const text=await f.text(); lastSeen[name]=stamp;
      let rows;
      if(/^[ER];/m.test(text)) rows=window.parseHytekResults(text,window.APP_CONFIG,getRegs(),[],true).rows.map(r=>({...r,source:'hytek-live'}));
      else rows=window.parseHytekPrintedResults(text,getRegs()).rows;
      if(rows.length) n+=await post(rows,name);
    }
    status(`<span class="text-green-800 font-semibold">● Watching ${esc(handle.name)}</span> — ${files} file(s), last checked ${new Date().toLocaleTimeString([], {hour:'numeric',minute:'2-digit',second:'2-digit'})}.${n?` ${n} event(s) updated.`:''}`);
  }

  async function tick(){
    if(!handle||busy) return; busy=true;
    try{ if(mode==='db') await readDb(); else await readFolder(); }
    catch(e){ if(e.wrongFile){ stop(); status(`<span class="text-red-700 font-semibold">${esc(e.message)}</span>`); return; }
      // Meet Manager in single-user mode locks the meet file so nothing else can read it (Chrome reports NotReadableError).
      const locked=mode==='db'&&(e.name==='NotReadableError'||/could not be read|permission/i.test(e.message||''));
      if(locked){ log('Meet Manager has the meet file locked. Switch Meet Manager to multi-user mode (see the guide) — this keeps trying and connects as soon as it can read the file.','text-red-700');
        status(`<span class="text-red-700 font-semibold">● Can't read the meet file — Meet Manager is in single-user mode.</span> In Meet Manager, close the meet and open it again in <b>multi-user mode</b>. This page keeps trying every 30 seconds.`); }
      else { log((mode==='db'?'Could not read the database this time (Meet Manager may be saving) — trying again. ':'Could not read the folder — trying again. ')+e.message,'text-orange-700'); status(`<span class="text-orange-700 font-semibold">● Retrying…</span> ${esc(e.message)}`); } }
    finally{ busy=false; }
  }
  async function start(m){
    try{
      if(timer) stop();
      if(m==='db'){ [handle]=await window.showOpenFilePicker({types:[{description:'Meet Manager database',accept:{'application/x-msaccess':['.mdb','.accdb']}}],excludeAcceptAllOption:false}); }
      else handle=await window.showDirectoryPicker({id:'hytek-realtime',mode:'read'});
    }catch(e){ return; } // picker closed
    mode=m; sig={}; lastSeen={}; $k('map').innerHTML=''; keepAwake();
    log(m==='db'?`Connected to ${handle.name}.`:`Watching folder ${handle.name}.`);
    status('Reading…'); await tick();
    timer=setInterval(tick, m==='db'?30000:10000);
    if(!el.querySelector('[data-k="stop"]')){ const b=document.createElement('button'); b.type='button'; b.dataset.k='stop'; b.className='btn bg-gray-200 text-sm mt-2 mr-2'; b.textContent='Stop'; b.onclick=()=>{ stop(); log('Stopped.'); };
      const r=document.createElement('button'); r.type='button'; r.dataset.k='report'; r.className='btn bg-gray-100 text-sm mt-2'; r.textContent='Download a database report'; r.title='For troubleshooting: the layout of the Meet Manager database (no athlete names)';
      r.onclick=async()=>{ if(mode!=='db') return alert('Connect to the database first.'); await loadMdbReader(); const f=await handle.getFile(); const rep=window.describeMeetManagerDb(new window.MDBReader(window.MDBBuffer.from(await f.arrayBuffer())));
        const a=document.createElement('a'); a.href=URL.createObjectURL(new Blob([rep],{type:'text/plain'})); a.download='meet-manager-database-report.txt'; a.click(); };
      $k('status').after(b); b.after(r); }
  }
  $k('db').onclick=()=>start('db');
  $k('folder').onclick=()=>start('folder');
  $k('test').onchange=()=>{ sig={}; lastSeen={}; log($k('test').checked?'Test mode on — nothing will be posted.':'Test mode off — results will be posted.'); tick(); };
};
})();
