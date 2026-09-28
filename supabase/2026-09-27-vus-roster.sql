-- 2026-09-27: Valley United roster cross-check (Riley's rule, simplified).
--   * vus_roster: last season's Valley United Striders roster, uploaded by Riley. notified_not_returning = the
--     athlete told their team BEFORE joining VUS that they weren't coming back (the only override).
--   * No "original team" question: the original team is the athlete's team LAST SEASON — the declared prior
--     team, else their matching last-season record (same name + birth date), else the roster's home team.
--   * Parent says Yes (or the roster shows them) and they're registering with a different team:
--       - notified_not_returning -> ordinary transfer (no VUS hold)
--       - otherwise -> Valley United move request: new team can't verify until the old team approves.
begin;

create table if not exists public.vus_roster (
  id uuid primary key default gen_random_uuid(),
  season_year integer not null,
  first_name text not null,
  last_name text not null,
  dob date,
  gender text,
  home_team text,
  notified_not_returning boolean not null default false,
  note text,
  created_at timestamptz not null default now()
);
alter table public.vus_roster enable row level security;
drop policy if exists "site admin all" on public.vus_roster;
create policy "site admin all" on public.vus_roster for all to authenticated
  using (public.is_site_admin()) with check (public.is_site_admin());

alter table public.transfer_clearances add column if not exists vus_on_roster boolean;
alter table public.transfer_clearances add column if not exists vus_notified boolean;

drop function if exists public.vus_record(text, text, date);
create or replace function public.vus_record(p_first text, p_last text, p_dob date)
returns table (home_team text, notified_not_returning boolean, season_year integer)
language sql stable security definer set search_path to 'public' as $$
  select x.home_team, x.notified, x.season_year from (
    select v.home_team, v.notified_not_returning notified, v.season_year, 1 pri from public.vus_roster v
     where v.season_year < public.current_season() and (v.dob = p_dob or v.dob is null)
       and public.name_key(v.first_name) = public.name_key(p_first) and public.name_key(v.last_name) = public.name_key(p_last)
    union all
    select p.vyc_home_team, (p.plans_to_return is false), p.season_year, 2 from public.postseason_registrations p
     where p.season_year < public.current_season() and p.dob = p_dob
       and public.name_key(p.first_name) = public.name_key(p_first) and public.name_key(p.last_name) = public.name_key(p_last)
  ) x order by x.season_year desc, x.pri limit 1
$$;

create or replace function public.reg_make_clearance() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare m record; d record; v record; last_team text; said_vus boolean; on_roster boolean; hold boolean;
begin
  select * into v from public.vus_record(new.first_name, new.last_name, new.dob);
  said_vus := coalesce(new.ran_vus_last_season,false);
  on_roster := v.season_year is not null;
  -- Team last season: declared, else their matching verified record, else the VUS roster's home team.
  last_team := new.prior_team_code;
  if last_team is null then
    select r.team_code into last_team from public.registrations r
     where r.id <> new.id and r.status = 'verified' and r.dob = new.dob and r.season_year < coalesce(new.season_year, 9999)
       and public.name_key(r.first_name) = public.name_key(new.first_name) and public.name_key(r.last_name) = public.name_key(new.last_name)
     order by (r.team_code = new.team_code) desc, r.season_year desc, r.created_at desc limit 1;
  end if;
  if last_team is null and on_roster then last_team := v.home_team; end if;
  -- VUS hold: ran for VUS (said so or on the roster) and did NOT notify their team beforehand.
  hold := (said_vus or on_roster) and not coalesce(v.notified_not_returning,false);

  if last_team is not null and last_team is distinct from new.team_code
     and (new.prior_team_code is not null or said_vus or on_roster) then
    select r.id,
           r.dob = new.dob as mdob,
           exists (select 1 from unnest(array[r.parent1_name, r.parent2_name]) a(p), unnest(array[new.parent1_name, new.parent2_name]) b(p)
                   where public.name_key(a.p) <> '' and public.name_key(a.p) = public.name_key(b.p)) as mpar
      into d
      from public.registrations r
     where r.id <> new.id and r.team_code = last_team
       and (r.id = new.prior_registration_id
            or (public.name_key(r.first_name) = public.name_key(new.first_name)
                and public.name_key(r.last_name) = public.name_key(new.last_name)))
     order by (r.id = new.prior_registration_id) desc, (r.dob = new.dob) desc, r.season_year desc nulls last, r.created_at desc
     limit 1;
    insert into public.transfer_clearances (registration_id, athlete_first, athlete_last, dob, division, from_team, to_team,
        match_registration_id, match_dob, match_parent, vus, vus_detected, vus_on_roster, vus_notified)
    values (new.id, new.first_name, new.last_name, new.dob, new.division, last_team, new.team_code, d.id, d.mdob, d.mpar,
        hold, on_roster and not said_vus, case when said_vus or on_roster then on_roster end, v.notified_not_returning);
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
        and r.team_code is distinct from last_team
        and public.name_key(r.first_name) = public.name_key(new.first_name)
        and public.name_key(r.last_name) = public.name_key(new.last_name)
    ) x
    where x.mdob and x.mpar
    order by x.team_code, x.season_year desc nulls last, x.created_at desc
  loop
    insert into public.transfer_clearances (registration_id, athlete_first, athlete_last, dob, division, from_team, to_team, flagged, match_registration_id, match_dob, match_parent, vus)
    values (new.id, new.first_name, new.last_name, new.dob, new.division, m.team_code, new.team_code, true, m.id, m.mdob, m.mpar, hold);
  end loop;
  return new;
end $$;

commit;
