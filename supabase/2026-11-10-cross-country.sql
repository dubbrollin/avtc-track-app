-- 2026-11-10: Cross Country is its own league inside the app.
--  * Teams: each team says whether it is in the Track & Field league, the Cross Country league, or both
--    (some track teams don't run cross country, and some cross country teams don't run track).
--  * Cross country has its own season year and its own registration window (opens / closes) and season
--    start / end dates, all set by the site admin in League Setup (app_settings keys below).
--  * Track-only rules don't touch cross country registrations: the track late check / late passes, the
--    track league fees, team payment fees, and track transfer approvals.
--  * Proof of birth: an athlete whose name + birth date match a VERIFIED VYC registration (track or cross
--    country, any team) doesn't upload proof again — so a track athlete signing up for cross country skips it.
--  * Certification: as for track (the team's Conference President), plus site admins may certify cross
--    country athletes (cross-country-only teams may not belong to an East/West conference).
-- Settings (app_settings): xc_season_year, xc_registration_open_<yr>, xc_registration_close_<yr>,
--   xc_season_start_<yr>, xc_season_end_<yr>   (dates as YYYY-MM-DD; blank = not set)
begin;

alter table public.league_teams add column if not exists in_track boolean not null default true;
alter table public.league_teams add column if not exists in_xc boolean not null default false;
alter table public.league_teams alter column conference drop not null;   -- a cross-country-only team may have no East/West conference

-- ---------- settings helpers ----------
create or replace function public.xc_season()
returns integer language sql stable security definer set search_path to 'public' as $$
  select coalesce((select nullif(value,'')::int from public.app_settings where key = 'xc_season_year'), public.current_season())
$$;
create or replace function public.xc_date(p_key text, p_season integer)
returns date language sql stable security definer set search_path to 'public' as $$
  select nullif(value,'')::date from public.app_settings where key = 'xc_' || p_key || '_' || p_season
$$;
grant execute on function public.xc_season() to anon, authenticated;
grant execute on function public.xc_date(text, integer) to anon, authenticated;

-- ---------- cross country registration window (replaces the track late check for XC) ----------
create or replace function public.reg_xc_window()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare s integer := coalesce(new.season_year, public.xc_season());
  op date := public.xc_date('registration_open', s); cl date := public.xc_date('registration_close', s);
  today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  new.is_late := false; new.late_pass_id := null;
  if not exists (select 1 from public.league_teams t where t.code = new.team_code and t.in_xc and t.active) then
    raise exception 'That team isn''t in the cross country league. Pick one of the cross country teams.';
  end if;
  if op is not null and today < op then
    raise exception 'Cross country registration for the % season opens on %.', s, to_char(op, 'FMMonth FMDD, YYYY');
  end if;
  if cl is not null and today > cl then
    raise exception 'Cross country registration for the % season closed on %. Contact your team.', s, to_char(cl, 'FMMonth FMDD, YYYY');
  end if;
  return new;
end $$;

-- ---------- proof of birth for cross country ----------
create or replace function public.reg_xc_verify()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare p record;
begin
  if coalesce(trim(new.proof_path),'') <> '' then return new; end if;
  select r.* into p from public.registrations r
   where r.id <> new.id and r.status = 'verified' and r.dob = new.dob
     and public.name_key(r.first_name) = public.name_key(new.first_name)
     and public.name_key(r.last_name) = public.name_key(new.last_name)
   order by r.season_year desc, r.created_at desc limit 1;
  if p.id is null then
    raise exception 'Please upload proof of birth. (Athletes whose name and birth date match a verified VYC track or cross country registration can skip it.)';
  end if;
  new.proof_path := null;
  new.dob_check_status := 'match';
  new.dob_check_note := 'Name and birth date match the verified ' || coalesce(p.season_year::text,'') || ' ' || coalesce(p.sport,'') ||
                        ' record (' || coalesce(p.team_code,'') || '). No proof of birth needed.';
  return new;
end $$;

-- The cross country form asks this as the name + birth date are typed: true = no proof of birth needed (yes/no only, no details).
create or replace function public.xc_birth_verified(p_first text, p_last text, p_dob date)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select p_dob is not null and length(public.name_key(p_first)) >= 1 and length(public.name_key(p_last)) >= 2
     and exists (select 1 from public.registrations r where r.status = 'verified' and r.dob = p_dob
                  and public.name_key(r.first_name) = public.name_key(p_first) and public.name_key(r.last_name) = public.name_key(p_last))
$$;
revoke all on function public.xc_birth_verified(text,text,date) from public;
grant execute on function public.xc_birth_verified(text,text,date) to authenticated;

-- ---------- high-school rule, cross country wording (CIF: no high school XC + club XC in the same season) ----------
create or replace function public.reg_xc_hs_rule()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(new.age_on_dec31,0) >= 13 and new.in_high_school is null then
    raise exception 'Please answer: is this athlete in high school?';
  end if;
  if new.in_high_school and new.hs_track_this_season is null then
    raise exception 'Please answer: is this athlete running with their current high school cross country team?';
  end if;
  if new.hs_track_this_season then
    raise exception 'This athlete can''t be registered: running for a high school cross country team and a VYC team in the same season is against California CIF rules (VYC rule IV.A.2).';
  end if;
  return new;
end $$;

-- ---------- triggers: track-only rules skip cross country; cross country gets its own ----------
drop trigger if exists reg_late_check_trg on public.registrations;
create trigger reg_late_check_trg before insert on public.registrations for each row
  when (new.sport is distinct from 'Cross Country') execute function public.reg_late_check();
drop trigger if exists reg_xc_window_trg on public.registrations;
create trigger reg_xc_window_trg before insert on public.registrations for each row
  when (new.sport = 'Cross Country') execute function public.reg_xc_window();

drop trigger if exists reg_returning_verify_trg on public.registrations;
create trigger reg_returning_verify_trg before insert on public.registrations for each row
  when (new.sport is distinct from 'Cross Country') execute function public.reg_returning_verify();
drop trigger if exists reg_xc_verify_trg on public.registrations;
create trigger reg_xc_verify_trg before insert on public.registrations for each row
  when (new.sport = 'Cross Country') execute function public.reg_xc_verify();

drop trigger if exists reg_hs_rule_trg on public.registrations;
create trigger reg_hs_rule_trg before insert on public.registrations for each row
  when (new.sport is distinct from 'Cross Country') execute function public.reg_hs_rule();
drop trigger if exists reg_xc_hs_rule_trg on public.registrations;
create trigger reg_xc_hs_rule_trg before insert on public.registrations for each row
  when (new.sport = 'Cross Country') execute function public.reg_xc_hs_rule();

drop trigger if exists reg_charges_trg on public.registrations;
create trigger reg_charges_trg after insert on public.registrations for each row
  when (new.sport is distinct from 'Cross Country') execute function public.reg_charges();
drop trigger if exists reg_make_fee on public.registrations;
create trigger reg_make_fee after insert on public.registrations for each row
  when (new.sport is distinct from 'Cross Country') execute function public.reg_make_fee_trg();
drop trigger if exists reg_clearance_trg on public.registrations;
create trigger reg_clearance_trg after insert on public.registrations for each row
  when (new.sport is distinct from 'Cross Country') execute function public.reg_make_clearance();

-- ---------- certification: site admins may also certify / edit cross country athletes ----------
create or replace function public.reg_cert_guard()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare
  claims text := current_setting('request.jwt.claims', true);
  me text := lower(coalesce(auth.jwt()->>'email',''));
  free text[] := array['status','verified_by','verified_at','reviewed_by','reviewed_at','coach_note','comp_number',
    'dob_check_status','dob_extracted','name_extracted','dob_check_note','dob_checked_at','prior_registration_id'];
  c_old text; c_new text; nm text; pres_ok boolean;
begin
  if coalesce(current_setting('vyc.cert_bypass', true),'') = 'on' or coalesce(claims,'') = ''
     or coalesce(claims::jsonb->>'role','') = 'service_role' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if tg_op = 'INSERT' then
    new.status := 'submitted'; new.verified_by := null; new.verified_at := null;
    new.reviewed_by := null; new.reviewed_at := null;
    return new;
  end if;

  if tg_op = 'DELETE' then
    -- Results from a past (locked) season stay linked to the athlete, so that athlete can't be deleted.
    if exists (select 1 from public.results x where x.registration_id = old.id and public.meet_is_locked(x.meet_id)) then
      raise exception '% % has results from a past season. Those results are locked and stay with the athlete, so this athlete can''t be deleted. Use Reject instead.', old.first_name, old.last_name;
    end if;
    if old.contract_version = 'ROSTER-2026' then return old; end if; -- test-roster cleanup button (until go-live)
    if public.is_site_admin() or public.is_president_of(public.team_conference(old.team_code)) then return old; end if;
    if public.is_team_admin_of(old.team_code) then
      if old.status = 'verified' then
        raise exception 'This athlete is certified. Only a site admin or the Conference President can delete a certified athlete.';
      end if;
      return old;
    end if;
    raise exception 'Only a site admin, this team''s team admin, or the Conference President can delete an athlete.';
  end if;

  c_old := public.team_conference(old.team_code); c_new := public.team_conference(new.team_code);
  nm := coalesce(case c_old when 'East' then 'Eastern' when 'West' then 'Western' end,'');
  -- Track: the Conference President. Cross country: the Conference President, or a site admin.
  pres_ok := (public.is_president_of(c_old) and public.is_president_of(c_new))
          or (old.sport = 'Cross Country' and new.sport = 'Cross Country' and public.is_site_admin());

  if (to_jsonb(old) - free) is distinct from (to_jsonb(new) - free) and not pres_ok then
    raise exception 'Only the % Conference President can change athlete information. Site admins: your change is sent to the president for approval from the Athletes tab.', nm;
  end if;

  if new.status is distinct from old.status then
    if new.status = 'verified' or old.status = 'verified' then
      if not pres_ok then
        raise exception 'Only the % Conference President can certify an athlete (or undo a certification).', nm;
      end if;
    elsif not (public.is_team_admin_of(old.team_code) or public.is_site_admin() or public.is_president_of(c_old)) then
      raise exception 'Only a team admin for this team can review registrations.';
    end if;
    if new.status = 'verified' then new.verified_by := me; new.verified_at := now();
    elsif old.status = 'verified' then new.verified_by := null; new.verified_at := null; end if;
    if new.status = 'reviewed' and old.status is distinct from 'verified' then new.reviewed_by := me; new.reviewed_at := now(); end if;
  else
    new.verified_by := old.verified_by; new.verified_at := old.verified_at;
    new.reviewed_by := old.reviewed_by; new.reviewed_at := old.reviewed_at;
  end if;
  return new;
end $function$;

-- Default: the cross country season year = the current league season until the site admin sets it.
insert into public.app_settings (key, value) values ('xc_season_year', (select public.current_season())::text) on conflict (key) do nothing;

commit;
notify pgrst, 'reload schema';
