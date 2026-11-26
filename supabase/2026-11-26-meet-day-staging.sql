-- ============================================================================
-- Meet Day Staging (2026-11-26, Riley)
-- Teams don't enter ahead of time: athletes are entered at the meet. This adds the staging page (staging.html):
--   * TRACK: at final call the stager ticks who is in the staging area. The app lists every certified athlete on that meet's
--     teams with this SEASON's best (FAT only, league meets in the app), puts them in heats fastest-heat-first and lanes them by
--     the VYC lane chart (Playing Rules XI). Each heat is saved here and becomes that meet's entries (rule IV.C.1 event limits
--     are enforced by check_entry, so a 5th event is refused).
--   * MEET MANAGER: the Meet Manager laptop downloads only the athletes it hasn't imported yet (Hy-Tek semicolon entries file).
--   * FIELD: field judges check athletes in at their event and record attempts; best mark kept per athlete.
-- Who can use it: site admins, team admins, approved timers, and Staging helpers (new list below, kept OUT of the coaches table
-- so a staging helper never gets any coach power).
-- ============================================================================
begin;

-- ---------- Staging helpers ----------
create table if not exists public.staging_helpers (
  email      text primary key check (email = lower(email)),
  name       text,
  active     boolean not null default true,
  added_by   text,
  added_at   timestamptz not null default now()
);
alter table public.staging_helpers enable row level security;
drop policy if exists "site admin all" on public.staging_helpers;
create policy "site admin all" on public.staging_helpers for all to authenticated
  using (public.is_site_admin() or public.is_team_admin()) with check (public.is_site_admin() or public.is_team_admin());
drop policy if exists "helper reads self" on public.staging_helpers;
create policy "helper reads self" on public.staging_helpers for select to authenticated
  using (email = lower(coalesce(auth.jwt()->>'email','')));

create or replace function public.can_stage() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.is_site_admin() or public.is_team_admin() or public.is_timer()
      or exists (select 1 from public.staging_helpers h where h.active and h.email = lower(coalesce(auth.jwt()->>'email','')))
$$;
revoke all on function public.can_stage() from public, anon;
grant execute on function public.can_stage() to authenticated;

