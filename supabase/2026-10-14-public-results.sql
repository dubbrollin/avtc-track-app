-- Public Results page: anyone (signed in or not) can see meets, results and season rankings.
-- Only the columns the Results page shows are opened up. Who uploaded a result (entered_by),
-- who created a meet (created_by) and other internal columns stay visible to signed-in users only.

-- ---------- meets: public can read the schedule columns ----------
revoke select on public.meets from anon;
grant select (id, name, meet_date, location, entries_close, status, is_championship, season_year, is_invitational, team_codes) on public.meets to anon;
drop policy if exists "public read meets" on public.meets;
create policy "public read meets" on public.meets for select to anon using (true);

-- ---------- results: public can read the marks ----------
revoke select on public.results from anon;
grant select (id, meet_id, registration_id, athlete_name, gender, division, event_code, event_name, is_relay, relay_runners,
              round, mark, mark_value, is_time, place, wind, team_code, heat, overall_place) on public.results to anon;
drop policy if exists "public read results" on public.results;
create policy "public read results" on public.results for select to anon using (true);

-- ---------- season_best: rebuilt with team_code, without uploader emails, and obeying the rules above ----------
-- (Before this, the view ran with the owner's rights, so anyone could read every column, including entered_by.)
drop view if exists public.season_best;
create view public.season_best with (security_invoker = true) as
  select distinct on (r.event_code, r.is_relay, coalesce(r.division,''), r.gender, coalesce(r.registration_id::text, r.athlete_name))
    r.id, r.meet_id, r.registration_id, r.athlete_name, r.gender, r.division, r.event_code, r.event_name, r.is_relay,
    r.relay_runners, r.round, r.mark, r.mark_value, r.is_time, r.place, r.wind, r.team_code, m.name as meet_name, m.meet_date
  from public.results r join public.meets m on m.id = r.meet_id
  where r.mark_value is not null
  order by r.event_code, r.is_relay, coalesce(r.division,''), r.gender, coalesce(r.registration_id::text, r.athlete_name),
           case when r.is_time then r.mark_value else -r.mark_value end asc;
revoke all on public.season_best from anon, authenticated;
grant select on public.season_best to anon, authenticated;
