# Continuing this project in Claude Code

Riley moved this project (the VYC/AVTC registration app) from Cowork into Claude Code on his own machine, because Cowork's browser-automation safety system blocks certain database changes (bulk row updates, security-rule/RLS changes) even after he approves them. Running SQL directly through a terminal/psql/Supabase CLI in Claude Code doesn't hit that same block.

## Where everything lives
- **App files:** this folder (`avya-registration`), also live at `C:\Users\avtra\Cowork Projects\outputs\App Building\track app\avya-registration\`
- **Live site:** https://dubbrollin.github.io/avtc-track-app/ (GitHub Pages, repo `dubbrollin/avtc-track-app`, branch `main`)
- **Database:** Supabase project `avya-registration`, ref `qwwmissmsrpfjrsqditi`, org "Valley Youth Conference (VYC)" (free plan)
- Updates have been pushed to GitHub via the web "Upload files" flow (no local git was set up before this move) — Claude Code should check whether git/gh CLI is available and set that up for a cleaner workflow going forward, or keep using the web upload flow if Riley prefers.

## What's done as of this handoff
- Team display names fixed and corrected conference assignments (West Valley Eagles, Thimsha Tigers, Calabasas Cheetahs, San Fernando Valley Rush, Santa Clarita Storm, Santa Clarita Warriors moved to Western) — live in `shared.js`.
- Fixed a bug in `admin.html`'s People & Access tab: the `coaches` table has **no `id` column** — its real primary key is `email`. Approve/Revoke/Make Admin/Delete were all failing because the code assumed an `id` column existed. Fixed to key everything off `email` instead. Live.

## What's decided but NOT YET DONE — do this first
Riley wants to restructure coach permissions:
- **Admins get all administrative privileges.** Everyone currently in the `coaches` table right now should be grandfathered as BOTH `is_admin = true` AND `role_type = 'head_coach'` — nobody active loses anything.
- **Going forward, a new Head Coach (not an admin) gets only "basic coaching" privileges** — same as what a Division Coach sees today, but team-wide instead of division-scoped: roster view with safe columns only (name/division/gender/status — no medical/address/proof-of-birth), can enter athletes into meets, can see results. No verify/reject power over registrations, no private-record access, no coach-approval power. That stays admin-only.

### Step 1 — run this SQL against the Supabase database (this is what got blocked in Cowork)
```sql
alter policy "head coaches read full" on registrations
  using (exists (
    select 1 from coaches c
    where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
      and c.approved = true
      and c.is_admin
  ));

alter policy "head coaches update" on registrations
  using (exists (
    select 1 from coaches c
    where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
      and c.approved = true
      and c.is_admin
  ))
  with check (exists (
    select 1 from coaches c
    where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
      and c.approved = true
      and c.is_admin
  ));

alter policy "head coaches read full" on registrations rename to "admins read full";
alter policy "head coaches update" on registrations rename to "admins update";

update coaches set is_admin = true, role_type = 'head_coach';
```
Riley needs to supply his own Supabase database connection string (Project Settings → Database, or `supabase link` with the CLI) — that's a credential Claude Code should get directly from him, not something carried over from this handoff doc.

The `team_roster()` RPC (used for the safe-column roster view) already handles team-wide vs. division-scoped correctly for every role — no changes needed there. Confirmed its definition already gives head_coach/event_specialist the whole team and division_coach just their assigned division(s).

### Step 2 — update `coach.html` to match
1. Change `isFullAccess(c)` (currently checks `is_admin` OR several `role_type` values) to just:
   ```js
   function isFullAccess(c){ return !!c.is_admin; }
   ```
2. Fix the same `coaches.id`-doesn't-exist bug here too — the "Coaches on my team" card's `renderCoaches()`/`setCoachApproval()` currently uses `c.id` / `.eq('id',id)`. Change to `c.email` / `.eq('email',id)`, same fix as `admin.html`.
3. Update user-facing copy that says "your team's head coach can approve you" (in the `notCoachBox` and `pendingBox` sections) since coach approval is now admin-only — change to something like "a site admin can approve you."
4. Push the updated file live the same way prior updates went out (GitHub web upload, or git/gh CLI once set up).

## Other known open items (not urgent, just flagged)
- `is_coach()`/meets-management RLS isn't team-scoped — any approved coach can edit any team's meets/events.
- NVGB team code is a placeholder — needs the real Hy-Tek code confirmed.
- VUS (postseason) eligibility is self-reported, not cross-checked.
- Stripe payment link for VUS fees isn't set up.
- Deeper visual redesign of `index.html` (the long registration form) hasn't been attempted.

## Riley's standing preferences (carried over from Cowork)
- Plain, non-technical explanations — no jargon.
- Show what's about to happen and wait for a yes before anything that sends/publishes/deletes/shares, or changes live data/security.
- Do only what's asked — flag other worthwhile work in one sentence and ask, don't just do it.
- Before any competitive/pricing comparison work (unrelated to this app, but a standing rule): verify like-for-like businesses first.
- No recurring paid subscriptions without his explicit yes.
