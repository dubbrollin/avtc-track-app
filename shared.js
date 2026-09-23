// Shared helpers used by both pages
// The 16 real Valley Youth Conference (VYC) member teams, with their Hy-Tek team codes.
// Pulled from the league's own roster (tcl01-01.tcl) and results (reslt002.csv) exports.
window.VYC_TEAMS = [
  {code:"AVTC", name:"Antelope Valley Track Club"},
  {code:"BV",   name:"Burbank Vikings"},
  {code:"CAL",  name:"Calabasas"},
  {code:"WVE",  name:"Eagles (WVE)"},
  {code:"FP",   name:"Flying Phoenix"},
  {code:"LRR",  name:"Lancaster Runnin Rebels"},
  {code:"L5",   name:"Lane 5"},
  {code:"LAF",  name:"Los Angeles Falcons"},
  {code:"NPTC", name:"Northridge Pacers"},
  {code:"PB",   name:"Palmdale Bullets"},
  {code:"SFR",  name:"Rush"},
  {code:"SCTC", name:"Storm"},
  {code:"TT",   name:"Thimsha"},
  {code:"VRTC", name:"Valley Raiders"},
  {code:"VC",   name:"Village Christian Schools"},
  {code:"SCW",  name:"Warriors"}
];
// Backward-compatible plain-name list, kept in case anything still expects window.TEAMS.
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
