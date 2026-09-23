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

  async function build(reg, clubName) {
    const doc = await PDFDocument.create();
    const F = await doc.embedFont(StandardFonts.Helvetica);
    const B = await doc.embedFont(StandardFonts.HelveticaBold);
    const aSig = await doc.embedPng(reg.athlete_signature);
    const pSig = await doc.embedPng(reg.parent_signature);
    const W = 612, H = 792, M = 40;
    const athlete = `${reg.first_name} ${reg.last_name}`;
    const signed = fmt(reg.created_at) || today();

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

    // ================= PAGE 1: PLAYER CONTRACT =================
    let p = pageTools(doc.addPage([W, H]));
    p.t("PLAYER CONTRACT", M, 14, B); p.y -= 16;
    p.t("VALLEY YOUTH CONFERENCE, INC. — A YOUTH SPORTS ATHLETIC ASSOCIATION", M, 9, B); p.y -= 14;
    p.t("SPORT:", M, 9, B); p.chk(reg.sport === "Track & Field", "Track & Field", M + 45); p.chk(reg.sport === "Cross Country", "Cross Country", M + 140); p.y -= 14;
    p.t(`Player Season Application for ${reg.season_year} Season.   Conference Member Organization: ${clubName}`, M); p.y -= 13;
    p.t(`Age: ${reg.age_on_dec31}`, M); p.chk(reg.gender === "Boy", "Boy", M + 60); p.chk(reg.gender === "Girl", "Girl", M + 110); p.t(`Name of Sport Division: ${reg.division}`, M + 170); p.y -= 18;
    p.para("PLEASE READ CAREFULLY — NOTE: Completion of this application DOES NOT guarantee applicant a position on a team. No applicant will be allowed to participate in any activity until this form has been completed in full and accepted by the above named member organization. Members organization acceptance is subject to final approval and certification by the sport. PLAYER AND PARENTS TAKE NOTE: All rules concerning certification, eligibility, playing rules, sport/conference procedures, and any dispute arising from these rules are procedures rests solely with the sport and/or conference. The final arbitration is the Valley Youth Conference, Inc. Executive Board. I agree to abide to all conference decisions.", 7.5);
    p.t("SECTION 1. APPLICANT'S STATEMENT", M, 9, B); p.y -= 11;
    p.para("I will faithfully keep and abide by the following rules and carry them out to the best of my ability.", 8);
    [
      "1. I will maintain at least a \"C\" average throughout the school year.",
      "2. I will play any position assigned and do my best for the team.",
      "3. When my team is not playing I will stay off the playing field completely and will not interfere with those playing.",
      "4. I solemnly pledge that I will not in any way damage, or deface any property, building or equipment.",
      "5. I agree to abide by all decisions of game officials and will not create any unsportmanlike gestures at any time.",
      "6. I promise that I will be a lady/gentleman at all times and I will refrain from using any foul language.",
      "7. I agree that I will remain a member of the team and the organization until properly released.",
      "8. I agree to return the uniform and other equipment issued to me in as good a condition as when received, except for normal wear and tear.",
    ].forEach(r => p.para(r, 8));
    p.y -= 4;
    p.field("Player's Name (Print in Full)", athlete, M, 200); p.field("Date of Birth", fmt(reg.dob), M + 215, 80); p.field("Age", reg.age_on_dec31, M + 305, 40); p.field("Date Signed", signed, M + 355, 90); p.y -= 28;
    p.field("Player's Address", reg.address, M, 300); p.field("City & Zip", `${reg.city} ${reg.zip}`, M + 315, 200); p.y -= 28;
    p.field("Phone", reg.phone, M, 140); p.field("Email", reg.email, M + 150, 200); p.y -= 2; p.sig(aSig, M + 365, 160, "Player Signature", reg.athlete_signature_method); p.y -= 46;
    p.field("Cell Phone/Emergency #", reg.emergency_phone, M, 200); p.field("Contact", reg.emergency_name, M + 215, 250); p.y -= 34;

    p.t("SECTION II. PARENTS/GUARDIANS ACKNOWLEDGEMENT, AUTHORIZATION AND CONSENT", M, 9, B); p.y -= 11;
    p.para("RELEASE: I/WE the parents/guardians of the above named applicant, hereby give my/our approval to his/her participation in all conference and member organizations activities during the specified season. I/WE assume all risks and hazards incidental to such participation including transportation to and from the activities and I/WE do hereby waive, release, absolve, indemnify and agree to hold harmless the conference, member organization, organizers, sponsors, supervisors, participants, and persons transporting the applicant to and from activities, from any claim arising out of an injury to the applicant.", 7);
    p.para("ATTEST: I/WE hereby acknowledge that the information provided in this application is factual and accurate, that I/WE understand that if applicant is accepted to member organization and is certified by the Conference the applicant must remain with the member organization until released, such release is subject to approval of the conference. I/WE have read the foregoing statement and understand them, and sign them voluntarily.", 7);
    p.para("MEDIA RELEASED: I/WE hereby give permission to the Valley Youth Conference to reproduce, adapt, and display in any and all media my child's name, and/or photographs, silhouettes, or other reproductions of my child's physical image. I further give permission to the Valley Youth Conference to reproduce, adapt, and display record of the sporting performance of my child that it may obtain as it pertains to the Valley Youth Conference Sport that he or she is participating in, on or about the above dates. I hereby release the Valley Youth Conference from any and all claims and liabilities that I or my child by reason of the publication in any media whatsoever (including publication in or by any news media), use, adaptation display or such use of my child's name and/or likeness.", 7);
    p.para("INSURANCE: I/WE hereby acknowledge and represent that I understand that the Conference, or member organizations upon approval of the Conference, maintains Group Accident Coverage for medical/hospital expenses, and that I have been advised and understand the limits and provisions of such coverage, including that such coverage may be considered as \"secondary\" coverage when there is any other valid and collectible coverage provided by applicant's parents/guardians separate insurance specified below if known. I/WE understand that any claim for medical service which arises out of an injury from a Conference or member organization activity must be reported to the member organization Coach/Manager of applicant's assigned team within ten days of the date of injury. Other Insurance is specified below; if none specify \"none\".", 7);
    p.field("Carrier", reg.insurance_carrier, M, 170); p.field("Policy Number", reg.insurance_policy, M + 185, 170); p.field("Employer", reg.insurance_employer, M + 370, 160); p.y -= 28;
    p.para("MEDICAL TREATMENT AUTHORIZATION: In the event of injury or illness to the above named applicant, I/WE hereby grant authority to a qualified physician to render such medical treatment to the applicant as said physician deems necessary under the circumstances upon presentation of this consent form.", 7);
    p.t(`I declare under penalty of perjury that I am a parent or guardian of:  ${athlete}`, M, 8.5); p.y -= 20;
    p.sig(pSig, M, 180, "Parent or Guardian Signature", reg.parent_signature_method); p.field("Name Parent or Guardian (print)", reg.parent_name, M + 200, 190); p.field("Date", signed, M + 405, 100); p.y -= 52;
    p.t("SECTION III. MEMBER ORGANIZATION USE ONLY", M, 9, B); p.y -= 12;
    p.t(`Organization: ${clubName}    Returning athlete: ${reg.is_returning ? "Yes" : "No"}${reg.ran_for_other_team ? `  (previously: ${reg.prior_team})` : ""}`, M, 8); p.y -= 12;
    p.t(`Proof of birth on file: ${reg.status === "verified" ? "VERIFIED by " + (reg.verified_by || "coach") : "pending"}    DOB auto-check: ${reg.dob_check_status}`, M, 8);

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
