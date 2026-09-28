-- 2026-09-27: Conference President certification.
-- Only the two VYC Conference Presidents can certify (status 'verified') or change an athlete:
--   the Eastern Conference President for Eastern teams, the Western Conference President for Western teams.
-- Team admins do the FIRST review only (status 'reviewed' = "Team reviewed", or 'rejected').
-- A site admin can't change athlete information directly: the change becomes a request that the
-- president of that athlete's conference approves (athlete_change_requests).
-- Presidents are requested on the Team Admin sign-up, approved by a site admin, and must be
-- re-confirmed every season (president_season = current season) because of elections every 2 years.
begin;

-- ---------- who is a president ----------
alter table public.coaches add column if not exists president_conference text;
alter table public.coaches add column if not exists president_season integer;
alter table public.coaches add column if not exists requested_president_conference text;
alter table public.coaches drop constraint if exists coaches_president_conf_check;
alter table public.coaches add constraint coaches_president_conf_check
  check ((president_conference is null or president_conference in ('East','West'))
     and (requested_president_conference is null or requested_president_conference in ('East','West')));
-- One president per conference per season.
create unique index if not exists coaches_one_president_per_conf
  on public.coaches (president_conference, president_season) where president_conference is not null;

-- The presidents on file (elected every 2 years; site admin updates these in People & Access).
insert into public.app_settings (key, value) values ('expected_president_East', 'Tiffany Armstead'), ('expected_president_West', 'Adrina Thomas')
  on conflict (key) do nothing;

create or replace function public.team_conference(t text)
returns text language sql stable security definer set search_path to 'public' as $$
  select conference from public.league_teams where code = t
$$;

