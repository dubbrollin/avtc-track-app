-- Live results (2026-10-14), modelled on Athletic.net's live results:
--   During a meet, whoever has the Meet Manager laptop (team admin or approved timer) uploads the results file
--   again after every few events. Each upload REPLACES the results for the events in the file instead of adding
--   them a second time, so the file can be uploaded over and over and the Results page "Live" tab stays correct.
--
--   * Only events that are in the file are touched — events already posted and not in this file stay as they are.
--   * all_teams = true  (semicolon file with every team): the whole event (division/gender/round) is replaced.
--     all_teams = false (only my team's rows): only rows for the team codes in the file are replaced, so one
--     team's upload never wipes another team's results.
--   * Results typed in by hand (source 'manual') are never removed by an upload.
--   * Timers can still only ADD results directly; this function is the one safe way they can replace them.
begin;

-- The upload already saves these; make sure they exist (no-op if they do).
alter table public.results add column if not exists team_code text;
alter table public.results add column if not exists overall_place int;
alter table public.results add column if not exists heat int;

create or replace function public.replace_meet_results(p_meet uuid, p_rows jsonb, p_all_teams boolean default true)
returns integer
language plpgsql security definer set search_path to 'public' as $$
declare n integer;
begin
  if not public.can_upload_results() then raise exception 'Only team admins and approved timers can upload results'; end if;
  if not exists (select 1 from public.meets m where m.id = p_meet and m.status is distinct from 'archived') then
    raise exception 'That meet is locked — its results can no longer be changed here';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then return 0; end if;

  drop table if exists _up;
  create temp table _up on commit drop as
    select * from jsonb_to_recordset(p_rows) as x(
      registration_id uuid, athlete_name text, gender text, division text, team_code text, event_code text, event_name text,
      is_relay boolean, relay_runners text, round text, mark text, mark_value numeric, is_time boolean,
      place int, overall_place int, heat int, wind text, source text);

  delete from public.results r
  using (select distinct event_code, coalesce(is_relay,false) as is_relay, coalesce(division,'') as division, gender,
                coalesce(round,'F') as round, coalesce(team_code,'') as team_code from _up) u
  where r.meet_id = p_meet
    and r.source is distinct from 'manual'
    and r.event_code = u.event_code and r.is_relay = u.is_relay and coalesce(r.division,'') = u.division
    and r.gender = u.gender and r.round = u.round
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

revoke all on function public.replace_meet_results(uuid, jsonb, boolean) from public, anon;
grant execute on function public.replace_meet_results(uuid, jsonb, boolean) to authenticated;

-- Fast "what changed in this meet" lookups for the Live tab (it re-checks every 30 seconds).
create index if not exists results_meet_created_idx on public.results (meet_id, created_at desc);

commit;
