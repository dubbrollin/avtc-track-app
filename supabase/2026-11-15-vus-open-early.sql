-- Valley United requests: open EARLY; parent picks vs coach entries; marks; relay eligibility (Riley, 2026-11-15).
--
-- Opening day (not IEC day any more), first match wins:
--   1. the "Valley United requests open" date a Valley United admin sets (app_settings vus_request_open_<season>)
--   2. the first meet of the season marked Invitational (Meet Admin)
--   3. the IEC meet (the old rule, kept as a last fallback)
-- Closing date unchanged (vus_request_close_<season>; blank = no closing date).
-- Asking early is fine: placement and season bests are worked out when the parent asks; a Valley United admin uses
-- "Re-check results" after league finals / IECs to refresh them.
--
-- TWO LISTS per athlete, so a conflict between parents and coaches is visible from the start:
--   * events  = PARENT PICKS: the individual events the parent wants, up to 3 (every age), each needing a mark from this
--               season. Set once on the request; nobody edits them afterwards (the record of what the parent asked for).
--   * entries = COACH ENTRIES: what the coaches decide, entered by a Valley United admin — up to 3 in total, a relay counts
--               as one. Null until the coaches enter the athlete.
--       - individual event: needs a mark from this season.
--       - relay: needs a mark in its race — 4x100 = 100m, 4x400 = 400m, 4x800 = 800m. Without one the relay shows
--         "needs a mark": the athlete must run that race at the relay deadline meet (usually LA Jets — Settings:
--         vus_relay_deadline_meet_<season> / vus_relay_deadline_date_<season>); no mark by then = not allowed on the
--         relay. A Valley United admin records the mark once it's run (vus_record_mark). That qualifying race isn't one
--         of the 3 entries.
begin;

create or replace function public.vus_window(p_season integer)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with s as (select nullif(value,'')::date d from public.app_settings where key = 'vus_request_open_' || p_season),
       inv as (select min(m.meet_date) d from public.meets m where m.season_year = p_season and m.is_invitational),
       iec as (select min(m.meet_date) d from public.meets m where m.season_year = p_season and m.postseason_kind = 'iec')
  select jsonb_build_object(
    'opens', coalesce((select d from s), (select d from inv), (select d from iec)),
    'opens_from', case when (select d from s) is not null then 'date'
                       when (select d from inv) is not null then 'invitational'
                       when (select d from iec) is not null then 'iec' end,
    'closes', (select nullif(value,'')::date from public.app_settings where key = 'vus_request_close_' || p_season),
    'relay_deadline_meet', (select nullif(value,'') from public.app_settings where key = 'vus_relay_deadline_meet_' || p_season),
    'relay_deadline_date', (select nullif(value,'')::date from public.app_settings where key = 'vus_relay_deadline_date_' || p_season))
$$;
grant execute on function public.vus_window(integer) to anon, authenticated;

-- ---------- relay willingness (asked of the parent up front) ----------
-- Relays take a different kind of commitment, so the parent says ahead of time whether the athlete is willing to run
-- on relays (true) or will only do individual events (false). Coaches see it; a relay entry against a "no" is flagged.
alter table public.vus_requests add column if not exists relay_ok boolean;
alter table public.postseason_registrations add column if not exists relay_ok boolean;

-- ---------- coach entries ----------
alter table public.vus_requests add column if not exists entries jsonb;   -- null = coaches haven't entered them yet
alter table public.vus_requests add column if not exists entries_by text;
alter table public.vus_requests add column if not exists entries_at timestamptz;

-- The individual race a relay needs a mark in.
create or replace function public.vus_relay_race(p_relay text)
returns jsonb language sql immutable as $$
  select case p_relay
    when '4x100' then '{"event_code":"100","event_name":"100m Dash"}'::jsonb
    when '4x400' then '{"event_code":"400","event_name":"400m Dash"}'::jsonb
    when '4x800' then '{"event_code":"800","event_name":"800m Run"}'::jsonb end
$$;

