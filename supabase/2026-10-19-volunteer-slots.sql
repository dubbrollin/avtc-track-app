-- ============================================================================
-- Meet volunteers, round 3 (2026-10-19) — Riley: let each team build its volunteer list the way it wants.
--   A duty (e.g. "Long jump") can be split into SLOTS, and parents sign up for a slot:
--     slot_mode = 'all'       one list for the whole duty (how it worked before)           — "3 people"
--                 'division'  one slot per division, in running order                      — "Gremlin · 3 people", "Bantam · 3 people"…
--                 'shift'     time shifts (every 1 / 2 / 3 hours)                           — "8:00–10:00 AM · 4 people"…
--                 'custom'    whatever rows the team types in
--   Who sets it up: the team the duty belongs to (its coaches / team admin) or the host team. Parents see every meet
--   their team is at: at a HOME meet the whole host list; at an AWAY meet the duties their team took.
-- Safe to run twice.
-- ============================================================================
begin;

alter table public.meet_duties add column if not exists slot_mode text not null default 'all' check (slot_mode in ('all','division','shift','custom'));

create table if not exists public.duty_slots (
  id uuid primary key default gen_random_uuid(),
  duty_id uuid not null references public.meet_duties(id) on delete cascade,
  meet_id uuid not null references public.meets(id) on delete cascade,
  label text not null,              -- "Gremlin", "Bantam Boys", "8:00–10:00 AM", "Morning"
  slots integer not null default 1 check (slots between 1 and 50),
  sort_order integer not null default 0,
  created_at timestamptz not null default now());
create index if not exists duty_slots_duty_idx on public.duty_slots (duty_id, sort_order);
alter table public.duty_slots enable row level security;
drop policy if exists "slots read" on public.duty_slots;
create policy "slots read" on public.duty_slots for select to authenticated using (public.meet_is_mine(meet_id));
grant select on public.duty_slots to authenticated;

alter table public.meet_volunteers add column if not exists slot_id uuid references public.duty_slots(id) on delete cascade;
create index if not exists meet_volunteers_slot_idx on public.meet_volunteers (slot_id);
-- one name per slot (or per duty when the duty has no slots) — the same parent CAN take two different shifts
drop index if exists public.meet_volunteers_name_idx;
create unique index if not exists meet_volunteers_name_slot_idx on public.meet_volunteers (duty_id, coalesce(slot_id, duty_id), lower(name));

-- How many people each slot has.
create or replace function public.duty_slot_counts(p_meet uuid) returns table(slot_id uuid, taken integer)
language sql stable security definer set search_path to 'public' as $$
  select s.id, (select count(*)::integer from public.meet_volunteers v where v.slot_id = s.id) from public.duty_slots s where s.meet_id = p_meet and public.meet_is_mine(p_meet)
$$;
grant execute on function public.duty_slot_counts(uuid) to authenticated;

-- May this person lay out the slots for this duty? The team that has the duty (coach / team admin) or the host.
create or replace function public.duty_can_schedule(p_duty uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select public.meet_can_host_manage(d.meet_id) or (d.team_code is not null and public.meet_team_can_manage(d.meet_id, d.team_code)) from public.meet_duties d where d.id = p_duty), false)
$$;
grant execute on function public.duty_can_schedule(uuid) to authenticated;

