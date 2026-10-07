-- 2026-10-06: "Is your athlete coming?" has a deadline — the Thursday before the meet at 8:00 PM (Pacific).
-- Parents must tell the team by then. An answer after the deadline is still recorded but marked LATE: the athlete is a
-- late add and runs at the end of each heat. No answer at all = same thing if they show up on meet day.
alter table public.meet_attendance add column if not exists late boolean not null default false;

-- The Thursday strictly before the meet date, 8:00 PM Pacific. (Meet on a Thursday → the Thursday a week before.)
create or replace function public.attendance_deadline(p_meet_date date) returns timestamptz
language sql immutable as $$
  select ((p_meet_date - (case when ((extract(dow from p_meet_date)::int - 4 + 7) % 7) = 0 then 7 else ((extract(dow from p_meet_date)::int - 4 + 7) % 7) end))::text || ' 20:00')::timestamp
         at time zone 'America/Los_Angeles'
$$;
grant execute on function public.attendance_deadline(date) to anon, authenticated;

create or replace function public.answer_attendance(p_meet uuid, p_reg uuid, p_attending boolean, p_event1 uuid default null, p_event2 uuid default null, p_note text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; m public.meets; nid uuid; e1 uuid := p_event1; e2 uuid := p_event2; me text := lower(coalesce(auth.jwt()->>'email','')); is_late boolean := false;
begin
  if not public.can_manage_athlete(p_reg) then raise exception 'Not your athlete.'; end if;
  select * into r from public.registrations where id = p_reg; if r.id is null then raise exception 'Athlete not found.'; end if;
  select * into m from public.meets where id = p_meet; if m.id is null then raise exception 'Meet not found.'; end if;
  if m.status = 'archived' then raise exception 'That meet is over.'; end if;
  if p_attending is null then raise exception 'Answer yes or no.'; end if;
  if m.meet_date is not null and now() > public.attendance_deadline(m.meet_date) then is_late := true; end if;
  if not p_attending then e1 := null; e2 := null; end if;
  if e2 is not null and e2 = e1 then e2 := null; end if;
  if e1 is not null and not exists (select 1 from public.meet_events v where v.id = e1 and v.meet_id = p_meet and (v.division = r.division or v.division = 'ALL') and (v.gender = r.gender or v.gender = 'Mixed')) then
    raise exception 'That first event isn''t offered for this athlete at this meet.'; end if;
  if e2 is not null and not exists (select 1 from public.meet_events v where v.id = e2 and v.meet_id = p_meet and (v.division = r.division or v.division = 'ALL') and (v.gender = r.gender or v.gender = 'Mixed')) then
    raise exception 'That second event isn''t offered for this athlete at this meet.'; end if;
  insert into public.meet_attendance (meet_id, registration_id, attending, event_1, event_2, note, answered_by, answered_at, updated_at, late)
  values (p_meet, p_reg, p_attending, e1, e2, nullif(trim(p_note),''), me, now(), now(), is_late)
  on conflict (meet_id, registration_id) do update set attending = excluded.attending, event_1 = excluded.event_1, event_2 = excluded.event_2, note = excluded.note,
    answered_by = excluded.answered_by, updated_at = now(),
    -- once on time, a later edit doesn't make it late; a first answer after the deadline is late for good
    late = public.meet_attendance.late or (excluded.late and public.meet_attendance.answered_at > public.attendance_deadline(m.meet_date))
  returning id into nid;
  return nid;
end $$;
revoke all on function public.answer_attendance(uuid, uuid, boolean, uuid, uuid, text) from public;
grant execute on function public.answer_attendance(uuid, uuid, boolean, uuid, uuid, text) to authenticated;
