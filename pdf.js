// Builds the two Valley Youth Conference forms as filled, signed PDFs using pdf-lib.
// Works in the browser (window.PDFLib) and in Node (require('pdf-lib')) for testing.
(function (root) {
  const LIB = typeof window !== "undefined" ? window.PDFLib : require("pdf-lib");
  const { PDFDocument, StandardFonts, rgb } = LIB;
  const fmt = (iso) => { if (!iso) return ""; const [y, m, d] = String(iso).slice(0, 10).split("-"); return `${m}/${d}/${y}`; };
  const today = () => { const d = new Date(); return `${String(d.getMonth() + 1).padStart(2, "0")}/${String(d.getDate()).padStart(2, "0")}/${d.getFullYear()}`; };

  // Simple word-wrap helper
  function wrap(text, font, size, maxW) {
    const words = text.split(/\s+/); const lines = []; let cur = "";
    for (const w of words) {
      const t = cur ? cur + " " + w : w;
      if (font.widthOfTextAtSize(t, size) > maxW && cur) { lines.push(cur); cur = w; } else cur = t;
    }
    if (cur) lines.push(cur); return lines;
  }

  // The official Valley Youth Conference Player Contract (VYC Form 001, from valleyconference.org/forms/PLAYER_CONTRACT.pdf),
  // kept next to the app as forms/PLAYER_CONTRACT.pdf. We fill its own form fields and place the signatures on its signature lines.
  let templateBytes = null;
  async function contractTemplate() {
    if (templateBytes) return templateBytes;
    if (typeof window !== "undefined") {
      const res = await fetch("forms/PLAYER_CONTRACT.pdf"); if (!res.ok) throw new Error("Could not load the Player Contract form (" + res.status + ")");
      templateBytes = new Uint8Array(await res.arrayBuffer());
    } else templateBytes = require("fs").readFileSync(require("path").join(__dirname, "forms", "PLAYER_CONTRACT.pdf"));
    return templateBytes;
  }

  // clubName = the athlete's own team (Conference Member Organization)
  async function build(reg, clubName) {
    const doc = await PDFDocument.load(await contractTemplate());
    const F = await doc.embedFont(StandardFonts.Helvetica);
    const B = await doc.embedFont(StandardFonts.HelveticaBold);
    const aSig = await doc.embedPng(reg.athlete_signature);
    const pSig = await doc.embedPng(reg.parent_signature);
    const W = 612, H = 792, M = 40;
    const athlete = `${reg.first_name} ${reg.last_name}`;
    const signed = fmt(reg.created_at) || today();
    const parentName = reg.parent1_name || reg.parent_name || "";

    // helpers per page
    function pageTools(page) {
      let y = H - M;
      const t = (s, x, size = 9, font = F) => page.drawText(String(s ?? ""), { x, y, size, font });
      const para = (s, size = 8, font = F, indent = 0) => {
        const lines = wrap(s, font, size, W - 2 * M - indent);
        for (const l of lines) { page.drawText(l, { x: M + indent, y, size, font }); y -= size + 2.5; }
        y -= 3;
      };
      const field = (label, value, x, w, size = 9) => {
        page.drawText(label, { x, y, size: 7, font: F, color: rgb(.35, .35, .35) });
        page.drawText(String(value ?? ""), { x, y: y - 11, size, font: B });
        page.drawLine({ start: { x, y: y - 14 }, end: { x: x + w, y: y - 14 }, thickness: .5 });
      };
      const box = (s, yy) => page.drawText(s, { x: M, y: yy, size: 9, font: B });
      const sig = (img, x, w, label, method) => {
        const h = 32; const sc = Math.min(w / img.width, h / img.height);
        page.drawImage(img, { x, y: y - h, width: img.width * sc, height: img.height * sc });
        page.drawLine({ start: { x, y: y - h - 2 }, end: { x: x + w, y: y - h - 2 }, thickness: .5 });
        page.drawText(`${label}${method === "typed" ? " (typed e-signature)" : ""}`, { x, y: y - h - 11, size: 7, font: F, color: rgb(.35, .35, .35) });
      };
      const chk = (on, label, x) => { page.drawRectangle({ x, y: y - 2, width: 9, height: 9, borderWidth: .7, borderColor: rgb(0, 0, 0) }); if (on) page.drawText("X", { x: x + 1.5, y: y - 1, size: 8, font: B }); page.drawText(label, { x: x + 13, y, size: 9, font: F }); };
      return { get y() { return y; }, set y(v) { y = v; }, t, para, field, box, sig, chk, page };
    }

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

    let p;
    // ================= PAGE 2: CODE OF CONDUCT / MEDICAL =================
    p = pageTools(doc.addPage([W, H]));
    p.t("VALLEY YOUTH CONFERENCE, INC.", M, 13, B); p.y -= 15;
    p.t("Track & Field and Cross Country Division", M, 10, B); p.y -= 13;
    p.t("CODE OF CONDUCT — NO FIGHTING CONTRACT", M, 10, B); p.y -= 16;
    [
      "Our goals are to provide a recreational environment that is fun, healthy and competitive for all who wish to play. We believe this is the right of every player enrolled in our program. In addition we wish to protect these players from those who wish to violate their rights via mean spirited play, unsporting behavior and/or undue or malicious outside interference. It is the intent of the Valley Youth Conference, Inc. (VYC) and all Clubs to stop ANY and ALL violent conduct. All players, parents, coaches and helpers who are connected with each VYC Club must read and sign this document.",
      "Any athlete receiving discipline by a coach or an official of the Valley Youth Conference for throwing a punch, participating in a fight or any type of violent conduct, or other type of inappropriate behavior, may be further suspended from play for the season. Any coach, parent or spectator receiving discipline, including, but not limited to being asked to leave, for violent conduct or other inappropriate behavior may be barred from attending any further meets and/or Valley Youth Conference event, including practices.",
      "Should there be an incident of a fight or punches thrown involving athletes, coaches, participants or spectators at any Valley Youth Conference Sport activity, then a report of this incident must be made to the Commissioner of that Sport by the highest officials of the Club(s) in question within 24 hrs. of the incident. If the Commissioner of the Sport is unavailable to receive the report, then the General Manager is to be contacted next.",
      "The use of alcohol and illegal drugs will not be tolerated. If a player, coach or spectator is found to be using, or under the influence of, such substances, that person will be barred from attending the game/event/meet in question and/or reported to the proper authorities. The use of tobacco will not be tolerated at any venue where games/events/meets are in progress. A person using tobacco at any game/event/meet of the Valley Conference will be barred from attending the game/event/meet in question and may receive further sanctions.",
      "The Commissioner, and/or a committee formed by the Commissioner (which shall report to the Commissioner), will review reports of violent conduct, inappropriate behavior, alcohol, illegal drug, or tobacco use and similar incidents. In doing so, said person(s) may receive such input as such person(s) deem necessary. The Commissioner shall issue a ruling and final penalty/sanction, which may be lesser or more than those stated above. Once a ruling on the incident is issued, the Commissioner shall inform the Club representative of the actions against the parties involved and/or penalty or club sanctions. In the event that a person who has been suspended or barred from participation is found to have participated during such person's term of suspension or exclusion, then the Commissioner may issue further sanctions, including, but not limited to, Club suspension.",
    ].forEach(s => p.para(s, 8));
    p.t("ANY ATHLETE, COACH or PARENT refusing to sign this document will not be able to participate in play.", M, 8.5, B); p.y -= 18;

    p.t("PARENTS MEDICAL CLEARANCE AND PERMISSION TO PARTICIPATE", M, 10, B); p.y -= 13;
    p.para("VALLEY YOUTH CONFERENCE TRACK AND FIELD AND CROSS COUNTRY strongly recommends that children have a medical check-up by a physician prior to participating. To participate in this CONFERENCE, the child's parent or guardian MUST fill out one of the statements below and sign at the bottom.", 7.5);
    p.chk(reg.medical_option === "clear", "", M);
    p.para("I am aware that Track & Field and Cross Country are physically demanding sports that requires strenuous effort to participate. I am not aware of any medical or physical condition(s) of my child (name listed below) that would limit his/her participation in the VALLEY YOUTH CONFERENCE Track and Field and Cross-Country programs.", 7.5, F, 14);
    p.field("PLAYER", athlete, M, 220); p.field("CLUB", clubName, M + 240, 250); p.y -= 28;
    p.chk(reg.medical_option === "conditions", "", M);
    p.para(`My Child ${athlete} has the following medical or physical condition(s) that are of concern to me: ${reg.medical_option === "conditions" ? (reg.medical_conditions || "") : "____________________"}`, 7.5, F, 14);
    p.para("Clearance to play VALLEY YOUTH CONFERENCE Track & Field and Cross-Country has been obtained through the following medical channels (including tests, examinations and evaluations) and approval to participate has been given by signature of Doctor indicated:", 7.5);
    p.field("DR.", reg.medical_option === "conditions" ? reg.doctor_name : "", M, 220); p.field("DATED", reg.medical_option === "conditions" ? fmt(reg.doctor_date) : "", M + 240, 150); p.y -= 30;
    p.para("Performance Enhancing Substances — The Valley Youth Conference, its member organizations and representatives of these organization shall NOT recommend, promote or suggest any type of substance whether chemical, vitamin, mineral, or herbal to be used by its athletes. I have read, understood and agree to the above requirements allowing me to participate in Valley Youth Conference, Inc.", 7.5);
    p.y -= 6;
    p.field("Player Name (Please Print)", athlete, M, 160); p.field("Parent's Name (Please Print)", reg.parent_name, M + 180, 170); p.field("Coach/Club Official's Name (Please Print)", reg.verified_by || "", M + 370, 160); p.y -= 34;
    p.sig(aSig, M, 160, "Player's Signature", reg.athlete_signature_method); p.sig(pSig, M + 180, 170, "Parent Signature", reg.parent_signature_method);
    p.page.drawLine({ start: { x: M + 370, y: p.y - 34 }, end: { x: M + 530, y: p.y - 34 }, thickness: .5 });
    p.page.drawText("Coach/Club Official's Signature", { x: M + 370, y: p.y - 43, size: 7, font: F, color: rgb(.35, .35, .35) });
    p.y -= 60;
    p.t(`Electronically signed ${signed} via ${clubName} online registration. Registration ID ${reg.id}`, M, 6.5);

    return await doc.save();
  }
  root.buildRegistrationPdf = build;
})(typeof window !== "undefined" ? window : module.exports);
