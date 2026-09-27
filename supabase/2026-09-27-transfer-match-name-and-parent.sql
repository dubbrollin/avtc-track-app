-- 2026-09-27: tighten transfer matching (Riley): an undeclared transfer is flagged only when ALL match —
-- athlete first name, last name, birth date, AND a parent/guardian name. Declared transfers record
-- which of these matched against the declared team so the old team sees the evidence.
begin;

alter table public.transfer_clearances add column if not exists match_dob boolean;
alter table public.transfer_clearances add column if not exists match_parent boolean;

create or replace function public.reg_make_clearance() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare m record; d record;
begin
  -- Declared by the parent: open the request, with the best matching athlete on that team as evidence.
  if new.prior_team_code is not null and new.prior_team_code is distinct from new.team_code then
    select r.id,
           r.dob = new.dob as mdob,
           exists (select 1 from unnest(array[r.parent1_name, r.parent2_name]) a(p), unnest(array[new.parent1_name, new.parent2_name]) b(p)
                   where public.name_key(a.p) <> '' and public.name_key(a.p) = public.name_key(b.p)) as mpar
      into d
      from public.registrations r
     where r.id <> new.id and r.team_code = new.prior_team_code
       and public.name_key(r.first_name) = public.name_key(new.first_name)
       and public.name_key(r.last_name) = public.name_key(new.last_name)
     order by (r.dob = new.dob) desc, r.season_year desc nulls last, r.created_at desc
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
