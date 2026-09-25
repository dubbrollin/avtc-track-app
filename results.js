// ---- Results helpers: parse Hy-Tek results export, convert marks, rank ----

// "1:19.14" / "58.83" / "13.4h" -> seconds ; field "12.33" (metres) / "12'10.25" (feet-inches) -> metres
window.markToValue = function(mark, isTime, measure){
  const s=String(mark||'').trim().replace(/h$/i,'');
  if(!s || /^(DNF|DNS|DQ|NH|NM|FOUL|SCR|NT|ND)$/i.test(s)) return null;
  if(isTime){
    const p=s.split(':').map(Number); if(p.some(isNaN)) return null;
    return p.reduce((a,b)=>a*60+b,0);
  }
  const ft=s.match(/^(\d+)['\-]\s*(\d+(?:\.\d+)?)?/); // English feet-inches: 12'10.25 or Hy-Tek's 12-10.25
  if(ft||measure==='E'){ if(!ft) return null; return +(((+ft[1])*12+(+(ft[2]||0)))*0.0254).toFixed(3); }
  const n=parseFloat(s.replace(/m$/i,'')); return isNaN(n)?null:n;
};

// Map Hy-Tek E/R records -> result rows. Only rows whose team code matches cfg.TEAM_CODE (unless all=true).
// Returns {rows, skippedOtherTeams, unmatched:[names], header}
window.parseHytekResults = function(text, cfg, regs, meetEvents, all){
  const lines=text.split(/\r?\n/).filter(l=>l.trim());
  const code=(cfg.TEAM_CODE||'').toUpperCase();
  const out=[], unmatched=new Set(); let skipped=0, header=null;
  const byKey={}; regs.forEach(r=>{ byKey[nk(r.last_name,r.first_name)]=r; });
  const evName=(c,relay)=>{ const e=(window.STANDARD_EVENTS||[]).find(x=>x.code===c&&!!x.relay===relay); return e?e.name:c; };
  for(const l of lines){
    const f=l.split(';').map(x=>x.trim());
    if(f[0]==='H'){ header={meet:f[1],start:f[2]}; continue; }
    if(f[0]==='E'){
      if(!all && f[27].toUpperCase()!==code){ skipped++; continue; }
      const isTime=f[1].startsWith('T')||f[1]==='M'||f[1]==='TM'; // combined events ranked by points, treated like field (higher better)
      const timeLike=f[1]==='T'||f[1]==='TM';
      const reg=byKey[nk(f[22],f[23])]; if(!reg) unmatched.add(`${f[23]} ${f[22]}`);
      out.push({ registration_id:reg?.id||null, athlete_name:`${f[23]} ${f[22]}`, gender:f[25]==='F'?'Girl':'Boy',
        division:divFromName(f[8])||reg?.division||divFromDob(f[26]), team_code:(f[27]||'').toUpperCase()||null, event_code:f[4], event_name:evName(f[4],false), is_relay:false,
        round:f[9]||'F', mark:f[10], mark_value:markToValue(f[10],timeLike,f[11]), is_time:timeLike,
        place:parseInt(f[13])||null, overall_place:parseInt(f[14])||null, heat:parseInt(f[15])||null, wind:f[12]||null, source:'hytek' });
    }
    if(f[0]==='R'){
      if(!all && f[12].toUpperCase()!==code){ skipped++; continue; }
      const runners=[]; for(let i=18;i+1<f.length;i+=9){ if(f[i]) runners.push(`${f[i+1]} ${f[i]}`); }
      const g=f[5]==='F'?'Girl':f[5]==='M'?'Boy':'Mixed';
      out.push({ registration_id:null, athlete_name:f[1]||`${cfg.CLUB_NAME} relay`, gender:g, division:divFromName(f[8]), team_code:(f[12]||'').toUpperCase()||null,
        event_code:f[4], event_name:evName(f[4],true), is_relay:true, relay_runners:runners.join(', '),
        round:f[9]||'F', mark:f[10], mark_value:markToValue(f[10],true,'M'), is_time:true,
        place:parseInt(f[13])||null, overall_place:parseInt(f[14])||null, heat:parseInt(f[15])||null, source:'hytek' });
    }
  }
  return {rows:out, skippedOtherTeams:skipped, unmatched:[...unmatched], header};
  function nk(l,f){ return (l+'|'+f).toLowerCase().replace(/[^a-z|]/g,''); }
  // Hy-Tek writes division names its own way ("Sub Gremlin", "Junior", "15-18", "ALL") — map them to ours.
  function divFromName(n){
    n=(n||'').toLowerCase().replace(/[^a-z0-9]/g,'');
    if(n.includes('subgremlin')) return 'Sub-Gremlin';
    if(n.includes('gremlin')) return 'Gremlin';
    if(n.includes('bantam')) return 'Bantam';
    if(n.includes('junior')) return 'Juniors';
    if(n.includes('youth')) return 'Youth';
    if(n.includes('1518')||n.includes('intermediate')) return 'Intermediates';
    return null; // "ALL" etc. — caller falls back to the athlete's age
  }
  // Age on Dec 31 of the meet's year, from date of birth "MM/DD/YYYY"
  function divFromDob(dob){
    const y=parseInt((dob||'').slice(-4),10), my=parseInt(((header&&header.start)||'').slice(-4),10);
    if(!y||!my) return null; const age=my-y; return (window.divisionFor&&window.divisionFor(age))||null;
  }
};

// ---- Hy-Tek "Team Manager interchange" (.tcl) parser — the REAL format this club's software exports (fixed-width
// A/B/C/D/E record types), distinct from the semicolon-delimited CL2 format parseHytekResults() above expects.
// Detect which format a file is with looksLikeHytekTeamFile() before choosing a parser.
window.looksLikeHytekTeamFile = function(text){
  return /^D1[MF]\d/m.test(text) && /^E6/m.test(text);
};
window.HYTEK_TM_DIV_MAP = {
  'sub-gremlin':'Sub-Gremlin','gremlin':'Gremlin','bantam':'Bantam',
  'junior':'Juniors','juniors':'Juniors','youth':'Youth',
  '15-18':'Intermediates','intermediate':'Intermediates','intermediates':'Intermediates'
};
// Returns {rows, teamCode, meetName}. rows: {athlete_id,first_name,last_name,athlete_name,gender,division,
// event_name,is_time,mark,mark_value,round,place,team_code}. Only this team's athletes appear (the file only
// ever contains the exporting team's own roster). regs (optional): existing verified registrations, used to
// attach registration_id by name match so results link to the athlete's record.
window.parseHytekTeamFile = function(text, regs){
  const byKey={}; (regs||[]).forEach(r=>{ byKey[(r.last_name+'|'+r.first_name).toLowerCase().replace(/[^a-z|]/g,'')]=r; });
  const lines=text.split(/\r?\n/);
  let cur=null, teamCode=null, meetName=null;
  const pending=[]; const out=[]; const unmatched=new Set();
  for(const l of lines){
    if(l.startsWith('B1') && !meetName) meetName=l.slice(2,50).trim();
    if(l.startsWith('C1') && !teamCode) teamCode=l.slice(2,6).trim();
    if(l.startsWith('D1')){
      const m=l.match(/^D1([MF])(\d+)(.{1,40}?)\s{2,}(\S.{0,25}?)\s{2,}/);
      if(m){ const [,g,id,last,first]=m; cur={id, gender:g==='F'?'Girl':'Boy', last_name:last.trim(), first_name:first.trim()}; }
      continue;
    }
    if(l.startsWith('E2')){
      const blocks=[...l.matchAll(/([FPT])\s+(\d+:?\d*\.\d+)[A-Z]?\s+[A-Z]-?[\d.]+\s*\d*:?\d*\.\d+\s*[\d.]*\s+(\d+)\s+(\d+)\s+(\d+)/g)]
        .map(b=>({round:b[1], mark:b[2], place:+b[5]}));
      pending.push({athlete:cur, blocks, isTime:true});
      continue;
    }
    if(l.startsWith('E8')){ // throws/jumps: up to 5 attempts, each "<attemptNo> <value>E" — take the best non-zero
      const vals=[...l.matchAll(/(\d+)\s+(\d+\.\d+)E/g)].map(m=>+m[2]).filter(v=>v>0);
      const best=vals.length?Math.max(...vals):null;
      pending.push({athlete:cur, blocks: best!=null?[{round:'F', mark:String(best), place:null}]:[], isTime:false, isFieldInches:true});
      continue;
    }
    if(l.startsWith('E6')){
      const rest=l.slice(2).replace(/\s{5,}\d*\s*$/,'').trim();
      const entry=pending.pop();
      if(!entry) continue;
      let division='?', eventName=rest;
      const evMatch=rest.match(/^(\d+)?\s*(Girls|Boys)\s+(.+?)\s+([A-Za-z0-9-]+)\s*$/);
      if(evMatch){ const [,,,name,divRaw]=evMatch; division=window.HYTEK_TM_DIV_MAP[divRaw.toLowerCase()]||divRaw; eventName=name.trim(); }
      const chosen=entry.blocks.find(b=>b.round==='F')||entry.blocks[0];
      if(!chosen || !entry.athlete) continue;
      let mark_value=window.markToValue(chosen.mark, entry.isTime);
      if(entry.isFieldInches && mark_value!=null) mark_value=+(mark_value*0.0254).toFixed(3); // inches -> metres
      const reg=byKey[(entry.athlete.last_name+'|'+entry.athlete.first_name).toLowerCase().replace(/[^a-z|]/g,'')];
      if(!reg) unmatched.add(entry.athlete.first_name+' '+entry.athlete.last_name);
      out.push({
        registration_id:reg?.id||null, athlete_id:entry.athlete.id,
        athlete_name:`${entry.athlete.first_name} ${entry.athlete.last_name}`, gender:entry.athlete.gender,
        division, event_name:eventName, is_relay:false, is_time:entry.isTime,
        mark:chosen.mark, mark_value, round:chosen.round, place:chosen.place, team_code:teamCode, source:'hytek-tm'
      });
    }
  }
  return {rows:out, teamCode, meetName, unmatched:[...unmatched]};
};

// Group results into ranked lists: key = event/division/gender, sorted best first. bestPerAthlete=true keeps one row per athlete.
// conference: null = all teams combined; 'East' or 'West' = only that conference's athletes (row must carry .conference, set via attachConference()).
// Season/overall rankings are capped at the top 50 per event/division/gender group per club policy — anything ranked 51+ is dropped, not just hidden.
window.rankResults = function(rows, bestPerAthlete, conference, capAt){
  const cap = capAt===undefined ? 50 : capAt; // pass null/0 to disable the cap (e.g. single-meet results)
  const filtered = conference ? rows.filter(r=>r.conference===conference) : rows;
  const groups={};
  for(const r of filtered){
    const k=`${r.division||'?'}|${r.gender}|${r.event_name}`;
    (groups[k]??={ division:r.division||'?', gender:r.gender, event:r.event_name, is_time:r.is_time, rows:[] }).rows.push(r);
  }
  const divOrder=(window.DIVISIONS||[]).map(d=>d.name);
  return Object.values(groups).map(g=>{
    const fin=r=>(r.round==='F'?0:1); // in a single meet, finalists rank ahead of athletes who only ran the prelims
    let rs=g.rows.filter(r=>r.mark_value!=null).sort((a,b)=>(bestPerAthlete?0:(fin(a)-fin(b)))||(g.is_time?a.mark_value-b.mark_value:b.mark_value-a.mark_value));
    if(bestPerAthlete){ const seen=new Set(); rs=rs.filter(r=>{ const id=r.registration_id||r.athlete_name; if(seen.has(id)) return false; seen.add(id); return true; }); }
    if(cap) rs=rs.slice(0,cap);
    g.rows=rs.concat(g.rows.filter(r=>r.mark_value==null)); return g;
  }).sort((a,b)=>(divOrder.indexOf(a.division)-divOrder.indexOf(b.division))||a.gender.localeCompare(b.gender)||a.event.localeCompare(b.event));
};

// Tags each result row with .conference (East/West/null) by looking up its registration's team.
// regsById: {registration_id: registrationRow} — registrationRow.team_code must be set (added in the 2026 rebuild).
window.attachConference = function(rows, regsById){
  return rows.map(r=>{
    const reg = r.registration_id ? regsById[r.registration_id] : null;
    const teamCode = reg?.team_code || r.team_code || null;
    return {...r, team_code:teamCode, conference: teamCode ? window.conferenceForTeamCode(teamCode) : null};
  });
};

// ---- Results PDF: a readable printout of whatever groups the results page is showing ----
// groups = output of rankResults(); opts = {title, subtitle, showPlaceNumbers}. Works in the browser (window.PDFLib) and Node (pdf-lib) for testing.
window.resultsPdf = async function(groups, opts){
  opts = opts || {};
  const LIB = typeof window !== 'undefined' && window.PDFLib ? window.PDFLib : require('pdf-lib');
  const { PDFDocument, StandardFonts, rgb } = LIB;
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica), bold = await doc.embedFont(StandardFonts.HelveticaBold), mono = await doc.embedFont(StandardFonts.Courier);
  const clean = s => String(s ?? '').replace(/[^\x20-\x7E\xA0-\xFF]/g, '?');
  const W=612, H=792, M=42, navy=rgb(0.08,0.15,0.32), gold=rgb(0.85,0.65,0.13), grey=rgb(0.42,0.45,0.5);
  const teamName = c => { const t=(window.VYC_TEAMS||[]).find(x=>x.code===c); return t?t.name:(c||''); };
  let page, y, pageNo=0; const pages=[];
  const newPage = () => {
    page = doc.addPage([W,H]); pages.push(page); pageNo++;
    page.drawRectangle({x:0,y:H-58,width:W,height:58,color:navy});
    page.drawText(clean(opts.title||'Results'), {x:M,y:H-30,size:16,font:bold,color:rgb(1,1,1)});
    if(opts.subtitle) page.drawText(clean(opts.subtitle), {x:M,y:H-47,size:9.5,font,color:rgb(0.85,0.88,0.95)});
    page.drawRectangle({x:0,y:H-61,width:W,height:3,color:gold});
    y = H-84;
  };
  const rowH = 15;
  const fit = (txt,f,size,max) => { txt=clean(txt); while(txt.length>1 && f.widthOfTextAtSize(txt,size)>max) txt=txt.slice(0,-1); return txt; };
  newPage();
  if(!groups.length){ page.drawText('No results to show.', {x:M,y,size:11,font,color:grey}); }
  for(const g of groups){
    const label = `${g.division} ${g.gender==='Boy'?'Boys':g.gender==='Girl'?'Girls':g.gender} - ${g.event}`;
    if(y < 60 + rowH*3) newPage();
    page.drawRectangle({x:M-4,y:y-5,width:W-2*M+8,height:19,color:rgb(0.92,0.94,0.98)});
    page.drawText(clean(label), {x:M,y:y,size:11,font:bold,color:navy});
    y -= 22;
    let i=0;
    for(const r of g.rows){
      const relay = r.relay_runners ? clean(r.relay_runners) : '';
      const need = rowH + (relay?10:0);
      if(y < 46 + need){ newPage(); page.drawText(clean(label)+' (cont.)', {x:M,y,size:10,font:bold,color:navy}); y -= 20; }
      const place = r.mark_value!=null ? i+1 : '';
      page.drawText(String(place), {x:M,y,size:9.5,font,color:grey});
      page.drawText(fit(r.athlete_name,font,9.5,190), {x:M+28,y,size:9.5,font:bold,color:rgb(0.1,0.1,0.1)});
      page.drawText(fit(teamName(r.team_code),font,9,150), {x:M+240,y,size:9,font,color:grey});
      const mk = clean(r.mark) + (r.wind?` (w ${clean(r.wind)})`:'');
      page.drawText(mk, {x:W-M-mono.widthOfTextAtSize(mk,9.5),y,size:9.5,font:mono,color:rgb(0.1,0.1,0.1)});
      y -= rowH-3;
      if(relay){ page.drawText(fit(relay,font,7.5,W-2*M-40), {x:M+28,y,size:7.5,font,color:grey}); y -= 10; }
      y -= 3; i++;
    }
    y -= 10;
  }
  pages.forEach((p,n)=>{
    p.drawText(`Page ${n+1} of ${pages.length}`, {x:W-M-50,y:24,size:8,font,color:grey});
    p.drawText('Valley Youth Conference Track & Field', {x:M,y:24,size:8,font,color:grey});
  });
  return doc.save();
};
