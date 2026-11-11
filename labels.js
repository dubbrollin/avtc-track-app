// Meet labels — the same label choices as Hy-Tek Meet Manager's Labels menu:
//   Award Labels (Standard, Mark Standard Achievement, Personal Best, By Heat, Exhibition, Participation, Record Breaker)
//   Competitor / Mailing / Registration Labels
// Pure functions (no page code) so they can be tested in Node:  require('./labels.js') with pdf-lib installed.
(function (root) {
  const LIB = typeof window !== "undefined" ? window.PDFLib : require("pdf-lib");
  const IN = 72, MM = 72 / 25.4;
  const LETTER = [8.5 * IN, 11 * IN], A4 = [210 * MM, 297 * MM];

  // Label stock — sizes match the Avery sheets Meet Manager prints on. "dot" = one label per page (tractor feed / label printer).
  const STOCKS = {
    '5160':  { name: '3 x 10 — Avery 5160 (1" x 2-5/8", 30 per page)', page: LETTER, cols: 3, rows: 10, w: 2.625 * IN, h: 1 * IN, left: 0.1875 * IN, top: 0.5 * IN, dx: 2.75 * IN, dy: 1 * IN },
    '5161':  { name: '2 x 10 — Avery 5161 (1" x 4", 20 per page)', page: LETTER, cols: 2, rows: 10, w: 4 * IN, h: 1 * IN, left: 0.15625 * IN, top: 0.5 * IN, dx: 4.1875 * IN, dy: 1 * IN },
    '5162':  { name: '1-1/3 x 4 — Avery 5162 (14 per page)', page: LETTER, cols: 2, rows: 7, w: 4 * IN, h: 1.3333 * IN, left: 0.15625 * IN, top: 0.8333 * IN, dx: 4.1875 * IN, dy: 1.3333 * IN },
    '5163':  { name: '2 x 4 — Avery 5163 (10 per page)', page: LETTER, cols: 2, rows: 5, w: 4 * IN, h: 2 * IN, left: 0.15625 * IN, top: 0.5 * IN, dx: 4.1875 * IN, dy: 2 * IN },
    '5164':  { name: '3-1/3 x 4 — Avery 5164 (6 per page)', page: LETTER, cols: 2, rows: 3, w: 4 * IN, h: 3.3333 * IN, left: 0.15625 * IN, top: 0.5 * IN, dx: 4.1875 * IN, dy: 3.3333 * IN },
    'A4UK':  { name: 'A4 - UK (2 x 8)', page: A4, cols: 2, rows: 8, w: 99.1 * MM, h: 33.9 * MM, left: 4.65 * MM, top: 12.9 * MM, dx: 101.6 * MM, dy: 33.9 * MM },
    'A4AUS': { name: 'A4 - AUS (3 x 11)', page: A4, cols: 3, rows: 11, w: 63.5 * MM, h: 25.4 * MM, left: 7.25 * MM, top: 8.8 * MM, dx: 66 * MM, dy: 25.4 * MM },
    'DOT14': { name: 'Dot-Matrix / label printer 1" x 4" (1 col)', dot: true, w: 4 * IN, h: 1 * IN },
    'DOT1516': { name: 'Dot-Matrix / label printer 1" x 3-1/2" (15/16", 1 col)', dot: true, w: 3.5 * IN, h: (15 / 16) * IN },
  };
  const AWARD_STOCKS = ['5160', '5161', 'A4UK', 'A4AUS', 'DOT14'];
  const COMP_STOCKS = ['5160', '5161', '5162', '5163', '5164', 'A4UK', 'A4AUS', 'DOT1516'];

  const DIV_AGES = { 'Sub-Gremlin': [5, 6], 'Gremlin': [7, 8], 'Bantam': [9, 10], 'Juniors': [11, 12], 'Youth': [13, 14], 'Intermediates': [15, 18] };
  const DIV_ORDER = ['Sub-Gremlin', 'Gremlin', 'Bantam', 'Juniors', 'Youth', 'Intermediates'];
  const ord = n => { const s = ['th', 'st', 'nd', 'rd'], v = n % 100; return n + (s[(v - 20) % 10] || s[v] || s[0]); };
  const gWord = g => g === 'Boy' ? 'Boys' : g === 'Girl' ? 'Girls' : 'Mixed';
  const better = (isTime, a, b) => isTime ? a < b : a > b;
  const atLeast = (isTime, a, b) => a === b || better(isTime, a, b);
  const nm = s => String(s || '').trim();
  const lastFirst = s => { const p = nm(s).split(/\s+/); return p.length > 1 ? p.slice(-1)[0] + ', ' + p.slice(0, -1).join(' ') : nm(s); };

  // ---------- Event numbers: one number per event (division + gender + event); rounds share it, like Meet Manager ----------
  function eventIndex(stdEvents) {
    const evs = stdEvents || [];
    return (code, isRelay, name) => { let i = evs.findIndex(e => e.code === code && !!e.relay === !!isRelay); if (i < 0) i = evs.findIndex(e => e.name === name); return i < 0 ? 999 : i; };
  }
  function numberEvents(keys, stdEvents) {
    // keys: [{code,is_relay,name,division,gender}] -> Map key->number
    const idx = eventIndex(stdEvents), seen = new Map();
    const list = [];
    keys.forEach(k => { const key = evKey(k); if (!seen.has(key)) { seen.set(key, 0); list.push(k); } });
    list.sort((a, b) => (idx(a.code, a.is_relay, a.name) - idx(b.code, b.is_relay, b.name)) || (DIV_ORDER.indexOf(a.division) - DIV_ORDER.indexOf(b.division)) || String(a.gender).localeCompare(String(b.gender)));
    list.forEach((k, i) => seen.set(evKey(k), i + 1));
    return seen;
  }
  const evKey = k => [k.division || '', k.gender || '', k.code || '', k.is_relay ? 1 : 0].join('|');
  const resEvKey = r => evKey({ division: r.division, gender: r.gender, code: r.event_code, is_relay: r.is_relay });
  const isFieldEv = (r, stdEvents) => { const e = (stdEvents || []).find(x => x.code === r.event_code && !!x.relay === !!r.is_relay); return e ? !!e.field : /^(HJ|PV|LJ|TJ|SP|DT|JT|HT|SB|TB|JAV|TURBO)/i.test(r.event_code || ''); };

  // The award event list (Meet Manager's EVENT LIST box): one row per event + round that has results.
  function awardEventList(results, stdEvents) {
    const nums = numberEvents(results.map(r => ({ code: r.event_code, is_relay: r.is_relay, name: r.event_name, division: r.division, gender: r.gender })), stdEvents);
    const map = new Map();
    results.forEach(r => {
      const rd = r.round || 'F', k = resEvKey(r) + '|' + rd;
      let e = map.get(k);
      if (!e) { e = { key: k, evKey: resEvKey(r), num: nums.get(resEvKey(r)), round: rd, name: `${gWord(r.gender)} ${r.division || ''} ${r.event_name}`.replace(/\s+/g, ' '), division: r.division, gender: r.gender, is_relay: !!r.is_relay, field: isFieldEv(r, stdEvents), heats: new Set(), count: 0, teams: new Set() }; map.set(k, e); }
      e.count++; if (r.heat) e.heats.add(r.heat); if (r.team_code) e.teams.add(r.team_code);
    });
    const rounds = {}; [...map.values()].forEach(e => { (rounds[e.evKey] ??= []).push(e.round); });
    return [...map.values()].map(e => ({ ...e, heats: e.heats.size || 1, teams: [...e.teams], firstRound: rounds[e.evKey].includes('P') ? 'P' : rounds[e.evKey][0] }))
      .sort((a, b) => (a.num - b.num) || ((a.round === 'P' ? 0 : 1) - (b.round === 'P' ? 0 : 1)));
  }

  // Filters from the top of Meet Manager's Award Labels window.
  function filterEvents(list, f) {
    return list.filter(e => {
      if (f.gender === 'Boy' && e.gender !== 'Boy') return false;
      if (f.gender === 'Girl' && e.gender !== 'Girl') return false;
      if (f.gender === 'Mixed' && e.gender !== 'Mixed') return false;
      if (f.ageLo || f.ageHi) { const a = DIV_AGES[e.division]; if (!a) return false; if (f.ageLo && a[1] < +f.ageLo) return false; if (f.ageHi && a[0] > +f.ageHi) return false; }
      if (f.team && f.team !== 'ALL' && !e.teams.includes(f.team)) return false;
      if (f.rounds === 'F' && e.round !== 'F') return false;
      if (f.rounds === 'P' && e.round !== 'P') return false;
      if (f.rounds === '1' && e.round !== e.firstRound) return false;
      if (f.kind === 'indiv' && e.is_relay) return false;
      if (f.kind === 'relay' && !e.is_relay) return false;
      return true;
    });
  }

  // ---------- Award labels ----------
  // ctx: {meet, results, entries:[{registration_id, code, is_relay, division, gender, seed_mark}], regs:{id->{comp_number}}, stds, recs, leagueRecs:{East:[],West:[]}, stdEvents, markToValue}
  // o: {team, events:Set(keys), type, indFrom, indTo, relFrom, relTo, useNT, excludePlaces, relayNames, sort}
  function buildAwardLabels(ctx, o) {
    const evs = new Map(awardEventList(ctx.results, ctx.stdEvents).map(e => [e.key, e]));
    const mtv = ctx.markToValue || ((m) => parseFloat(m));
    const seedFor = r => {
      if (!r.registration_id) return null;
      const e = (ctx.entries || []).find(x => x.registration_id === r.registration_id && x.code === r.event_code && !!x.is_relay === !!r.is_relay);
      if (!e || !nm(e.seed_mark) || /^(NT|NM|ND)$/i.test(nm(e.seed_mark))) return null;
      const v = mtv(e.seed_mark, r.is_time, /[-']/.test(e.seed_mark) ? 'E' : 'M');
      return v == null || isNaN(v) ? null : { mark: e.seed_mark, v };
    };
    const ageOf = r => DIV_AGES[r.division];
    const stdFor = r => { const a = ageOf(r); if (!a || r.is_relay) return null; const [lo, hi] = r.division === 'Intermediates' ? [0, 99] : a;
      return (ctx.stds || []).find(s => s.gender === r.gender && s.event_code === r.event_code && !s.is_relay && s.age_low === lo && s.age_high === hi) || null; };
    const recsFor = r => { const a = ageOf(r); if (!a) return [];
      const m = x => x.gender === r.gender && x.event_code === r.event_code && !!x.is_relay === !!r.is_relay && x.age_low === a[0] && x.age_high === a[1];
      const out = []; const c = (ctx.recs || []).find(m); if (c) out.push({ book: 'Conference', rec: c });
      [['East', 'Eastern League'], ['West', 'Western League']].forEach(([k, b]) => { const x = ((ctx.leagueRecs || {})[k] || []).find(m); if (x) out.push({ book: b, rec: x }); });
      return out; };
    const ovPlace = r => r.overall_place || r.place || null;
    const inRange = (p, r) => p > 0 && (r.is_relay ? p >= +o.relFrom && p <= +o.relTo : p >= +o.indFrom && p <= +o.indTo);

    const picked = [];
    ctx.results.forEach(r => {
      const ev = evs.get(resEvKey(r) + '|' + (r.round || 'F'));
      if (!ev || !o.events.has(ev.key)) return;
      if (o.team && o.team !== 'ALL' && r.team_code !== o.team) return;
      const ok = r.mark_value != null;
      let head = null;
      switch (o.type) {
        case 'standard': { const p = ovPlace(r); if (!inRange(p, r)) return; head = ord(p) + ' Place'; break; }
        case 'heat': { const p = r.place; if (!inRange(p, r)) return; head = (r.heat ? 'Heat ' + r.heat + ' — ' : '') + ord(p) + ' Place'; break; }
        case 'pb': { if (r.is_relay || !ok) return; const s = seedFor(r); if (s ? !better(r.is_time, r.mark_value, s.v) : !o.useNT) return; head = 'Personal Best'; break; }
        case 'std': { if (r.is_relay || !ok) return; const st = stdFor(r); if (!st || !atLeast(r.is_time, r.mark_value, st.mark_value)) return;
          const s = seedFor(r); if (s ? atLeast(r.is_time, s.v, st.mark_value) : !o.useNT) return; head = 'Qualifying Standard'; break; }
        case 'exh': { if (ovPlace(r) > 0 || !ok) return; head = 'Exhibition'; break; }
        case 'part': { if (o.excludePlaces && inRange(ovPlace(r), r)) return; head = 'Participant'; break; }
        // Records can only be broken at championship meets (same rule as the Results page).
        case 'record': { if (!ok || !(ctx.meet && ctx.meet.is_championship)) return; const hit = recsFor(r).filter(x => x.rec.mark_value != null && better(r.is_time, r.mark_value, x.rec.mark_value)); if (!hit.length) return; head = 'New ' + hit.map(x => x.book).join(' / ') + ' Record'; break; }
        default: return;
      }
      picked.push({ r, ev, head });
    });

    const labels = [];
    picked.forEach(({ r, ev, head }) => {
      const base = { ev, r, head, team: r.team_code || '', comp: (ctx.regs && r.registration_id && ctx.regs[r.registration_id] && ctx.regs[r.registration_id].comp_number) || null };
      if (r.is_relay && +o.relayNames > 0) {
        const runners = nm(r.relay_runners).split(/\s*[,;]\s*/).filter(Boolean).slice(0, +o.relayNames);
        if (runners.length) { runners.forEach(n => labels.push({ ...base, who: n, sub: r.athlete_name })); return; }
      }
      labels.push({ ...base, who: r.athlete_name, sub: '' });
    });
    const byEv = (a, b) => (a.ev.num - b.ev.num) || ((a.ev.round === 'P' ? 0 : 1) - (b.ev.round === 'P' ? 0 : 1)) || ((ovPlace(a.r) || 999) - (ovPlace(b.r) || 999)) || a.who.localeCompare(b.who);
    const cmp = {
      event: byEv,
      session: (a, b) => ((a.ev.field ? 0 : 1) - (b.ev.field ? 0 : 1)) || byEv(a, b),
      teamevent: (a, b) => a.team.localeCompare(b.team) || byEv(a, b),
      teamathlete: (a, b) => a.team.localeCompare(b.team) || lastFirst(a.who).localeCompare(lastFirst(b.who)) || byEv(a, b),
      athlete: (a, b) => lastFirst(a.who).localeCompare(lastFirst(b.who)) || byEv(a, b),
      comp: (a, b) => ((a.comp || 1e9) - (b.comp || 1e9)) || lastFirst(a.who).localeCompare(lastFirst(b.who)) || byEv(a, b),
    }[o.sort || 'event'] || byEv;
    labels.sort(cmp);
    const meetName = (ctx.meet && ctx.meet.name) || '';
    const date = ctx.meet && ctx.meet.meet_date ? (([y, m, d]) => `${+m}/${+d}/${y}`)(ctx.meet.meet_date.split('-')) : '';
    return labels.map(L => ({
      lines: [
        { text: meetName, right: date, size: 7 },
        { text: L.ev.name + (L.ev.round === 'P' ? ' (Prelims)' : ''), size: 8 },
        { text: L.head, right: L.r.mark + (L.r.wind ? ' (' + L.r.wind + ')' : ''), size: 10, bold: true },
        { text: L.who + (L.sub ? ' — ' + L.sub : ''), right: L.team, size: 9, bold: true },
      ], _evKey: L.ev.key,
    }));
  }

  // ---------- Competitor / Mailing / Registration labels ----------
  // ctx: {meet, athletes:[{id, first_name,last_name, gender, division, age, team_code, comp_number, address, city, zip, parent_name, entries:[{num, name, heat}]}],
  //       relays:[{team_code, num, name, runners:[...], declared}], teams:[{code,name,conference, coaches:[]}]}
  // o: {kind:'comp'|'mail'|'reg', gender, team, division, ageLo, ageHi, noComp, copies, compFrom, compTo, mail:'team'|'athlete', noAddr,
  //     reg:'athlete'|'relay'|'team', undeclared, alternates, noEntries, coaches, evNum, heatLane, sort1, sort2, stock}
  function buildCompLabels(ctx, o) {
    const st = STOCKS[o.stock] || STOCKS['5160'];
    const teamName = c => ((ctx.teams || []).find(t => t.code === c) || {}).name || c || '';
    const conf = c => ((ctx.teams || []).find(t => t.code === c) || {}).conference || '';
    const fullName = a => nm(a.first_name) + ' ' + nm(a.last_name);
    let A = (ctx.athletes || []).filter(a => {
      if (o.gender === 'Boy' && a.gender !== 'Boy') return false;
      if (o.gender === 'Girl' && a.gender !== 'Girl') return false;
      if (o.team && o.team !== 'ALL' && a.team_code !== o.team) return false;
      if (o.division && a.division !== o.division) return false;
      if (o.ageLo && a.age != null && a.age < +o.ageLo) return false;
      if (o.ageHi && a.age != null && a.age > +o.ageHi) return false;
      return true;
    });
    const s1 = {
      team: (a, b) => String(a.team_code).localeCompare(String(b.team_code)),
      athlete: () => 0,
      comp: (a, b) => (a.comp_number || 1e9) - (b.comp_number || 1e9),
      region: (a, b) => conf(a.team_code).localeCompare(conf(b.team_code)) || String(a.team_code).localeCompare(String(b.team_code)),
    }[o.sort1 || 'team'];
    const s2 = {
      alpha: (a, b) => (nm(a.last_name) + ' ' + nm(a.first_name)).localeCompare(nm(b.last_name) + ' ' + nm(b.first_name)),
      comp: (a, b) => (a.comp_number || 1e9) - (b.comp_number || 1e9),
      zip: (a, b) => String(a.zip || '~').localeCompare(String(b.zip || '~')),
    }[o.sort2 || 'alpha'];
    A.sort((a, b) => s1(a, b) || s2(a, b) || (nm(a.last_name) + nm(a.first_name)).localeCompare(nm(b.last_name) + nm(b.first_name)));
    const out = [];
    if (o.kind === 'comp') {
      A.filter(a => a.comp_number ? (a.comp_number >= (+o.compFrom || 0) && a.comp_number <= (+o.compTo || 1e9)) : !!o.noComp).forEach(a => {
        const L = { lines: [
          { text: a.comp_number ? '#' + a.comp_number : '#____', right: a.team_code, size: 16, bold: true },
          { text: fullName(a), size: 11, bold: true },
          { text: teamName(a.team_code), right: [a.division, a.age != null ? 'Age ' + a.age : ''].filter(Boolean).join(' · '), size: 7 },
        ] };
        for (let i = 0; i < Math.max(1, Math.min(99, +o.copies || 1)); i++) out.push(L);
      });
    } else if (o.kind === 'mail') {
      if (o.mail === 'team') {
        const codes = [...new Set(A.map(a => a.team_code))].sort();
        (o.team && o.team !== 'ALL' && !codes.includes(o.team) ? [o.team] : codes).forEach(c => {
          const t = (ctx.teams || []).find(x => x.code === c) || { code: c, name: c };
          if (!t.address && !o.noAddr) return;
          out.push({ lines: [{ text: t.name, size: 10, bold: true }, { text: t.coaches && t.coaches.length ? 'Attn: ' + t.coaches[0] : 'Attn: Head Coach', size: 9 }, { text: t.address || '', size: 9 }, { text: t.cityzip || '', size: 9 }] });
        });
      } else {
        A.forEach(a => {
          if (!nm(a.address) && !o.noAddr) return;
          out.push({ lines: [
            { text: (a.parent_name ? 'Parent/Guardian of ' : '') + fullName(a), right: a.team_code, size: 9, bold: true },
            ...(a.parent_name ? [{ text: nm(a.parent_name), size: 9 }] : []),
            { text: nm(a.address), size: 9 },
            { text: [nm(a.city), 'CA', nm(a.zip)].filter(Boolean).join(nm(a.city) ? ', ' : ' ').replace(', CA, ', ', CA '), size: 9 },
          ] });
        });
      }
    } else if (o.kind === 'reg') {
      // How many events fit, same as Meet Manager: 1-1/3" label = 4 events, 2" = 7, 3-1/3" = 16 (1" labels = 2).
      const maxLines = st.h < 1.1 * IN ? 2 : st.h < 1.5 * IN ? 4 : st.h < 2.5 * IN ? 7 : 16;
      if (o.reg === 'athlete') {
        A.forEach(a => {
          const ents = (a.entries || []).slice().sort((x, y) => (x.num || 999) - (y.num || 999));
          if (!ents.length && !o.noEntries) return;
          const evLines = ents.map(e => ({ text: (o.evNum && e.num ? 'Ev ' + e.num + '  ' : '') + e.name, right: o.heatLane && (e.heat || e.lane) ? [e.heat ? 'H' + e.heat : '', e.lane ? 'L' + e.lane : ''].filter(Boolean).join(' ') : '', size: 9 }));
          const room = maxLines;
          const shown = evLines.length > room ? evLines.slice(0, room - 1).concat([{ text: '+ ' + (evLines.length - room + 1) + ' more event' + (evLines.length - room + 1 > 1 ? 's' : ''), size: 9 }]) : evLines;
          out.push({ top: true, lines: [
            { text: (a.comp_number ? '#' + a.comp_number + '  ' : '') + fullName(a), right: a.team_code, size: 10, bold: true },
            { text: teamName(a.team_code), right: [a.division, a.age != null ? 'Age ' + a.age : ''].filter(Boolean).join(' · '), size: 7 },
            ...(shown.length ? shown : [{ text: 'No entries', size: 9 }]),
          ] });
        });
      } else if (o.reg === 'relay') {
        (ctx.relays || []).filter(r => (!o.team || o.team === 'ALL' || r.team_code === o.team) && (o.gender === 'Boy' ? r.gender === 'Boy' : o.gender === 'Girl' ? r.gender === 'Girl' : true) && (!o.division || r.division === o.division))
          .filter(r => r.runners.length || o.undeclared)
          .sort((a, b) => String(a.team_code).localeCompare(String(b.team_code)) || (a.num || 999) - (b.num || 999))
          .forEach(r => {
            const legs = r.runners.slice(0, 4), alts = r.runners.slice(4);
            const names = legs.map((n, i) => ({ text: (i + 1) + ') ' + n, size: 9 })).concat(o.alternates ? alts.map(n => ({ text: 'Alt) ' + n, size: 9 })) : []);
            out.push({ top: true, lines: [
              { text: teamName(r.team_code) + (r.letter ? ' ' + r.letter : ''), right: r.team_code, size: 10, bold: true },
              { text: (o.evNum && r.num ? 'Ev ' + r.num + '  ' : '') + r.name, right: o.heatLane && r.heat ? 'H' + r.heat : '', size: 8 },
              ...(names.length ? names.slice(0, maxLines) : [{ text: 'Runners not declared', size: 9 }]),
            ] });
          });
      } else {
        const codes = [...new Set(A.map(a => a.team_code))].sort();
        codes.forEach(c => {
          const mine = A.filter(a => a.team_code === c);
          const nEnt = mine.reduce((s, a) => s + (a.entries || []).length, 0);
          out.push({ top: true, lines: [
            { text: teamName(c), right: c, size: 11, bold: true },
            { text: (ctx.meet && ctx.meet.name) || '', size: 8 },
            { text: mine.length + ' athlete' + (mine.length === 1 ? '' : 's') + ' · ' + nEnt + ' entr' + (nEnt === 1 ? 'y' : 'ies'), size: 8 },
          ] });
        });
      }
      if (o.coaches) {
        const codes = [...new Set(A.map(a => a.team_code))].sort();
        codes.forEach(c => {
          const t = (ctx.teams || []).find(x => x.code === c) || {};
          out.push({ top: true, lines: [{ text: 'COACHES', right: c, size: 11, bold: true }, { text: teamName(c), size: 9, bold: true }, { text: (ctx.meet && ctx.meet.name) || '', size: 8 }, ...((t.coaches || []).slice(0, maxLines - 1).map(n => ({ text: n, size: 9 })))] });
        });
      }
    }
    return out;
  }

  // ---------- Entry Cards / Tag Labels (before the meet: one per entry, from the app's meet entries) ----------
  // Event list for entry cards = the meet's events (meet_events), numbered like the award list.
  function entryEventList(meetEvents, entryRows, regs, stdEvents) {
    const nums = numberEvents(meetEvents.map(e => ({ code: e.code, is_relay: e.is_relay, name: e.name, division: e.division, gender: e.gender })), stdEvents);
    return meetEvents.map(e => {
      const k = evKey({ code: e.code, is_relay: e.is_relay, division: e.division, gender: e.gender });
      const ents = entryRows.filter(x => x.key === k);
      return { key: k, evKey: k, num: nums.get(k), round: 'F', firstRound: 'F', name: `${gWord(e.gender)} ${e.division} ${e.name}`, short: e.name, division: e.division, gender: e.gender, is_relay: !!e.is_relay,
        field: e.is_field != null ? !!e.is_field : isFieldEv({ event_code: e.code, is_relay: e.is_relay }, stdEvents), count: ents.length, heats: 0,
        teams: [...new Set(ents.map(x => (regs[x.registration_id] || {}).team_code).filter(Boolean))] };
    }).sort((a, b) => a.num - b.num);
  }
  // ctx: {meet, events (entryEventList), entries:[{registration_id, key, seed_mark}], regs, results, markToValue}
  // o: {team, events:Set, format:'heatlane'|'fast'|'slow'|'session', sort:'event'|'session'|'lane'|'team', blanks, relayNames}
  function buildEntryCards(ctx, o) {
    const mtv = ctx.markToValue || (m => parseFloat(m));
    const evs = new Map((ctx.events || []).map(e => [e.key, e]));
    const date = ctx.meet && ctx.meet.meet_date ? (([y, m, d]) => `${+m}/${+d}/${y}`)(ctx.meet.meet_date.split('-')) : '';
    const fieldMark = s => /[-']/.test(s || '');
    const heatOf = (regId, ev) => { const rs = (ctx.results || []).filter(r => r.registration_id === regId && resEvKey(r) === ev.key); const p = rs.find(r => r.round === 'P') || rs[0]; return p ? p.heat : null; };
    const cards = [];
    (ctx.events || []).filter(e => o.events.has(e.key)).forEach(ev => {
      let rows = (ctx.entries || []).filter(x => x.key === ev.key).map(x => ({ ...x, reg: ctx.regs[x.registration_id] })).filter(x => x.reg && (!o.team || o.team === 'ALL' || x.reg.team_code === o.team));
      // seed value: field events higher = better, running lower = better
      rows.forEach(x => { const s = String(x.seed_mark || '').trim(); const v = s && !/^(NT|NM|ND)$/i.test(s) ? mtv(s, !ev.field, fieldMark(s) ? 'E' : 'M') : null; x.v = v == null || isNaN(v) ? null : v; });
      const rank = rows.filter(x => x.v != null).sort((a, b) => ev.field ? b.v - a.v : a.v - b.v);
      rows.forEach(x => { x.rank = x.v == null ? null : rank.indexOf(x) + 1; x.heat = heatOf(x.registration_id, ev); });
      const total = rows.length;
      if (ev.is_relay) {
        // one card per team relay; runners = the team's athletes entered in the relay (first 4 = legs, rest alternates)
        const byTeam = {}; rows.forEach(x => (byTeam[x.reg.team_code] ??= []).push(x));
        Object.entries(byTeam).forEach(([team, xs]) => {
          const names = xs.map(x => nm(x.reg.first_name) + ' ' + nm(x.reg.last_name)).slice(0, Math.max(0, +o.relayNames || 0));
          cards.push({ ev, team, rank: null, heat: xs[0].heat, who: team + ' relay', lines: [
            { text: 'Ev ' + ev.num + '  ' + ev.name, right: date, size: 10, bold: true },
            { text: 'Heat ____  Lane ____', right: 'Team: ' + team, size: 9 },
            ...(names.length ? names.map((n, i) => ({ text: (i < 4 ? (i + 1) + ') ' : 'Alt) ') + n, size: 9 })) : [1, 2, 3, 4].map(i => ({ text: i + ') ______________________', size: 9 }))),
            { text: 'Time: ____________', right: (ctx.meet && ctx.meet.name) || '', size: 8 },
          ] });
        });
        return;
      }
      rows.forEach(x => {
        const r = x.reg, useHeat = o.format === 'heatlane' || (o.format === 'session' && !ev.field);
        const second = useHeat ? (x.heat ? 'Heat ' + x.heat + '   Lane ____' : 'Heat ____   Lane ____') : (x.rank ? 'Rank ' + x.rank + ' of ' + total : 'Rank — (no seed)');
        cards.push({ ev, team: r.team_code, rank: x.rank, v: x.v, heat: x.heat, who: nm(r.last_name) + ', ' + nm(r.first_name), lines: [
          { text: 'Ev ' + ev.num + '  ' + ev.name, right: date, size: 10, bold: true },
          { text: second, right: r.comp_number ? '#' + r.comp_number : '', size: 9 },
          { text: nm(r.first_name) + ' ' + nm(r.last_name), right: r.team_code, size: 12, bold: true },
          { text: 'Seed: ' + (nm(x.seed_mark) || 'NT'), right: (ev.field ? 'Mark' : 'Time') + ': ____________', size: 9 },
        ] });
      });
    });
    const slowFast = o.format === 'slow';
    const rankCmp = (a, b) => ((a.rank || 1e6) - (b.rank || 1e6)) * (slowFast ? -1 : 1) || a.who.localeCompare(b.who);
    const byEv = (a, b) => (a.ev.num - b.ev.num) || ((a.heat || 999) - (b.heat || 999)) || rankCmp(a, b);
    const cmp = { event: byEv, session: (a, b) => ((a.ev.field ? 0 : 1) - (b.ev.field ? 0 : 1)) || byEv(a, b),
      lane: (a, b) => ((a.heat || 999) - (b.heat || 999)) || byEv(a, b), team: (a, b) => String(a.team).localeCompare(String(b.team)) || byEv(a, b) }[o.sort || 'event'] || byEv;
    cards.sort(cmp);
    for (let i = 0; i < (+o.blanks || 0); i++) cards.push({ lines: [
      { text: 'Ev ____  Event ______________________', right: date, size: 10, bold: true },
      { text: 'Heat ____   Lane ____', right: '#______', size: 9 },
      { text: 'Name ______________________', right: 'Team ______', size: 12, bold: true },
      { text: 'Seed: ________', right: 'Mark/Time: ____________', size: 9 },
    ] });
    return cards.map(c => ({ lines: c.lines, top: true, grow: 3 }));
  }

  // ---------- Bar Code Competitor Labels (Code 39, the "3 of 9" format Meet Manager prints) ----------
  // ctx: {athletes (same shape as competitor labels, plus birth_year and entries[].key), teams}
  // o: {source:'event'|'roster'|'teamcomp'|'noname', events:Set, gender, sort:'comp'|'name'|'team', digits:5|6, from, to, birthYear, team, test}
  function buildBarcodes(ctx, o) {
    const digits = +o.digits === 6 ? 6 : 5, pad = n => String(n).padStart(digits, '0');
    const teamName = c => ((ctx.teams || []).find(t => t.code === c) || {}).name || c || '';
    const lab = (num, name, team, yr) => ({ lines: [
      { barcode: pad(num), size: 0.42 * IN },
      { text: pad(num), right: team || '', size: 8, bold: true },
      { text: name || 'Name ____________________', right: yr ? 'Born ' + yr : '', size: 8 },
    ] });
    if (o.test) return Array.from({ length: 6 }, (_, i) => lab(i + 1, 'TEST LABEL — check the scanner reads it', 'TEST'));
    const from = +o.from || 0, to = o.to === '' || o.to == null ? 1e9 : +o.to;
    if (o.source === 'noname') { const out = []; for (let n = Math.max(0, from); n <= Math.min(to, from + 5000); n++) out.push(lab(n, '', '')); return out; }
    let A = (ctx.athletes || []).filter(a => a.comp_number && a.comp_number >= from && a.comp_number <= to)
      .filter(a => !o.gender || o.gender === 'Mixed' || a.gender === o.gender)
      .filter(a => !o.team || o.team === 'ALL' || a.team_code === o.team);
    if (o.source === 'event') A = A.filter(a => (a.entries || []).some(e => o.events.has(e.key)));
    const byName = (a, b) => (nm(a.last_name) + ' ' + nm(a.first_name)).localeCompare(nm(b.last_name) + ' ' + nm(b.first_name));
    const sort = o.source === 'teamcomp' ? 'team' : o.sort;
    A.sort(sort === 'name' ? byName : sort === 'team' ? (a, b) => String(a.team_code).localeCompare(String(b.team_code)) || a.comp_number - b.comp_number : (a, b) => a.comp_number - b.comp_number);
    return A.map(a => lab(a.comp_number, nm(a.first_name) + ' ' + nm(a.last_name), a.team_code, o.birthYear ? a.birth_year : ''));
  }
  // Code 39 patterns (n = narrow, w = wide), bar/space alternating, starting with a bar.
  const C39 = { '0': 'nnnwwnwnn', '1': 'wnnwnnnnw', '2': 'nnwwnnnnw', '3': 'wnwwnnnnn', '4': 'nnnwwnnnw', '5': 'wnnwwnnnn', '6': 'nnwwwnnnn', '7': 'nnnwnnwnw', '8': 'wnnwnnwnn', '9': 'nnwwnnwnn', '*': 'nwnnwnwnn' };
  function drawCode39(page, value, x, y, w, h) {
    const s = '*' + String(value).replace(/[^0-9]/g, '') + '*', R = 2.5;
    const units = s.length * (6 + 3 * R + 1) - 1 + 20;           // + 10 narrow quiet zone each side
    const n = Math.min(w / units, 2.2); let cx = x + (w - n * units) / 2 + 10 * n;
    for (const ch of s) { const p = C39[ch]; for (let i = 0; i < 9; i++) { const bw = (p[i] === 'w' ? R : 1) * n; if (i % 2 === 0) page.drawRectangle({ x: cx, y, width: bw, height: h, color: LIB.rgb(0, 0, 0) }); cx += bw; } cx += n; }
  }

  const CARD_STOCKS = {
    'CARD3': { name: 'Cards 3-1/2" x 8-1/2" (3 per page)', page: LETTER, cols: 1, rows: 3, w: 8.5 * IN, h: 3.5 * IN, left: 0, top: 0.25 * IN, dx: 0, dy: 3.5 * IN },
    'CARD6': { name: '6 per sheet (2 across, 3 down)', page: LETTER, cols: 2, rows: 3, w: 4 * IN, h: 3.3333 * IN, left: 0.25 * IN, top: 0.5 * IN, dx: 4 * IN, dy: 3.3333 * IN },
    'L7421': { name: 'A4 postcards — Avery L7421 (4 per page, landscape)', page: [A4[1], A4[0]], cols: 2, rows: 2, w: 139.7 * MM, h: 96.5 * MM, left: 8.8 * MM, top: 8.5 * MM, dx: 139.7 * MM, dy: 96.5 * MM },
  };
  Object.assign(STOCKS, CARD_STOCKS);
  const ENTRY_STOCKS = ['CARD3', 'CARD6', 'L7421', '5160', '5161', 'A4UK', 'A4AUS', 'DOT14'];
  const BAR_STOCKS = ['5160', '5161', 'A4UK', 'A4AUS', 'DOT14'];

  // ---------- PDF ----------
  // Only characters the built-in PDF fonts know (Latin-1); accents kept, anything else becomes its plain letter or "?".
  const clean = s => Array.from(String(s ?? '')).map(c => { const k = c.charCodeAt(0); if (k >= 32 && k <= 126 || k >= 160 && k <= 255) return c;
    const map = { '‘': "'", '’': "'", '“': '"', '”': '"', '–': '-', '—': '-', '…': '...', '·': '·' }; if (map[c]) return map[c];
    const b = c.normalize('NFD')[0]; return b && b.charCodeAt(0) < 256 ? b : '?'; }).join('');

  async function renderPdf(labels, stockKey, opts) {
    opts = opts || {};
    const st = STOCKS[stockKey] || STOCKS['5160'];
    const doc = await LIB.PDFDocument.create();
    const F = await doc.embedFont(LIB.StandardFonts.Helvetica), B = await doc.embedFont(LIB.StandardFonts.HelveticaBold);
    const per = st.dot ? 1 : st.cols * st.rows, skip = st.dot ? 0 : Math.max(0, Math.min(per - 1, +opts.skip || 0));
    let page = null;
    const padX = 0.09 * IN, padY = 0.07 * IN;
    labels.forEach((L, n) => {
      const slot = n + skip, i = slot % per;
      if (i === 0 || !page) page = st.dot ? doc.addPage([st.w, st.h]) : doc.addPage(st.page);
      const col = st.dot ? 0 : i % st.cols, row = st.dot ? 0 : Math.floor(i / st.cols);
      const x = st.dot ? 0 : st.left + col * st.dx, yTop = st.dot ? st.h : page.getHeight() - st.top - row * st.dy;
      const w = st.w - 2 * padX, h = st.h - 2 * padY;
      const lines = L.lines.filter(l => l.text || l.right || l.barcode);
      const need = lines.reduce((s, l) => s + (l.barcode ? l.size + 3 : l.size * 1.18), 0);
      const k = Math.min(L.grow || 1, h / need);
      let y = yTop - padY - (L.top ? 0 : Math.max(0, (h - need * k) / 2));
      lines.forEach(l => {
        if (l.barcode) { const bh = l.size * k; y -= bh + 3 * k; drawCode39(page, l.barcode, x + padX, y + 2 * k, w, bh); return; }
        const font = l.bold ? B : F; let size = l.size * k;
        const t = clean(l.text), r = clean(l.right || '');
        const fit = () => font.widthOfTextAtSize(t, size) + (r ? F.widthOfTextAtSize(r, size) + 6 : 0);
        while (size > 4 && fit() > w) size -= 0.25;
        y -= size * 1.18;
        const wr = r ? F.widthOfTextAtSize(r, size) + 6 : 0; let tt = t;
        if (font.widthOfTextAtSize(tt, size) + wr > w) { while (tt.length > 1 && font.widthOfTextAtSize(tt + '.', size) + wr > w) tt = tt.slice(0, -1); tt += '.'; }
        page.drawText(tt, { x: x + padX, y: y + size * 0.22, size, font });
        if (r) page.drawText(r, { x: x + padX + w - F.widthOfTextAtSize(r, size), y: y + size * 0.22, size, font: F });
      });
      if (opts.outline) page.drawRectangle({ x, y: yTop - st.h, width: st.w, height: st.h, borderWidth: 0.3, borderColor: LIB.rgb(0.8, 0.8, 0.8) });
    });
    if (!labels.length) doc.addPage(st.dot ? [st.w, st.h] : st.page);
    return doc.save();
  }

  const api = { STOCKS, AWARD_STOCKS, COMP_STOCKS, ENTRY_STOCKS, BAR_STOCKS, DIV_AGES, DIV_ORDER, awardEventList, entryEventList, filterEvents, buildAwardLabels, buildCompLabels, buildEntryCards, buildBarcodes, renderPdf, numberEvents, evKey, ord, clean };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.MeetLabels = api;
})(typeof window !== 'undefined' ? window : globalThis);
