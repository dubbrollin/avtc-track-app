# Meet Day Staging (`staging.html`)

For meets where teams don't enter ahead of time. Athletes are entered **at the meet**: the staging area ticks who is there at final call, the app seeds them by this season's best time, and each heat goes to the Meet Manager laptop.

Open it at **vycregistration.avyouthathletics.org/staging.html** (also linked from the Timer page). It works on a phone, tablet or laptop.

## Who can use it
- Site admins, team admins and approved timers.
- **Staging helpers**: anyone a site admin adds on the page's *Staging helpers* tab, using their email. They sign in with that email (password or Google). A helper can use this page and nothing else. They get no rosters, athlete records or coach tools.

## Before the first meet: Meet Manager setup (once per meet database)
Meet Manager's import file carries entries and seed times but **not lanes**. Meet Manager assigns lanes when you seed. Set it up once so its lanes match the VYC chart the app shows (Playing Rules XI):

1. **Set-up › Seeding Preferences › Lane Preferences › Standard Lane Preferences** (used by the 100 and the hurdles):
   - 6 lanes: `4 3 5 2 6 1`
   - 8 lanes: `4 5 3 6 2 7 1 8`
   - 9 lanes: `5 6 4 7 3 8 2 9 1`
2. 200, 400, 4x100 and 4x400 use a different chart. Set those events to **Custom lanes**:
   - 6 lanes: `3 4 2 5 6 1`
   - 8 lanes: `3 4 5 2 6 1 7 8`
   - 9 lanes: `4 5 6 3 7 2 8 1 9`
3. **Randomization rule: A (No randomization)** for timed finals. If you skip this, Meet Manager shuffles lanes within groups and they won't match.
4. **Heat order: Fast to Slow** (the fastest heat runs first).
5. 800 and longer use **Waterfall start**.

## On meet day
1. Open the meet. The first time, the app asks **how many lanes the track has** (6, 8 or 9). You can change it at the top.
2. **Track staging.** Events are listed in the order they run (rule IV.C.1.b). Open a division. You'll see every certified athlete on that meet's teams with their competition number, **this season's best** (no-time athletes at the bottom) and how many events they're already in.
   - Tick each athlete who is in the staging area at final call, then **Seed heats**.
   - Seeding is fastest heat first, filled first, and laned by the VYC chart. 800 and longer get waterfall positions, with a maximum of 18 per 800 heat (rule VI.A).
   - **Send to Meet Manager** on each heat as it's ready. Use **Mark run** once it has gone.
   - **Late arrival:** tick them and Seed again. They go into an empty lane of a heat that's been sent but not run. If there's no room, they go into the next heat.
   - **Mixed races** (800s and up, relays): *Combine divisions into one race*. Each athlete is still entered in their own division's event.
   - **Relays:** add each team's relay with all 4 runners (required). The A relay gets the team's best relay time this season and B the second best. A C relay, or any relay without a time, can have a time typed in or run as NT.
   - **Event limits (rule IV.C.1) are enforced and can't be overridden.** Sub-Gremlin and Gremlin get any 3 events. Bantam through Youth get 3 individual events + 1 relay, or 2 + 2. 15-18 get any 4. An athlete at the limit can't be ticked into another event, and the database refuses it too.
3. **Field events.** Each judge opens their event. Flights are listed in the rulebook order (IV.C.1.a), with the one that's up now and the one that's next. Check athletes in, then type marks:
   - Long jump: 4 attempts (Gremlin and Sub-Gremlin 3).
   - Shot put: 4 attempts.
   - Javelin: 3 attempts.
   - Type feet-inches like `12-04.25`, `F` for a foul, `P` for a pass.
   - High jump: one column per bar height (starting heights per rule V.B.1, up 2"). Type `O`, `XO`, `XXO`, `XXX` or `P` at each height. The app flags an athlete out after 3 misses in a row.
   - **Flight done** moves to the next division. **Print sheet** prints the flight.
4. **Meet Manager table** (on the laptop): shows how many athletes and relays are waiting, and checks every 15 seconds.
   - **Download new heats** gives a file of only what Meet Manager doesn't have yet.
   - In Meet Manager: **File › Import › Semi-Colon Delimited Rosters/Entries**, pick the file, answer **No** to "Only update seed times?", then seed that event.
   - A late arrival added to a heat that's already seeded: place them in the lane the heat sheet shows, using **Adjust (F8)**.
   - The red list shows anyone taken out after Meet Manager already had them. Scratch them there, then click Done.
   - Field marks are listed in Meet Manager's format, ready to type on the Run screen.

## If something breaks on meet day
Meet Manager still has every heat it has imported. Fall back to the paper heat sheets and field event sheets from valleyconference.org. With no connection, the page shows the last list it loaded on that device, but ticking and sending need a connection (use a phone hotspot).

## Tested (Nov 26, 2026)
- **Database:** 26 automated checks on a real Postgres engine. They cover permissions, season-best seeding, limits (including the 4th-event refusal), relays, late adds, scratches, and re-saving for an athlete already at the limit.
- **Page:** clicked through in a browser.
- **Meet Manager:** the file was imported into a copy of VYC-26-28 in Meet Manager 6.0 with 0 exceptions. Entries arrived with competition numbers and seeds, and relay seeds arrived as 1:08.40 / 1:10.12.

## What it doesn't do yet
- It doesn't write lanes into Meet Manager directly. Meet Manager's Seed (set up as above) or Adjust does that.
- It doesn't send field marks into Meet Manager automatically. They're typed on the Run screen; the official results still come from the Meet Manager upload after the meet.
- Relays added but not yet seeded are only saved on the device that added them.

Files: `staging.html`, `staging.js`, `supabase/2026-11-26-meet-day-staging.sql`.
