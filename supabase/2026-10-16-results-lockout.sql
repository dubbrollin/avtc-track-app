-- ============================================================================
-- Results lockout (2026-10-16, Riley's spec)
-- When a team owes fees or fines, a conference president (own conference's teams/athletes) or the Commissioner
-- (any team) can LOCK a whole team's results, or one athlete's results, for a season.
--   * Locked results are hidden from EVERYONE (public, the team's own coaches and parents) except the two
--     presidents, the Commissioner and site admins.
--   * Other athletes keep the place they earned (rows are only hidden, never re-scored).
--   * Manual only: nothing locks automatically. Unlocking = the same people.
--   * Enforced in the database (results read policies), so every page — Results, Live, Rankings, Schedule
--     result counts, the season_best view — hides them, and nobody can read them around the app.
-- Athlete match: the result's registration link, OR same team + same "First Last" name (most uploaded
-- results aren't linked to a registration). Relay rows are hidden only by a TEAM lock.
-- ============================================================================
begin;

create table if not exists public.results_lockouts (
  id uuid primary key default gen_random_uuid(),
  season_year int not null,
  team_code text not null,
  registration_id uuid references public.registrations(id) on delete cascade, -- null = the whole team
  athlete_name text,                                                           -- "First Last" for athlete locks
  name_key text,                                                               -- lower(trim) of athlete_name
  reason text not null,
  locked_by text not null,
  locked_at timestamptz not null default now(),
  lifted_by text,
  lifted_at timestamptz,
  lift_note text
);
create unique index if not exists results_lockouts_one_active
  on public.results_lockouts (season_year, team_code, coalesce(registration_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where lifted_at is null;
create index if not exists results_lockouts_active on public.results_lockouts (team_code) where lifted_at is null;

alter table public.results_lockouts enable row level security;
-- Signed-in users can see which locks exist (a coach sees why their team's results are missing). Writes only via the functions below.
drop policy if exists "signed in read lockouts" on public.results_lockouts;
create policy "signed in read lockouts" on public.results_lockouts for select to authenticated using (true);
revoke all on public.results_lockouts from anon;
grant select on public.results_lockouts to authenticated;

-- Who may lock/unlock this team: the Commissioner, or the president of the team's conference.
create or replace function public.can_lock_results(p_team text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.is_commissioner() or public.is_president_of(public.team_conference(p_team))
$$;

-- Who still sees locked results: either president, the Commissioner, site admins.
create or replace function public.sees_locked_results() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.is_site_admin() or public.is_commissioner() or public.is_president_of('East') or public.is_president_of('West')
$$;

-- Is this result row locked? (active lock for the meet's season on the team, or on this athlete)
create or replace function public.result_locked(p_meet uuid, p_team text, p_reg uuid, p_name text, p_relay boolean) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.results_lockouts l
    join public.meets m on m.id = p_meet and m.season_year = l.season_year
    where l.lifted_at is null
      and l.team_code = case upper(coalesce(p_team,'')) when 'RUSH' then 'SFR' else upper(coalesce(p_team,'')) end
      and ( l.registration_id is null
            or ( not coalesce(p_relay,false)
                 and ( l.registration_id = p_reg or l.name_key = lower(trim(coalesce(p_name,''))) ) ) )
  )
$$;
grant execute on function public.result_locked(uuid, text, uuid, text, boolean) to anon, authenticated;
grant execute on function public.sees_locked_results() to anon, authenticated;
grant execute on function public.can_lock_results(text) to authenticated;

-- ---------- results: hide locked rows ----------
drop policy if exists "public read results" on public.results;
create policy "public read results" on public.results for select to anon
  using (not public.result_locked(meet_id, team_code, registration_id, athlete_name, is_relay));
drop policy if exists "logged in read results" on public.results;
create policy "logged in read results" on public.results for select to authenticated
  using (public.sees_locked_results() or not public.result_locked(meet_id, team_code, registration_id, athlete_name, is_relay));
-- ("site admin all" still lets site admins see everything.)

-- ---------- lock / unlock ----------
create or replace function public.lock_results(p_team text, p_registration uuid, p_reason text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me text := lower(coalesce(auth.jwt()->>'email','')); t text := upper(trim(coalesce(p_team,''))); r public.registrations; nid uuid; nm text;
begin
  if p_registration is not null then
    select * into r from public.registrations where id = p_registration;
    if r.id is null then raise exception 'Athlete not found.'; end if;
    t := r.team_code; nm := trim(r.first_name)||' '||trim(r.last_name);
  end if;
  if t = '' or not exists (select 1 from public.league_teams where code = t) then raise exception 'Team not found.'; end if;
  if not public.can_lock_results(t) then raise exception 'Only the Commissioner or that conference''s president can lock results.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Give a reason (for example: team fees unpaid).'; end if;
  insert into public.results_lockouts (season_year, team_code, registration_id, athlete_name, name_key, reason, locked_by)
  values (public.current_season(), t, p_registration, nm, lower(nm), trim(p_reason), me)
  returning id into nid;
  return nid;
exception when unique_violation then raise exception 'That is already locked.';
end $$;

create or replace function public.unlock_results(p_lock uuid, p_note text default null) returns void
language plpgsql security definer set search_path to 'public' as $$
declare l public.results_lockouts;
begin
  select * into l from public.results_lockouts where id = p_lock;
  if l.id is null or l.lifted_at is not null then raise exception 'That lock is not active.'; end if;
  if not public.can_lock_results(l.team_code) then raise exception 'Only the Commissioner or that conference''s president can unlock results.'; end if;
  update public.results_lockouts set lifted_at = now(), lifted_by = lower(coalesce(auth.jwt()->>'email','')), lift_note = nullif(trim(coalesce(p_note,'')),'')
  where id = p_lock;
end $$;
revoke all on function public.lock_results(text, uuid, text) from public, anon;
revoke all on function public.unlock_results(uuid, text) from public, anon;
grant execute on function public.lock_results(text, uuid, text) to authenticated;
grant execute on function public.unlock_results(uuid, text) to authenticated;

commit;
