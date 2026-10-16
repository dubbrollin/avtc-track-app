-- ============================================================================
-- (1) Every uploaded result is linked to the athlete's registration (2026-10-16)
-- Riley: "All uploaded results should be linked to a registration" — that's how a parent sees their own athlete's results.
-- The upload pages matched by exact name against VERIFIED athletes only, ignoring team and season, so most rows
-- landed with no registration_id. Now the database links every individual (non-relay) result itself, whichever
-- way it arrives (file upload, Meet Manager live connection, printed results):
--   same team + same first/last name (letters only, any case), not rejected, preferring the meet's own season,
--   then the most recent season. A link the upload supplied is kept only if it's the same team.
-- Relay rows stay team rows (no single athlete).
-- (2) Results lockout is WHOLE-TEAM only (Riley): athlete-level locks removed.
-- ============================================================================
begin;

create or replace function public.name_letters(t text) returns text
language sql immutable as $$ select lower(regexp_replace(coalesce(t,''), '[^a-zA-Z]', '', 'g')) $$;

-- Speeds up the name lookup.
create index if not exists registrations_name_letters on public.registrations (team_code, public.name_letters(first_name || last_name));

-- Letters only, without Jr./Sr./II/III/IV (meet files and the roster disagree on suffixes).
create or replace function public.name_core(t text) returns text
language sql immutable as $$ select public.name_letters(regexp_replace(lower(coalesce(t,'')), '\m(jr|sr|ii|iii|iv)\M\.?', '', 'g')) $$;

create or replace function public.match_result_registration(p_meet uuid, p_team text, p_name text) returns uuid
language plpgsql stable security definer set search_path to 'public' as $$
declare t text := case upper(coalesce(p_team,'')) when 'RUSH' then 'SFR' else upper(coalesce(p_team,'')) end;
        yr int := (select m.season_year from public.meets m where m.id = p_meet);
        r text := public.name_core(p_name); hit uuid; people int;
begin
  if t = '' or r = '' then return null; end if;
  -- 1) exact: same team, same first+last name
  select g.id into hit from public.registrations g
  where g.team_code = t and public.name_letters(g.first_name || g.last_name) = public.name_letters(p_name) and g.status is distinct from 'rejected'
  order by (g.season_year = yr) desc nulls last, g.season_year desc nulls last, g.created_at desc limit 1;
  if hit is not null then return hit; end if;
  -- 2) careful: the roster import cut long names short ("Taupier-Shevlof") and suffixes differ ("Neal" / "Neal Jr.").
  --    Same team; the result starts with the registered first name; and the registered last name is inside the result,
  --    or the rest of the result is the start of the registered last name. Only when exactly ONE person fits.
  select count(distinct public.name_core(g.first_name || g.last_name)) into people from public.registrations g
  where g.team_code = t and g.status is distinct from 'rejected' and length(public.name_letters(g.first_name)) >= 2 and length(public.name_core(g.last_name)) >= 2
    and r like public.name_letters(g.first_name) || '%'
    and (position(public.name_core(g.last_name) in r) > 0 or public.name_core(g.last_name) like substr(r, length(public.name_letters(g.first_name)) + 1) || '%');
  if people <> 1 then return null; end if;
  select g.id into hit from public.registrations g
  where g.team_code = t and g.status is distinct from 'rejected' and length(public.name_letters(g.first_name)) >= 2 and length(public.name_core(g.last_name)) >= 2
    and r like public.name_letters(g.first_name) || '%'
    and (position(public.name_core(g.last_name) in r) > 0 or public.name_core(g.last_name) like substr(r, length(public.name_letters(g.first_name)) + 1) || '%')
  order by (g.season_year = yr) desc nulls last, g.season_year desc nulls last, g.created_at desc limit 1;
  return hit;
end $$;

create or replace function public.results_link_registration() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(new.is_relay, false) then return new; end if;
  if new.registration_id is not null and exists (
       select 1 from public.registrations g where g.id = new.registration_id
       and (new.team_code is null or g.team_code = case upper(new.team_code) when 'RUSH' then 'SFR' else upper(new.team_code) end)) then
    return new;
  end if;
  new.registration_id := coalesce(public.match_result_registration(new.meet_id, new.team_code, new.athlete_name), new.registration_id);
  return new;
end $$;
drop trigger if exists results_link_registration on public.results;
create trigger results_link_registration before insert or update of athlete_name, team_code, registration_id on public.results
  for each row execute function public.results_link_registration();

-- Uploaders' matching list: every athlete that isn't rejected (not just certified), oldest season first so the
-- newest record wins on the page; the database trigger above has the final say.
drop function if exists public.results_athletes();
create function public.results_athletes() returns table(id uuid, first_name text, last_name text, gender text, division text, team_code text)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.can_upload_results() then raise exception 'Only admins and approved timers can upload results.'; end if;
  return query select r.id, r.first_name, r.last_name, r.gender, r.division, r.team_code
    from public.registrations r where r.status is distinct from 'rejected' order by r.season_year nulls first, r.created_at;
end $$;
revoke all on function public.results_athletes() from public, anon;
grant execute on function public.results_athletes() to authenticated;

-- ---------- (2) lockout: whole team only ----------
create or replace function public.result_locked(p_meet uuid, p_team text, p_reg uuid, p_name text, p_relay boolean) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.results_lockouts l
    join public.meets m on m.id = p_meet and m.season_year = l.season_year
    where l.lifted_at is null and l.registration_id is null
      and l.team_code = case upper(coalesce(p_team,'')) when 'RUSH' then 'SFR' else upper(coalesce(p_team,'')) end
  )
$$;
create or replace function public.lock_results(p_team text, p_registration uuid, p_reason text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me text := lower(coalesce(auth.jwt()->>'email','')); t text := upper(trim(coalesce(p_team,''))); nid uuid;
begin
  if p_registration is not null then raise exception 'Lockouts are for a whole team.'; end if;
  if t = '' or not exists (select 1 from public.league_teams where code = t) then raise exception 'Team not found.'; end if;
  if not public.can_lock_results(t) then raise exception 'Only the Commissioner or that conference''s president can lock results.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Give a reason (for example: team fees unpaid).'; end if;
  insert into public.results_lockouts (season_year, team_code, reason, locked_by)
  values (public.current_season(), t, trim(p_reason), me) returning id into nid;
  return nid;
exception when unique_violation then raise exception 'That team is already locked.';
end $$;
update public.results_lockouts set lifted_at = now(), lifted_by = 'system', lift_note = 'Athlete locks retired: lockouts are whole-team only'
  where registration_id is not null and lifted_at is null;

-- ---------- (3) link the results already uploaded ----------
-- (touching athlete_name fires the trigger; past-season results are normally locked, this is maintenance by the database owner)
alter table public.results disable trigger user;
alter table public.results enable trigger results_link_registration;
update public.results set athlete_name = athlete_name where not coalesce(is_relay,false);
alter table public.results enable trigger user;

commit;
