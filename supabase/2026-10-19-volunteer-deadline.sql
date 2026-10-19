-- ============================================================================
-- Meet volunteers, round 2 (2026-10-19) — Riley's rules:
--   * Visiting teams take the open duties (field events) at meets they visit: FIRST COME, FIRST SERVED, and one team
--     per duty — once a team has it, nobody else can take it. Taking one is atomic (two teams can't both get it).
--   * Field events can be split BOYS / GIRLS (usually only long jump): a duty carries gender = 'Boys' | 'Girls' | null (both).
--   * DEADLINE: Thursday 8:00 PM before the meet (same clock as "is your athlete coming?"). After that visiting teams can't
--     take or give back duties; whatever is still open is ASSIGNED to the visiting teams automatically (fewest duties first)
--     by duties_settle(), which the app calls whenever someone opens the meet after the deadline. The host can still change
--     anything by hand.
-- Safe to run twice.
-- ============================================================================
begin;

alter table public.meet_duties add column if not exists gender text check (gender in ('Boys','Girls'));
alter table public.meet_duties add column if not exists auto_assigned boolean not null default false;
alter table public.meet_duties add column if not exists claimed_at timestamptz;
alter table public.meet_duties add column if not exists claimed_by text;

-- Thursday 8 PM before the meet (null when the meet has no date).
create or replace function public.duty_deadline(p_meet uuid) returns timestamptz
language sql stable security definer set search_path to 'public' as $$
  select public.attendance_deadline(m.meet_date) from public.meets m where m.id = p_meet and m.meet_date is not null
$$;
grant execute on function public.duty_deadline(uuid) to anon, authenticated;
create or replace function public.duty_deadline_passed(p_meet uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce(now() > public.duty_deadline(p_meet), false)
$$;
grant execute on function public.duty_deadline_passed(uuid) to anon, authenticated;

-- ---------- host: add / change a duty (now with Boys / Girls) ----------
drop function if exists public.duty_save(uuid, uuid, text, text, integer, text, text, text, boolean, integer);
create or replace function public.duty_save(p_id uuid, p_meet uuid, p_name text, p_category text, p_slots integer, p_team text default null, p_time text default null, p_notes text default null, p_host_only boolean default false, p_sort integer default null, p_gender text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.hub_me(); nm text := nullif(trim(coalesce(p_name,'')),''); nid uuid; t text := nullif(trim(coalesce(p_team,'')),''); mid uuid := p_meet; host text; cur public.meet_duties; g text := nullif(trim(coalesce(p_gender,'')),'');
begin
  if p_id is not null then select * into cur from public.meet_duties where id = p_id; if cur.id is null then raise exception 'Duty not found.'; end if; mid := cur.meet_id; end if;
  if not public.meet_can_host_manage(mid) then raise exception 'Only the host team''s coaches and team admin (or a site admin) can set up this meet''s duties.'; end if;
  if nm is null then raise exception 'Name the duty.'; end if;
  if coalesce(p_category,'') not in ('field','track','meet','hospitality','setup','other') then raise exception 'Pick a category.'; end if;
  if coalesce(p_slots,0) < 1 or p_slots > 50 then raise exception 'How many people? (1 to 50)'; end if;
  if g is not null and g not in ('Boys','Girls') then raise exception 'Boys, Girls, or leave it blank for both.'; end if;
  host := public.meet_host_team(mid);
  if t is not null and not public.meet_includes_team(mid, t) then raise exception 'That team is not competing at this meet.'; end if;
  if p_host_only then t := host; end if;
  if p_id is null then
    insert into public.meet_duties (meet_id, name, category, slots, team_code, assigned_by_host, host_only, time_note, notes, sort_order, created_by, gender, claimed_at, claimed_by)
    values (mid, nm, p_category, p_slots, t, t is not null and t <> host, coalesce(p_host_only,false), nullif(trim(coalesce(p_time,'')),''), nullif(trim(coalesce(p_notes,'')),''),
            coalesce(p_sort, (select coalesce(max(sort_order),0)+10 from public.meet_duties where meet_id = mid)), me, g, case when t is not null then now() end, case when t is not null then me end)
    returning id into nid;
  else
    update public.meet_duties set name = nm, category = p_category, slots = p_slots, host_only = coalesce(p_host_only,false), gender = g,
      team_code = t, assigned_by_host = (t is not null and t <> host), auto_assigned = case when t is distinct from cur.team_code then false else auto_assigned end,
      claimed_at = case when t is null then null when t is distinct from cur.team_code then now() else claimed_at end,
      claimed_by = case when t is null then null when t is distinct from cur.team_code then me else claimed_by end,
      time_note = nullif(trim(coalesce(p_time,'')),''), notes = nullif(trim(coalesce(p_notes,'')),''), sort_order = coalesce(p_sort, sort_order)
    where id = p_id returning id into nid;
    delete from public.meet_volunteers v where v.duty_id = p_id and (t is null or v.team_code <> t);
  end if;
  return nid;
end $$;
revoke all on function public.duty_save(uuid, uuid, text, text, integer, text, text, text, boolean, integer, text) from public;
grant execute on function public.duty_save(uuid, uuid, text, text, integer, text, text, text, boolean, integer, text) to authenticated;

-- Host: split a field event into a Boys duty and a Girls duty (e.g. long jump when two teams run it).
create or replace function public.duty_split(p_duty uuid) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare d public.meet_duties; nid uuid; me text := public.hub_me();
begin
  select * into d from public.meet_duties where id = p_duty; if d.id is null then raise exception 'Duty not found.'; end if;
  if not public.meet_can_host_manage(d.meet_id) then raise exception 'Only the host team can split a duty.'; end if;
  if d.gender is not null then raise exception 'This duty is already just for %.', lower(d.gender); end if;
  update public.meet_duties set gender = 'Boys' where id = p_duty;
  insert into public.meet_duties (meet_id, name, category, slots, team_code, assigned_by_host, host_only, time_note, notes, sort_order, created_by, gender, auto_assigned, claimed_at, claimed_by)
  values (d.meet_id, d.name, d.category, d.slots, d.team_code, d.assigned_by_host, d.host_only, d.time_note, d.notes, d.sort_order + 1, me, 'Girls', d.auto_assigned, d.claimed_at, d.claimed_by)
  returning id into nid;
  return nid;
end $$;
revoke all on function public.duty_split(uuid) from public;
grant execute on function public.duty_split(uuid) to authenticated;

-- ---------- the standard VYC list: long jump comes split Boys / Girls ----------
create or replace function public.duties_add_standard(p_meet uuid) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.hub_me(); host text; n integer := 0;
begin
  if not public.meet_can_host_manage(p_meet) then raise exception 'Only the host team can set up this meet''s duties.'; end if;
  if exists (select 1 from public.meet_duties where meet_id = p_meet) then return 0; end if;
  host := public.meet_host_team(p_meet);
  insert into public.meet_duties (meet_id, name, category, slots, team_code, assigned_by_host, host_only, time_note, notes, sort_order, created_by, gender)
  select p_meet, v.name, v.cat, v.slots, case when v.is_host then host end, false, v.is_host, v.t, v.notes, v.ord, me, v.g
  from (values
    ('Set-up crew',            'setup',       4, true,  '7:00 AM',           'Hurdles, blocks, pits, tents, tables', 10, null),
    ('Clerk of the course',    'meet',        2, true,  '8:15 AM – done',    'Check athletes in and line up the heats', 20, null),
    ('Starter',                'track',       1, true,  '8:45 AM – done',    null, 30, null),
    ('Finish line & timing',   'track',       3, true,  '8:45 AM – done',    'Help the timers; hand off results', 40, null),
    ('Hurdle crew',            'track',       3, true,  'Hurdle races',      'Set and clear hurdles', 50, null),
    ('Announcer',              'meet',        1, true,  'All day',           null, 60, null),
    ('Awards table',           'meet',        2, true,  '10:00 AM – done',   'Ribbons and results posting', 70, null),
    ('Snack bar',              'hospitality', 4, true,  'Shifts',            null, 80, null),
    ('First aid',              'meet',        1, true,  'All day',           null, 90, null),
    ('Clean-up crew',          'setup',       4, true,  'After the last race', null, 100, null),
    ('Long jump',              'field',       3, false, '8:30 AM – done',    'Visiting team: measure, rake, record', 200, 'Boys'),
    ('Long jump',              'field',       3, false, '8:30 AM – done',    'Visiting team: measure, rake, record', 201, 'Girls'),
    ('High jump',              'field',       3, false, '8:30 AM – done',    'Visiting team: set the bar, judge, record (boys and girls)', 210, null),
    ('Shot put',               'field',       3, false, '8:30 AM – done',    'Visiting team: measure, return the shots, record (boys and girls)', 220, null),
    ('Javelin',                'field',       3, false, '8:30 AM – done',    'Visiting team: measure, retrieve, record (boys and girls)', 230, null)
  ) v(name, cat, slots, is_host, t, notes, ord, g);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.duties_add_standard(uuid) from public;
grant execute on function public.duties_add_standard(uuid) to authenticated;

-- ---------- visiting team takes an open duty: first come, first served, atomic; closed after the deadline ----------
create or replace function public.duty_claim(p_duty uuid, p_team text, p_take boolean default true) returns void
language plpgsql security definer set search_path to 'public' as $$
declare d public.meet_duties; host text; hosting boolean; me text := public.hub_me(); got uuid;
begin
  select * into d from public.meet_duties where id = p_duty; if d.id is null then raise exception 'Duty not found.'; end if;
  if not public.meet_team_can_manage(d.meet_id, p_team) then raise exception 'Only a coach or team admin of that team can take duties for it.'; end if;
  host := public.meet_host_team(d.meet_id); hosting := public.meet_can_host_manage(d.meet_id);
  if d.host_only and not hosting then raise exception 'That is a host-team duty.'; end if;
  if not hosting and public.duty_deadline_passed(d.meet_id) then
    raise exception 'The deadline for picking duties (Thursday 8:00 PM) has passed — what was left has been assigned. Ask the host team if you need a change.'; end if;
  if p_take then
    if d.team_code = p_team then return; end if;
    -- one team per duty: only an OPEN duty can be taken, and only one taker wins
    update public.meet_duties set team_code = p_team, assigned_by_host = hosting and p_team <> host, auto_assigned = false, claimed_at = now(), claimed_by = me
      where id = p_duty and team_code is null returning id into got;
    if got is null then raise exception 'Another team just took this one — pick a different duty.'; end if;
  else
    if d.team_code is distinct from p_team then return; end if;
    if d.assigned_by_host and not hosting then raise exception 'The host assigned this duty to your team — ask the host team to change it.'; end if;
    if d.host_only then raise exception 'Host-team duties stay with the host.'; end if;
    update public.meet_duties set team_code = null, assigned_by_host = false, auto_assigned = false, claimed_at = null, claimed_by = null where id = p_duty;
    delete from public.meet_volunteers where duty_id = p_duty;
  end if;
end $$;
revoke all on function public.duty_claim(uuid, text, boolean) from public;
grant execute on function public.duty_claim(uuid, text, boolean) to authenticated;

-- ---------- after the deadline: hand every open duty to a visiting team (fewest duties first, then alphabetical) ----------
-- Anyone on a team at the meet may call it (the app does, whenever the meet is opened after the deadline); it only does anything once.
create or replace function public.duties_settle(p_meet uuid) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare host text; m public.meets; visitors text[]; d record; pick text; n integer := 0;
begin
  if not public.meet_is_mine(p_meet) then return 0; end if;
  if not public.duty_deadline_passed(p_meet) then return 0; end if;
  select * into m from public.meets where id = p_meet; host := m.host_team_code;
  -- only meets with a known team list (a league week) are settled; invitationals open to everyone are left to the host
  select array_agg(t order by t) into visitors from unnest(coalesce(m.team_codes, '{}')) t where t is distinct from host;
  if visitors is null or cardinality(visitors) = 0 then return 0; end if;
  for d in select * from public.meet_duties where meet_id = p_meet and team_code is null and not host_only order by sort_order, name loop
    select t into pick from unnest(visitors) t
      order by (select count(*) from public.meet_duties x where x.meet_id = p_meet and x.team_code = t and not x.host_only), t limit 1;
    update public.meet_duties set team_code = pick, assigned_by_host = true, auto_assigned = true, claimed_at = now(), claimed_by = 'deadline' where id = d.id and team_code is null;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.duties_settle(uuid) from public;
grant execute on function public.duties_settle(uuid) to authenticated;

commit;
