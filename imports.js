// ---- Importing athletes a team already registered somewhere else (supabase/2026-11-10-team-imports.sql) ----
// Team Admin → "Import athletes": upload a Team Manager roster export (.tcl, or the .ZIP it comes in) or a CSV / Excel
// export from another app → match the columns → preview → import. Each athlete waits in reg_imports until a parent
// finishes a short confirm-and-sign registration (index.html?import=<id>). Each family gets one link code.
// Parent Dashboard: "Finish registration" list + "Got a code from your team?" box (parent.html?code=XXXXXX fills it in).
(function(){
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const toast=(m,bad)=>{ if(window.toast) return window.toast(m,bad); alert(m); };
const teamName=c=>((window.VYC_TEAMS||[]).find(t=>t.code===c)||{}).name||c;

// ---------- reading files ----------
// .zip directory + inflate one entry (the browser's own DecompressionStream; same as the Meet Manager backup reader).
function zipEntries(buf){
  const u8=new Uint8Array(buf), dv=new DataView(buf); let eocd=-1;
  for(let i=u8.length-22;i>=Math.max(0,u8.length-65557);i--){ if(dv.getUint32(i,true)===0x06054b50){ eocd=i; break; } }
  if(eocd<0) throw new Error('That file isn\'t a readable .zip.');
  const n=dv.getUint16(eocd+10,true), list=[]; let p=dv.getUint32(eocd+16,true);
  for(let k=0;k<n;k++){ if(dv.getUint32(p,true)!==0x02014b50) break;
    const method=dv.getUint16(p+10,true), csize=dv.getUint32(p+20,true), nlen=dv.getUint16(p+28,true), xlen=dv.getUint16(p+30,true), clen=dv.getUint16(p+32,true), off=dv.getUint32(p+42,true);
    const name=new TextDecoder().decode(u8.subarray(p+46,p+46+nlen)); p+=46+nlen+xlen+clen; if(!/\/$/.test(name)) list.push({name,method,csize,off}); }
  return list;
}
async function zipText(buf,e){
  const u8=new Uint8Array(buf), dv=new DataView(buf), start=e.off+30+dv.getUint16(e.off+26,true)+dv.getUint16(e.off+28,true), data=u8.subarray(start,start+e.csize);
  let out; if(e.method===0) out=data; else if(e.method===8) out=new Uint8Array(await new Response(new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer());
  else throw new Error('That .zip is packed in a way the app can\'t open.');
  return new TextDecoder('latin1').decode(out);
}
// Team Manager roster export ("D1" lines, fixed columns — checked against two real AVTC exports):
//   3 gender M/F · 4-8 athlete id · 9-23 last name · 24-48 first name · comp number · 54-61 birthday MM/DD-YY (then age).
function parseTeamManager(text){
  const rows=[];
  text.split(/\r?\n/).forEach(l=>{ if(!/^D1[MF]/.test(l)) return;
    const last=l.slice(8,23).trim(), first=l.slice(23,48).trim(); if(!last||!first) return;
    const m=l.slice(53,61).match(/^(\d{2})\/(\d{2})-(\d{2})$/); let dob='';   // the age follows right after, so read exactly these 8 columns
    if(m){ let y=+m[3]; if(y<100) y+=(y>((new Date().getFullYear()+1)%100)?1900:2000); dob=`${y}-${m[1]}-${m[2]}`; }
    rows.push({first_name:first,last_name:last,gender:l[2]==='F'?'Girl':'Boy',dob}); });
  return rows;
}
const looksTeamManager=t=>/^A1/.test(t)&&/\nD1[MF]/.test(t);
function parseCsv(text){
  text=text.replace(/^﻿/,'');
  const first=text.split(/\r?\n/)[0]||'', delim=[',',';','\t'].sort((a,b)=>first.split(b).length-first.split(a).length)[0];
  const rows=[]; let row=[], f='', q=false;
  for(let i=0;i<text.length;i++){ const c=text[i];
    if(q){ if(c==='"'){ if(text[i+1]==='"'){ f+='"'; i++; } else q=false; } else f+=c; continue; }
    if(c==='"') q=true; else if(c===delim){ row.push(f); f=''; } else if(c==='\n'||c==='\r'){ if(c==='\r'&&text[i+1]==='\n') i++; row.push(f); rows.push(row); row=[]; f=''; } else f+=c; }
  if(f||row.length){ row.push(f); rows.push(row); }
  return rows.filter(r=>r.some(x=>String(x).trim()));
}
let xlsxLoading=null;
const loadXlsx=()=>xlsxLoading||(xlsxLoading=new Promise((ok,bad)=>{ if(window.XLSX) return ok(); const s=document.createElement('script');
  s.src='https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js'; s.onload=ok; s.onerror=()=>bad(new Error('Could not load the Excel reader — save the sheet as CSV and upload that instead.')); document.head.appendChild(s); }));
// Any file -> {kind:'tm', rows} (ready) or {kind:'table', table:[[...]]} (needs the column match).
async function readFile(f){
  const n=f.name.toLowerCase();
  if(/\.zip$/.test(n)){ const buf=await f.arrayBuffer(), list=zipEntries(buf);
    const e=list.find(x=>/\.tcl$/i.test(x.name))||list.find(x=>/\.(csv|txt)$/i.test(x.name));
    if(!e) throw new Error('No roster file inside that .zip. Use Team Manager\'s roster export, or a CSV.');
    const t=await zipText(buf,e); if(looksTeamManager(t)) return {kind:'tm',rows:parseTeamManager(t)}; return {kind:'table',table:parseCsv(t)}; }
  if(/\.(xlsx|xls)$/.test(n)){ await loadXlsx(); const wb=window.XLSX.read(await f.arrayBuffer(),{type:'array',cellDates:false});
    const ws=wb.Sheets[wb.SheetNames[0]]; return {kind:'table',table:window.XLSX.utils.sheet_to_json(ws,{header:1,raw:false,defval:''}).filter(r=>r.some(x=>String(x).trim()))}; }
  const t=await f.text(); if(looksTeamManager(t)) return {kind:'tm',rows:parseTeamManager(t)};
  return {kind:'table',table:parseCsv(t)};
}

// ---------- column matching ----------
const FIELDS=[
  ['first_name','First name',/^(athlete\s*)?first(\s*name)?$|^given/i],
  ['last_name','Last name',/^(athlete\s*)?last(\s*name)?$|^surname|^family\s*name/i],
  ['full_name','Full name (if no first/last columns)',/^(athlete|participant|player)?\s*(full\s*)?name$/i],
  ['dob','Date of birth',/birth|^dob$|bday/i],
  ['gender','Gender',/^(gender|sex)$/i],
  ['guardian_name','Parent / guardian name',/(guardian|parent|mother|father).*name|^(guardian|parent)s?$/i],
  ['guardian_email','Parent email',/e-?mail/i],
  ['guardian_phone','Parent phone',/phone|mobile|cell/i],
  ['address','Street address',/^(street\s*)?address(\s*1)?$|^street$/i],
  ['city','City',/^city$/i],
  ['zip','Zip',/^zip|postal/i]];
function guessMap(head){ const m={}; FIELDS.forEach(([k,,re])=>{ const i=head.findIndex((h,ix)=>re.test(String(h).trim())&&!Object.values(m).includes(ix)); if(i>=0) m[k]=i; });
  if(m.first_name!=null&&m.last_name!=null) delete m.full_name; return m; }
const first=v=>String(v??'').split(/[;,\n|]|\s+\/\s+/)[0].trim();
function normDate(v){ v=String(v??'').trim(); if(!v) return '';
  if(/^\d{5}$/.test(v)){ const d=new Date(Date.UTC(1899,11,30)+(+v)*86400000); return d.toISOString().slice(0,10); }   // Excel day number
  let m=v.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/); if(m) return `${m[1]}-${m[2].padStart(2,'0')}-${m[3].padStart(2,'0')}`;
  m=v.match(/^(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{2,4})/); if(m){ let y=+m[3]; if(y<100) y+=(y>((new Date().getFullYear()+1)%100)?1900:2000); return `${y}-${m[1].padStart(2,'0')}-${m[2].padStart(2,'0')}`; }
  const d=new Date(v); return isNaN(d)?'':d.toISOString().slice(0,10); }
const normGender=v=>{ const s=String(v??'').trim().toLowerCase(); return /^(f|g|girl|female|w|women)/.test(s)?'Girl':/^(m|b|boy|male|men)/.test(s)?'Boy':''; };
function rowsFromTable(table,map){
  return table.slice(1).map(r=>{ const g=k=>map[k]!=null?String(r[map[k]]??'').trim():'';
    let fn=g('first_name'), ln=g('last_name');
    if((!fn||!ln)&&g('full_name')){ const full=g('full_name'); if(full.includes(',')){ [ln,fn]=full.split(',').map(x=>x.trim()); } else { const p=full.split(/\s+/); fn=p.shift()||''; ln=p.join(' '); } }
    return {first_name:fn,last_name:ln,dob:normDate(g('dob')),gender:normGender(g('gender')),guardian_name:first(g('guardian_name')),guardian_email:first(g('guardian_email')).toLowerCase(),
      guardian_phone:first(g('guardian_phone')),address:g('address'),city:g('city'),zip:g('zip')}; }).filter(r=>r.first_name||r.last_name);
}

// ---------- Team Admin: Import athletes tab ----------
window.mountAthleteImport=async function(el, ctx){
  const sb=ctx.sb, team=ctx.team, season=ctx.season;
  el.innerHTML=`<div class="card"><div class="col-head"><h2 class="flex-1">Import athletes you already registered</h2></div>
    <p class="text-sm text-gray-700">Registered athletes somewhere else before the app (Team Manager, another app, a spreadsheet)? Import that list here. Parents then get a <b>short confirm-and-sign</b> instead of the full form: everything you send is filled in, they check it, add what's missing and sign the VYC agreements. Each family gets one <b>link code</b> to connect to their athletes.</p>
    <ul class="text-xs text-gray-600 list-disc ml-5 mt-2">
      <li><b>Team Manager:</b> export the roster (File › Export › Roster — the .ZIP or .tcl file). It has names, gender and birthdays but <b>no parent contact</b>, so every family will link with their code.</li>
      <li><b>Another app or a spreadsheet:</b> export a CSV or Excel file. Include the parent's email if you have it — a parent who signs in with that email sees their athlete right away, no code needed.</li>
      <li>Nothing goes on your roster until the parent finishes. Athletes already registered on your team are skipped.</li></ul>
    <input type="file" id="impFile" accept=".zip,.tcl,.csv,.txt,.xlsx,.xls" class="text-sm mt-3">
    <div id="impWork" class="mt-3"></div></div>
    <div class="card"><div class="col-head"><h2 class="flex-1">Waiting for parents</h2></div><div id="impList" class="text-sm">Loading…</div></div>`;
  const work=el.querySelector('#impWork');
  el.querySelector('#impFile').onchange=async e=>{
    const f=e.target.files[0]; if(!f) return; work.innerHTML='Reading…';
    let got; try{ got=await readFile(f); }catch(err){ work.innerHTML=`<p class="text-red-700">${esc(err.message)}</p>`; return; }
    if(got.kind==='tm') return preview(got.rows,'Team Manager · '+f.name);
    const table=got.table; if(table.length<2){ work.innerHTML='<p class="text-red-700">That file has no rows under the header.</p>'; return; }
    const head=table[0], map=guessMap(head);
    const opt=i=>`<option value="">— not in this file —</option>`+head.map((h,ix)=>`<option value="${ix}" ${i===ix?'selected':''}>${esc(h||'Column '+(ix+1))}</option>`).join('');
    work.innerHTML=`<p class="font-semibold">Which column is which?</p><p class="text-xs text-gray-600 mb-2">We guessed from the column names — fix any that are wrong. First name, last name and date of birth are needed (or one full-name column).</p>
      <div class="grid sm:grid-cols-2 gap-2">${FIELDS.map(([k,label])=>`<label class="text-xs">${esc(label)}<select data-map="${k}" class="w-full border rounded p-1 text-sm">${opt(map[k])}</select></label>`).join('')}</div>
      <button type="button" id="impNext" class="btn bg-blue-600 text-white text-sm mt-3">Preview ${table.length-1} rows →</button>`;
    work.querySelector('#impNext').onclick=()=>{ const m={}; work.querySelectorAll('[data-map]').forEach(s=>{ if(s.value!=='') m[s.dataset.map]=+s.value; }); preview(rowsFromTable(table,m),'CSV · '+f.name); };
  };
  function preview(rows, source){
    const bad=r=>!r.first_name||!r.last_name?'name missing':!r.dob?'birthday missing':'';
    const ok=rows.filter(r=>!bad(r)), skip=rows.filter(bad);
    const key=r=>r.guardian_email||(r.guardian_phone||'').replace(/\D/g,'').slice(-10)||'';
    const fams=new Set(ok.map(r=>key(r)||Math.random())).size, withEmail=ok.filter(r=>r.guardian_email).length;
    work.innerHTML=`<p class="font-semibold">${ok.length} athlete${ok.length===1?'':'s'} ready to import (${fams} famil${fams===1?'y':'ies'}). ${withEmail?`${withEmail} have a parent email.`:'<span class="text-amber-800">No parent emails — every family will link with their code.</span>'}</p>
      ${skip.length?`<p class="text-sm text-amber-800 mt-1">${skip.length} row${skip.length===1?'':'s'} can't be imported: ${skip.slice(0,8).map(r=>esc(`${r.first_name} ${r.last_name}`.trim()||'(blank)')+' — '+bad(r)).join('; ')}${skip.length>8?'…':''}</p>`:''}
      <div class="overflow-x-auto mt-2" style="max-height:320px;overflow-y:auto"><table class="text-xs w-full"><thead><tr class="text-left"><th>Athlete</th><th>Birthday</th><th>Gender</th><th>Parent</th><th>Email</th><th>Phone</th></tr></thead><tbody>
      ${ok.map(r=>`<tr class="border-t"><td>${esc(r.first_name)} ${esc(r.last_name)}</td><td>${esc(r.dob)}</td><td>${esc(r.gender||'—')}</td><td>${esc(r.guardian_name||'')}</td><td>${esc(r.guardian_email||'')}</td><td>${esc(r.guardian_phone||'')}</td></tr>`).join('')}</tbody></table></div>
      ${ok.length?`<button type="button" id="impGo" class="btn bg-green-600 text-white text-sm mt-3">Import ${ok.length} athlete${ok.length===1?'':'s'} to ${esc(teamName(team))}</button>`:''}`;
    const go=work.querySelector('#impGo'); if(!go) return;
    go.onclick=async()=>{ go.disabled=true; go.textContent='Importing…';
      const payload=ok.map(r=>({...r,family_key:key(r)}));
      const {data,error}=await sb.rpc('import_athletes',{p_team:team,p_rows:payload,p_source:source});
      if(error){ work.innerHTML=`<p class="text-red-700">${esc(error.message)}</p>`; return; }
      const sk=(data&&data.skipped)||[];
      work.innerHTML=`<p class="text-green-800 font-semibold">✓ Imported ${data.added} athlete${data.added===1?'':'s'}.</p>${sk.length?`<p class="text-sm text-gray-700">Skipped ${sk.length}: ${sk.slice(0,10).map(esc).join('; ')}${sk.length>10?'…':''}</p>`:''}<p class="text-sm mt-1">Now send each family their code (below).</p>`;
      el.querySelector('#impFile').value=''; list(); };
  }
  async function list(){
    const box=el.querySelector('#impList');
    const {data,error}=await sb.from('reg_imports').select('id,family_code,first_name,last_name,dob,gender,guardian_name,guardian_email,guardian_phone,status,claimed_email,completed_at,imported_at').eq('team_code',team).eq('season_year',season).neq('status','removed').order('last_name');
    if(error){ box.innerHTML=`<p class="text-red-700">${/reg_imports/.test(error.message)?'Imports aren\'t switched on in the database yet (supabase/2026-11-10-team-imports.sql).':esc(error.message)}</p>`; return; }
    const waiting=(data||[]).filter(x=>x.status==='waiting'), done=(data||[]).filter(x=>x.status==='completed');
    if(!waiting.length&&!done.length){ box.innerHTML='<p class="text-gray-500">Nothing imported yet.</p>'; return; }
    const fam={}; waiting.forEach(x=>(fam[x.family_code]??=[]).push(x));
    const link=c=>new URL('parent.html?code='+c, location.href).href;
    const message=(c,kids)=>`Hi! ${teamName(team)} has moved registration to the VYC app. To finish ${kids.map(k=>k.first_name).join(' & ')}'s registration (about 2 minutes), open ${link(c)} , sign in or create an account, and enter code ${c} with ${kids.length>1?'one of your athletes\'':'your athlete\'s'} birthday.`;
    box.innerHTML=`<p class="text-xs text-gray-600 mb-2"><b>${waiting.length}</b> athlete${waiting.length===1?'':'s'} waiting in ${Object.keys(fam).length} famil${Object.keys(fam).length===1?'y':'ies'} · <b>${done.length}</b> finished. Send each family its message (text or email). A parent whose email is listed can also just sign in with that email.
      ${waiting.length?' <a href="#" id="impCsv" class="underline">Download the codes (CSV)</a>':''}</p>
      ${Object.entries(fam).map(([c,kids])=>`<div class="border rounded p-2 mb-2"><div class="flex flex-wrap items-center gap-2"><b class="font-mono text-base tracking-widest">${esc(c)}</b>
        <span class="flex-1">${kids.map(k=>esc(`${k.first_name} ${k.last_name}`)).join(', ')}</span>
        <button type="button" class="btn bg-gray-800 text-white text-xs" data-copy="${esc(c)}">Copy message</button></div>
        <div class="text-xs text-gray-600 mt-1">${esc(kids[0].guardian_name||'Parent not given')}${kids[0].guardian_email?' · '+esc(kids[0].guardian_email):''}${kids[0].guardian_phone?' · '+esc(kids[0].guardian_phone):''}${kids.some(k=>k.claimed_email)?` · <span class="text-green-700">linked by ${esc(kids.find(k=>k.claimed_email).claimed_email)}</span>`:''}
          · <a href="#" class="underline" data-email="${esc(kids[0].id)}">${kids[0].guardian_email?'Change':'Add'} parent email</a></div>
        <div class="text-xs mt-1">${kids.map(k=>`<span class="mr-3">${esc(k.first_name)} <a href="#" class="text-red-700 underline" data-rm="${esc(k.id)}" data-name="${esc(k.first_name+' '+k.last_name)}">remove</a></span>`).join('')}</div></div>`).join('')}
      ${done.length?`<details class="mt-2"><summary class="cursor-pointer text-xs font-semibold">Finished by parents (${done.length}) — now on your roster for review</summary><ul class="text-xs mt-1">${done.map(x=>`<li>${esc(x.first_name)} ${esc(x.last_name)} — ${esc(new Date(x.completed_at).toLocaleDateString())}</li>`).join('')}</ul></details>`:''}`;
    box.querySelectorAll('[data-copy]').forEach(b=>b.onclick=async()=>{ const c=b.dataset.copy, txt=message(c,fam[c]);
      try{ await navigator.clipboard.writeText(txt); b.textContent='Copied ✓'; setTimeout(()=>b.textContent='Copy message',2000); }catch(e){ prompt('Copy this message:',txt); } });
    box.querySelectorAll('[data-rm]').forEach(a=>a.onclick=async e=>{ e.preventDefault(); if(!confirm(`Take ${a.dataset.name} off the import list? (Nothing on your roster changes.)`)) return;
      const {error}=await sb.rpc('import_remove',{p_id:a.dataset.rm}); if(error) return toast(error.message,true); list(); });
    box.querySelectorAll('[data-email]').forEach(a=>a.onclick=async e=>{ e.preventDefault(); const v=prompt('Parent email (they can then just sign in with it — no code needed):'); if(v==null) return;
      if(v.trim()&&!/^\S+@\S+\.\S+$/.test(v.trim())) return toast('That doesn\'t look like an email.',true);
      const kid=waiting.find(k=>k.id===a.dataset.email); for(const k of fam[kid.family_code]){ const {error}=await sb.rpc('import_set_email',{p_id:k.id,p_email:v.trim()}); if(error) return toast(error.message,true); } list(); });
    const csv=box.querySelector('#impCsv'); if(csv) csv.onclick=e=>{ e.preventDefault();
      const q=s=>`"${String(s??'').replace(/"/g,'""')}"`, lines=[['Code','Athletes','Parent','Email','Phone','Link','Message'].map(q).join(',')];
      Object.entries(fam).forEach(([c,kids])=>lines.push([c,kids.map(k=>`${k.first_name} ${k.last_name}`).join('; '),kids[0].guardian_name,kids[0].guardian_email,kids[0].guardian_phone,link(c),message(c,kids)].map(q).join(',')));
      const a=document.createElement('a'); a.href=URL.createObjectURL(new Blob([lines.join('\r\n')],{type:'text/csv'})); a.download=`${team}-import-codes.csv`; a.click(); };
  }
  list();
};