-- Build coach entries: individual events from the season bests (mark required), then relays with their race mark —
-- the season best, else a mark an admin recorded earlier (in p_old), else "needs a mark".
create or replace function public.vus_build_entries(p_bests jsonb, p_codes text[], p_relays text[], p_old jsonb default '[]'::jsonb)
returns jsonb language sql stable as $$
  select coalesce((
    select jsonb_agg(x order by o) from (
      select o, (b || jsonb_build_object('kind','event')) x
        from unnest(p_codes) with ordinality u(c,o)
        join lateral (select b from jsonb_array_elements(coalesce(p_bests,'[]'::jsonb)) b where b->>'event_code' = u.c limit 1) bb on true
      union all
      select 100 + o, jsonb_build_object('kind','relay','relay',r,
               'race_code', public.vus_relay_race(r)->>'event_code', 'race_name', public.vus_relay_race(r)->>'event_name')
             || coalesce(
                  (select jsonb_build_object('race_mark', b->>'mark', 'needs_mark', false)
                     from jsonb_array_elements(coalesce(p_bests,'[]'::jsonb)) b where b->>'event_code' = public.vus_relay_race(r)->>'event_code' limit 1),
                  (select jsonb_build_object('race_mark', z->>'race_mark', 'needs_mark', false, 'meet', z->>'meet',
                                             'recorded_at', z->>'recorded_at', 'recorded_by', z->>'recorded_by')
                     from jsonb_array_elements(coalesce(p_old,'[]'::jsonb)) z where z->>'relay' = r and z ? 'recorded_at' limit 1),
                  jsonb_build_object('race_mark', null, 'needs_mark', true))
        from unnest(p_relays) with ordinality v(r,o) where public.vus_relay_race(r) is not null
    ) t), '[]'::jsonb)
$$;

-- Parent request: individual events only (up to 3, each with a mark). Coach entries start empty.
create or replace function public.vus_request_fill()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; e jsonb; w jsonb; today date := (now() at time zone 'America/Los_Angeles')::date;
  picked text[]; allowed text[]; adm boolean := public.is_vus_admin();
begin
  select * into r from public.registrations where id = new.registration_id;
  if r.id is null or r.status = 'rejected' then raise exception 'Athlete not found.'; end if;
  if coalesce(r.sport,'Track & Field') = 'Cross Country' then
    raise exception 'Valley United requests come from the athlete''s track & field registration.';
  end if;
  if not (lower(r.email) = lower(coalesce(auth.jwt()->>'email','')) or adm) then
    raise exception 'Only the parent who registered this athlete can ask for Valley United.';
  end if;
  e := public.vus_compute(r.id); w := e->'window';
  if not adm then
    if w->>'opens' is null then raise exception 'Valley United requests aren''t open yet — the opening date isn''t set.'; end if;
    if today < (w->>'opens')::date then
      raise exception 'Valley United requests open on %.', to_char((w->>'opens')::date, 'FMMonth FMDD, YYYY');
    end if;
    if w->>'closes' is not null and today > (w->>'closes')::date then
      raise exception 'Valley United requests closed on %.', to_char((w->>'closes')::date, 'FMMonth FMDD, YYYY');
    end if;
  end if;

  select coalesce(array_agg(x->>'event_code'), '{}') into allowed from jsonb_array_elements(coalesce(e->'bests','[]'::jsonb)) x;
  select coalesce(array_agg(distinct x->>'event_code'), '{}') into picked from jsonb_array_elements(coalesce(new.events,'[]'::jsonb)) x;
  if cardinality(picked) = 0 then raise exception 'Please pick at least one individual event.'; end if;
  if new.relay_ok is null and not adm then raise exception 'Please answer whether your athlete is willing to run on relays.'; end if;
  if cardinality(picked) > 3 then raise exception 'Pick up to 3 individual events.'; end if;
  if not picked <@ allowed then
    raise exception 'Every Valley United event needs a mark from this season. Pick events the athlete competed in.';
  end if;

  new.season_year := r.season_year; new.team_code := r.team_code;
  new.first_name := r.first_name; new.last_name := r.last_name; new.gender := r.gender; new.dob := r.dob; new.division := r.division;
  new.email := lower(r.email);
  new.qualified := (e->>'qualified')::boolean; new.ran_league_final := (e->>'ran_league_final')::boolean; new.ran_iec := (e->>'ran_iec')::boolean;
  new.placement := e->>'placement'; new.best_marks := e->'bests';
  new.events := (select jsonb_agg(b) from jsonb_array_elements(e->'bests') b where b->>'event_code' = any(picked));
  new.entries := null; new.entries_by := null; new.entries_at := null;
  new.status := 'submitted'; new.reviewed_by := null; new.reviewed_at := null; new.fee_paid := false; new.fee_paid_at := null;
  new.checked_at := now();
  return new;
