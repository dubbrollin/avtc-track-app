-- ============================================================================
-- Practice meets for Meet Day Staging (2026-11-26, Riley: "make me a practice meet ... 5 teams ... based off the kids
-- in last season's meets ... I want to test this myself").
--   * meets.is_practice: a practice meet. The staging page lists LAST season's certified athletes of the meet's teams and
--     their last-season best marks, so staging can be tried before this season has any results.
--   * Practice meets are also status 'archived' (coach, parent, entries and team pages already hide archived meets);
--     the schedule and results pages skip is_practice meets.
--   * check_entry: the certification-fee check is skipped for practice meets (last season's teams have no 2027 fees on file).
--     Event limits still apply.
-- ============================================================================
begin;
alter table public.meets add column if not exists is_practice boolean not null default false;

create or replace function public.check_entry() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare
  reg record; ev record; m record;
  cnt int; relay_cnt int; maxev int; relay_rule boolean;
begin
  select * into reg from public.registrations where id = new.registration_id;
  select * into ev  from public.meet_events   where id = new.meet_event_id;
  select * into m   from public.meets         where id = new.meet_id;
  if reg is null or ev is null or m is null then raise exception 'Bad entry'; end if;
  if ev.meet_id <> new.meet_id then raise exception 'Event does not belong to this meet'; end if;
  if reg.status <> 'verified' then raise exception 'Athlete is not certified yet'; end if;
  if not coalesce(m.is_practice,false) and not public.team_fees_cleared(reg.team_code, coalesce(m.season_year, reg.season_year)) then
    raise exception '%''s certification fees have not been confirmed paid by the Treasurer, so its athletes can''t be entered in meets yet (rule I.E). Only the Commissioner or the Conference President can overrule this.', reg.team_code;
  end if;
  if m.status <> 'open' or now() > m.entries_close then
    if not (public.is_coach() or public.can_stage()) then raise exception 'Entries for this meet are closed'; end if;
  end if;
  if (ev.division <> 'ALL' and ev.division <> reg.division) or (ev.gender <> 'Mixed' and ev.gender <> reg.gender) then
    raise exception 'Event is not for this athlete''s division/gender';
  end if;
  select count(*), count(*) filter (where e2.is_relay) into cnt, relay_cnt
    from public.entries e join public.meet_events e2 on e2.id = e.meet_event_id
    where e.registration_id = new.registration_id and e.meet_id = new.meet_id
      and e.id is distinct from new.id;
  cnt := cnt + 1; if ev.is_relay then relay_cnt := relay_cnt + 1; end if;
  select l.max_events, l.relay_required_for_max into maxev, relay_rule from public.entry_limits l where l.division = reg.division;
  if maxev is null then
    maxev := case when reg.division in ('Sub-Gremlin','Gremlin') then 3 else 4 end;
    relay_rule := reg.division in ('Bantam','Juniors','Youth');
  end if;
  if cnt > maxev then raise exception 'Max % events for %', maxev, reg.division; end if;
  if relay_rule and cnt = maxev and relay_cnt = 0 then
    raise exception '% may only have % events if one is a relay', reg.division, maxev;
  end if;
  return new;
end $$;

create or replace function public.staging_board(p_meet uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare m record; yr int; ay int; out jsonb;
begin
  perform public.stage_guard();
  select * into m from public.meets where id = p_meet;
  if m is null then raise exception 'Meet not found'; end if;
  yr := coalesce(m.season_year, public.current_season());
  ay := case when coalesce(m.is_practice,false) then yr - 1 else yr end;   -- practice meet: last season's athletes and marks
  with ath as (
    select r.id, r.first_name, r.last_name, r.gender, r.division, r.team_code, r.comp_number, r.dob, r.age_on_dec31
      from public.registrations r
     where r.status = 'verified' and r.season_year = ay
       and coalesce(r.sport,'Track & Field') = 'Track & Field'
       and (coalesce(cardinality(m.team_codes),0) = 0 or r.team_code = any(m.team_codes))
  ),
  res as (
    select x.registration_id reg, x.event_code, x.mark, x.mark_value, x.is_time, mm.meet_date
      from public.results x join public.meets mm on mm.id = x.meet_id
     where mm.season_year = ay and not coalesce(x.is_relay,false)
       and x.registration_id in (select id from ath)
       and x.mark_value is not null and x.mark_value > 0
       and (public.sees_locked_results() or not public.result_locked(x.meet_id, x.team_code, x.registration_id, x.athlete_name, x.is_relay))
  ),
  best as (
    select distinct on (reg, event_code) reg, event_code, mark, mark_value, is_time
      from res order by reg, event_code, case when is_time then mark_value else -mark_value end, meet_date desc
  ),
  rel as (
    select x.team_code, x.division, x.gender, x.event_code, x.mark, x.mark_value, mm.meet_date, mm.name meet_name
      from public.results x join public.meets mm on mm.id = x.meet_id
     where mm.season_year = ay and coalesce(x.is_relay,false) and x.is_time
       and x.mark_value is not null and x.mark_value > 0
       and (coalesce(cardinality(m.team_codes),0) = 0 or x.team_code = any(m.team_codes))
  ),
  ent as (
    select e.registration_id reg, ev.code event_code, ev.is_relay, e.relay_team, e.leg, coalesce(e.entered_by,'') entered_by
      from public.entries e join public.meet_events ev on ev.id = e.meet_event_id
     where e.meet_id = p_meet
  )
  select jsonb_build_object(
    'meet', jsonb_build_object('id', m.id, 'name', m.name, 'meet_date', m.meet_date, 'season_year', yr, 'team_codes', m.team_codes,
                               'venue', m.venue, 'is_practice', coalesce(m.is_practice,false), 'athlete_season', ay, 'host_team_code', m.host_team_code,
                               'lanes', coalesce((select s.lanes from public.stage_meet s where s.meet_id = m.id), 0)),
    'athletes', coalesce((select jsonb_agg(to_jsonb(a)) from ath a), '[]'::jsonb),
    'bests',    coalesce((select jsonb_agg(to_jsonb(b)) from best b), '[]'::jsonb),
    'relays',   coalesce((select jsonb_agg(to_jsonb(r) order by r.mark_value) from rel r), '[]'::jsonb),
    'entries',  coalesce((select jsonb_agg(to_jsonb(e)) from ent e), '[]'::jsonb)
  ) into out;
  return out;
end $$;
revoke all on function public.staging_board(uuid) from public, anon;
grant execute on function public.staging_board(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
