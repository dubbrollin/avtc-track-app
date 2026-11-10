-- A Meet Manager backup replaces the WHOLE meet's results (2026-11-10).
--   A backup is the complete meet database, so a newer (fixed) backup must replace everything an earlier upload posted —
--   including events the fix emptied out entirely (every result scratched, or moved to another division/gender), which the
--   normal per-event replace would leave behind.
--   replace_meet_results gets a 4th argument p_whole_meet (default false). false = exactly as before (results files and the
--   live connection replace only the events they contain). true = every uploaded result for the meet is removed first, then
--   the backup's rows go in. Hand-typed results (source 'manual') are never removed either way.
--   Same body as 2026-10-22-mixed-results-refile.sql otherwise.
begin;

drop function if exists public.replace_meet_results(uuid, jsonb, boolean);

create or replace function public.replace_meet_results(p_meet uuid, p_rows jsonb, p_all_teams boolean default true, p_whole_meet boolean default false)
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

  if p_whole_meet then
    delete from public.results r where r.meet_id = p_meet and r.source is distinct from 'manual';
  else
    delete from public.results r
    using (select distinct event_code, coalesce(is_relay,false) as is_relay, coalesce(nullif(division,'ALL'),'') as division, gender,
                  coalesce(round,'F') as round, coalesce(team_code,'') as team_code from _up) u
    where r.meet_id = p_meet
      and r.source is distinct from 'manual'
      and r.event_code = u.event_code and r.is_relay = u.is_relay
      and coalesce(nullif(case when r.raced_gender is not null then r.raced_division else r.division end,'ALL'),'') = u.division
      and coalesce(r.raced_gender, r.gender) = u.gender and r.round = u.round
      and (p_all_teams or coalesce(r.team_code,'') = u.team_code);
  end if;

  insert into public.results (meet_id, registration_id, athlete_name, gender, division, team_code, event_code, event_name,
                              is_relay, relay_runners, round, mark, mark_value, is_time, place, overall_place, heat, wind, source, entered_by)
  select p_meet, registration_id, athlete_name, gender, division, team_code, event_code, event_name,
         coalesce(is_relay,false), relay_runners, coalesce(round,'F'), mark, mark_value, coalesce(is_time,true),
         place, overall_place, heat, wind, coalesce(source,'hytek'), lower(coalesce(auth.jwt()->>'email',''))
  from _up;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.replace_meet_results(uuid, jsonb, boolean, boolean) from public, anon;
grant execute on function public.replace_meet_results(uuid, jsonb, boolean, boolean) to authenticated;

commit;

-- Let the data API see the new argument right away.
notify pgrst, 'reload schema';