end $$;

-- Parent picks are the parent's record: a Valley United admin changes the coach entries, never the parent picks.
create or replace function public.vus_request_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(current_setting('request.jwt.claims', true),'') = '' then return new; end if;
  if not public.is_vus_admin() then raise exception 'Only a Valley United admin can change a request.'; end if;
  if (new.registration_id, new.season_year, new.team_code, new.placement, new.qualified, new.ran_league_final, new.ran_iec, new.best_marks, new.events, new.relay_ok)
     is distinct from (old.registration_id, old.season_year, old.team_code, old.placement, old.qualified, old.ran_league_final, old.ran_iec, old.best_marks, old.events, old.relay_ok)
     and current_setting('vus.recheck', true) is distinct from 'on' then
    raise exception 'The parent''s picks, placement and season bests can''t be edited. Use "Re-check results" to refresh marks, and Coach entries for what the coaches decide.';
  end if;
  if new.entries is distinct from old.entries and current_setting('vus.entries', true) is distinct from 'on' and current_setting('vus.recheck', true) is distinct from 'on' then
    raise exception 'Use Coach entries to change what the athlete is entered in.';
  end if;
  if new.status is distinct from old.status then
    new.reviewed_by := lower(coalesce(auth.jwt()->>'email','')); new.reviewed_at := now();
  end if;
  if new.fee_paid and not old.fee_paid then new.fee_paid_at := now(); end if;
  if not new.fee_paid then new.fee_paid_at := null; end if;
  return new;
end $$;

-- Re-check: refresh placement and season bests; the parent's picks and the coach entries keep their events and pick up
-- the newest marks (a relay race that now has a season mark becomes eligible; recorded marks are kept).
create or replace function public.vus_recheck(p_id uuid)
returns public.vus_requests language plpgsql security definer set search_path to 'public' as $$
declare q public.vus_requests; e jsonb;
begin
  if not public.is_vus_admin() then raise exception 'Only a Valley United admin can re-check a request.'; end if;
  select * into q from public.vus_requests where id = p_id;
  if q.id is null then raise exception 'Request not found.'; end if;
  e := public.vus_compute(q.registration_id);
  perform set_config('vus.recheck', 'on', true);
  update public.vus_requests set
    qualified = (e->>'qualified')::boolean, ran_league_final = (e->>'ran_league_final')::boolean, ran_iec = (e->>'ran_iec')::boolean,
    placement = e->>'placement', best_marks = e->'bests',
    events = coalesce((select jsonb_agg(coalesce(
               (select b from jsonb_array_elements(coalesce(e->'bests','[]'::jsonb)) b where b->>'event_code' = x->>'event_code' limit 1), x))
             from jsonb_array_elements(coalesce(q.events,'[]'::jsonb)) x), '[]'::jsonb),
    entries = case when q.entries is null then null else public.vus_build_entries(e->'bests',
               array(select x->>'event_code' from jsonb_array_elements(q.entries) x where x->>'kind' = 'event'),
               array(select x->>'relay' from jsonb_array_elements(q.entries) x where x->>'kind' = 'relay'), q.entries) end,
    checked_at = now()
   where id = p_id returning * into q;
  perform set_config('vus.recheck', 'off', true);
  return q;
