-- ============================================================================
-- Meet volunteers (2026-10-19): "Sign me up" from the Parent Dashboard ties the spot to the signed-in login even when
-- that login is a coach / team admin / site admin (p_self = true), so the "You're signed up ✓" mark and the
-- "please volunteer" reminder work for coaches who are also parents. Coaches adding OTHER people by name pass p_self = false.
-- Safe to run twice.
-- ============================================================================
begin;

drop function if exists public.volunteer_add(uuid, text, text, uuid, text, uuid);
create or replace function public.volunteer_add(p_duty uuid, p_name text, p_phone text default null, p_registration uuid default null, p_athlete_name text default null, p_slot uuid default null, p_self boolean default false) returns uuid
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
  elsif coalesce(p_self, false) then em := me;   -- a coach signing THEMSELVES up: keep it tied to their login
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
revoke all on function public.volunteer_add(uuid, text, text, uuid, text, uuid, boolean) from public;
grant execute on function public.volunteer_add(uuid, text, text, uuid, text, uuid, boolean) to authenticated;

commit;
