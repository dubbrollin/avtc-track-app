-- ============================================================================
-- Livestream (2026-10-31) — a PAID team extra, like the Team Messenger.
-- One person on a team (a team admin, or a coach) broadcasts a game or event; the team's coaches and
-- parents watch it live in the app, and the recording stays available afterward. This mirrors what
-- BAND calls "Livestream": a one-way broadcast (RTMP/SRT in from a phone or OBS, HLS out to viewers),
-- NOT a two-way video call.
--
-- What lives where:
--   * The VIDEO itself never touches Supabase. A provider (Cloudflare Stream by default) ingests the
--     broadcast over RTMPS and serves it as HLS. The `supabase/functions/livestream` Edge Function is
--     the ONLY thing that talks to the provider; it holds the provider API token.
--   * Supabase holds only metadata (who/what/when, status, the playback id, the recording URL) and the
--     per-team paid switch. The ingest stream key is a secret, kept in its own table that the app can
--     never read — only the Edge Function (service role) and the broadcaster (via a checked function).
--
-- Paywall: nothing works for a team until a site admin turns the add-on on (team_livestream.enabled),
-- exactly like team_messaging. When billing is built it flips the same switch.
--
-- The rules (matching the messenger):
--   * A TEAM ADMIN or league SITE ADMIN can create a stream, go live, end it, and see the ingest key.
--   * A COACH on the team (any approved coach that isn't a timer) can also create and broadcast.
--   * WATCHING is open to the team: any approved coach, or any parent with a reviewed/verified
--     registration on the team (current or previous season). Watching a game is less sensitive than
--     reading messages, so it is season-light on purpose.
-- Who can watch is worked out live, never stored. All writes go through the functions below; the
-- tables themselves are read-only to the app (and the secrets table is not readable at all).
-- Reuses existing helpers: public.is_site_admin(), public.is_team_admin_of(text), public.coaches,
-- public.registrations.
-- ============================================================================

-- ---------- the paid switch, per team ----------
create table if not exists public.team_livestream (
  team_code  text primary key,
  enabled    boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.team_livestream enable row level security;
create policy "team livestream read" on public.team_livestream for select using (true);

-- ---------- streams (metadata only; no secrets here) ----------
create table if not exists public.live_streams (
  id                 uuid primary key default gen_random_uuid(),
  team_code          text not null,
  title              text not null default 'Live',
  status             text not null default 'scheduled',   -- scheduled | live | ended
  provider           text not null default 'cloudflare',
  provider_uid       text,              -- Cloudflare live input id (also the HLS video id)
  playback_id        text,              -- what the player loads (Cloudflare: same as provider_uid)
  require_signed_url boolean not null default true,
  recording_url      text,              -- set by the webhook when the VOD is ready
  scheduled_at       timestamptz,
  started_at         timestamptz,
  ended_at           timestamptz,
  created_by         text,              -- email
  created_at         timestamptz not null default now()
);
alter table public.live_streams enable row level security;

-- ---------- ingest secrets (never selectable by the app) ----------
create table if not exists public.live_stream_secrets (
  stream_id  uuid primary key references public.live_streams(id) on delete cascade,
  rtmps_url  text,
  rtmps_key  text,        -- the ingest stream key — sensitive
  srt_url    text,
  webrtc_url text,
  updated_at timestamptz not null default now()
);
alter table public.live_stream_secrets enable row level security;   -- no policies: functions/service role only

-- ---------- identity + permission helpers ----------
create or replace function public.live_me() returns text
language sql stable as $$ select lower(coalesce(auth.jwt()->>'email','')) $$;

create or replace function public.live_enabled(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select l.enabled from public.team_livestream l where l.team_code = t), false)
$$;

create or replace function public.live_can_manage(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.is_site_admin() or public.is_team_admin_of(t)
$$;

create or replace function public.live_is_coach(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.coaches c
    where lower(c.email) = public.live_me() and c.approved is true
      and c.team_code = t and c.role_type is distinct from 'timer')
$$;

create or replace function public.live_is_parent(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.registrations r
    where lower(r.email) = public.live_me() and r.team_code = t
      and r.status in ('reviewed','verified')
      and r.season_year >= (extract(year from now())::int - 1))
$$;

-- A coach or team admin may create/broadcast; anyone on the team (incl. parents) may watch.
create or replace function public.live_can_broadcast(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.live_enabled(t) and (public.live_can_manage(t) or public.live_is_coach(t))
$$;
create or replace function public.live_can_watch(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.live_enabled(t) and (public.live_can_manage(t) or public.live_is_coach(t) or public.live_is_parent(t))
$$;

-- ---------- RLS: streams are readable by anyone who may watch; secrets never ----------
create policy "live streams read" on public.live_streams
  for select to authenticated using (public.live_can_watch(team_code));

-- ---------- site-admin switch ----------
create or replace function public.live_set_enabled(p_team text, p_on boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_site_admin() then raise exception 'Only a league site admin can change this.'; end if;
  insert into public.team_livestream(team_code, enabled, updated_at) values (p_team, p_on, now())
    on conflict (team_code) do update set enabled = excluded.enabled, updated_at = now();
end $$;
grant execute on function public.live_set_enabled(text, boolean) to authenticated;

-- ---------- create a stream (metadata row; the Edge Function provisions the provider next) ----------
create or replace function public.live_create(p_team text, p_title text, p_scheduled_at timestamptz default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if not public.live_enabled(p_team) then raise exception 'Livestream is not enabled for this team.'; end if;
  if not public.live_can_broadcast(p_team) then raise exception 'You do not have permission to broadcast for this team.'; end if;
  insert into public.live_streams(team_code, title, status, scheduled_at, created_by)
    values (p_team, coalesce(nullif(trim(p_title),''),'Live'), 'scheduled', p_scheduled_at, public.live_me())
    returning id into v_id;
  return v_id;
end $$;
grant execute on function public.live_create(text, text, timestamptz) to authenticated;

-- ---------- the Edge Function stores provider ids + ingest secret here (service role only) ----------
create or replace function public.live_attach_provider(
  p_stream uuid, p_provider text, p_provider_uid text, p_playback_id text,
  p_rtmps_url text, p_rtmps_key text, p_srt_url text default null, p_webrtc_url text default null
) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.live_streams
     set provider = coalesce(p_provider, provider), provider_uid = p_provider_uid, playback_id = p_playback_id
   where id = p_stream;
  insert into public.live_stream_secrets(stream_id, rtmps_url, rtmps_key, srt_url, webrtc_url, updated_at)
    values (p_stream, p_rtmps_url, p_rtmps_key, p_srt_url, p_webrtc_url, now())
    on conflict (stream_id) do update
      set rtmps_url = excluded.rtmps_url, rtmps_key = excluded.rtmps_key,
          srt_url = excluded.srt_url, webrtc_url = excluded.webrtc_url, updated_at = now();
end $$;
revoke all on function public.live_attach_provider(uuid, text, text, text, text, text, text, text) from public, authenticated;
grant execute on function public.live_attach_provider(uuid, text, text, text, text, text, text, text) to service_role;

-- ---------- broadcaster reads the ingest key (permission-checked) ----------
create or replace function public.live_get_ingest(p_stream uuid)
returns table(rtmps_url text, rtmps_key text, srt_url text, webrtc_url text)
language plpgsql security definer set search_path to 'public' as $$
declare v_team text;
begin
  select team_code into v_team from public.live_streams where id = p_stream;
  if v_team is null then raise exception 'No such stream.'; end if;
  if not public.live_can_broadcast(v_team) then raise exception 'You cannot broadcast this stream.'; end if;
  return query select s.rtmps_url, s.rtmps_key, s.srt_url, s.webrtc_url
                 from public.live_stream_secrets s where s.stream_id = p_stream;
end $$;
grant execute on function public.live_get_ingest(uuid) to authenticated;

-- ---------- go live / end (broadcaster), or the webhook via service role ----------
create or replace function public.live_set_status(p_stream uuid, p_status text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_team text; v_is_service boolean;
begin
  if p_status not in ('scheduled','live','ended') then raise exception 'Bad status.'; end if;
  v_is_service := (auth.jwt()->>'role' = 'service_role');
  select team_code into v_team from public.live_streams where id = p_stream;
  if v_team is null then raise exception 'No such stream.'; end if;
  if not (v_is_service or public.live_can_broadcast(v_team)) then raise exception 'Not allowed.'; end if;
  update public.live_streams
     set status = p_status,
         started_at = case when p_status = 'live' and started_at is null then now() else started_at end,
         ended_at   = case when p_status = 'ended' then now() else ended_at end
   where id = p_stream;
end $$;
grant execute on function public.live_set_status(uuid, text) to authenticated;

-- ---------- recording ready (webhook, service role only) ----------
create or replace function public.live_set_recording(p_provider_uid text, p_url text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.live_streams set recording_url = p_url
   where provider_uid = p_provider_uid;
end $$;
revoke all on function public.live_set_recording(text, text) from public, authenticated;
grant execute on function public.live_set_recording(text, text) to service_role;

-- ---------- delete ----------
create or replace function public.live_delete(p_stream uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_team text;
begin
  select team_code into v_team from public.live_streams where id = p_stream;
  if v_team is null then return; end if;
  if not public.live_can_broadcast(v_team) then raise exception 'Not allowed.'; end if;
  delete from public.live_streams where id = p_stream;   -- secrets cascade
end $$;
grant execute on function public.live_delete(uuid) to authenticated;

-- ---------- the player asks "what may I load for this stream?" (checked) ----------
-- Returns the playback id only to someone allowed to watch, and only once the stream is live
-- or has a finished recording. The Edge Function turns this into a short-lived signed HLS URL.
create or replace function public.live_playback_target(p_stream uuid)
returns table(provider text, playback_id text, status text, recording_url text)
language plpgsql security definer set search_path to 'public' as $$
declare v_team text;
begin
  select team_code into v_team from public.live_streams where id = p_stream;
  if v_team is null or not public.live_can_watch(v_team) then return; end if;
  return query select s.provider, s.playback_id, s.status, s.recording_url
                 from public.live_streams s where s.id = p_stream;
end $$;
grant execute on function public.live_playback_target(uuid) to authenticated;

-- ---------- list streams for a team (metadata only; RLS already gates visibility) ----------
create or replace function public.live_list(p_team text)
returns setof public.live_streams
language sql stable security definer set search_path to 'public' as $$
  select * from public.live_streams
   where team_code = p_team and public.live_can_watch(p_team)
   order by case status when 'live' then 0 when 'scheduled' then 1 else 2 end, created_at desc
$$;
grant execute on function public.live_list(text) to authenticated;

-- ---------- which of my teams have livestream, and what can I do there (for the dashboard tab) ----------
create or replace function public.live_my_teams()
returns table(team_code text, can_broadcast boolean, can_manage boolean, enabled boolean)
language sql stable security definer set search_path to 'public' as $$
  with teams as (
    select c.team_code from public.coaches c where lower(c.email) = public.live_me() and c.approved is true
    union
    select r.team_code from public.registrations r where lower(r.email) = public.live_me()
      and r.status in ('reviewed','verified') and r.season_year >= (extract(year from now())::int - 1)
  )
  select t.team_code, public.live_can_broadcast(t.team_code), public.live_can_manage(t.team_code), public.live_enabled(t.team_code)
    from (select distinct team_code from teams) t
   where public.live_can_watch(t.team_code)
$$;
grant execute on function public.live_my_teams() to authenticated;