end $$;
grant execute on function public.vus_recheck(uuid) to authenticated;

-- A Valley United admin enters what the coaches decided: up to 3 in total (a relay counts as one); individual events
-- need a mark this season; relays without their race mark show "needs a mark".
drop function if exists public.vus_set_events(uuid, text[]);
drop function if exists public.vus_set_events(uuid, text[], text[]);
create or replace function public.vus_set_entries(p_id uuid, p_codes text[], p_relays text[])
returns public.vus_requests language plpgsql security definer set search_path to 'public' as $$
declare q public.vus_requests; codes text[]; rl text[]; allowed text[];
begin
  if not public.is_vus_admin() then raise exception 'Only a Valley United admin can enter athletes.'; end if;
  select * into q from public.vus_requests where id = p_id;
  if q.id is null then raise exception 'Request not found.'; end if;
  codes := coalesce((select array_agg(distinct c) from unnest(p_codes) c where c is not null), '{}');
  rl := coalesce((select array_agg(distinct r) from unnest(p_relays) r where r is not null), '{}');
  if not rl <@ array['4x100','4x400','4x800'] then raise exception 'Unknown relay.'; end if;
  if cardinality(codes) + cardinality(rl) > 3 then raise exception 'Up to 3 entries in total — a relay counts as one.'; end if;
  select coalesce(array_agg(x->>'event_code'), '{}') into allowed from jsonb_array_elements(coalesce(q.best_marks,'[]'::jsonb)) x;
  if not codes <@ allowed then
    raise exception 'Every individual event needs a mark from this season. Pick events the athlete competed in.';
  end if;
  perform set_config('vus.entries', 'on', true);
  update public.vus_requests set
    entries = case when cardinality(codes) + cardinality(rl) = 0 then null else public.vus_build_entries(q.best_marks, codes, rl, q.entries) end,
    entries_by = lower(coalesce(auth.jwt()->>'email','')), entries_at = now()
   where id = p_id returning * into q;
  perform set_config('vus.entries', 'off', true);
  return q;
end $$;
grant execute on function public.vus_set_entries(uuid, text[], text[]) to authenticated;

-- A Valley United admin records the relay race mark run at the deadline meet (blank mark = back to "needs a mark").
drop function if exists public.vus_record_mark(uuid, text, text, text);
create or replace function public.vus_record_mark(p_id uuid, p_relay text, p_mark text, p_meet text default null)
returns public.vus_requests language plpgsql security definer set search_path to 'public' as $$
declare q public.vus_requests;
begin
  if not public.is_vus_admin() then raise exception 'Only a Valley United admin can record a mark.'; end if;
  select * into q from public.vus_requests where id = p_id;
  if q.id is null then raise exception 'Request not found.'; end if;
  if not exists (select 1 from jsonb_array_elements(coalesce(q.entries,'[]'::jsonb)) x where x->>'relay' = p_relay) then
    raise exception 'That athlete isn''t entered on the %.', p_relay;
  end if;
  perform set_config('vus.entries', 'on', true);
  update public.vus_requests set entries = (
    select jsonb_agg(case when x->>'relay' = p_relay then
             case when coalesce(trim(p_mark),'') = '' then (x - 'recorded_at' - 'recorded_by' - 'meet') || jsonb_build_object('race_mark', null, 'needs_mark', true)
                  else x || jsonb_build_object('race_mark', trim(p_mark), 'needs_mark', false, 'meet', nullif(trim(coalesce(p_meet,'')),''),
                                               'recorded_at', now(), 'recorded_by', lower(auth.jwt()->>'email')) end
             else x end)
    from jsonb_array_elements(q.entries) x)
   where id = p_id returning * into q;
  perform set_config('vus.entries', 'off', true);
  return q;
end $$;
grant execute on function public.vus_record_mark(uuid, text, text, text) to authenticated;

