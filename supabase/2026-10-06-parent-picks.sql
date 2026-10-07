-- ============================================================================
-- Parents never enter meet events themselves (2026-10-06, Riley). Per team, the choice is:
--   parent_entry_enabled = false → parents are only asked "Is your athlete coming?" (yes / no)
--   parent_entry_enabled = true  → same question, plus the parent picks up to parent_event_picks (1–3) events they'd
--                                   like; the coaches do the entering either way.
-- ============================================================================
alter table public.team_settings add column if not exists parent_event_picks integer not null default 2;
alter table public.team_settings drop constraint if exists team_settings_picks_check;
alter table public.team_settings add constraint team_settings_picks_check check (parent_event_picks between 1 and 3);
alter table public.meet_attendance add column if not exists event_3 uuid references public.meet_events(id) on delete set null;

drop function if exists public.set_parent_entry(text, boolean);
create or replace function public.set_parent_entry(p_team text, p_on boolean, p_picks integer default null) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not (public.is_site_admin() or public.is_team_admin_of(p_team)) then raise exception 'Only this team''s team admin (or a site admin) can change that.'; end if;
  if p_picks is not null and p_picks not between 1 and 3 then raise exception 'Parents can choose 1, 2 or 3 events.'; end if;
  insert into public.team_settings (team_code, parent_entry_enabled, parent_event_picks, updated_at, updated_by)
  values (p_team, coalesce(p_on, true), coalesce(p_picks, 2), now(), lower(coalesce(auth.jwt()->>'email','')))
  on conflict (team_code) do update set parent_entry_enabled = excluded.parent_entry_enabled,
    parent_event_picks = coalesce(p_picks, public.team_settings.parent_event_picks), updated_at = now(), updated_by = excluded.updated_by;
end $$;
revoke all on function public.set_parent_entry(text, boolean, integer) from public;
grant execute on function public.set_parent_entry(text, boolean, integer) to authenticated;

-- Parents no longer add or remove meet entries directly — coaches only.
drop policy if exists "insert own or coach" on public.entries;
create policy "insert own or coach" on public.entries for insert to authenticated
  with check (public.is_coach() and public.can_manage_athlete(registration_id) and lower(entered_by) = lower(coalesce(auth.jwt()->>'email','')));
drop policy if exists "delete own or coach" on public.entries;
create policy "delete own or coach" on public.entries for delete to authenticated
  using (public.is_coach() and public.can_manage_athlete(registration_id));

drop function if exists public.answer_attendance(uuid, uuid, boolean, uuid, uuid, text);
create or replace function public.answer_attendance(p_meet uuid, p_reg uuid, p_attending boolean, p_event1 uuid default null, p_event2 uuid default null, p_event3 uuid default null, p_note text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; m public.meets; ts public.team_settings; nid uuid; evs uuid[]; e uuid; me text := lower(coalesce(auth.jwt()->>'email','')); is_late boolean := false; picks integer := 0;
begin
  if not public.can_manage_athlete(p_reg) then raise exception 'Not your athlete.'; end if;
  select * into r from public.registrations where id = p_reg; if r.id is null then raise exception 'Athlete not found.'; end if;
  select * into m from public.meets where id = p_meet; if m.id is null then raise exception 'Meet not found.'; end if;
  if m.status = 'archived' then raise exception 'That meet is over.'; end if;
  if not public.meet_includes_team(p_meet, r.team_code) then raise exception 'Your team is not competing at this meet.'; end if;
  if p_attending is null then raise exception 'Answer yes or no.'; end if;
  if m.meet_date is not null and now() > public.attendance_deadline(m.meet_date) then is_late := true; end if;
  select * into ts from public.team_settings where team_code = r.team_code;
  if ts.team_code is not null and ts.parent_entry_enabled then picks := ts.parent_event_picks; end if;  -- no row = team hasn't chosen = no picks
  -- Event picks: only when the team allows them, only while attending, no duplicates, at most `picks`, and offered for this athlete.
  evs := array[]::uuid[];
  if p_attending and picks > 0 then
    foreach e in array array[p_event1, p_event2, p_event3] loop
      if e is not null and not (e = any(evs)) then evs := evs || e; end if;
    end loop;
    if array_length(evs, 1) > picks then raise exception 'You can pick up to % event%.', picks, case when picks = 1 then '' else 's' end; end if;
    foreach e in array evs loop
      if not exists (select 1 from public.meet_events v where v.id = e and v.meet_id = p_meet and (v.division = r.division or v.division = 'ALL') and (v.gender = r.gender or v.gender = 'Mixed')) then
        raise exception 'One of those events isn''t offered for this athlete at this meet.'; end if;
    end loop;
  end if;
  insert into public.meet_attendance (meet_id, registration_id, attending, event_1, event_2, event_3, note, answered_by, answered_at, updated_at, late)
  values (p_meet, p_reg, p_attending, evs[1], evs[2], evs[3], nullif(trim(p_note),''), me, now(), now(), is_late)
  on conflict (meet_id, registration_id) do update set attending = excluded.attending, event_1 = excluded.event_1, event_2 = excluded.event_2, event_3 = excluded.event_3, note = excluded.note,
    answered_by = excluded.answered_by, updated_at = now(),
    late = public.meet_attendance.late or (excluded.late and public.meet_attendance.answered_at > public.attendance_deadline(m.meet_date))
  returning id into nid;
  return nid;
end $$;
revoke all on function public.answer_attendance(uuid, uuid, boolean, uuid, uuid, uuid, text) from public;
grant execute on function public.answer_attendance(uuid, uuid, boolean, uuid, uuid, uuid, text) to authenticated;
