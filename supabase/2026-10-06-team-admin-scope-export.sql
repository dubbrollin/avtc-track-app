-- 2026-10-06: a team admin sees ONLY their own team's athletes — everywhere.
-- The one place that still showed every team was the meet entries download (Hy-Tek entries file): it's built for
-- timers and site admins, who need the whole meet. A team admin now gets just their own team's entries and roster
-- from it; site admins and approved timers still get the whole meet. (Riley's rule: only the site admin sees everyone.)
begin;

create or replace function public.meet_export(p_meet uuid)
returns table(kind text, reg_id uuid, first_name text, last_name text, gender text, dob date, division text,
              age_on_dec31 integer, team_code text, ev_code text, ev_name text, ev_division text, ev_gender text,
              ev_is_relay boolean, seed_mark text, relay_team text, leg integer)
language plpgsql stable security definer set search_path to 'public' as $$
declare whole_meet boolean := public.is_site_admin() or public.is_timer();
begin
  if not public.can_upload_results() then raise exception 'Only admins and approved timers can download entries.'; end if;
  return query
    select 'entry'::text, r.id, r.first_name, r.last_name, r.gender, r.dob, r.division, r.age_on_dec31, r.team_code,
           ev.code, ev.name, ev.division, ev.gender, ev.is_relay, en.seed_mark, en.relay_team, en.leg
      from public.entries en
      join public.registrations r on r.id = en.registration_id
      join public.meet_events ev on ev.id = en.meet_event_id
     where en.meet_id = p_meet
       and (whole_meet or public.is_team_admin_of(r.team_code))
    union all
    select 'roster'::text, r.id, r.first_name, r.last_name, r.gender, r.dob, r.division, r.age_on_dec31, r.team_code,
           null, null, null, null, null, null, null, null
      from public.registrations r
     where r.status = 'verified'
       and (whole_meet or public.is_team_admin_of(r.team_code))
       and r.team_code in (select r2.team_code from public.entries e2 join public.registrations r2 on r2.id = e2.registration_id where e2.meet_id = p_meet)
       and not exists (select 1 from public.entries e3 where e3.meet_id = p_meet and e3.registration_id = r.id)
    order by 1, 9, 4, 3;
end $$;
revoke all on function public.meet_export(uuid) from public;
grant execute on function public.meet_export(uuid) to authenticated;

commit;
