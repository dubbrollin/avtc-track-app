-- 2026-09-27: Valley United Striders (VUS) return rule.
-- An athlete who ran for VUS last season must go back to their ORIGINAL VYC team. Moving to a different team
-- needs a valid move request: the original team must approve it (transfer_clearances.status = 'cleared')
-- before the new team can mark the registration verified (which is also what lets them enter meets).
--   * registrations.ran_vus_last_season: the parent's answer on the form.
--   * Also detected automatically from last season's VUS sign-ups (postseason_registrations: same first +
--     last name + birth date), even if the parent answers "No". Their VUS sign-up's home team is the original team.
begin;

alter table public.registrations add column if not exists ran_vus_last_season boolean not null default false;
alter table public.transfer_clearances add column if not exists vus boolean not null default false;
alter table public.transfer_clearances add column if not exists vus_detected boolean not null default false;
alter table public.transfer_clearances add column if not exists vus_plans_to_return boolean;

-- Last season's VUS sign-up for this athlete, if any.
create or replace function public.vus_record(p_first text, p_last text, p_dob date)
returns table (home_team text, plans_to_return boolean, season_year integer)
language sql stable security definer set search_path to 'public' as $$
  select v.vyc_home_team, v.plans_to_return, v.season_year from public.postseason_registrations v
   where v.dob = p_dob and v.season_year < public.current_season()
     and public.name_key(v.first_name) = public.name_key(p_first) and public.name_key(v.last_name) = public.name_key(p_last)
   order by v.season_year desc, v.created_at desc limit 1
$$;

create or replace function public.reg_make_clearance() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare m record; d record; v record; is_vus boolean; from_t text;
begin
  select * into v from public.vus_record(new.first_name, new.last_name, new.dob);
  is_vus := coalesce(new.ran_vus_last_season,false) or v.home_team is not null;
  -- Original team: what the parent declared, else the VUS sign-up's home team.
  from_t := coalesce(new.prior_team_code, case when v.home_team is not null and v.home_team is distinct from new.team_code then v.home_team end);

  if from_t is not null and from_t is distinct from new.team_code then
    select r.id,
           r.dob = new.dob as mdob,
           exists (select 1 from unnest(array[r.parent1_name, r.parent2_name]) a(p), unnest(array[new.parent1_name, new.parent2_name]) b(p)
                   where public.name_key(a.p) <> '' and public.name_key(a.p) = public.name_key(b.p)) as mpar
      into d
      from public.registrations r
     where r.id <> new.id and r.team_code = from_t
       and (r.id = new.prior_registration_id
            or (public.name_key(r.first_name) = public.name_key(new.first_name)
                and public.name_key(r.last_name) = public.name_key(new.last_name)))
     order by (r.id = new.prior_registration_id) desc, (r.dob = new.dob) desc, r.season_year desc nulls last, r.created_at desc
     limit 1;
    insert into public.transfer_clearances (registration_id, athlete_first, athlete_last, dob, division, from_team, to_team,
        match_registration_id, match_dob, match_parent, vus, vus_detected, vus_plans_to_return)
    values (new.id, new.first_name, new.last_name, new.dob, new.division, from_t, new.team_code, d.id, d.mdob, d.mpar,
        is_vus, v.home_team is not null and not coalesce(new.ran_vus_last_season,false), v.plans_to_return);
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
        and r.team_code is distinct from from_t
        and public.name_key(r.first_name) = public.name_key(new.first_name)
        and public.name_key(r.last_name) = public.name_key(new.last_name)
    ) x
    where x.mdob and x.mpar
    order by x.team_code, x.season_year desc nulls last, x.created_at desc
  loop
    insert into public.transfer_clearances (registration_id, athlete_first, athlete_last, dob, division, from_team, to_team, flagged, match_registration_id, match_dob, match_parent, vus)
    values (new.id, new.first_name, new.last_name, new.dob, new.division, m.team_code, new.team_code, true, m.id, m.mdob, m.mpar, is_vus);
  end loop;
  return new;
end $$;

-- A VUS athlete moving teams can't be verified until the original team approves the move.
create or replace function public.reg_vus_verify_guard() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare c record;
begin
  if new.status = 'verified' and old.status is distinct from 'verified' then
    select * into c from public.transfer_clearances t
     where t.registration_id = new.id and t.vus and t.status <> 'cleared' and t.status <> 'not_same'
     limit 1;
    if c.id is not null then
      raise exception 'Valley United rule: this athlete ran for Valley United last season, so %''s team must approve the move before this registration can be verified.', c.from_team;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists reg_vus_verify_trg on public.registrations;
create trigger reg_vus_verify_trg before update on public.registrations
  for each row execute function public.reg_vus_verify_guard();

commit;
