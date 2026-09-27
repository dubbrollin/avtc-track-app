-- 2026-09-27: "Is this your athlete?" lookup on the registration form.
-- As a parent types a last name (3+ letters), the form lists LAST season's athletes league-wide with that
-- last name. Only first name, last name, team and division are returned: no birth dates, parents,
-- addresses or anything else. Picking one links the new registration to it (prior_registration_id), so a
-- different team becomes a declared transfer and the same team is a returning athlete.
begin;

alter table public.registrations add column if not exists prior_registration_id uuid references public.registrations(id) on delete set null;

create or replace function public.find_returning_athletes(p_last text)
returns table (id uuid, first_name text, last_name text, team_code text, division text, season_year integer)
language sql stable security definer set search_path to 'public' as $$
  select r.id, r.first_name, r.last_name, r.team_code, r.division, r.season_year
  from public.registrations r
  where length(public.name_key(p_last)) >= 3
    and r.status = 'verified'
    and r.season_year < coalesce((select nullif(value,'')::int from public.app_settings where key = 'season_year'), extract(year from now())::int + 1)
    and public.name_key(r.last_name) like public.name_key(p_last) || '%'
  order by r.last_name, r.first_name
  limit 15
$$;
revoke all on function public.find_returning_athletes(text) from public;
grant execute on function public.find_returning_athletes(text) to anon, authenticated;

-- When the parent picked last season's athlete, use that exact record as the match evidence.
create or replace function public.reg_make_clearance() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare m record; d record;
begin
  -- Declared by the parent (typed/picked the old team, or picked last season's athlete from another team).
  if new.prior_team_code is not null and new.prior_team_code is distinct from new.team_code then
    select r.id,
           r.dob = new.dob as mdob,
           exists (select 1 from unnest(array[r.parent1_name, r.parent2_name]) a(p), unnest(array[new.parent1_name, new.parent2_name]) b(p)
                   where public.name_key(a.p) <> '' and public.name_key(a.p) = public.name_key(b.p)) as mpar
      into d
      from public.registrations r
     where r.id <> new.id and r.team_code = new.prior_team_code
       and (r.id = new.prior_registration_id
            or (public.name_key(r.first_name) = public.name_key(new.first_name)
                and public.name_key(r.last_name) = public.name_key(new.last_name)))
     order by (r.id = new.prior_registration_id) desc, (r.dob = new.dob) desc, r.season_year desc nulls last, r.created_at desc
     limit 1;
    insert into public.transfer_clearances (registration_id, athlete_first, athlete_last, dob, division, from_team, to_team, match_registration_id, match_dob, match_parent)
    values (new.id, new.first_name, new.last_name, new.dob, new.division, new.prior_team_code, new.team_code, d.id, d.mdob, d.mpar);
  end if;

  -- Not declared: same first name, last name, birth date AND parent name on another team.
  for m in
    select distinct on (x.team_code) x.*
    from (
      select r.id, r.team_code, r.season_year, r.created_at,
             r.dob = new.dob as mdob,
             exists (select 1 from unnest(array[r.parent1_name, r.parent2_name]) a(p), unnest(array[new.parent1_name, new.parent2_name]) b(p)
                     where public.name_key(a.p) <> '' and public.name_key(a.p) = public.name_key(b.p)) as mpar
      from public.registrations r
      where r.id <> new.id
        and r.team_code is not null and r.team_code is distinct from new.team_code
        and r.team_code is distinct from new.prior_team_code
        and public.name_key(r.first_name) = public.name_key(new.first_name)
        and public.name_key(r.last_name) = public.name_key(new.last_name)
    ) x
    where x.mdob and x.mpar
    order by x.team_code, x.season_year desc nulls last, x.created_at desc
  loop
    insert into public.transfer_clearances (registration_id, athlete_first, athlete_last, dob, division, from_team, to_team, flagged, match_registration_id, match_dob, match_parent)
    values (new.id, new.first_name, new.last_name, new.dob, new.division, m.team_code, new.team_code, true, m.id, m.mdob, m.mpar);
  end loop;
  return new;
end $$;

commit;