-- ---------- high school athletes: marks checked on Athletic.net ----------
-- High school athletes (no VYC season) type their marks themselves; a Valley United admin checks each one on
-- Athletic.net (Athletic.net blocks automated lookups, so it's a person checking): 'yes' = verified, 'no' = can't verify.
-- The Athletic.net profile link is optional (many parents won't have it); without it the admin searches by name + high
-- school. A mark that can't be verified must be run at the next available Valley United meet — high schoolers can sign
-- up early but can't run with Valley United until their high school (CIF) season is over, so "next available" = the
-- first Valley United meet after their CIF season ends (meet list: Settings, app_settings vus_meets_<season>).
-- The verification can't come from the form: it's stripped on sign-up and only vus_hs_verify sets it.
-- FIX (found 2026-11-15): the high school form sends gender 'Girl' / 'Boy' (like the rest of the app), but this table
-- only accepted 'Male' / 'Female', so every high school sign-up failed. Accept Boy / Girl (old values still allowed).
alter table public.postseason_registrations drop constraint if exists postseason_registrations_gender_check;
alter table public.postseason_registrations add constraint postseason_registrations_gender_check
  check (gender = any (array['Boy','Girl','Male','Female']));

alter table public.postseason_registrations add column if not exists athletic_net_url text;
alter table public.postseason_registrations add column if not exists high_school text;
alter table public.postseason_registrations add column if not exists cif_season_end date;      -- null + cif_done = already over
alter table public.postseason_registrations add column if not exists cif_done boolean not null default false;

create or replace function public.ps_hs_fill()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if public.is_vus_admin() then return new; end if;
  if coalesce(new.vyc_home_team,'') = 'HS' then
    if coalesce(new.athletic_net_url,'') <> '' and new.athletic_net_url !~* '^https?://([a-z0-9-]+\.)*athletic\.net/' then
      raise exception 'That link isn''t an Athletic.net link (it starts with https://www.athletic.net/). Leave it blank if you don''t have it.';
    end if;
    if coalesce(trim(new.high_school),'') = '' then raise exception 'Please enter the athlete''s high school.'; end if;
    if new.cif_season_end is null and not new.cif_done then
      raise exception 'Please tell us when the athlete''s high school (CIF) season ends, or that it''s already over.';
    end if;
  end if;
  new.events := (select coalesce(jsonb_agg(x - 'verified' - 'verified_by' - 'verified_at'), '[]'::jsonb)
                   from jsonb_array_elements(coalesce(new.events,'[]'::jsonb)) x);
  return new;
end $$;
drop trigger if exists ps_hs_fill_trg on public.postseason_registrations;
create trigger ps_hs_fill_trg before insert on public.postseason_registrations for each row execute function public.ps_hs_fill();

-- A Valley United admin marks one entered event as checked on Athletic.net: 'yes' = verified, 'no' = can't verify (must
-- run it at the next available Valley United meet), null = not checked yet.
create or replace function public.vus_hs_verify(p_id uuid, p_index integer, p_status text)
returns public.postseason_registrations language plpgsql security definer set search_path to 'public' as $$
declare h public.postseason_registrations;
begin
  if not public.is_vus_admin() then raise exception 'Only a Valley United admin can verify marks.'; end if;
  if p_status is not null and p_status not in ('yes','no') then raise exception 'Unknown status.'; end if;
  select * into h from public.postseason_registrations where id = p_id;
  if h.id is null then raise exception 'Sign-up not found.'; end if;
  if p_index < 0 or p_index >= jsonb_array_length(coalesce(h.events,'[]'::jsonb)) then raise exception 'Event not found.'; end if;
  update public.postseason_registrations set events = (
    select jsonb_agg(case when o - 1 = p_index then
             case when p_status is null then x - 'verified' - 'verified_by' - 'verified_at'
                  else x || jsonb_build_object('verified', p_status, 'verified_by', lower(auth.jwt()->>'email'), 'verified_at', now()) end
             else x end order by o)
    from jsonb_array_elements(h.events) with ordinality t(x, o))
   where id = p_id returning * into h;
  return h;
end $$;
grant execute on function public.vus_hs_verify(uuid, integer, text) to authenticated;

commit;
