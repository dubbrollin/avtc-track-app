> **Status 2026-11-06:** the FREE YouTube option is LIVE on track.avyouthathletics.org for every team with
> Paid extras on (same switch as the messenger). Database = `supabase/2026-11-06-livestream.sql` (applied to
> the server by `server-move/livestream-db.ps1`; the two 2026-10-31 SQL files are the old drafts and were never
> applied). The private Cloudflare option is built but OFF: it needs a Cloudflare account, then
> `LIVESTREAM_PRIVATE: true` in the server's config.js and the `livestream` Edge Function deployed on the server.

# Livestream — setup & wiring

Live video for the track app, matching BAND's model: one person broadcasts a game (phone or OBS),
the team's coaches and parents watch it live in the app, and the recording stays available after.
It is a **one-way broadcast**, not a video call. Built as a paid team add-on, like the Team Messenger.

## What's in the repo now
| File | What it is |
|---|---|
| `supabase/2026-10-31-livestream.sql` | Tables (`team_livestream` switch, `live_streams`, `live_stream_secrets`), permission helpers, and all the write RPCs. Matches the messenger's conventions (SECURITY DEFINER, tables read-only to the app). |
| `supabase/functions/livestream/index.ts` | Edge Function — the only thing that talks to Cloudflare. Creates live inputs, hands the broadcaster the ingest key, mints short-lived signed playback URLs, and receives the recording webhook. |
| `livestream.js` | Drop-in UI module (`Livestream.mount(el, {team, sb})`) — stream list, player (hls.js), and broadcaster controls. |
| `supabase/2026-10-31-livestream-youtube.sql` | Adds the FREE YouTube option (`live_create_youtube`). Apply it after the base migration. |

### Two ways to broadcast
When a coach/admin clicks **Start a broadcast**, they pick:
- **Private (option 1)** — Cloudflare Stream. Signed, per-member playback; usage-priced (see LIVESTREAM-COSTS.md). Needs the Cloudflare account + Edge Function below.
- **Free (option 2)** — YouTube Live. They start a stream in YouTube (phone app or OBS with YouTube's own key), paste the link, and the app embeds it for members. No Cloudflare, no per-minute cost; weaker privacy (unlisted link). Works with just the two SQL files — no Edge Function or Cloudflare account needed.

Video never touches Supabase. Supabase stores only metadata; the ingest stream key lives in a table the
app cannot read; Cloudflare holds and serves the actual video.

## The one step only you can do: a Cloudflare Stream account
I can't sign up or add billing. You do this part:
1. Create a Cloudflare account and enable **Stream** (Stream is usage-priced; see cost below).
2. Note your **Account ID** and your Stream **customer subdomain** (`customer-xxxx.cloudflarestream.com`),
   shown on the Stream dashboard.
3. Create an **API token** with the *Stream:Edit* permission.
4. (Optional, for recordings) add a Stream **webhook** pointing at the function's `?action=webhook&secret=...` URL.

## Install
```bash
# 1. Apply the database migration (from the app folder)
powershell -File supabase/run-sql.ps1 supabase/2026-10-31-livestream.sql

# 2. Set the function's secrets
supabase secrets set CF_ACCOUNT_ID=xxxx CF_API_TOKEN=xxxx CF_SUBDOMAIN=customer-xxxx.cloudflarestream.com WEBHOOK_SECRET=$(openssl rand -hex 16)

# 3. Deploy the Edge Function
supabase functions deploy livestream
```
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` are provided to the function
automatically by Supabase; you don't set those.

## Turn it on for a team
Livestream does nothing for a team until a **site admin** switches it on:
```js
await sb.rpc('live_set_enabled', { p_team: 'AVTC', p_on: true });
```
(Wire this into the same Site Admin add-ons screen that toggles the messenger.)

## Wire the UI into the dashboards
The messenger lives inside `coach.html` / `parent.html`; livestream goes in the same way — a new tab or
card. Add once, near the other dashboard scripts:
```html
<script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.15/dist/hls.min.js"></script>
<script src="livestream.js"></script>
```
Then, where you render the team's section (you already know the signed-in user's `team`):
```html
<div id="live"></div>
<script> Livestream.mount(document.getElementById('live'), { team: currentTeamCode, sb: window.sb }); </script>
```
Coaches and team admins see a **Start a broadcast** button; parents just see the list and the player.
Add a `Live` link to the dashboard nav alongside Messages.

## Testing it
1. Enable it for AVTC and sign in as a coach/team admin on the Coach Dashboard.
2. Click **Start a broadcast**, name it. You'll get an RTMPS URL + stream key.
3. In OBS (or the Larix/Streamlabs phone app): set that RTMPS URL + key, start streaming. Press **Go Live**.
4. Sign in as a parent on that team on another device → open the stream → you should see it within a few seconds.
5. Stop the encoder / press **End** → after Cloudflare finishes the recording, the webhook fills
   `recording_url` and the stream shows as a replay.

## Cost (Cloudflare Stream)
Usage-priced: roughly **$5 per 1,000 minutes stored** and **$1 per 1,000 minutes delivered**. A 90-minute
game watched by ~50 people is ~4,500 delivered minutes — a few dollars, plus pennies to store. You
control how long recordings are kept (BAND keeps 30 days).

## Caveats / what to confirm
- I built the Cloudflare calls without a live account to test against. Two spots in
  `functions/livestream/index.ts` are marked **CONFIRM** against current Cloudflare Stream docs: the
  `live_inputs` create body/response field names, and the live webhook payload shape. Everything else
  (auth, RLS, RPCs, the player) is standard.
- The migration is **additive and gated** — it creates tables/functions but changes nothing until a site
  admin enables a team, so it's safe to apply ahead of the Cloudflare account.
- Swapping providers later (Mux, AWS IVS) means changing only `functions/livestream/index.ts`; the
  database and UI don't care which provider is behind it.