-- ---------- Per-meet settings (lane count is decided at the track) ----------
create table if not exists public.stage_meet (
  meet_id    uuid primary key references public.meets(id) on delete cascade,
  lanes      integer not null default 8 check (lanes in (6,8,9)),
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table public.stage_meet enable row level security;
drop policy if exists "stagers read" on public.stage_meet;
create policy "stagers read" on public.stage_meet for select to authenticated using (public.can_stage());

-- ---------- Heats and lanes ----------
create table if not exists public.stage_heats (
  id          uuid primary key default gen_random_uuid(),
  meet_id     uuid not null references public.meets(id) on delete cascade,
  race_key    text not null,         -- event code + the division/gender groups in this race, e.g. 100|Gremlin|Girl  or  800|Bantam|Girl+Bantam|Boy
  event_code  text not null,         -- Hy-Tek code (100, 800, 400 = 4x100 relay, 1600 = 4x400 relay, 80H ...)
  event_name  text not null,
  is_relay    boolean not null default false,
  groups      jsonb not null,        -- [{"division":"Gremlin","gender":"Girl"}, ...]  (more than one = mixed race)
  heat_no     integer not null check (heat_no between 1 and 40),
  lanes_total integer not null check (lanes_total between 1 and 30),
  status      text not null default 'draft' check (status in ('draft','sent','run')),
  version     integer not null default 1,
  updated_by  text,
  updated_at  timestamptz not null default now(),
  unique (meet_id, race_key, heat_no)
);
create table if not exists public.stage_lanes (
  heat_id         uuid not null references public.stage_heats(id) on delete cascade,
  lane            integer not null check (lane between 1 and 30),
  registration_id uuid references public.registrations(id) on delete cascade,  -- individual races
  team_code       text not null,
  relay_letter    text check (relay_letter ~ '^[A-Z]$'),                     -- relays
  runners         uuid[],                                                    -- relays: legs 1-4 in order
  seed_mark       text,
  seed_value      numeric,
  exported_at     timestamptz,       -- when the Meet Manager laptop downloaded it
  primary key (heat_id, lane),
  check ((registration_id is not null and relay_letter is null) or (registration_id is null and relay_letter is not null and cardinality(runners) = 4))
);
create index if not exists stage_lanes_reg on public.stage_lanes(registration_id);
-- Athletes taken out of a heat AFTER Meet Manager already imported them: the laptop is told to scratch them.
create table if not exists public.stage_scratches (
  id           uuid primary key default gen_random_uuid(),
  meet_id      uuid not null references public.meets(id) on delete cascade,
  event_code   text not null,
  event_name   text not null,
  who          text not null,
  team_code    text,
  scratched_by text,
  scratched_at timestamptz not null default now(),
  done         boolean not null default false
);
alter table public.stage_heats enable row level security;
alter table public.stage_lanes enable row level security;
alter table public.stage_scratches enable row level security;
-- All writes go through the functions below; stagers may read.
drop policy if exists "stagers read" on public.stage_heats;
create policy "stagers read" on public.stage_heats for select to authenticated using (public.can_stage());
drop policy if exists "stagers read" on public.stage_lanes;
create policy "stagers read" on public.stage_lanes for select to authenticated using (public.can_stage());
drop policy if exists "stagers read" on public.stage_scratches;
create policy "stagers read" on public.stage_scratches for select to authenticated using (public.can_stage());

-- ---------- Field events ----------
create table if not exists public.field_marks (
  meet_id         uuid not null references public.meets(id) on delete cascade,
  event_code      text not null,         -- LJ, HJ, SP, JT
  registration_id uuid not null references public.registrations(id) on delete cascade,
  division        text not null,
  gender          text not null,
  checked_in      boolean not null default true,
  attempts        jsonb not null default '[]'::jsonb,  -- LJ/SP/JT: ["12-04.25","F","P",...]   HJ: [{"h":"4-02","r":"XO"}, ...]
  best_mark       text,                  -- feet-inches as Meet Manager takes it, e.g. 12-04.25
  best_value      numeric,               -- metres, for ranking
  updated_by      text,
  updated_at      timestamptz not null default now(),
  primary key (meet_id, event_code, registration_id)
);
alter table public.field_marks enable row level security;
drop policy if exists "stagers read" on public.field_marks;
create policy "stagers read" on public.field_marks for select to authenticated using (public.can_stage());

-- ---------- Entries made at staging may be made after entries close ----------
create or replace function public.check_entry() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare
  reg record; ev record; m record;
  cnt int; relay_cnt int; maxev int; relay_rule boolean;
begin
  select * into reg from public.registrations where id = new.registration_id;
  select * into ev  from public.meet_events   where id = new.meet_event_id;
  select * into m   from public.meets         where id = new.meet_id;
  if reg is null or ev is null or m is null then raise exception 'Bad entry'; end if;
  if ev.meet_id <> new.meet_id then raise exception 'Event does not belong to this meet'; end if;
  if reg.status <> 'verified' then raise exception 'Athlete is not certified yet'; end if;
  if not public.team_fees_cleared(reg.team_code, coalesce(m.season_year, reg.season_year)) then
    raise exception '%''s certification fees have not been confirmed paid by the Treasurer, so its athletes can''t be entered in meets yet (rule I.E). Only the Commissioner or the Conference President can overrule this.', reg.team_code;
  end if;
  if m.status <> 'open' or now() > m.entries_close then
    if not (public.is_coach() or public.can_stage()) then raise exception 'Entries for this meet are closed'; end if;
  end if;
  if (ev.division <> 'ALL' and ev.division <> reg.division) or (ev.gender <> 'Mixed' and ev.gender <> reg.gender) then
    raise exception 'Event is not for this athlete''s division/gender';
  end if;
  select count(*), count(*) filter (where e2.is_relay) into cnt, relay_cnt
    from public.entries e join public.meet_events e2 on e2.id = e.meet_event_id
    where e.registration_id = new.registration_id and e.meet_id = new.meet_id
      and e.id is distinct from new.id;
  cnt := cnt + 1; if ev.is_relay then relay_cnt := relay_cnt + 1; end if;
  select l.max_events, l.relay_required_for_max into maxev, relay_rule from public.entry_limits l where l.division = reg.division;
  if maxev is null then
    maxev := case when reg.division in ('Sub-Gremlin','Gremlin') then 3 else 4 end;
    relay_rule := reg.division in ('Bantam','Juniors','Youth');
  end if;
  if cnt > maxev then raise exception 'Max % events for %', maxev, reg.division; end if;
  if relay_rule and cnt = maxev and relay_cnt = 0 then
    raise exception '% may only have % events if one is a relay', reg.division, maxev;
  end if;
  return new;
end $$;

-- ---------- Helpers ----------
create or replace function public.stage_guard() returns void
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.can_stage() then raise exception 'Only admins, timers and staging helpers can use meet-day staging.'; end if;
end $$;

-- The meet event an athlete is entered under (their own division + gender); created if the meet doesn't have it yet.
create or replace function public.stage_meet_event(p_meet uuid, p_code text, p_name text, p_div text, p_gender text, p_relay boolean)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v uuid;
begin
  select id into v from public.meet_events where meet_id = p_meet and code = p_code and division = p_div and gender = p_gender and is_relay = p_relay limit 1;
  if v is null then
    insert into public.meet_events (meet_id, code, name, division, gender, is_relay, is_field)
    values (p_meet, p_code, p_name, p_div, p_gender, p_relay, p_code in ('LJ','HJ','SP','JT','TJ','PV','DT','HT'))
    on conflict (meet_id, code, division, gender, is_relay) do update set name = excluded.name
    returning id into v;
  end if;
  return v;
end $$;
revoke all on function public.stage_meet_event(uuid,text,text,text,text,boolean) from public, anon, authenticated;

-- Everything the staging page needs for one meet, in one call:
--   athletes  = certified athletes of the meet's teams (meets.team_codes; all teams when empty) for the meet's season
--   bests     = each athlete's best mark THIS season per individual event (results from this season's meets)
--   relays    = each team's relay marks this season per event/division/gender, best first
--   entries   = what each athlete is already entered in at this meet (for the event limits)
create or replace function public.staging_board(p_meet uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare m record; yr int; out jsonb;
begin
  perform public.stage_guard();
  select * into m from public.meets where id = p_meet;
  if m is null then raise exception 'Meet not found'; end if;
  yr := coalesce(m.season_year, public.current_season());
  with ath as (
    select r.id, r.first_name, r.last_name, r.gender, r.division, r.team_code, r.comp_number, r.dob, r.age_on_dec31
      from public.registrations r
     where r.status = 'verified' and r.season_year = yr
       and coalesce(r.sport,'Track & Field') = 'Track & Field'
       and (coalesce(cardinality(m.team_codes),0) = 0 or r.team_code = any(m.team_codes))
  ),
  res as (
    select x.registration_id reg, x.event_code, x.mark, x.mark_value, x.is_time, mm.meet_date
      from public.results x join public.meets mm on mm.id = x.meet_id
     where mm.season_year = yr and not coalesce(x.is_relay,false)
       and x.registration_id in (select id from ath)
       and x.mark_value is not null and x.mark_value > 0
       and (public.sees_locked_results() or not public.result_locked(x.meet_id, x.team_code, x.registration_id, x.athlete_name, x.is_relay))
  ),
  best as (
    select distinct on (reg, event_code) reg, event_code, mark, mark_value, is_time
      from res order by reg, event_code, case when is_time then mark_value else -mark_value end, meet_date desc
  ),
  rel as (
    select x.team_code, x.division, x.gender, x.event_code, x.mark, x.mark_value, mm.meet_date, mm.name meet_name
      from public.results x join public.meets mm on mm.id = x.meet_id
     where mm.season_year = yr and coalesce(x.is_relay,false) and x.is_time
       and x.mark_value is not null and x.mark_value > 0
       and (coalesce(cardinality(m.team_codes),0) = 0 or x.team_code = any(m.team_codes))
  ),
  ent as (
    select e.registration_id reg, ev.code event_code, ev.is_relay, e.relay_team, e.leg, coalesce(e.entered_by,'') entered_by
      from public.entries e join public.meet_events ev on ev.id = e.meet_event_id
     where e.meet_id = p_meet
  )
  select jsonb_build_object(
    'meet', jsonb_build_object('id', m.id, 'name', m.name, 'meet_date', m.meet_date, 'season_year', yr, 'team_codes', m.team_codes,
                               'venue', m.venue, 'host_team_code', m.host_team_code,
                               'lanes', coalesce((select s.lanes from public.stage_meet s where s.meet_id = m.id), 0)),
    'athletes', coalesce((select jsonb_agg(to_jsonb(a)) from ath a), '[]'::jsonb),
    'bests',    coalesce((select jsonb_agg(to_jsonb(b)) from best b), '[]'::jsonb),
    'relays',   coalesce((select jsonb_agg(to_jsonb(r) order by r.mark_value) from rel r), '[]'::jsonb),
    'entries',  coalesce((select jsonb_agg(to_jsonb(e)) from ent e), '[]'::jsonb)
  ) into out;
  return out;
end $$;
revoke all on function public.staging_board(uuid) from public, anon;
grant execute on function public.staging_board(uuid) to authenticated;

create or replace function public.staging_meets() returns setof public.meets
language sql stable security definer set search_path to 'public' as $$
  select m.* from public.meets m
   where public.can_stage()
     and coalesce(m.season_year, public.current_season()) >= public.current_season() - 1
   order by m.meet_date desc
$$;
revoke all on function public.staging_meets() from public, anon;
grant execute on function public.staging_meets() to authenticated;

create or replace function public.staging_set_lanes(p_meet uuid, p_lanes int) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.stage_guard();
  insert into public.stage_meet (meet_id, lanes, updated_by) values (p_meet, p_lanes, auth.jwt()->>'email')
  on conflict (meet_id) do update set lanes = excluded.lanes, updated_by = excluded.updated_by, updated_at = now();
end $$;
revoke all on function public.staging_set_lanes(uuid,int) from public, anon;
grant execute on function public.staging_set_lanes(uuid,int) to authenticated;

-- Heats of a meet with their lanes (for the stagers' screens and the Meet Manager laptop).
create or replace function public.staging_heats(p_meet uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public.stage_guard();
  return coalesce((
    select jsonb_agg(to_jsonb(h) || jsonb_build_object('lanes',
             coalesce((select jsonb_agg(to_jsonb(l) order by l.lane) from public.stage_lanes l where l.heat_id = h.id), '[]'::jsonb))
           order by h.event_code, h.race_key, h.heat_no)
      from public.stage_heats h where h.meet_id = p_meet), '[]'::jsonb);
end $$;
revoke all on function public.staging_heats(uuid) from public, anon;
grant execute on function public.staging_heats(uuid) to authenticated;

-- Take the entries made at staging for one event in step with what is now in its heats.
create or replace function public.stage_sync_entries(p_meet uuid, p_code text, p_relay boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
declare r record; evid uuid; who text := 'staging:' || coalesce(auth.jwt()->>'email','');
begin
  -- who should be entered in this event (individual athletes, and relay runners with their team letter + leg)
  create temp table if not exists _want (reg uuid, relay text, leg int, code text, name text, is_relay boolean, seed text) on commit drop;
  delete from _want where true;   -- (live database requires a WHERE on every DELETE)
  insert into _want
    select l.registration_id, null, null, h.event_code, h.event_name, false, l.seed_mark
      from public.stage_heats h join public.stage_lanes l on l.heat_id = h.id
     where h.meet_id = p_meet and h.event_code = p_code and not p_relay and not h.is_relay and l.registration_id is not null
    union all
    select u.reg, l.relay_letter, u.ord::int, h.event_code, h.event_name, true, null
      from public.stage_heats h join public.stage_lanes l on l.heat_id = h.id
      cross join lateral unnest(l.runners) with ordinality as u(reg, ord)
     where h.meet_id = p_meet and h.event_code = p_code and p_relay and h.is_relay;
  -- drop staging-made entries that are no longer in a heat
  delete from public.entries e using public.meet_events ev
   where ev.id = e.meet_event_id and e.meet_id = p_meet and ev.code = p_code
     and e.entered_by like 'staging:%'
     and ev.is_relay = p_relay and ev.is_field = false
     and not exists (select 1 from _want w where w.reg = e.registration_id);
  -- add / update the rest (check_entry refuses anything over the rule IV.C.1 limits)
  for r in select w.*, g.division, g.gender, g.first_name, g.last_name from _want w join public.registrations g on g.id = w.reg loop
    evid := public.stage_meet_event(p_meet, r.code, r.name, r.division, r.gender, r.is_relay);
    begin
      -- already entered: just update (check_entry runs BEFORE INSERT and would count the existing entry twice)
      update public.entries set relay_team = r.relay, leg = r.leg where registration_id = r.reg and meet_event_id = evid;
      if not found then
        insert into public.entries (meet_id, registration_id, meet_event_id, entered_by, seed_mark, relay_team, leg)
        values (p_meet, r.reg, evid, who, r.seed, r.relay, r.leg);
      end if;
    exception when others then
      raise exception '% % can''t be entered in the %: %', r.first_name, r.last_name, r.name, sqlerrm;
    end;
  end loop;
end $$;
revoke all on function public.stage_sync_entries(uuid,text,boolean) from public, anon, authenticated;

-- Save one heat (create or replace its lanes). p:
--  {meet_id, race_key, event_code, event_name, is_relay, groups, heat_no, lanes_total, status,
--   lanes:[{lane, registration_id | relay_letter+team_code+runners[4], team_code, seed_mark, seed_value}]}
create or replace function public.staging_save_heat(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare hid uuid; v int; m uuid := (p->>'meet_id')::uuid; code text := p->>'event_code'; x jsonb; old record; who text := auth.jwt()->>'email';
begin
  perform public.stage_guard();
  if public.meet_is_locked(m) then raise exception 'This meet''s season is locked.'; end if;
  insert into public.stage_heats (meet_id, race_key, event_code, event_name, is_relay, groups, heat_no, lanes_total, status, updated_by)
  values (m, p->>'race_key', code, p->>'event_name', coalesce((p->>'is_relay')::boolean,false), p->'groups', (p->>'heat_no')::int,
          (p->>'lanes_total')::int, coalesce(p->>'status','draft'), who)
  on conflict (meet_id, race_key, heat_no) do update
     set event_name = excluded.event_name, groups = excluded.groups, lanes_total = excluded.lanes_total,
         status = excluded.status, version = public.stage_heats.version + 1, updated_by = who, updated_at = now()
  returning id, version into hid, v;

  -- keep "already in Meet Manager" for athletes/relays who stay in this heat; tell the laptop to scratch any that leave
  create temp table if not exists _old (lane int, registration_id uuid, relay_letter text, team_code text, runners uuid[], exported_at timestamptz) on commit drop;
  delete from _old where true;
  insert into _old select l.lane, l.registration_id, l.relay_letter, l.team_code, l.runners, l.exported_at from public.stage_lanes l where l.heat_id = hid;
  delete from public.stage_lanes where heat_id = hid;
  for x in select * from jsonb_array_elements(coalesce(p->'lanes','[]'::jsonb)) loop
    insert into public.stage_lanes (heat_id, lane, registration_id, team_code, relay_letter, runners, seed_mark, seed_value, exported_at)
    values (hid, (x->>'lane')::int, nullif(x->>'registration_id','')::uuid, x->>'team_code', nullif(x->>'relay_letter',''),
            case when x ? 'runners' and jsonb_typeof(x->'runners') = 'array' then array(select jsonb_array_elements_text(x->'runners')::uuid) end,
            nullif(x->>'seed_mark',''), nullif(x->>'seed_value','')::numeric,
            (select o.exported_at from _old o
              where (o.registration_id is not null and o.registration_id = nullif(x->>'registration_id','')::uuid)
                 or (o.relay_letter is not null and o.relay_letter = x->>'relay_letter' and o.team_code = x->>'team_code'
                     and o.runners = array(select jsonb_array_elements_text(coalesce(x->'runners','[]'::jsonb))::uuid))
              limit 1));
  end loop;
  -- a relay is 4 different runners from that team; nobody (and no relay team) is in the same race twice
  if exists (select 1 from public.stage_lanes l where l.heat_id = hid and l.runners is not null
              and ((select count(distinct u) from unnest(l.runners) u) <> 4
                   or exists (select 1 from unnest(l.runners) u left join public.registrations g on g.id = u where g.id is null or g.team_code <> l.team_code))) then
    raise exception 'A relay needs 4 different runners from its own team.';
  end if;
  if exists (select 1 from public.stage_lanes l join public.stage_heats h on h.id = l.heat_id
              where h.meet_id = m and h.race_key = p->>'race_key' and l.registration_id is not null
              group by l.registration_id having count(*) > 1)
     or exists (select 1 from public.stage_lanes l join public.stage_heats h on h.id = l.heat_id
              where h.meet_id = m and h.race_key = p->>'race_key' and l.relay_letter is not null
              group by l.team_code, l.relay_letter having count(*) > 1)
     or exists (select 1 from public.stage_lanes l join public.stage_heats h on h.id = l.heat_id cross join unnest(l.runners) u
              where h.meet_id = m and h.race_key = p->>'race_key' group by u having count(*) > 1) then
    raise exception 'Someone is in this race twice (another heat already has them).';
  end if;
  -- moved to another heat of the same race = still in Meet Manager: carry exported_at across
  update public.stage_lanes l set exported_at = o.exported_at
    from _old o
   where l.heat_id = hid and l.exported_at is null and o.exported_at is not null and o.registration_id = l.registration_id;
  insert into public.stage_scratches (meet_id, event_code, event_name, who, team_code, scratched_by)
  select m, code, p->>'event_name',
         case when o.registration_id is not null then (select g.first_name || ' ' || g.last_name from public.registrations g where g.id = o.registration_id)
              else o.team_code || ' relay ' || o.relay_letter end,
         o.team_code, who
    from _old o
   where o.exported_at is not null
     and not exists (select 1 from public.stage_lanes l join public.stage_heats h on h.id = l.heat_id
                      where h.meet_id = m and h.race_key = p->>'race_key'
                        and ((o.registration_id is not null and l.registration_id = o.registration_id)
                          or (o.relay_letter is not null and l.relay_letter = o.relay_letter and l.team_code = o.team_code)));
  perform public.stage_sync_entries(m, code, coalesce((p->>'is_relay')::boolean,false));
  return jsonb_build_object('id', hid, 'version', v);
end $$;
revoke all on function public.staging_save_heat(jsonb) from public, anon;
grant execute on function public.staging_save_heat(jsonb) to authenticated;

create or replace function public.staging_set_status(p_heat uuid, p_status text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.stage_guard();
  update public.stage_heats set status = p_status, updated_by = auth.jwt()->>'email', updated_at = now() where id = p_heat;
end $$;
revoke all on function public.staging_set_status(uuid,text) from public, anon;
grant execute on function public.staging_set_status(uuid,text) to authenticated;

create or replace function public.staging_delete_heat(p_heat uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare h record;
begin
  perform public.stage_guard();
  select * into h from public.stage_heats where id = p_heat;
  if h is null then return; end if;
  insert into public.stage_scratches (meet_id, event_code, event_name, who, team_code, scratched_by)
  select h.meet_id, h.event_code, h.event_name,
         case when l.registration_id is not null then (select g.first_name || ' ' || g.last_name from public.registrations g where g.id = l.registration_id)
              else l.team_code || ' relay ' || l.relay_letter end, l.team_code, auth.jwt()->>'email'
    from public.stage_lanes l where l.heat_id = p_heat and l.exported_at is not null;
  delete from public.stage_heats where id = p_heat;
  perform public.stage_sync_entries(h.meet_id, h.event_code, h.is_relay);
end $$;
revoke all on function public.staging_delete_heat(uuid) from public, anon;
grant execute on function public.staging_delete_heat(uuid) to authenticated;

-- Meet Manager laptop: everything not imported yet, with what the Hy-Tek file needs. p_mark = true marks them imported.
create or replace function public.staging_export(p_meet uuid, p_mark boolean default false) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare out jsonb;
begin
  perform public.stage_guard();
  select coalesce(jsonb_agg(jsonb_build_object(
           'heat_id', h.id, 'lane', l.lane, 'heat_no', h.heat_no, 'race_key', h.race_key, 'event_code', h.event_code, 'event_name', h.event_name,
           'is_relay', h.is_relay, 'seed_mark', l.seed_mark, 'team_code', l.team_code, 'relay_letter', l.relay_letter,
           'athlete', (select to_jsonb(g) from (select r.id, r.first_name, r.last_name, r.gender, r.dob, r.division, r.age_on_dec31, r.team_code, r.comp_number
                                                  from public.registrations r where r.id = l.registration_id) g),
           'runners', (select jsonb_agg(to_jsonb(g) order by g.ord) from (select r.id, r.first_name, r.last_name, r.gender, r.dob, r.division, r.age_on_dec31, r.team_code, r.comp_number, u.ord
                                                  from unnest(l.runners) with ordinality u(reg, ord) join public.registrations r on r.id = u.reg) g)
         ) order by h.event_code, h.race_key, h.heat_no, l.lane), '[]'::jsonb)
    into out
    from public.stage_heats h join public.stage_lanes l on l.heat_id = h.id
   where h.meet_id = p_meet and h.status in ('sent','run') and l.exported_at is null;
  if p_mark then
    update public.stage_lanes l set exported_at = now()
      from public.stage_heats h
     where h.id = l.heat_id and h.meet_id = p_meet and h.status in ('sent','run') and l.exported_at is null;
  end if;
  return out;
end $$;
revoke all on function public.staging_export(uuid,boolean) from public, anon;
grant execute on function public.staging_export(uuid,boolean) to authenticated;

create or replace function public.staging_scratch_done(p_id uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.stage_guard();
  update public.stage_scratches set done = true where id = p_id;
end $$;
revoke all on function public.staging_scratch_done(uuid) from public, anon;
grant execute on function public.staging_scratch_done(uuid) to authenticated;

-- Field events: check in / record attempts. Checking in enters the athlete in the event (limits enforced); un-checking removes
-- the entry only if staging made it.
create or replace function public.staging_save_field(p jsonb) returns void
language plpgsql security definer set search_path to 'public' as $$
declare m uuid := (p->>'meet_id')::uuid; code text := p->>'event_code'; reg record; evid uuid; who text := auth.jwt()->>'email';
begin
  perform public.stage_guard();
  if public.meet_is_locked(m) then raise exception 'This meet''s season is locked.'; end if;
  select * into reg from public.registrations where id = (p->>'registration_id')::uuid;
  if reg is null then raise exception 'Athlete not found'; end if;
  insert into public.field_marks (meet_id, event_code, registration_id, division, gender, checked_in, attempts, best_mark, best_value, updated_by)
  values (m, code, reg.id, reg.division, reg.gender, coalesce((p->>'checked_in')::boolean,true), coalesce(p->'attempts','[]'::jsonb),
          nullif(p->>'best_mark',''), nullif(p->>'best_value','')::numeric, who)
  on conflict (meet_id, event_code, registration_id) do update
     set checked_in = excluded.checked_in, attempts = excluded.attempts, best_mark = excluded.best_mark,
         best_value = excluded.best_value, updated_by = who, updated_at = now();
  evid := public.stage_meet_event(m, code, p->>'event_name', reg.division, reg.gender, false);
  if coalesce((p->>'checked_in')::boolean,true) then
    begin
      if not exists (select 1 from public.entries where registration_id = reg.id and meet_event_id = evid) then
        insert into public.entries (meet_id, registration_id, meet_event_id, entered_by)
        values (m, reg.id, evid, 'staging:' || coalesce(who,''));
      end if;
    exception when others then
      raise exception '% % can''t be entered in the %: %', reg.first_name, reg.last_name, p->>'event_name', sqlerrm;
    end;
  else
    delete from public.entries where meet_id = m and registration_id = reg.id and meet_event_id = evid and entered_by like 'staging:%';
  end if;
end $$;
revoke all on function public.staging_save_field(jsonb) from public, anon;
grant execute on function public.staging_save_field(jsonb) to authenticated;

create or replace function public.staging_field(p_meet uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public.stage_guard();
  return coalesce((select jsonb_agg(to_jsonb(f)) from public.field_marks f where f.meet_id = p_meet), '[]'::jsonb);
end $$;
revoke all on function public.staging_field(uuid) from public, anon;
grant execute on function public.staging_field(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
