-- ============================================================================
-- Which teams compete at a meet (2026-10-06)
-- meets.team_codes lists the teams at that meet; empty / null = every team. Coaches and parents only see (and can
-- only enter, or answer "are you coming?" for) meets their team is competing at. Set on Meet Admin ("Teams competing").
-- ============================================================================
alter table public.meets add column if not exists team_codes text[];

create or replace function public.meet_includes_team(p_meet uuid, p_team text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select coalesce(array_length(m.team_codes, 1), 0) = 0 or p_team = any(m.team_codes) from public.meets m where m.id = p_meet), false)
$$;
grant execute on function public.meet_includes_team(uuid, text) to anon, authenticated;

-- An athlete can only be entered in a meet their team is competing at.
create or replace function public.entry_team_in_meet() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare t text;
begin
  select team_code into t from public.registrations where id = new.registration_id;
  if not public.meet_includes_team(new.meet_id, t) then raise exception 'This athlete''s team is not competing at this meet.'; end if;
  return new;
end $$;
drop trigger if exists entries_team_in_meet on public.entries;
create trigger entries_team_in_meet before insert on public.entries for each row execute function public.entry_team_in_meet();

-- "Are you coming?" only for meets the athlete's team is at.
create or replace function public.answer_attendance(p_meet uuid, p_reg uuid, p_attending boolean, p_event1 uuid default null, p_event2 uuid default null, p_note text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; m public.meets; nid uuid; e1 uuid := p_event1; e2 uuid := p_event2; me text := lower(coalesce(auth.jwt()->>'email','')); is_late boolean := false;
begin
  if not public.can_manage_athlete(p_reg) then raise exception 'Not your athlete.'; end if;
  select * into r from public.registrations where id = p_reg; if r.id is null then raise exception 'Athlete not found.'; end if;
  select * into m from public.meets where id = p_meet; if m.id is null then raise exception 'Meet not found.'; end if;
  if m.status = 'archived' then raise exception 'That meet is over.'; end if;
  if not public.meet_includes_team(p_meet, r.team_code) then raise exception 'Your team is not competing at this meet.'; end if;
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
    late = public.meet_attendance.late or (excluded.late and public.meet_attendance.answered_at > public.attendance_deadline(m.meet_date))
  returning id into nid;
  return nid;
end $$;
revoke all on function public.answer_attendance(uuid, uuid, boolean, uuid, uuid, text) from public;
grant execute on function public.answer_attendance(uuid, uuid, boolean, uuid, uuid, text) to authenticated;