// ---------- Parent Dashboard: link with a code + finish registration ----------
window.mountParentImports=async function(el, ctx){
  const sb=ctx.sb; if(!el) return;
  const code=(new URLSearchParams(location.search).get('code')||'').toUpperCase();
  const {data,error}=await sb.rpc('my_imports');
  if(error){ el.innerHTML=''; return; }   // not switched on yet
  const rows=data||[];
  const finishList=rows.length?`<div class="rounded-lg p-3 mb-3" style="border:2px solid #2563eb;background:#eff6ff"><p class="font-semibold">Your team already sent ${rows.length===1?'this athlete':'these athletes'} — finish the registration (about 2 minutes each):</p>
    ${rows.map(r=>`<div class="flex flex-wrap items-center gap-2 mt-2"><span class="flex-1"><b>${esc(r.first_name)} ${esc(r.last_name)}</b> <span class="text-gray-600 text-sm">· ${esc(teamName(r.team_code))}</span></span><a class="btn bg-blue-600 text-white text-sm" href="index.html?import=${encodeURIComponent(r.id)}">Finish registration →</a></div>`).join('')}</div>`:'';
  el.innerHTML=finishList+`<details ${code&&!rows.length?'open':''} class="mb-3"><summary class="cursor-pointer text-sm font-semibold">Got a code from your team?</summary>
    <p class="text-xs text-gray-600 mt-1">If your team moved your athlete's registration into this app, they gave you a 6-letter code. Enter it with your athlete's birthday to connect them to this account.</p>
    <div class="flex flex-wrap gap-2 mt-2 items-end"><label class="text-xs">Code<input id="impCode" class="border rounded p-2 font-mono uppercase tracking-widest w-32 block" maxlength="8" value="${esc(code)}"></label>
      <label class="text-xs">Athlete's date of birth<input id="impDob" type="date" class="border rounded p-2 block"></label>
      <button type="button" id="impClaim" class="btn bg-blue-600 text-white text-sm">Connect</button></div><p id="impMsg" class="text-sm mt-1"></p></details>`;
  el.querySelector('#impClaim').onclick=async()=>{ const m=el.querySelector('#impMsg'), c=el.querySelector('#impCode').value.trim(), d=el.querySelector('#impDob').value;
    if(!c||!d){ m.innerHTML='<span class="text-red-700">Enter the code and the birthday.</span>'; return; }
    const {data:n,error:e}=await sb.rpc('claim_import',{p_code:c,p_dob:d});
    if(e){ m.innerHTML=`<span class="text-red-700">${esc(e.message)}</span>`; return; }
    m.innerHTML=`<span class="text-green-800">✓ Connected ${n} athlete${n===1?'':'s'}.</span>`; if(code) history.replaceState(null,'',location.pathname); window.mountParentImports(el,ctx); };
};

// For the registration form's confirm-and-sign mode (index.html?import=<id>).
window.getMyImport=async function(sb,id){ const {data,error}=await sb.rpc('my_imports'); if(error) throw error; return (data||[]).find(r=>r.id===id)||null; };
// Exposed for tests.
window.__imports={parseTeamManager,parseCsv,guessMap,rowsFromTable,normDate,normGender,looksTeamManager};
})();
