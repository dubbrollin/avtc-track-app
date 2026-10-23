-- Mixed-race results are filed under the athlete's own division and gender (2026-10-22).
--   At a meet, distance races (800, 1500...) are often run as ONE "Mixed" race: boys and girls, several divisions,
--   all on the track together. Meet Manager calls that event sex X. Those results used to be posted under "Mixed" with
--   no division, so they never showed in Season Rankings, qualifying standards, bests, or the right event box.
--   Riley (2026-10-22): once the results come in, the system must put each one in the event it belongs to.
--
--   How it works:
--   * BEFORE INSERT/UPDATE trigger results_refile_mixed (runs after results_link_registration, which finds the athlete's
--     registration): a result whose gender is Mixed, or whose division is missing / ALL, takes gender + division from the
--     athlete's registration. What it was uploaded as is kept in raced_gender / raced_division / raced_place / raced_heat,
--     so the page can say "ran in the mixed 800 (heat 2, 5th overall)" and a re-upload of the same file still replaces it.
--   * AFTER statement trigger results_refile_places: re-filed results are placed 1, 2, 3... among the athletes of that
--     division + gender who ran that race (ties share a place; DNF / no mark = no place). Heat is cleared so the event box
--     shows them as one list, not a scatter of partial heats.
--   * replace_meet_results matches posted rows by what they were UPLOADED as, so a corrected file replaces the re-filed
--     rows instead of adding a second copy.
--   Relays are never re-filed (a mixed relay is a real mixed-gender event). A Mixed result whose athlete can't be matched
--   to a registration stays as uploaded.
begin;

alter table public.results add column if not exists raced_gender text;    -- 'Mixed' / 'Boy' / 'Girl' as uploaded, when re-filed
alter table public.results add column if not exists raced_division text;  -- division as uploaded (null = none / ALL), when re-filed
alter table public.results add column if not exists raced_place integer;  -- place in the race as run
alter table public.results add column if not exists raced_heat integer;   -- heat of the race as run

create or replace function public.results_refile_mixed() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare g record;
begin
  if coalesce(new.is_relay,false) or new.registration_id is null then return new; end if;
  if tg_op = 'UPDATE' and new.raced_gender is not null
     and new.gender is not distinct from old.gender and new.division is not distinct from old.division
     and new.registration_id is not distinct from old.registration_id then
    return new;   -- already re-filed and nothing relevant changed
  end if;
  if new.gender <> 'Mixed' and new.division is not null and new.division <> 'ALL' then return new; end if;
  select gender, division into g from public.registrations where id = new.registration_id;
  if g.gender is null or g.division is null then return new; end if;
  if new.raced_gender is null then   -- first time through: remember the race as it was run
    new.raced_gender := new.gender; new.raced_division := nullif(new.division,'ALL');
    new.raced_place := new.place; new.raced_heat := new.heat;
  end if;
  new.gender := g.gender; new.division := g.division;
  new.event_name := regexp_replace(coalesce(new.event_name,''), '^\s*(mixed|x)\s+', '', 'i');
  new.place := null; new.heat := null;   -- placed among their own division + gender by results_refile_places
  return new;
end $$;
drop trigger if exists results_refile_mixed on public.results;
create trigger results_refile_mixed before insert or update of registration_id, gender, division on public.results
  for each row execute function public.results_refile_mixed();

create or replace function public.results_refile_places() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;   -- the place update below fires this trigger again: stop there
  with grp as (
    select distinct meet_id, event_code, coalesce(round,'F') as round, division, gender from new_rows
    where raced_gender is not null and not coalesce(is_relay,false)
  ), ranked as (
    select r.id, case when r.mark_value is null then null
                 else rank() over (partition by r.meet_id, r.event_code, coalesce(r.round,'F'), r.division, r.gender
                                   order by case when r.is_time then r.mark_value else -r.mark_value end) end as pl
    from public.results r join grp on grp.meet_id = r.meet_id and grp.event_code = r.event_code
      and grp.round = coalesce(r.round,'F') and grp.division = r.division and grp.gender = r.gender
    where r.raced_gender is not null and not coalesce(r.is_relay,false)
  )
  update public.results r set place = ranked.pl from ranked where r.id = ranked.id and r.place is distinct from ranked.pl;
  return null;
end $$;
-- (Postgres allows one event and no column list per trigger when a transition table is used, so insert and update get one each.)
drop trigger if exists results_refile_places on public.results;
drop trigger if exists results_refile_places_ins on public.results;
create trigger results_refile_places_ins after insert on public.results
  referencing new table as new_rows for each statement execute function public.results_refile_places();
drop trigger if exists results_refile_places_upd on public.results;
create trigger results_refile_places_upd after update on public.results
  referencing new table as new_rows for each statement execute function public.results_refile_places();

-- The public results page reads the "as run" columns too.
grant select (raced_gender, raced_division, raced_place, raced_heat) on public.results to anon;

-- Re-uploads: a posted row is matched by what it was UPLOADED as (raced_* when it was re-filed).
create or replace function public.replace_meet_results(p_meet uuid, p_rows jsonb, p_all_teams boolean default true)
returns integer
language plpgsql security definer set search_path to 'public' as $$
declare n integer;
begin
  if not public.can_upload_results() then raise exception 'Only team admins and approved timers can upload results'; end if;
  if not exists (select 1 from public.meets m where m.id = p_meet and m.status is distinct from 'archived') then
    raise exception 'That meet is locked - its results can no longer be changed here';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then return 0; end if;

  drop table if exists _up;
  create temp table _up on commit drop as
    select * from jsonb_to_recordset(p_rows) as x(
      registration_id uuid, athlete_name text, gender text, division text, team_code text, event_code text, event_name text,
      is_relay boolean, relay_runners text, round text, mark text, mark_value numeric, is_time boolean,
      place int, overall_place int, heat int, wind text, source text);

  delete from public.results r
  using (select distinct event_code, coalesce(is_relay,false) as is_relay, coalesce(nullif(division,'ALL'),'') as division, gender,
                coalesce(round,'F') as round, coalesce(team_code,'') as team_code from _up) u
  where r.meet_id = p_meet
    and r.source is distinct from 'manual'
    and r.event_code = u.event_code and r.is_relay = u.is_relay
    and coalesce(nullif(case when r.raced_gender is not null then r.raced_division else r.division end,'ALL'),'') = u.division
    and coalesce(r.raced_gender, r.gender) = u.gender and r.round = u.round
    and (p_all_teams or coalesce(r.team_code,'') = u.team_code);

  insert into public.results (meet_id, registration_id, athlete_name, gender, division, team_code, event_code, event_name,
                              is_relay, relay_runners, round, mark, mark_value, is_time, place, overall_place, heat, wind, source, entered_by)
  select p_meet, registration_id, athlete_name, gender, division, team_code, event_code, event_name,
         coalesce(is_relay,false), relay_runners, coalesce(round,'F'), mark, mark_value, coalesce(is_time,true),
         place, overall_place, heat, wind, coalesce(source,'hytek'), lower(coalesce(auth.jwt()->>'email',''))
  from _up;
  get diagnostics n = row_count;
  return n;
end $$;

-- Anything already posted as Mixed / no division and linked to an athlete gets filed now (there were none on 2026-10-22).
update public.results set gender = gender
  where not coalesce(is_relay,false) and registration_id is not null and (gender = 'Mixed' or division is null or division = 'ALL');

commit;