create or replace function public.is_president_of(conf text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select conf is not null and exists (
    select 1 from public.coaches c
     where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
       and c.approved is true and c.president_conference = conf
       and c.president_season = public.current_season())
$$;

-- Only a site admin can make someone a president (or re-confirm them for a new season).
create or replace function public.coaches_guard()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if coalesce(current_setting('request.jwt.claims', true),'') = '' or public.is_site_admin() then return new; end if;
  if new.is_admin is distinct from old.is_admin then
    raise exception 'Only a site admin can change site-admin access';
  end if;
  if new.president_conference is distinct from old.president_conference
     or new.president_season is distinct from old.president_season then
    raise exception 'Only a site admin can confirm a Conference President';
  end if;
  if new.team_code is distinct from old.team_code or lower(new.email) is distinct from lower(old.email) then
    raise exception 'Only a site admin can change a coach team or email';
  end if;
  if new.approved is distinct from old.approved
     or new.role_type is distinct from old.role_type
     or new.team_admin is distinct from old.team_admin then
    if lower(old.email) = lower(coalesce(auth.jwt()->>'email',''))
       or not public.is_team_admin_of(old.team_code) then
      raise exception 'Only an admin for this team can approve coaches, change roles, or grant team-admin access (and not for yourself)';
    end if;
  end if;
  return new;
end $function$;

drop policy if exists coaches_register on public.coaches;
create policy coaches_register on public.coaches for insert
  with check (coalesce(approved,false) = false and coalesce(is_admin,false) = false
              and coalesce(team_admin,false) = false and president_conference is null);

-- Team Admin sign-up: now also asks "Do you hold any of these positions?" (p_president = 'East' / 'West' / null).
drop function if exists public.submit_team_admin_request(text,text,text,text,text,date,boolean,date,boolean);
create or replace function public.submit_team_admin_request(
  p_first text, p_last text, p_phone text, p_team text, p_title text,
  p_bg_date date default null, p_usatf boolean default false, p_usatf_date date default null, p_contract boolean default false,
  p_president text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_email text := coalesce(auth.jwt()->>'email','');
begin
  if v_email = '' then raise exception 'Please sign in first.'; end if;
  if coalesce(trim(p_first),'') = '' or coalesce(trim(p_last),'') = '' or coalesce(trim(p_team),'') = '' then
    raise exception 'Name and team are required.'; end if;
  if coalesce(trim(p_title),'') = '' then raise exception 'Please choose your role on the team.'; end if;
  if nullif(p_president,'') is not null and p_president not in ('East','West') then
    raise exception 'Pick Eastern or Western Conference President (or neither).'; end if;
  if exists (select 1 from public.coaches where lower(email) = lower(v_email)) then
    raise exception 'You already have a coach or team admin request on file. Ask your site admin to update it.'; end if;
  insert into public.coaches (email, first_name, last_name, phone, team_code, role_type, admin_title, requested_team_admin,
    requested_president_conference,
    background_check_date, usatf_certified, usatf_cert_date, contract_signed_at, contract_version, approved, season_year)
  values (v_email, trim(p_first), trim(p_last), trim(p_phone), trim(p_team),
    case when p_title = 'Head Coach' then 'head_coach' else 'team_staff' end, trim(p_title), true,
    nullif(p_president,''),
    p_bg_date, coalesce(p_usatf,false), p_usatf_date,
    case when p_contract then now() end, case when p_contract then 'VYC-2026' end, false,
    public.current_season());
end $$;
revoke all on function public.submit_team_admin_request(text,text,text,text,text,date,boolean,date,boolean,text) from public;
grant execute on function public.submit_team_admin_request(text,text,text,text,text,date,boolean,date,boolean,text) to authenticated;

-- ---------- registrations: 'reviewed' status + who reviewed ----------
alter table public.registrations add column if not exists reviewed_by text;
alter table public.registrations add column if not exists reviewed_at timestamptz;
alter table public.registrations drop constraint if exists registrations_status_check;
alter table public.registrations add constraint registrations_status_check
  check (status in ('submitted','reviewed','verified','rejected','archived'));

-- Presidents see and work on every athlete in their own conference.
drop policy if exists "presidents read conference" on public.registrations;
create policy "presidents read conference" on public.registrations for select
  using (public.is_president_of(public.team_conference(team_code)));
drop policy if exists "presidents update conference" on public.registrations;
create policy "presidents update conference" on public.registrations for update
  using (public.is_president_of(public.team_conference(team_code)))
  with check (public.is_president_of(public.team_conference(team_code)));
drop policy if exists "presidents delete conference" on public.registrations;
create policy "presidents delete conference" on public.registrations for delete
  using (public.is_president_of(public.team_conference(team_code)));

-- The rule itself, enforced in the database no matter which page makes the change.
create or replace function public.reg_cert_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  claims text := current_setting('request.jwt.claims', true);
  me text := lower(coalesce(auth.jwt()->>'email',''));
  -- Fields that are NOT athlete information (workflow, system and numbering fields).
  free text[] := array['status','verified_by','verified_at','reviewed_by','reviewed_at','coach_note','comp_number',
    'dob_check_status','dob_extracted','name_extracted','dob_check_note','dob_checked_at','prior_registration_id'];
  c_old text; c_new text; nm text;
begin
  -- Approved change requests, direct database maintenance and the server-side ID checker pass through.
  if coalesce(current_setting('vyc.cert_bypass', true),'') = 'on' or coalesce(claims,'') = ''
     or coalesce(claims::jsonb->>'role','') = 'service_role' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if tg_op = 'INSERT' then
    -- A new registration always starts un-reviewed, whoever submits it.
    new.status := 'submitted'; new.verified_by := null; new.verified_at := null;
    new.reviewed_by := null; new.reviewed_at := null;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.contract_version = 'ROSTER-2026' then return old; end if; -- test-roster cleanup button (until go-live)
    if not public.is_president_of(public.team_conference(old.team_code)) then
      raise exception 'Only the % Conference President can remove an athlete. Site admins: send a change request from the Athletes tab.',
        coalesce(case public.team_conference(old.team_code) when 'East' then 'Eastern' when 'West' then 'Western' end,'');
    end if;
    return old;
  end if;

  c_old := public.team_conference(old.team_code); c_new := public.team_conference(new.team_code);
  nm := coalesce(case c_old when 'East' then 'Eastern' when 'West' then 'Western' end,'');

  if (to_jsonb(old) - free) is distinct from (to_jsonb(new) - free)
     and not (public.is_president_of(c_old) and public.is_president_of(c_new)) then
    raise exception 'Only the % Conference President can change athlete information. Site admins: your change is sent to the president for approval from the Athletes tab.', nm;
  end if;

  if new.status is distinct from old.status then
    if new.status = 'verified' or old.status = 'verified' then
      if not (public.is_president_of(c_old) and public.is_president_of(c_new)) then
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
end $$;
drop trigger if exists reg_cert_guard_trg on public.registrations;
create trigger reg_cert_guard_trg before insert or update or delete on public.registrations
  for each row execute function public.reg_cert_guard();

-- Presidents (and every team admin, who now does the first review) can open proof-of-birth documents.
drop policy if exists "presidents and team admins view proof" on storage.objects;
create policy "presidents and team admins view proof" on storage.objects for select
  using (bucket_id = 'proof-of-birth' and exists (
    select 1 from public.registrations r where r.proof_path = storage.objects.name
      and (public.is_president_of(public.team_conference(r.team_code)) or public.is_team_admin_of(r.team_code))));

-- ---------- site-admin change requests ----------
create table if not exists public.athlete_change_requests (
  id uuid primary key default gen_random_uuid(),
  registration_id uuid references public.registrations(id) on delete set null,
  team_code text, conference text not null, athlete_name text,
  kind text not null default 'edit' check (kind in ('edit','delete')),
  changes jsonb not null default '{}'::jsonb, old_values jsonb not null default '{}'::jsonb,
  reason text, requested_by text, requested_at timestamptz not null default now(),
  status text not null default 'pending' check (status in ('pending','approved','declined','cancelled')),
  decided_by text, decided_at timestamptz, decision_note text);
alter table public.athlete_change_requests enable row level security;
drop policy if exists "site admins and presidents read" on public.athlete_change_requests;
create policy "site admins and presidents read" on public.athlete_change_requests for select
  using (public.is_site_admin() or public.is_president_of(conference));
-- No direct writes: only through the two functions below.

create or replace function public.request_athlete_change(p_reg uuid, p_kind text, p_changes jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; k text; olds jsonb := '{}'::jsonb; nid uuid;
  allowed text[] := array['first_name','last_name','gender','dob','division','team_code','status','sport','age_on_dec31',
    'parent1_name','parent1_relationship','parent2_name','parent2_relationship','phone','email','address','city','zip',
    'emergency_name','emergency_phone','coach_note','is_returning','prior_team','insurance_carrier','medical_option','medical_conditions','in_high_school','hs_track_this_season'];
begin
  if not public.is_site_admin() then raise exception 'Only a site admin can send an athlete change request.'; end if;
  select * into r from public.registrations where id = p_reg;
  if r.id is null then raise exception 'Athlete not found.'; end if;
  if public.team_conference(r.team_code) is null then raise exception 'This athlete''s team has no conference set (League Setup).'; end if;
  if p_kind not in ('edit','delete') then raise exception 'Unknown request type.'; end if;
  if p_kind = 'edit' then
    if p_changes is null or p_changes = '{}'::jsonb then raise exception 'Nothing to change.'; end if;
    for k in select jsonb_object_keys(p_changes) loop
      if not k = any(allowed) then raise exception 'The field "%" can''t be changed by request.', k; end if;
      olds := olds || jsonb_build_object(k, to_jsonb(r)->k);
    end loop;
  end if;
  insert into public.athlete_change_requests (registration_id, team_code, conference, athlete_name, kind, changes, old_values, reason, requested_by)
  values (r.id, r.team_code, public.team_conference(r.team_code), r.first_name || ' ' || r.last_name, p_kind,
          case when p_kind = 'edit' then p_changes else '{}'::jsonb end, olds, nullif(trim(p_reason),''),
          lower(coalesce(auth.jwt()->>'email','')))
  returning id into nid;
  return nid;
end $$;

create or replace function public.decide_athlete_change(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare q public.athlete_change_requests; k text; sets text[] := '{}'; me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  select * into q from public.athlete_change_requests where id = p_id for update;
  if q.id is null then raise exception 'Request not found.'; end if;
  if q.status <> 'pending' then raise exception 'This request was already %.', q.status; end if;
  if not public.is_president_of(q.conference) then
    raise exception 'Only the % Conference President can approve or decline this request.',
      case q.conference when 'East' then 'Eastern' else 'Western' end; end if;
  if p_approve then
    if q.registration_id is null then raise exception 'That athlete no longer exists.'; end if;
    perform set_config('vyc.cert_bypass', 'on', true);
    if q.kind = 'delete' then
      delete from public.entries where registration_id = q.registration_id;
      update public.results set registration_id = null where registration_id = q.registration_id;
      delete from public.registrations where id = q.registration_id;
    else
      for k in select jsonb_object_keys(q.changes) loop
        sets := sets || format('%I = ($1->>%L)::%s', k, k,
          (select format_type(a.atttypid, a.atttypmod) from pg_attribute a
            where a.attrelid = 'public.registrations'::regclass and a.attname = k and not a.attisdropped));
      end loop;
      execute 'update public.registrations set ' || array_to_string(sets, ', ') || ' where id = $2' using q.changes, q.registration_id;
      if q.changes ? 'status' then
        update public.registrations set
          verified_by = case when status = 'verified' then me end, verified_at = case when status = 'verified' then now() end
         where id = q.registration_id;
      end if;
    end if;
    perform set_config('vyc.cert_bypass', '', true);
  end if;
  update public.athlete_change_requests
     set status = case when p_approve then 'approved' else 'declined' end,
         decided_by = me, decided_at = now(), decision_note = nullif(trim(p_note),'')
   where id = p_id;
end $$;

-- A site admin can withdraw their own pending request.
create or replace function public.cancel_athlete_change(p_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_site_admin() then raise exception 'Only a site admin can withdraw a request.'; end if;
  update public.athlete_change_requests set status = 'cancelled', decided_by = lower(coalesce(auth.jwt()->>'email','')), decided_at = now()
   where id = p_id and status = 'pending';
end $$;

revoke all on function public.request_athlete_change(uuid,text,jsonb,text) from public;
revoke all on function public.decide_athlete_change(uuid,boolean,text) from public;
revoke all on function public.cancel_athlete_change(uuid) from public;
grant execute on function public.request_athlete_change(uuid,text,jsonb,text) to authenticated;
grant execute on function public.decide_athlete_change(uuid,boolean,text) to authenticated;
grant execute on function public.cancel_athlete_change(uuid) to authenticated;
-- ---------- certification date, late registrations, and the 2-week cutoff ----------
-- Site admin sets the date each season in League Setup (app_settings 'certification_date_<season>').
-- Registered AFTER that date = late registration. More than 14 days after it, registration is closed;
-- only a Conference President can let an athlete in, with a late pass for that athlete.
insert into public.app_settings (key, value) values ('certification_date_2027', '2027-03-13') on conflict (key) do nothing;
alter table public.registrations add column if not exists is_late boolean not null default false;
alter table public.registrations add column if not exists late_pass_id uuid;

create or replace function public.certification_date(p_season integer)
returns date language sql stable security definer set search_path to 'public' as $$
  select nullif(value,'')::date from public.app_settings where key = 'certification_date_' || p_season
$$;

create table if not exists public.late_registration_passes (
  id uuid primary key default gen_random_uuid(),
  season_year integer not null, team_code text not null, conference text not null,
  athlete_first text not null, athlete_last text not null, note text,
  expires_on date not null, created_by text, created_at timestamptz not null default now(),
  used_registration_id uuid references public.registrations(id) on delete set null, used_at timestamptz,
  revoked boolean not null default false);
alter table public.late_registration_passes enable row level security;
drop policy if exists "passes read" on public.late_registration_passes;
create policy "passes read" on public.late_registration_passes for select
  using (public.is_site_admin() or public.is_president_of(conference) or public.is_team_admin_of(team_code));
drop policy if exists "presidents add passes" on public.late_registration_passes;
create policy "presidents add passes" on public.late_registration_passes for insert
  with check (public.is_president_of(conference) and conference = public.team_conference(team_code)
              and used_registration_id is null and created_by = lower(coalesce(auth.jwt()->>'email','')));
drop policy if exists "presidents revoke passes" on public.late_registration_passes;
create policy "presidents revoke passes" on public.late_registration_passes for update
  using (public.is_president_of(conference)) with check (public.is_president_of(conference));

-- Runs on every new registration (before the certification guard resets status).
create or replace function public.reg_late_check()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare cd date := public.certification_date(coalesce(new.season_year, public.current_season()));
  today date := (now() at time zone 'America/Los_Angeles')::date; p record;
begin
  new.late_pass_id := null;
  if cd is null or today <= cd then new.is_late := false; return new; end if;
  new.is_late := true;
  if today > cd + 14 then
    select * into p from public.late_registration_passes x
     where x.season_year = coalesce(new.season_year, public.current_season()) and x.team_code = new.team_code
       and not x.revoked and x.used_registration_id is null and x.expires_on >= today
       and public.name_key(x.athlete_first) = public.name_key(new.first_name)
       and public.name_key(x.athlete_last) = public.name_key(new.last_name)
     order by x.created_at limit 1 for update;
    if p.id is null then
      raise exception 'Registration for the % season closed on % (two weeks after roster certification). A late registration can only be allowed by your Conference President — ask your team admin to request a late pass for this athlete.',
        coalesce(new.season_year, public.current_season()), to_char(cd + 14, 'FMMonth FMDD, YYYY');
    end if;
    new.late_pass_id := p.id;
  end if;
  return new;
end $$;
drop trigger if exists reg_late_check_trg on public.registrations;
create trigger reg_late_check_trg before insert on public.registrations for each row execute function public.reg_late_check();

-- Mark the pass used once the registration really exists.
create or replace function public.reg_late_pass_used()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.late_pass_id is not null then
    update public.late_registration_passes set used_registration_id = new.id, used_at = now() where id = new.late_pass_id;
  end if;
  return new;
end $$;
drop trigger if exists reg_late_pass_used_trg on public.registrations;
create trigger reg_late_pass_used_trg after insert on public.registrations for each row execute function public.reg_late_pass_used();

grant execute on function public.certification_date(integer) to anon, authenticated;
grant execute on function public.is_president_of(text) to anon, authenticated;

-- =====================================================================================================
-- PART 2 (VYC Playing Rules / Bylaws alignment): Commissioner, late-pass approval, transfer approvals,
-- fees & fines, high-school rule, SafeSport / head-coach age.
-- =====================================================================================================

-- ---------- Commissioner (Rules §IX: appoints presidents, approves late additions, transfers, rosters > 350, fines) ----------
alter table public.coaches add column if not exists commissioner_season integer;
alter table public.coaches add column if not exists treasurer_season integer;
create unique index if not exists coaches_one_treasurer_per_season on public.coaches (treasurer_season) where treasurer_season is not null;
alter table public.coaches drop constraint if exists coaches_president_conf_check;
alter table public.coaches add constraint coaches_president_conf_check
  check ((president_conference is null or president_conference in ('East','West'))
     and (requested_president_conference is null or requested_president_conference in ('East','West','Commissioner','Treasurer')));
create unique index if not exists coaches_one_commissioner_per_season on public.coaches (commissioner_season) where commissioner_season is not null;

create or replace function public.is_commissioner()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.coaches c
     where lower(c.email) = lower(coalesce(auth.jwt()->>'email','')) and c.approved is true
       and c.commissioner_season = public.current_season())
$$;
grant execute on function public.is_commissioner() to anon, authenticated;
-- Treasurer (Rules §IX.2.d): receives and deposits all certification and club fees — so the Treasurer records payments.
create or replace function public.is_treasurer()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.coaches c
     where lower(c.email) = lower(coalesce(auth.jwt()->>'email','')) and c.approved is true
       and c.treasurer_season = public.current_season())
$$;
grant execute on function public.is_treasurer() to anon, authenticated;

create or replace function public.coaches_guard()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if coalesce(current_setting('request.jwt.claims', true),'') = '' or public.is_site_admin() then return new; end if;
  if new.is_admin is distinct from old.is_admin then
    raise exception 'Only a site admin can change site-admin access';
  end if;
  if new.president_conference is distinct from old.president_conference
     or new.president_season is distinct from old.president_season
     or new.commissioner_season is distinct from old.commissioner_season
     or new.treasurer_season is distinct from old.treasurer_season then
    raise exception 'Only a site admin can confirm a Conference President, the Commissioner or the Treasurer';
  end if;
  if new.team_code is distinct from old.team_code or lower(new.email) is distinct from lower(old.email) then
    raise exception 'Only a site admin can change a coach team or email';
  end if;
  if new.approved is distinct from old.approved
     or new.role_type is distinct from old.role_type
     or new.team_admin is distinct from old.team_admin then
    if lower(old.email) = lower(coalesce(auth.jwt()->>'email',''))
       or not public.is_team_admin_of(old.team_code) then
      raise exception 'Only an admin for this team can approve coaches, change roles, or grant team-admin access (and not for yourself)';
    end if;
  end if;
  return new;
end $function$;

drop policy if exists coaches_register on public.coaches;
create policy coaches_register on public.coaches for insert
  with check (coalesce(approved,false) = false and coalesce(is_admin,false) = false
              and coalesce(team_admin,false) = false and president_conference is null and commissioner_season is null and treasurer_season is null);

-- Sign-up: p_president may now be 'East', 'West' or 'Commissioner'.
create or replace function public.submit_team_admin_request(
  p_first text, p_last text, p_phone text, p_team text, p_title text,
  p_bg_date date default null, p_usatf boolean default false, p_usatf_date date default null, p_contract boolean default false,
  p_president text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_email text := coalesce(auth.jwt()->>'email','');
begin
  if v_email = '' then raise exception 'Please sign in first.'; end if;
  if coalesce(trim(p_first),'') = '' or coalesce(trim(p_last),'') = '' or coalesce(trim(p_team),'') = '' then
    raise exception 'Name and team are required.'; end if;
  if coalesce(trim(p_title),'') = '' then raise exception 'Please choose your role on the team.'; end if;
  if nullif(p_president,'') is not null and p_president not in ('East','West','Commissioner','Treasurer') then
    raise exception 'Pick Commissioner, Treasurer, Eastern or Western Conference President (or none).'; end if;
  if exists (select 1 from public.coaches where lower(email) = lower(v_email)) then
    raise exception 'You already have a coach or team admin request on file. Ask your site admin to update it.'; end if;
  insert into public.coaches (email, first_name, last_name, phone, team_code, role_type, admin_title, requested_team_admin,
    requested_president_conference,
    background_check_date, usatf_certified, usatf_cert_date, contract_signed_at, contract_version, approved, season_year)
  values (v_email, trim(p_first), trim(p_last), trim(p_phone), trim(p_team),
    case when p_title = 'Head Coach' then 'head_coach' else 'team_staff' end, trim(p_title), true,
    nullif(p_president,''),
    p_bg_date, coalesce(p_usatf,false), p_usatf_date,
    case when p_contract then now() end, case when p_contract then 'VYC-2026' end, false,
    public.current_season());
end $$;

-- Austin Shanks = Commissioner for the current season (Riley, 2026-09-27).
insert into public.app_settings (key, value) values ('expected_commissioner', 'Austin Shanks') on conflict (key) do nothing;
update public.coaches set commissioner_season = public.current_season() where lower(email) = 'thimshaluv28@gmail.com';
-- Leeza Piano (Northridge Pacers) = Treasurer for the current season (Riley, 2026-09-27).
insert into public.app_settings (key, value) values ('expected_treasurer', 'Leeza Piano') on conflict (key) do nothing;
update public.coaches set treasurer_season = public.current_season() where lower(email) = 'pacerstrackteam@gmail.com';

-- Commissioner (and presidents) can see every registration; the Commissioner may spot-check any roster (§II.D.8).
drop policy if exists "commissioner reads all" on public.registrations;
create policy "commissioner reads all" on public.registrations for select using (public.is_commissioner());

-- ---------- Coaches: SafeSport (§IX.2.f.7) and head coach 21+ (§II.D.9) ----------
alter table public.coaches add column if not exists safesport_date date;
alter table public.coaches add column if not exists age_21_attested boolean not null default false;

-- ---------- Late window per the rules (§I.C): late until midnight of the 2nd meet; late fee due by the 3rd meet ----------
create or replace function public.season_meet_date(p_season integer, p_nth integer)
returns date language sql stable security definer set search_path to 'public' as $$
  select m.meet_date from public.meets m where m.season_year = p_season and coalesce(m.status,'') <> 'archived'
   order by m.meet_date offset greatest(p_nth,1) - 1 limit 1
$$;
-- Last day a late registration is accepted: the 2nd meet date if the schedule is posted, otherwise 14 days after certification.
create or replace function public.late_cutoff(p_season integer)
returns date language sql stable security definer set search_path to 'public' as $$
  select case when public.certification_date(p_season) is null then null
              else coalesce(public.season_meet_date(p_season, 2), public.certification_date(p_season) + 14) end
$$;
grant execute on function public.season_meet_date(integer,integer) to anon, authenticated;
grant execute on function public.late_cutoff(integer) to anon, authenticated;

-- Late passes: a president REQUESTS, the Commissioner APPROVES (§X: "Only the commissioner can approve the late addition
-- of an athlete upon the request of the league president").
alter table public.late_registration_passes add column if not exists status text not null default 'requested';
alter table public.late_registration_passes drop constraint if exists late_pass_status_check;
alter table public.late_registration_passes add constraint late_pass_status_check check (status in ('requested','approved','declined'));
alter table public.late_registration_passes add column if not exists decided_by text;
alter table public.late_registration_passes add column if not exists decided_at timestamptz;
alter table public.late_registration_passes add column if not exists decision_note text;

drop policy if exists "passes read" on public.late_registration_passes;
create policy "passes read" on public.late_registration_passes for select
  using (public.is_site_admin() or public.is_commissioner() or public.is_president_of(conference) or public.is_team_admin_of(team_code));
drop policy if exists "presidents add passes" on public.late_registration_passes;
create policy "presidents add passes" on public.late_registration_passes for insert
  with check (public.is_president_of(conference) and conference = public.team_conference(team_code)
              and used_registration_id is null and status = 'requested'
              and created_by = lower(coalesce(auth.jwt()->>'email','')));
drop policy if exists "presidents revoke passes" on public.late_registration_passes;
create policy "presidents revoke passes" on public.late_registration_passes for update
  using (public.is_president_of(conference)) with check (public.is_president_of(conference));
drop policy if exists "commissioner decides passes" on public.late_registration_passes;
create policy "commissioner decides passes" on public.late_registration_passes for update
  using (public.is_commissioner()) with check (public.is_commissioner());

create or replace function public.late_pass_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if public.is_site_admin() then return new; end if;
  if new.status is distinct from old.status or new.decision_note is distinct from old.decision_note then
    if not public.is_commissioner() then raise exception 'Only the Commissioner can approve or decline a late pass.'; end if;
    new.decided_by := lower(coalesce(auth.jwt()->>'email','')); new.decided_at := now();
  end if;
  if new.revoked is distinct from old.revoked and not (public.is_president_of(old.conference) or public.is_commissioner()) then
    raise exception 'Only the Conference President or the Commissioner can revoke a late pass.';
  end if;
  return new;
end $$;
drop trigger if exists late_pass_guard_trg on public.late_registration_passes;
create trigger late_pass_guard_trg before update on public.late_registration_passes for each row execute function public.late_pass_guard();

create or replace function public.reg_late_check()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare s integer := coalesce(new.season_year, public.current_season());
  cd date := public.certification_date(coalesce(new.season_year, public.current_season()));
  cutoff date; today date := (now() at time zone 'America/Los_Angeles')::date; p record;
begin
  new.late_pass_id := null;
  if cd is null or today <= cd then new.is_late := false; return new; end if;
  new.is_late := true;
  cutoff := public.late_cutoff(s);
  if today > cutoff then
    select * into p from public.late_registration_passes x
     where x.season_year = s and x.team_code = new.team_code and x.status = 'approved'
       and not x.revoked and x.used_registration_id is null and x.expires_on >= today
       and public.name_key(x.athlete_first) = public.name_key(new.first_name)
       and public.name_key(x.athlete_last) = public.name_key(new.last_name)
     order by x.created_at limit 1 for update;
    if p.id is null then
      raise exception 'Registration for the % season closed on % (athletes may be added until the 2nd meet). A late addition needs a late pass requested by your Conference President and approved by the Commissioner — ask your team admin.',
        s, to_char(cutoff, 'FMMonth FMDD, YYYY');
    end if;
    new.late_pass_id := p.id;
  end if;
  return new;
end $$;

-- ---------- High-school rule (§IV.A.2): 9th grade+ who trained/competed with a high school track team this year are ineligible ----------
-- Two questions for 13+: in high school? -> if yes, running with the high school track team? (yes = rejected, CIF rules)
alter table public.registrations add column if not exists in_high_school boolean;
alter table public.registrations add column if not exists hs_track_this_season boolean;
create or replace function public.reg_hs_rule()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(new.age_on_dec31,0) >= 13 and new.in_high_school is null then
    raise exception 'Please answer: is this athlete in high school?';
  end if;
  if new.in_high_school and new.hs_track_this_season is null then
    raise exception 'Please answer: is this athlete running with their current high school track team?';
  end if;
  if new.hs_track_this_season then
    raise exception 'This athlete can''t be registered: running for a high school track team and a VYC team in the same season is against California CIF rules (VYC rule IV.A.2).';
  end if;
  return new;
end $$;
drop trigger if exists reg_hs_rule_trg on public.registrations;
create trigger reg_hs_rule_trg before insert on public.registrations for each row execute function public.reg_hs_rule();

-- ---------- Transfers (§IV.A.3.c): written approval of BOTH teams AND the Commissioner; good standing with the old team ----------
alter table public.transfer_clearances add column if not exists to_team_approved_by text;
alter table public.transfer_clearances add column if not exists to_team_approved_at timestamptz;
alter table public.transfer_clearances add column if not exists commissioner_approved_by text;
alter table public.transfer_clearances add column if not exists commissioner_approved_at timestamptz;
alter table public.transfer_clearances add column if not exists commissioner_note text;

drop policy if exists "new team approves clearance" on public.transfer_clearances;
create policy "new team approves clearance" on public.transfer_clearances for update
  using (public.is_team_admin_of(to_team)) with check (public.is_team_admin_of(to_team));
drop policy if exists "commissioner approves clearance" on public.transfer_clearances;
create policy "commissioner approves clearance" on public.transfer_clearances for update
  using (public.is_commissioner()) with check (public.is_commissioner());
drop policy if exists "commissioner and presidents read clearances" on public.transfer_clearances;
create policy "commissioner and presidents read clearances" on public.transfer_clearances for select
  using (public.is_commissioner() or public.is_president_of(public.team_conference(from_team)) or public.is_president_of(public.team_conference(to_team)));

create or replace function public.clearance_guard()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  if new.registration_id is distinct from old.registration_id or new.from_team is distinct from old.from_team
     or new.to_team is distinct from old.to_team or new.athlete_first is distinct from old.athlete_first
     or new.athlete_last is distinct from old.athlete_last or new.dob is distinct from old.dob then
    raise exception 'Only the approvals and notes can be changed';
  end if;
  if public.is_site_admin() then
    if new.status is distinct from old.status or new.note is distinct from old.note then new.responded_by := me; new.responded_at := now(); end if;
    return new;
  end if;
  -- Old team: answers (status + note).
  if new.status is distinct from old.status or new.note is distinct from old.note then
    if not public.is_team_admin_of(old.from_team) then raise exception 'Only the athlete''s former team can answer this transfer request.'; end if;
    new.responded_by := me; new.responded_at := now();
  end if;
  -- New team: written approval that they accept the athlete.
  if new.to_team_approved_at is distinct from old.to_team_approved_at then
    if not public.is_team_admin_of(old.to_team) then raise exception 'Only the joining team can give its approval.'; end if;
    if new.to_team_approved_at is not null then new.to_team_approved_by := me; new.to_team_approved_at := now(); else new.to_team_approved_by := null; end if;
  end if;
  -- Commissioner: final approval (may also waive the post-season rule, §IV.A.3.a).
  if new.commissioner_approved_at is distinct from old.commissioner_approved_at or new.commissioner_note is distinct from old.commissioner_note then
    if not public.is_commissioner() then raise exception 'Only the Commissioner can give final approval of a transfer.'; end if;
    if new.commissioner_approved_at is not null then new.commissioner_approved_by := me; new.commissioner_approved_at := now(); else new.commissioner_approved_by := null; end if;
  end if;
  return new;
end $function$;

-- Certification of a transferring athlete needs: old team cleared (good standing) + new team approved + Commissioner approved.
-- (Replaces reg_vus_verify_guard, which only covered Valley United moves.)
create or replace function public.reg_vus_verify_guard()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare c record;
begin
  if new.status = 'verified' and old.status is distinct from 'verified' then
    for c in select * from public.transfer_clearances t where t.registration_id = new.id and t.status <> 'not_same' loop
      if c.status <> 'cleared' then
        if c.vus then raise exception 'Valley United rule: this athlete ran for Valley United last season, so %''s team must approve the move before this registration can be certified.', c.from_team; end if;
        raise exception 'Transfer rule (IV.A.3.c): % has not yet confirmed this athlete is in good standing (no balance owed, no Code of Conduct issue). The athlete can''t be certified until the former team, the joining team and the Commissioner have all approved the transfer.', c.from_team;
      end if;
      if c.to_team_approved_at is null then
        raise exception 'Transfer rule (IV.A.3.c): the joining team (%) must give written approval of this transfer before the athlete can be certified.', c.to_team;
      end if;
      if c.commissioner_approved_at is null then
        raise exception 'Transfer rule (IV.A.3.c): the Commissioner must approve this transfer before the athlete can be certified.';
      end if;
    end loop;
    -- Bylaws Uniform Regs III.C.2: an athlete dropped from a team can't be certified again that season.
    if exists (select 1 from public.registrations r where r.season_year = new.season_year and r.id <> new.id and r.status = 'rejected'
                 and r.team_code is distinct from new.team_code and r.dob = new.dob
                 and public.name_key(r.first_name) = public.name_key(new.first_name) and public.name_key(r.last_name) = public.name_key(new.last_name)) then
      raise exception 'Bylaws III.C.2: this athlete was dropped by another VYC team this season (%), so they can''t be certified again this season.',
        (select r.team_code from public.registrations r where r.season_year = new.season_year and r.status = 'rejected' and r.dob = new.dob
           and public.name_key(r.first_name) = public.name_key(new.first_name) and public.name_key(r.last_name) = public.name_key(new.last_name) limit 1);
    end if;
    if new.hs_track_this_season then
      raise exception 'This athlete runs for a high school track team and can''t be certified (California CIF rules; VYC rule IV.A.2).';
    end if;
  end if;
  return new;
end $function$;

-- ---------- Fees & fines ----------
-- Amounts are per-season settings (site admin, League Setup). Rules: $25 team affiliation fee (§II.A.7), $10 late fee per athlete
-- (§I.C, §X), invitational $5/athlete; the per-athlete certification fee is set by the Board ($38 for 2027 per Riley).
insert into public.app_settings (key, value) values
  ('fee_team_2027','25'), ('fee_athlete_2027','38'), ('fee_late_2027','10'), ('fee_invitational_2027','5')
  on conflict (key) do nothing;
create or replace function public.fee_amount(p_kind text, p_season integer)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select nullif(value,'')::numeric from public.app_settings where key = 'fee_' || p_kind || '_' || p_season),
                  case p_kind when 'team' then 25 when 'late' then 10 when 'invitational' then 5 else 0 end)
$$;
grant execute on function public.fee_amount(text,integer) to anon, authenticated;

alter table public.meets add column if not exists is_invitational boolean not null default false;

create table if not exists public.team_charges (
  id uuid primary key default gen_random_uuid(),
  season_year integer not null, team_code text not null,
  kind text not null check (kind in ('team_fee','athlete_fee','late_fee','invitational_fee','fine')),
  description text, amount numeric(10,2) not null check (amount >= 0),
  due_on date, registration_id uuid references public.registrations(id) on delete set null,
  meet_id uuid references public.meets(id) on delete set null,
  rule_ref text, assessed_by text, assessed_at timestamptz not null default now(),
  status text not null default 'due' check (status in ('due','paid','void')),
  paid_on date, paid_by text, paid_note text);
create index if not exists team_charges_team_idx on public.team_charges (season_year, team_code, status);
alter table public.team_charges enable row level security;
drop policy if exists "charges read" on public.team_charges;
create policy "charges read" on public.team_charges for select
  using (public.is_site_admin() or public.is_commissioner() or public.is_treasurer() or public.is_president_of(public.team_conference(team_code)) or public.is_team_admin_of(team_code));
-- Writes only through the functions below.

-- Automatic charges: team fee once per team-season, athlete fee per registration, late fee for late registrations.
create or replace function public.reg_charges()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare s integer := coalesce(new.season_year, public.current_season()); nm text := new.first_name || ' ' || new.last_name;
begin
  if new.contract_version = 'ROSTER-2026' then return new; end if; -- imported reference roster, no fees
  if not exists (select 1 from public.team_charges c where c.season_year = s and c.team_code = new.team_code and c.kind = 'team_fee') then
    insert into public.team_charges (season_year, team_code, kind, description, amount, due_on, rule_ref)
    values (s, new.team_code, 'team_fee', 'Team affiliation fee', public.fee_amount('team', s), public.certification_date(s), 'Rules II.A.7');
  end if;
  insert into public.team_charges (season_year, team_code, kind, description, amount, due_on, registration_id, rule_ref)
  values (s, new.team_code, 'athlete_fee', 'Certification fee — ' || nm, public.fee_amount('athlete', s), public.certification_date(s), new.id, 'Rules X');
  if new.is_late then
    insert into public.team_charges (season_year, team_code, kind, description, amount, due_on, registration_id, rule_ref)
    values (s, new.team_code, 'late_fee', 'Late registration fee — ' || nm, public.fee_amount('late', s), public.season_meet_date(s, 3), new.id, 'Rules I.C');
  end if;
  return new;
end $$;
drop trigger if exists reg_charges_trg on public.registrations;
create trigger reg_charges_trg after insert on public.registrations for each row execute function public.reg_charges();

-- Rejected or removed athletes don't owe (unpaid fees for them are voided; paid ones are left as a record).
create or replace function public.reg_charges_void()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if tg_op = 'DELETE' or (new.status = 'rejected' and old.status is distinct from 'rejected') then
    update public.team_charges set status = 'void', paid_note = coalesce(paid_note,'') || ' (athlete ' || case when tg_op = 'DELETE' then 'removed' else 'rejected' end || ')'
     where registration_id = old.id and status = 'due';
  elsif tg_op = 'UPDATE' and old.status = 'rejected' and new.status <> 'rejected' then
    update public.team_charges set status = 'due', paid_note = null where registration_id = old.id and status = 'void';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists reg_charges_void_trg on public.registrations;
create trigger reg_charges_void_trg before update or delete on public.registrations for each row execute function public.reg_charges_void();

-- Invitational fee: $/athlete for every athlete entered in a meet marked as an invitational (one charge per team per meet).
create or replace function public.add_invitational_fees(p_meet uuid)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare m public.meets; t record; n integer := 0;
begin
  if not (public.is_commissioner() or public.is_treasurer() or public.is_site_admin()) then raise exception 'Only the Commissioner, the Treasurer or a site admin can add invitational fees.'; end if;
  select * into m from public.meets where id = p_meet;
  if m.id is null then raise exception 'Meet not found.'; end if;
  delete from public.team_charges where meet_id = p_meet and kind = 'invitational_fee' and status = 'due';
  for t in select r.team_code, count(distinct e.registration_id) cnt from public.entries e join public.registrations r on r.id = e.registration_id
            where e.meet_id = p_meet group by r.team_code loop
    if not exists (select 1 from public.team_charges where meet_id = p_meet and kind = 'invitational_fee' and team_code = t.team_code) then
      insert into public.team_charges (season_year, team_code, kind, description, amount, due_on, meet_id, rule_ref, assessed_by)
      values (m.season_year, t.team_code, 'invitational_fee', m.name || ' — ' || t.cnt || ' athlete(s) × $' || public.fee_amount('invitational', m.season_year),
              t.cnt * public.fee_amount('invitational', m.season_year), m.meet_date, p_meet, 'Rules I.E', lower(coalesce(auth.jwt()->>'email','')));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- Fines: only the Commissioner, or the Conference President of that team's conference (Code of Conduct; Rules IX.2.g).
create or replace function public.assess_fine(p_team text, p_amount numeric, p_description text, p_due date, p_rule text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare nid uuid;
begin
  if not (public.is_commissioner() or public.is_president_of(public.team_conference(p_team))) then
    raise exception 'Only the Commissioner or the Conference President for this team can assess a fine.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter the fine amount.'; end if;
  if coalesce(trim(p_description),'') = '' then raise exception 'Describe what the fine is for.'; end if;
  insert into public.team_charges (season_year, team_code, kind, description, amount, due_on, rule_ref, assessed_by)
  values (public.current_season(), p_team, 'fine', trim(p_description), p_amount, p_due, nullif(trim(p_rule),''), lower(coalesce(auth.jwt()->>'email','')))
  returning id into nid;
  return nid;
end $$;

-- Payment: the Treasurer (receives all fees, §IX.2.d) or a site admin. Cancelling a fine: Commissioner or whoever assessed it.
create or replace function public.settle_charge(p_id uuid, p_status text, p_note text default null, p_paid_on date default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c public.team_charges;
begin
  if p_status not in ('due','paid','void') then raise exception 'Unknown status.'; end if;
  select * into c from public.team_charges where id = p_id; if c.id is null then raise exception 'Charge not found.'; end if;
  if c.kind = 'fine' and p_status = 'void' then
    if not (public.is_commissioner() or public.is_site_admin() or lower(coalesce(auth.jwt()->>'email','')) = c.assessed_by) then
      raise exception 'Only the Commissioner or the person who assessed it can cancel a fine.'; end if;
  elsif not (public.is_treasurer() or public.is_site_admin()) then
    raise exception 'Only the Treasurer (or a site admin) can record payments.'; end if;
  update public.team_charges set status = p_status,
    paid_on = case when p_status = 'paid' then coalesce(p_paid_on, (now() at time zone 'America/Los_Angeles')::date) end,
    paid_by = case when p_status = 'paid' then lower(coalesce(auth.jwt()->>'email','')) end,
    paid_note = nullif(trim(p_note),'')
   where id = p_id;
end $$;

revoke all on function public.add_invitational_fees(uuid) from public;
revoke all on function public.assess_fine(text,numeric,text,date,text) from public;
revoke all on function public.settle_charge(uuid,text,text,date) from public;
grant execute on function public.add_invitational_fees(uuid) to authenticated;
grant execute on function public.assess_fine(text,numeric,text,date,text) to authenticated;
grant execute on function public.settle_charge(uuid,text,text,date) to authenticated;

-- ---------- Meet entry gate: the Treasurer confirms a team's certification fees are paid; until then its athletes can't be
-- entered in meets. Only the Commissioner or the team's Conference President can overrule that (Riley, 2026-09-27; rule I.E). ----------
create table if not exists public.team_fee_clearance (
  season_year integer not null, team_code text not null,
  fees_paid boolean not null default false, paid_by text, paid_at timestamptz, paid_note text,
  override boolean not null default false, override_by text, override_at timestamptz, override_note text,
  primary key (season_year, team_code));
alter table public.team_fee_clearance enable row level security;
drop policy if exists "fee clearance read" on public.team_fee_clearance;
create policy "fee clearance read" on public.team_fee_clearance for select using (auth.role() = 'authenticated');

create or replace function public.team_fees_cleared(p_team text, p_season integer)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select c.fees_paid or c.override from public.team_fee_clearance c where c.season_year = p_season and c.team_code = p_team), false)
$$;
grant execute on function public.team_fees_cleared(text,integer) to anon, authenticated;

-- Treasurer: "all certification fees paid" for a team (also marks the team's due team/athlete/late fees as paid).
create or replace function public.set_team_fees_paid(p_team text, p_season integer, p_paid boolean, p_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  if not (public.is_treasurer() or public.is_site_admin()) then raise exception 'Only the Treasurer (or a site admin) can confirm that a team''s certification fees are paid.'; end if;
  insert into public.team_fee_clearance (season_year, team_code, fees_paid, paid_by, paid_at, paid_note)
  values (p_season, p_team, p_paid, case when p_paid then me end, case when p_paid then now() end, nullif(trim(p_note),''))
  on conflict (season_year, team_code) do update set fees_paid = excluded.fees_paid, paid_by = excluded.paid_by, paid_at = excluded.paid_at, paid_note = excluded.paid_note;
  if p_paid then
    update public.team_charges set status = 'paid', paid_on = (now() at time zone 'America/Los_Angeles')::date, paid_by = me,
      paid_note = coalesce(nullif(trim(p_note),''), 'Certification fees confirmed paid')
     where season_year = p_season and team_code = p_team and status = 'due' and kind in ('team_fee','athlete_fee','late_fee');
  end if;
end $$;

-- Commissioner or the team's Conference President: overrule the fee gate (lets the team enter meets while fees are outstanding).
create or replace function public.set_team_fee_override(p_team text, p_season integer, p_on boolean, p_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  if not (public.is_commissioner() or public.is_president_of(public.team_conference(p_team))) then
    raise exception 'Only the Commissioner or the team''s Conference President can overrule the fee requirement.'; end if;
  if p_on and coalesce(trim(p_note),'') = '' then raise exception 'Give a reason for the override.'; end if;
  insert into public.team_fee_clearance (season_year, team_code, override, override_by, override_at, override_note)
  values (p_season, p_team, p_on, case when p_on then me end, case when p_on then now() end, nullif(trim(p_note),''))
  on conflict (season_year, team_code) do update set override = excluded.override, override_by = excluded.override_by, override_at = excluded.override_at, override_note = excluded.override_note;
end $$;
revoke all on function public.set_team_fees_paid(text,integer,boolean,text) from public;
revoke all on function public.set_team_fee_override(text,integer,boolean,text) from public;
grant execute on function public.set_team_fees_paid(text,integer,boolean,text) to authenticated;
grant execute on function public.set_team_fee_override(text,integer,boolean,text) to authenticated;

create or replace function public.check_entry()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  reg record; ev record; m record;
  cnt int; relay_cnt int; maxev int; relay_rule boolean;
begin
  select * into reg from public.registrations where id = new.registration_id;
  select * into ev  from public.meet_events   where id = new.meet_event_id;
  select * into m   from public.meets         where id = new.meet_id;
  if reg is null or ev is null or m is null then raise exception 'Bad entry'; end if;
  if ev.meet_id <> new.meet_id then raise exception 'Event does not belong to this meet'; end if;
  if reg.status <> 'verified' then raise exception 'Athlete is not certified yet'; end if;
  if not public.team_fees_cleared(reg.team_code, coalesce(m.season_year, reg.season_year)) then
    raise exception '%''s certification fees have not been confirmed paid by the Treasurer, so its athletes can''t be entered in meets yet (rule I.E). Only the Commissioner or the Conference President can overrule this.', reg.team_code;
  end if;
  if m.status <> 'open' or now() > m.entries_close then
    if not public.is_coach() then raise exception 'Entries for this meet are closed'; end if;
  end if;
  if (ev.division <> 'ALL' and ev.division <> reg.division) or (ev.gender <> 'Mixed' and ev.gender <> reg.gender) then
    raise exception 'Event is not for this athlete''s division/gender';
  end if;
  select count(*), count(*) filter (where e2.is_relay) into cnt, relay_cnt
    from public.entries e join public.meet_events e2 on e2.id = e.meet_event_id
    where e.registration_id = new.registration_id and e.meet_id = new.meet_id;
  cnt := cnt + 1; if ev.is_relay then relay_cnt := relay_cnt + 1; end if;
  maxev := case when reg.division in ('Sub-Gremlin','Gremlin') then 3 else 4 end;
  relay_rule := reg.division in ('Bantam','Juniors','Youth');
  if cnt > maxev then raise exception 'Max % events for %', maxev, reg.division; end if;
  if relay_rule and cnt = 4 and relay_cnt = 0 then
    raise exception '% may only have 4 events if one is a relay', reg.division;
  end if;
  return new;
end $function$;

-- Charges for athletes already registered this season (before this change went in).
insert into public.team_charges (season_year, team_code, kind, description, amount, due_on, registration_id, rule_ref)
select r.season_year, r.team_code, 'athlete_fee', 'Certification fee — ' || r.first_name || ' ' || r.last_name,
       public.fee_amount('athlete', r.season_year), public.certification_date(r.season_year), r.id, 'Rules X'
  from public.registrations r
 where r.season_year = public.current_season() and r.status <> 'rejected' and coalesce(r.contract_version,'') <> 'ROSTER-2026'
   and not exists (select 1 from public.team_charges c where c.registration_id = r.id and c.kind = 'athlete_fee');
insert into public.team_charges (season_year, team_code, kind, description, amount, due_on, rule_ref)
select distinct r.season_year, r.team_code, 'team_fee', 'Team affiliation fee', public.fee_amount('team', r.season_year), public.certification_date(r.season_year), 'Rules II.A.7'
  from public.registrations r
 where r.season_year = public.current_season() and coalesce(r.contract_version,'') <> 'ROSTER-2026'
   and not exists (select 1 from public.team_charges c where c.season_year = r.season_year and c.team_code = r.team_code and c.kind = 'team_fee');
grant execute on function public.team_conference(text) to anon, authenticated;

commit;
