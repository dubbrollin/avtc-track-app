// ---- Standard event list (edit this file to match what the league actually runs) ----
// divs: which divisions may enter. Codes are Hy-Tek Meet Manager event codes.
// SG=Sub-Gremlin(5-6) G=Gremlin(7-8) B=Bantam(9-10) J=Juniors(11-12) Y=Youth(13-14) I=Intermediates(15-18)
// Source of truth: Riley's actual Hy-Tek Team Manager Event List export (2026-09-23) — replaces the
// earlier placeholder list. That export doesn't carry TJ/PV/DT/HT, race walks, or 200H/400H, so those
// were dropped; divisions per event were corrected to match exactly what's in the real program
// (e.g. 1500m Run has no Sub-Gremlin, 4x400m Relay DOES include Gremlin, Shot/HJ/Javelin start at
// Bantam or Gremlin rather than Sub-Gremlin, and 100m Hurdles/110m Hurdles split by gender per the
// real hurdle-height rules).
window.DIV_KEY = {"Sub-Gremlin":"SG","Gremlin":"G","Bantam":"B","Juniors":"J","Youth":"Y","Intermediates":"I"};
window.STANDARD_EVENTS = [
  // code, name, divisions, relay?, gender restriction (null = both)
  {code:"100",  name:"100m Dash",          divs:"SG G B J Y I"},
  {code:"200",  name:"200m Dash",          divs:"SG G B J Y I"},
  {code:"400",  name:"400m Dash",          divs:"SG G B J Y I"},
  {code:"800",  name:"800m Run",           divs:"SG G B J Y I"},
  {code:"1500", name:"1500m Run",          divs:"G B J Y I"},
  {code:"3000", name:"3000m Run",          divs:"J Y I"},
  {code:"80H",  name:"80m Hurdles",        divs:"J"},          // 30" hurdles
  {code:"100H", name:"100m Hurdles",       divs:"Y I", gender:"Girl"}, // Youth 30", Intermediates 33"
  {code:"100H", name:"100m Hurdles",       divs:"Y",   gender:"Boy"},  // 36"
  {code:"110H", name:"110m Hurdles",       divs:"I",   gender:"Boy"},  // 39"
  {code:"400",  name:"4x100m Relay",       divs:"SG G B J Y I", relay:true},
  {code:"1600", name:"4x400m Relay",       divs:"G B J Y I",    relay:true},
  {code:"LJ",   name:"Long Jump",          divs:"SG G B J Y I", field:true},
  {code:"HJ",   name:"High Jump",          divs:"B J Y I",      field:true},
  {code:"SP",   name:"Shot Put",           divs:"B J Y I",      field:true}, // 6lb (B/J), 4kg or 10lb by gender for Y/I
  {code:"JT",   name:"Javelin Throw",      divs:"G B J Y I",    field:true}, // 300g (G/B), 450g (J), 600g (Y/I)
];
// Entry limits per division
window.ENTRY_RULES = {
  "Sub-Gremlin":  {max:3, relayRequiredFor4th:false},
  "Gremlin":      {max:3, relayRequiredFor4th:false},
  "Bantam":       {max:4, relayRequiredFor4th:true},
  "Juniors":      {max:4, relayRequiredFor4th:true},
  "Youth":        {max:4, relayRequiredFor4th:true},
  "Intermediates":{max:4, relayRequiredFor4th:false},
};
window.eventsFor = function(division, gender){
  const k = window.DIV_KEY[division];
  return window.STANDARD_EVENTS.filter(e => e.divs.split(" ").includes(k) && (!e.gender || e.gender===gender));
};
// Returns an error string if adding `newEv` to `current` (array of events) breaks the rules, else null.
window.checkLimits = function(division, current, newEv){
  const r = window.ENTRY_RULES[division]; if(!r) return "Unknown division";
  const all = newEv ? [...current, newEv] : current;
  if(all.length > r.max) return `Max ${r.max} events for ${division}`;
  if(r.relayRequiredFor4th && all.length===4 && !all.some(e=>e.relay)) return `${division} may only have 4 events if one is a relay`;
  return null;
};