-- Lay out a duty's slots. p_rows = [{"label":"Gremlin","slots":3}, ...]; for mode 'all' pass one row and its slots is the head count.
-- People already signed up stay when a new slot has the same label as their old one (so re-saving doesn't wipe the list);
-- anyone whose slot is gone comes off. Going back to 'all' keeps everyone on the duty.
create or replace function public.duty_schedule(p_duty uuid, p_mode text, p_rows jsonb) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare d public.meet_duties; r jsonb; i integer := 0; lbl text; n integer; total integer := 0; nid uuid; keep jsonb;
begin
  select * into d from public.meet_duties where id = p_duty; if d.id is null then raise exception 'Duty not found.'; end if;
  if not public.duty_can_schedule(p_duty) then raise exception 'Only the team covering this duty (its coaches or team admin) or the host team can set up its sign-up list.'; end if;
  if coalesce(p_mode,'') not in ('all','division','shift','custom') then raise exception 'Pick how to split it up.'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'Add at least one row.'; end if;
  if p_mode = 'all' then
    n := coalesce((p_rows->0->>'slots')::integer, d.slots);
    if n < 1 or n > 50 then raise exception 'How many people? (1 to 50)'; end if;
    update public.meet_volunteers set slot_id = null where duty_id = p_duty;
    delete from public.duty_slots where duty_id = p_duty;
    update public.meet_duties set slot_mode = 'all', slots = n where id = p_duty;
    return 1;
  end if;
  if jsonb_array_length(p_rows) > 40 then raise exception 'That is too many rows (40 at most).'; end if;
  -- remember who was in which slot (by label) so they survive a re-save
  select coalesce(jsonb_agg(jsonb_build_object('name',v.name,'phone',v.phone,'email',v.email,'registration_id',v.registration_id,'athlete_name',v.athlete_name,'added_by',v.added_by,'created_at',v.created_at,'label',s.label)), '[]'::jsonb)
    into keep from public.meet_volunteers v join public.duty_slots s on s.id = v.slot_id where v.duty_id = p_duty;
  delete from public.duty_slots where duty_id = p_duty;
  delete from public.meet_volunteers where duty_id = p_duty;      -- people with no slot (old 'all' list) come off too: they must pick a slot
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1; lbl := nullif(trim(coalesce(r->>'label','')),''); n := coalesce(nullif(r->>'slots','')::integer, 1);
    if lbl is null then raise exception 'Row % needs a name.', i; end if;
    if n < 1 or n > 50 then raise exception '"%": how many people? (1 to 50)', lbl; end if;
    if exists (select 1 from public.duty_slots where duty_id = p_duty and lower(label) = lower(lbl)) then raise exception 'Two rows are both called "%".', lbl; end if;
    insert into public.duty_slots (duty_id, meet_id, label, slots, sort_order) values (p_duty, d.meet_id, lbl, n, i * 10) returning id into nid;
    insert into public.meet_volunteers (duty_id, meet_id, team_code, slot_id, name, phone, email, registration_id, athlete_name, added_by, created_at)
      select p_duty, d.meet_id, d.team_code, nid, k.name, k.phone, k.email, k.registration_id, k.athlete_name, k.added_by, k.created_at
      from jsonb_to_recordset(keep) as k(name text, phone text, email text, registration_id uuid, athlete_name text, added_by text, created_at timestamptz, label text)
      where lower(k.label) = lower(lbl) order by k.created_at limit n;
    total := total + n;
  end loop;
  update public.meet_duties set slot_mode = p_mode, slots = least(50, greatest(1, total)) where id = p_duty;
  return i;
end $$;
revoke all on function public.duty_schedule(uuid, text, jsonb) from public;
grant execute on function public.duty_schedule(uuid, text, jsonb) to authenticated;

-- ---------- duty_save: editing a duty that has slots keeps the head count = the slots' total ----------
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
    update public.meet_duties set name = nm, category = p_category, slots = case when cur.slot_mode = 'all' then p_slots else cur.slots end, host_only = coalesce(p_host_only,false), gender = g,
      team_code = t, assigned_by_host = (t is not null and t <> host), auto_assigned = case when t is distinct from cur.team_code then false else auto_assigned end,
      claimed_at = case when t is null then null when t is distinct from cur.team_code then now() else claimed_at end,
      claimed_by = case when t is null then null when t is distinct from cur.team_code then me else claimed_by end,
      time_note = nullif(trim(coalesce(p_time,'')),''), notes = nullif(trim(coalesce(p_notes,'')),''), sort_order = coalesce(p_sort, sort_order)
    where id = p_id returning id into nid;
    delete from public.meet_volunteers v where v.duty_id = p_id and (t is null or v.team_code <> t);
    -- a duty that changes hands starts over with one plain list: the new team lays out its own slots
    if t is distinct from cur.team_code then delete from public.duty_slots where duty_id = p_id; update public.meet_duties set slot_mode = 'all' where id = p_id; end if;
  end if;
  return nid;
end $$;
revoke all on function public.duty_save(uuid, uuid, text, text, integer, text, text, text, boolean, integer, text) from public;
grant execute on function public.duty_save(uuid, uuid, text, text, integer, text, text, text, boolean, integer, text) to authenticated;

-- ---------- duty_split: the Girls copy gets the same slot layout ----------
create or replace function public.duty_split(p_duty uuid) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare d public.meet_duties; nid uuid; me text := public.hub_me();
begin
  select * into d from public.meet_duties where id = p_duty; if d.id is null then raise exception 'Duty not found.'; end if;
  if not public.meet_can_host_manage(d.meet_id) then raise exception 'Only the host team can split a duty.'; end if;
  if d.gender is not null then raise exception 'This duty is already just for %.', lower(d.gender); end if;
  update public.meet_duties set gender = 'Boys' where id = p_duty;
  insert into public.meet_duties (meet_id, name, category, slots, team_code, assigned_by_host, host_only, time_note, notes, sort_order, created_by, gender, auto_assigned, claimed_at, claimed_by, slot_mode)
  values (d.meet_id, d.name, d.category, d.slots, d.team_code, d.assigned_by_host, d.host_only, d.time_note, d.notes, d.sort_order + 1, me, 'Girls', d.auto_assigned, d.claimed_at, d.claimed_by, d.slot_mode)
  returning id into nid;
  insert into public.duty_slots (duty_id, meet_id, label, slots, sort_order) select nid, d.meet_id, label, slots, sort_order from public.duty_slots where duty_id = p_duty;
  return nid;
end $$;
revoke all on function public.duty_split(uuid) from public;
grant execute on function public.duty_split(uuid) to authenticated;

-- ---------- duty_claim: giving a duty back also clears the slot layout ----------
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
    update public.meet_duties set team_code = p_team, assigned_by_host = hosting and p_team <> host, auto_assigned = false, claimed_at = now(), claimed_by = me
      where id = p_duty and team_code is null returning id into got;
    if got is null then raise exception 'Another team just took this one — pick a different duty.'; end if;
  else
    if d.team_code is distinct from p_team then return; end if;
    if d.assigned_by_host and not hosting then raise exception 'The host assigned this duty to your team — ask the host team to change it.'; end if;
    if d.host_only then raise exception 'Host-team duties stay with the host.'; end if;
    update public.meet_duties set team_code = null, assigned_by_host = false, auto_assigned = false, claimed_at = null, claimed_by = null, slot_mode = 'all' where id = p_duty;
    delete from public.meet_volunteers where duty_id = p_duty;
    delete from public.duty_slots where duty_id = p_duty;
  end if;
end $$;
revoke all on function public.duty_claim(uuid, text, boolean) from public;
grant execute on function public.duty_claim(uuid, text, boolean) to authenticated;

-- ---------- sign up: for a slot when the duty has slots, otherwise for the duty ----------
drop function if exists public.volunteer_add(uuid, text, text, uuid, text);
create or replace function public.volunteer_add(p_duty uuid, p_name text, p_phone text default null, p_registration uuid default null, p_athlete_name text default null, p_slot uuid default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.hub_me(); d public.meet_duties; s public.duty_slots; nm text := nullif(trim(coalesce(p_name,'')),''); taken integer; cap integer; nid uuid; mgr boolean; em text;
begin
  if me = '' then raise exception 'Please sign in.'; end if;
  select * into d from public.meet_duties where id = p_duty; if d.id is null then raise exception 'Duty not found.'; end if;
  if d.team_code is null then raise exception 'No team has taken this duty yet.'; end if;
  if nm is null then raise exception 'Whose name goes on it?'; end if;
  mgr := public.meet_team_can_manage(d.meet_id, d.team_code);
  if not mgr then
    if public.team_member_role(d.team_code) is distinct from 'parent' then raise exception 'This duty belongs to another team.'; end if;
    em := me;
  else em := null; end if;
  if d.slot_mode <> 'all' then
    if p_slot is null then raise exception 'Pick a spot on the list.'; end if;
    select * into s from public.duty_slots where id = p_slot and duty_id = p_duty; if s.id is null then raise exception 'That spot is not on this duty.'; end if;
    select count(*) into taken from public.meet_volunteers where slot_id = p_slot; cap := s.slots;
    if taken >= cap then raise exception '"%" is full — thank you! Pick another spot.', s.label; end if;
    if exists (select 1 from public.meet_volunteers v where v.slot_id = p_slot and lower(v.name) = lower(nm)) then raise exception '% is already signed up for %.', nm, s.label; end if;
  else
    p_slot := null;
    select count(*) into taken from public.meet_volunteers where duty_id = p_duty; cap := d.slots;
    if taken >= cap then raise exception 'This duty is full — thank you! Pick another one.'; end if;
    if exists (select 1 from public.meet_volunteers v where v.duty_id = p_duty and lower(v.name) = lower(nm)) then raise exception '% is already signed up for this.', nm; end if;
  end if;
  insert into public.meet_volunteers (duty_id, meet_id, team_code, slot_id, name, phone, email, registration_id, athlete_name, added_by)
  values (p_duty, d.meet_id, d.team_code, p_slot, nm, nullif(trim(coalesce(p_phone,'')),''), em, p_registration, nullif(trim(coalesce(p_athlete_name,'')),''), me)
  returning id into nid;
  return nid;
end $$;
revoke all on function public.volunteer_add(uuid, text, text, uuid, text, uuid) from public;
grant execute on function public.volunteer_add(uuid, text, text, uuid, text, uuid) to authenticated;

commit;
