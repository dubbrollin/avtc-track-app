-- ============================================================================
-- Parent meet sign-up switch + "Are you coming?" questionnaire (2026-10-06)
-- A team admin can turn OFF parents entering athletes into meet events themselves. When it's off, the Parent
-- Dashboard asks instead: "Is <athlete> coming to <meet>?" Yes / No, and (optionally) which two events they'd like
-- to compete in. The answer goes to the coaches of that athlete's division, who do the actual entering.
-- ============================================================================

-- ---------- per-team switches ----------
create table if not exists public.team_settings (
  team_code text primary key,
  parent_entry_enabled boolean not null default true,   -- true = parents may enter events themselves (old behaviour)
  updated_at timestamptz not null default now(), updated_by text);
alter table public.team_settings enable row level security;
drop policy if exists "team settings read" on public.team_settings;
create policy "team settings read" on public.team_settings for select using (true);

create or replace function public.set_parent_entry(p_team text, p_on boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not (public.is_site_admin() or public.is_team_admin_of(p_team)) then raise exception 'Only this team''s team admin (or a site admin) can change that.'; end if;
  insert into public.team_settings (team_code, parent_entry_enabled, updated_at, updated_by)
  values (p_team, coalesce(p_on, true), now(), lower(coalesce(auth.jwt()->>'email','')))
  on conflict (team_code) do update set parent_entry_enabled = excluded.parent_entry_enabled, updated_at = now(), updated_by = excluded.updated_by;
end $$;
revoke all on function public.set_parent_entry(text, boolean) from public;
grant execute on function public.set_parent_entry(text, boolean) to authenticated;

-- May a parent add/remove meet entries for this athlete? (coaches always can)
create or replace function public.parent_entry_allowed(reg uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.is_coach() or coalesce((select s.parent_entry_enabled from public.team_settings s join public.registrations r on r.team_code = s.team_code where r.id = reg), true)
$$;

-- The entries policies now respect the switch (coaches unaffected).
drop policy if exists "insert own or coach" on public.entries;
create policy "insert own or coach" on public.entries for insert to authenticated
  with check (public.can_manage_athlete(registration_id) and lower(entered_by) = lower(coalesce(auth.jwt()->>'email','')) and public.parent_entry_allowed(registration_id));
drop policy if exists "delete own or coach" on public.entries;
create policy "delete own or coach" on public.entries for delete to authenticated
  using (public.can_manage_athlete(registration_id) and public.parent_entry_allowed(registration_id)
         and (public.is_coach() or exists (select 1 from public.meets m where m.id = meet_id and m.status = 'open' and now() <= m.entries_close)));

-- ---------- the questionnaire ----------
create table if not exists public.meet_attendance (
  id uuid primary key default gen_random_uuid(),
  meet_id uuid not null references public.meets(id) on delete cascade,
  registration_id uuid not null references public.registrations(id) on delete cascade,
  attending boolean not null,
  event_1 uuid references public.meet_events(id) on delete set null,   -- events the parent would like the athlete in (requests, not entries)
  event_2 uuid references public.meet_events(id) on delete set null,
  note text,
  answered_by text, answered_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (meet_id, registration_id));
create index if not exists meet_attendance_meet_idx on public.meet_attendance (meet_id);
alter table public.meet_attendance enable row level security;
drop policy if exists "attendance read own or coach" on public.meet_attendance;
create policy "attendance read own or coach" on public.meet_attendance for select to authenticated using (public.can_manage_athlete(registration_id));
-- Writes only through answer_attendance() below.

create or replace function public.answer_attendance(p_meet uuid, p_reg uuid, p_attending boolean, p_event1 uuid default null, p_event2 uuid default null, p_note text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; m public.meets; nid uuid; e1 uuid := p_event1; e2 uuid := p_event2; me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  if not public.can_manage_athlete(p_reg) then raise exception 'Not your athlete.'; end if;
  select * into r from public.registrations where id = p_reg; if r.id is null then raise exception 'Athlete not found.'; end if;
  select * into m from public.meets where id = p_meet; if m.id is null then raise exception 'Meet not found.'; end if;
  if m.status = 'archived' then raise exception 'That meet is over.'; end if;
  if p_attending is null then raise exception 'Answer yes or no.'; end if;
  if not p_attending then e1 := null; e2 := null; end if;
  if e2 is not null and e2 = e1 then e2 := null; end if;
  -- Requested events must be offered at this meet for this athlete's division and gender.
  if e1 is not null and not exists (select 1 from public.meet_events v where v.id = e1 and v.meet_id = p_meet and (v.division = r.division or v.division = 'ALL') and (v.gender = r.gender or v.gender = 'Mixed')) then
    raise exception 'That first event isn''t offered for this athlete at this meet.'; end if;
  if e2 is not null and not exists (select 1 from public.meet_events v where v.id = e2 and v.meet_id = p_meet and (v.division = r.division or v.division = 'ALL') and (v.gender = r.gender or v.gender = 'Mixed')) then
    raise exception 'That second event isn''t offered for this athlete at this meet.'; end if;
  insert into public.meet_attendance (meet_id, registration_id, attending, event_1, event_2, note, answered_by, answered_at, updated_at)
  values (p_meet, p_reg, p_attending, e1, e2, nullif(trim(p_note),''), me, now(), now())
  on conflict (meet_id, registration_id) do update set attending = excluded.attending, event_1 = excluded.event_1, event_2 = excluded.event_2, note = excluded.note,
    answered_by = excluded.answered_by, updated_at = now()
  returning id into nid;
  return nid;
end $$;
revoke all on function public.answer_attendance(uuid, uuid, boolean, uuid, uuid, text) from public;
grant execute on function public.answer_attendance(uuid, uuid, boolean, uuid, uuid, text) to authenticated;
