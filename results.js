// ---- Results helpers: parse Hy-Tek results export, convert marks, rank ----

// "1:19.14" / "58.83" / "13.4h" -> seconds ; field "12.33" (metres) / "12'10.25" (feet-inches) -> metres
window.markToValue = function(mark, isTime, measure){
  const s=String(mark||'').trim().replace(/h$/i,'');
  if(!s || /^(DNF|DNS|DQ|NH|NM|FOUL|SCR|NT|ND)$/i.test(s)) return null;
  if(isTime){
    const p=s.split(':').map(Number); if(p.some(isNaN)) return null;
    return p.reduce((a,b)=>a*60+b,0);
  }
  const ft=s.match(/^(\d+)'\s*(\d+(?:\.\d+)?)?/); // English 12'10.25
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
        division:reg?.division||divFromName(f[8]), event_code:f[4], event_name:evName(f[4],false), is_relay:false,
        round:f[9]||'F', mark:f[10], mark_value:markToValue(f[10],timeLike,f[11]), is_time:timeLike,
        place:parseInt(f[13])||null, wind:f[12]||null, source:'hytek' });
    }
    if(f[0]==='R'){
      if(!all && f[12].toUpperCase()!==code){ skipped++; continue; }
      const runners=[]; for(let i=18;i+1<f.length;i+=9){ if(f[i]) runners.push(`${f[i+1]} ${f[i]}`); }
      const g=f[5]==='F'?'Girl':f[5]==='M'?'Boy':'Mixed';
      out.push({ registration_id:null, athlete_name:f[1]||`${cfg.CLUB_NAME} relay`, gender:g, division:divFromName(f[8]),
        event_code:f[4], event_name:evName(f[4],true), is_relay:true, relay_runners:runners.join(', '),
        round:f[9]||'F', mark:f[10], mark_value:markToValue(f[10],true,'M'), is_time:true,
        place:parseInt(f[13])||null, source:'hytek' });
    }
  }
  return {rows:out, skippedOtherTeams:skipped, unmatched:[...unmatched], header};
  function nk(l,f){ return (l+'|'+f).toLowerCase().replace(/[^a-z|]/g,''); }
  function divFromName(n){ n=(n||'').toLowerCase(); const d=(window.DIVISIONS||[]).find(d=>n.includes(d.name.toLowerCase())); return d?d.name:null; }
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
    let rs=g.rows.filter(r=>r.mark_value!=null).sort((a,b)=>g.is_time?a.mark_value-b.mark_value:b.mark_value-a.mark_value);
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
