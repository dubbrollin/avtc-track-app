# Livestream cost — is it feasible for all-day track meets?

Short answer: **yes, with guardrails** on Cloudflare Stream — low hundreds of dollars per season at
realistic club audiences. And there's a **free** alternative (YouTube Live) for when the audience is big
and privacy can be looser. The thing that drives cost is **total viewer-minutes (audience × how long each
watches)**, not video quality.

## How Cloudflare Stream bills (the important mechanic)
- **Delivery: $1 per 1,000 minutes watched**, summed across every viewer.
- **Storage: $5 per 1,000 minutes stored per month** (the recording's length).
- Billing is **by minutes, not bandwidth** — so 1080p costs the same as 480p. Quality is effectively free;
  **duration and audience are the cost.** Live ingest/encoding is included.

## One all-day meet = 8 hours = 480 minutes broadcast
Delivery cost depends on how many watch and for how long (viewer-minutes = viewers × avg minutes each):

| Audience | Avg watched | Viewer-minutes | Delivery cost |
|---|---|---|---|
| 20 families | 2 hrs | 2,400 | **$2.40** |
| 50 families | 3 hrs | 9,000 | **$9.00** |
| 100 families | 4 hrs | 24,000 | **$24.00** |
| 200 families | full 8 hrs | 96,000 | **$96.00** |

Storage: one 8-hour recording = 480 min = **$2.40/month** to keep it. Ten meets kept = ~$24/month; prune
at 30 days (like BAND) to cap it.

## A full season (≈10 meets)
- **Realistic (moderate audience, ~$9–$24/meet):** ~$90–$240 delivery + storage → call it **~$150–$300/season.**
- **Heavy (big audience watching most of the day):** could reach **$500–$1,000/season.**

That's very affordable at club scale, and it's a **paid add-on** — price it to families or a meet sponsor
and it covers itself easily.

## The free option: YouTube Live
YouTube Live is **free** — unlimited viewers, unlimited duration, auto-archives the recording. For an
8-hour meet with a large audience it's unbeatable on cost ($0). Trade-offs: an unlisted link is weaker
privacy than per-user gating, there's YouTube branding/ads, and less control. For youth athletes that
privacy gap matters, so treat it as the budget/large-audience option, embedded in the app, while
Cloudflare stays the truly-private option. Because all provider calls live behind one Edge Function,
adding a YouTube backend (even as a per-team toggle) is a contained change.

## What NOT to overlook
- **The broadcaster's own data.** An 8-hour live upload at ~2–3 Mbps is **7–10 GB** off whoever's phone or
  hotspot is streaming. On venue wifi it's fine; on cellular it's real. Budget a hotspot/unlimited plan
  for the person who streams.
- **You already have cheap "can't attend" coverage.** The app's live *results* feed (from Meet Manager)
  already tells families how their athlete did, for near-zero cost. Video is the premium layer on top —
  not everyone needs 8 hours of it.

## Cost-control levers (in priority order)
1. **30-day auto-delete** on recordings (caps storage).
2. **Team-gated viewing** (already built) caps the audience to real members.
3. **Stream the racing, not the idle hours** — start/stop around active events instead of 8 continuous hours.
4. **YouTube backend** for zero delivery cost when privacy allows.
5. **Price the add-on / get a sponsor** so families or a banner cover the meet's cost.

## Provider comparison for long, multi-viewer events
- **Cloudflare Stream** — cheapest *private* managed option; minutes-based so quality is free. Recommended default.
- **YouTube Live** — free, best for cost; weakest privacy.
- **Mux / AWS IVS** — comparable or pricier for long multi-viewer events (IVS bills per viewer-hour + input hour).

## Verdict
Feasible. At realistic club usage, a few hundred dollars a season on Cloudflare, or free on YouTube if an
unlisted link is acceptable. The honest risk is an unbounded case — a huge audience watching all day across
many meets — which the retention cap, team gating, racing-only streaming, and the paid-add-on pricing all
exist to contain.
