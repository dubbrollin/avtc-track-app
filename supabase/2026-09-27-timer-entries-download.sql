-- 2026-09-27: timers can download a meet's entries (the Hy-Tek Meet Manager entries file).
-- Timers can't read entries/registrations directly, so this returns exactly what the file needs for ONE meet:
-- every entry (athlete + event + seed/relay info) plus the rest of each participating team's verified roster
-- (Meet Manager's roster "I" records). Admins and approved timers only.
begin;

create or replace function public.meet_export(p_meet uuid)
returns table(kind text, reg_id uuid, first_name text, last_name text, gender text, dob date, division text,
              age_on_dec31 integer, team_code text, ev_code text, ev_name text, ev_division text, ev_gender text,
              ev_is_relay boolean, seed_mark text, relay_team text, leg integer)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.can_upload_results() then raise exception 'Only admins and approved timers can download entries.'; end if;
  return query
    select 'entry'::text, r.id, r.first_name, r.last_name, r.gender, r.dob, r.division, r.age_on_dec31, r.team_code,
           ev.code, ev.name, ev.division, ev.gender, ev.is_relay, en.seed_mark, en.relay_team, en.leg
      from public.entries en
      join public.registrations r on r.id = en.registration_id
      join public.meet_events ev on ev.id = en.meet_event_id
     where en.meet_id = p_meet
    union all
    select 'roster'::text, r.id, r.first_name, r.last_name, r.gender, r.dob, r.division, r.age_on_dec31, r.team_code,
           null, null, null, null, null, null, null, null
      from public.registrations r
     where r.status = 'verified'
       and r.team_code in (select r2.team_code from public.entries e2 join public.registrations r2 on r2.id = e2.registration_id where e2.meet_id = p_meet)
       and not exists (select 1 from public.entries e3 where e3.meet_id = p_meet and e3.registration_id = r.id)
    order by 1, 9, 4, 3;
end $$;
revoke all on function public.meet_export(uuid) from public;
grant execute on function public.meet_export(uuid) to authenticated;

commit;
