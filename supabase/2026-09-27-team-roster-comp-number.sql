-- 2026-09-27: include the competition number in the coaches' safe roster view.
begin;
drop function if exists public.team_roster();
create function public.team_roster()
returns table(id uuid, team_code text, first_name text, last_name text, gender text, division text, sport text, status text, age_on_dec31 integer, created_at timestamptz, comp_number integer)
language sql stable security definer set search_path to 'public' as $$
  select r.id, r.team_code, r.first_name, r.last_name, r.gender, r.division, r.sport, r.status, r.age_on_dec31, r.created_at, r.comp_number
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
grant execute on function public.team_roster() to authenticated;
commit;
