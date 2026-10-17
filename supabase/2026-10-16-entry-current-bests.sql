-- ============================================================================
-- Meet entry: own team, this season, current best marks (2026-10-16, Riley)
-- (1) team_roster() also returns season_year, so the entry pages can show only athletes registered for the
--     meet's season (last season's roster is not eligible).
-- (2) athlete_bests(ids): each athlete's CURRENT best per event = the best mark from the most recent season in
--     which they have a result in that event. Looks across all of the athlete's registrations (a returning athlete's
--     2026 results hang off their 2026 registration; same person = same first/last name letters + birthday).
--     Only athletes the caller may manage (their team's coach / an admin / the parent). Locked teams' results stay
--     hidden unless the caller is a president, the Commissioner or a site admin.
-- ============================================================================
begin;

drop function if exists public.team_roster();
create function public.team_roster()
 returns table(id uuid, team_code text, first_name text, last_name text, gender text, division text, sport text, status text,
               age_on_dec31 integer, created_at timestamptz, comp_number integer, season_year integer)
 language sql stable security definer set search_path to 'public' as $$
  select r.id, r.team_code, r.first_name, r.last_name, r.gender, r.division, r.sport, r.status, r.age_on_dec31, r.created_at, r.comp_number, r.season_year
  from public.registrations r
  join public.coaches c on lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
  where c.approved = true
    and c.role_type is distinct from 'timer'
    and (c.is_admin or r.team_code = c.team_code)
    and (c.is_admin or c.role_type is distinct from 'division_coach'
         or coalesce(c.division_or_age_group,'') ilike 'all%'
         or ( r.division = any(string_to_array(replace(coalesce(c.division_or_age_group,''),', ',','),','))
              and ( c.coach_gender is null
                    or (case r.gender when 'Boy' then 'Boys' when 'Girl' then 'Girls' end)
                       = any(string_to_array(replace(c.coach_gender,', ',','),',')) ) ) )
$$;
revoke all on function public.team_roster() from public, anon;
grant execute on function public.team_roster() to authenticated;

create or replace function public.athlete_bests(p_regs uuid[])
 returns table(registration_id uuid, event_code text, event_name text, mark text, mark_value numeric, is_time boolean, season_year integer, meet_name text, meet_date date)
 language sql stable security definer set search_path to 'public' as $$
  with me as (select r.id, public.name_letters(r.first_name || r.last_name) nk, r.dob, r.prior_registration_id
              from public.registrations r where r.id = any(p_regs) and public.can_manage_athlete(r.id)),
  person as (  -- every registration that is this same athlete
    select me.id as reg, g.id as any_reg from me join public.registrations g
      on g.id = me.id or g.id = me.prior_registration_id
      or (me.dob is not null and g.dob = me.dob and public.name_letters(g.first_name || g.last_name) = me.nk)
  ),
  res as (
    select p.reg, x.event_code, x.event_name, x.mark, x.mark_value, x.is_time, m.season_year, m.name meet_name, m.meet_date
    from person p join public.results x on x.registration_id = p.any_reg
    join public.meets m on m.id = x.meet_id
    where not coalesce(x.is_relay,false) and x.mark_value is not null and x.mark_value > 0
      and (public.sees_locked_results() or not public.result_locked(x.meet_id, x.team_code, x.registration_id, x.athlete_name, x.is_relay))
  ),
  latest as (select reg, event_code, max(season_year) yr from res group by 1,2)
  select distinct on (r.reg, r.event_code) r.reg, r.event_code, r.event_name, r.mark, r.mark_value, r.is_time, r.season_year, r.meet_name, r.meet_date
  from res r join latest l on l.reg = r.reg and l.event_code = r.event_code and l.yr = r.season_year
  order by r.reg, r.event_code, case when r.is_time then r.mark_value else -r.mark_value end, r.meet_date desc
$$;
revoke all on function public.athlete_bests(uuid[]) from public, anon;
grant execute on function public.athlete_bests(uuid[]) to authenticated;

commit;
