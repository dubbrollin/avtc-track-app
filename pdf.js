// Builds the two Valley Youth Conference forms as filled, signed PDFs using pdf-lib.
// Works in the browser (window.PDFLib) and in Node (require('pdf-lib')) for testing.
(function (root) {
  const LIB = typeof window !== "undefined" ? window.PDFLib : require("pdf-lib");
  const { PDFDocument, StandardFonts, rgb } = LIB;
  const fmt = (iso) => { if (!iso) return ""; const [y, m, d] = String(iso).slice(0, 10).split("-"); return `${m}/${d}/${y}`; };
  const today = () => { const d = new Date(); return `${String(d.getMonth() + 1).padStart(2, "0")}/${String(d.getDate()).padStart(2, "0")}/${d.getFullYear()}`; };

  // Simple word-wrap helper

  // The official Valley Youth Conference Player Contract (VYC Form 001, from valleyconference.org/forms/PLAYER_CONTRACT.pdf),
  // kept next to the app as forms/PLAYER_CONTRACT.pdf. We fill its own form fields and place the signatures on its signature lines.
  const templates = {};
  async function formTemplate(file) {
    if (templates[file]) return templates[file];
    if (typeof window !== "undefined") {
      const res = await fetch("forms/" + file); if (!res.ok) throw new Error("Could not load the form " + file + " (" + res.status + ")");
      templates[file] = new Uint8Array(await res.arrayBuffer());
    } else templates[file] = require("fs").readFileSync(require("path").join(__dirname, "forms", file));
    return templates[file];
  }

  // clubName = the athlete's own team (Conference Member Organization)
  async function build(reg, clubName) {
    const doc = await PDFDocument.load(await formTemplate("PLAYER_CONTRACT.pdf"));
    const F = await doc.embedFont(StandardFonts.Helvetica);
    const B = await doc.embedFont(StandardFonts.HelveticaBold);
    const aSig = await doc.embedPng(reg.athlete_signature);
    const pSig = await doc.embedPng(reg.parent_signature);
    const athlete = `${reg.first_name} ${reg.last_name}`;
    const signed = fmt(reg.created_at) || today();
    const parentName = reg.parent1_name || reg.parent_name || "";

    // ================= PAGE 1: OFFICIAL PLAYER CONTRACT =================
    const form = doc.getForm();
    const FP = "topmostSubform[0].Page1[0]."; // the form's fields all sit under this prefix
    const setText = (name, v) => { try { const f = form.getTextField(FP + name); f.setFontSize(0); f.setText(String(v ?? "")); } catch (e) {} };
    const setCheck = (name, on) => { try { const f = form.getCheckBox(FP + name); on ? f.check() : f.uncheck(); } catch (e) {} };
    setCheck("track[0]", (reg.sport || "Track & Field") === "Track & Field");
    setCheck("cross_country[0]", reg.sport === "Cross Country");
    setCheck("boy[0]", reg.gender === "Boy"); setCheck("girl[0]", reg.gender === "Girl");
    setText("Age[0]", reg.age_on_dec31);
    let divDrawn = false;
    try { const d = form.getDropdown(FP + "Divisions[0]"); if (reg.division) { if (!d.getOptions().includes(reg.division)) d.addOptions([reg.division]); d.select(reg.division); } divDrawn = true; } catch (e) {}
    setText("Players_Name[0]", athlete); setText("Date_of_Birth[0]", fmt(reg.dob)); setText("Age_2[0]", reg.age_on_dec31); setText("Date_Signed[0]", signed);
    setText("Players_Address[0]", reg.address); setText("City__Zip[0]", `${reg.city || ""} ${reg.zip || ""}`.trim());
    setText("Phone[0]", reg.phone); setText("Email[0]", reg.email);
    setText("Cell_PhoneEmergency[0]", reg.emergency_phone); setText("Contact[0]", reg.emergency_name);
    setText("Carrier[0]", reg.insurance_carrier || "none"); setText("Policy_Number[0]", reg.insurance_policy); setText("Employer[0]", reg.insurance_employer);
    setText("I_declare_under_penalty_of_perjury_that_I_am_a_parent_or_guardian_of[0]", athlete);
    setText("Name_Parent_or_Guardian_print[0]", parentName); setText("Date[0]", signed);
    // Section III (member organization use): only what the registration already knows
    if (reg.doctor_date) setText("MEDICAL_EXAM__SPORT__DATE[0]", `${reg.sport || "Track & Field"} ${fmt(reg.doctor_date)}`);
    if (reg.ran_for_other_team && reg.prior_team) setText("PREVIOUS_CLUB[0]", reg.prior_team);
    try { form.updateFieldAppearances(F); } catch (e) {}
    form.flatten();

    const p1 = doc.getPage(0);
    const fit = (s, maxW, size) => { s = String(s ?? ""); while (size > 4 && F.widthOfTextAtSize(s, size) > maxW) size -= 0.25; return size; };
    // Blanks on the form that aren't fill-in fields: season year ("20__") and the member organization (athlete's team)
    p1.drawText(String(reg.season_year || "").slice(-2), { x: 259, y: 600, size: 8, font: B });
    p1.drawText(String(clubName || ""), { x: 432, y: 600, size: fit(clubName, 80, 8), font: B });
    if (!divDrawn && reg.division) p1.drawText(reg.division, { x: 400, y: 578, size: 8, font: B });
    // Signatures on the form's own signature lines
    const sig = (img, x, y, w, h) => { const sc = Math.min(w / img.width, h / img.height); p1.drawImage(img, { x, y, width: img.width * sc, height: img.height * sc }); };
    sig(aSig, 432, 343, 74, 18);   // Player: "Signature ____" on the Phone / Email line
    sig(pSig, 80, 104, 150, 20);   // Parent or Guardian: "Signature ____"
    const note = (s, x, y) => p1.drawText(s, { x, y, size: 4.5, font: F, color: rgb(.35, .35, .35) });
    if (reg.athlete_signature_method === "typed") note("typed e-signature", 432, 338);
    if (reg.parent_signature_method === "typed") note("typed e-signature", 80, 99);
    note(`Signed electronically ${signed} through VYC online registration. Registration ID ${reg.id || ""}`, 300, 712);

    // ================= PAGE 2: OFFICIAL CODE OF CONDUCT / MEDICAL CLEARANCE =================
    // The conference's own form (valleyconference.org/forms/CodeofConduct-VYC-TF1A.pdf), filled in on its blank lines.
    const coc = await PDFDocument.load(await formTemplate("CodeofConduct-VYC-TF1A.pdf"));
    const [p2] = await doc.copyPages(coc, [0]); doc.addPage(p2);
    const put = (s, x, y, maxW, size = 9) => { if (s) p2.drawText(String(s), { x, y, size: fit(s, maxW, size), font: B }); };
    const sig2 = (img, x, y, w, h) => { const sc = Math.min(w / img.width, h / img.height); p2.drawImage(img, { x, y, width: img.width * sc, height: img.height * sc }); };
    if (reg.medical_option === "conditions") {
      put(athlete, 78, 210, 168);                                // My Child ____
      put(reg.medical_conditions, 40, 197, 525, 8);              // conditions line
      put(reg.doctor_name, 92, 156, 190);                        // DR. ____
      put(fmt(reg.doctor_date), 327, 156, 185);                  // DATED: ____
    } else {
      put(athlete, 125, 245, 155);                               // PLAYER ____ (no known conditions)
      put(clubName, 393, 245, 160);                              // CLUB ____
    }
    put(athlete, 38, 84, 144);                                   // Player Name (Please Print)
    put(parentName, 193, 84, 178);                               // Parent's Name (Please Print)
    put(reg.verified_by, 387, 84, 176);                          // Coach/Club Official's Name, once verified
    sig2(aSig, 38, 49, 140, 18);                                 // Player's Signature
    sig2(pSig, 193, 49, 170, 18);                                // Parent Signature
    const note2 = (s, x, y) => p2.drawText(s, { x, y, size: 5, font: F, color: rgb(.35, .35, .35) });
    if (reg.athlete_signature_method === "typed") note2("(typed e-signature)", 104, 38);
    if (reg.parent_signature_method === "typed") note2("(typed e-signature)", 279, 38);
    note2(`Signed electronically ${signed} through VYC online registration. Registration ID ${reg.id || ""}`, 36, 22);

    return await doc.save();
  }
  root.buildRegistrationPdf = build;
})(typeof window !== "undefined" ? window : module.exports);
