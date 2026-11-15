-- Coaches by sport, and Valley United coaches (Riley, 2026-11-15).
-- Run AFTER 2026-11-15-vus-open-early.sql (it adds vus_requests.entries, which the Valley United roster returns).
--
-- Cross country is handled like track:
--  * Each coach row says which sport(s) they coach on their team: Track & Field, Cross Country, or both
--    (coaches.sports). Existing coaches start as Track & Field only (no team was in cross country yet).
--  * The team's team admin (or a site admin) approves coaches and changes their sports — the coach can't change
--    their own sports (coaches_guard).
--  * Regular coaches only see athletes of the sports they coach (team_roster, can_manage_athlete).
--    Team admins and site admins still see every sport on their team.
--
-- Valley United Striders has its own coaches:
--  * vus_coaches: separate from the regular coach list, so a person can coach a regular team AND Valley United
--    with the same sign-in. Same background check / SafeSport / USATF / contract answers as track.
--  * Valley United admins (and site admins) approve them, and can now add or remove other Valley United admins.
--  * Each Valley United coach is on the Postseason team, Developmental, or both. Roles (no head coach — the Team
--    President takes that role): Team President (every division), Division Head Coach and Assistant Coach (their
--    divisions + boys/girls), Field Event Coach (athletes in their field events). A Valley United admin confirms them.
--  * An approved Valley United coach sees only the ACCEPTED athletes of their roster(s) and divisions, with contact
--    and medical details (vus_coach_roster). Entering them into postseason meets is part 2.
begin;

-- ---------- sports on the coach row ----------
alter table public.coaches add column if not exists sports text[] not null default array['Track & Field'];
alter table public.coaches drop constraint if exists coaches_sports_check;
alter table public.coaches add constraint coaches_sports_check
  check (cardinality(sports) >= 1 and sports <@ array['Track & Field','Cross Country']);

-- Same guard as before, plus: only a team admin of the team (not the coach themself) or a site admin changes sports.
create or replace function public.coaches_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(current_setting('request.jwt.claims', true),'') = '' or public.is_site_admin() then return new; end if;
  if new.is_admin is distinct from old.is_admin then raise exception 'Only a site admin can change site-admin access'; end if;
  if new.president_conference is distinct from old.president_conference or new.president_season is distinct from old.president_season
     or new.commissioner_season is distinct from old.commissioner_season or new.treasurer_season is distinct from old.treasurer_season then
    raise exception 'Only a site admin can confirm a Conference President, the Commissioner or the Treasurer';
  end if;
  if new.team_code is distinct from old.team_code or lower(new.email) is distinct from lower(old.email) then
    raise exception 'Only a site admin can change a coach team or email';
  end if;
  if new.approved is distinct from old.approved or new.role_type is distinct from old.role_type
     or new.team_admin is distinct from old.team_admin or new.sports is distinct from old.sports then
    if lower(old.email) = lower(coalesce(auth.jwt()->>'email','')) or not public.is_team_admin_of(old.team_code) then
      raise exception 'Only an admin for this team can approve coaches, change roles or sports, or grant team-admin access (and not for yourself)';
    end if;
  end if;
  return new;
end $$;

-- Signed-in (Google) coach sign-up, now with the sport(s).
drop function if exists public.submit_coach_profile(text,text,text,text,text,text,text,text,date,boolean,date,boolean);
create or replace function public.submit_coach_profile(p_first text, p_last text, p_phone text, p_team text, p_role text,
  p_division text default null, p_gender text default null, p_events text default null, p_bg_date date default null,
  p_usatf boolean default false, p_usatf_date date default null, p_contract boolean default false,
  p_sports text[] default array['Track & Field'])
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_email text := coalesce(auth.jwt()->>'email','');
begin
  if v_email = '' then raise exception 'Please sign in first.'; end if;
  if p_role not in ('head_coach','division_coach','event_specialist') then raise exception 'Invalid coach type.'; end if;
  if coalesce(trim(p_first),'')='' or coalesce(trim(p_last),'')='' or coalesce(trim(p_team),'')='' then raise exception 'Name and team are required.'; end if;
  if p_role='division_coach' and (p_division is null or p_gender not in ('Boys','Girls','Boys, Girls','Girls, Boys')) then raise exception 'Division and boys/girls are required.'; end if;
  if p_role='event_specialist' and coalesce(p_events,'')='' then raise exception 'Pick at least one field event.'; end if;
  if coalesce(cardinality(p_sports),0) = 0 or not (p_sports <@ array['Track & Field','Cross Country']) then raise exception 'Pick Track & Field, Cross Country, or both.'; end if;
  if exists (select 1 from public.coaches where lower(email)=lower(v_email)) then raise exception 'You already have a coach request on file.'; end if;
  insert into public.coaches (email, first_name, last_name, phone, team_code, role_type, division_or_age_group, coach_gender,
    event_specialty, background_check_date, usatf_certified, usatf_cert_date, contract_signed_at, contract_version, approved, season_year, sports)
  values (v_email, trim(p_first), trim(p_last), trim(p_phone), trim(p_team), p_role,
    case when p_role='division_coach' then p_division end, case when p_role='division_coach' then p_gender end,
    case when p_role='event_specialist' then p_events end, p_bg_date, coalesce(p_usatf,false), p_usatf_date,
    case when p_contract then now() end, case when p_contract then 'VYC-2026' end, false, 2027,
    (select array_agg(distinct s) from unnest(p_sports) s));
end $$;
grant execute on function public.submit_coach_profile(text,text,text,text,text,text,text,text,date,boolean,date,boolean,text[]) to authenticated;

-- ---------- regular coaches only see the sports they coach ----------
create or replace function public.team_roster()
returns table(id uuid, team_code text, first_name text, last_name text, gender text, division text, sport text, status text,
  age_on_dec31 integer, created_at timestamptz, comp_number integer, season_year integer)
language sql stable security definer set search_path to 'public' as $$
  select r.id, r.team_code, r.first_name, r.last_name, r.gender, r.division, r.sport, r.status, r.age_on_dec31, r.created_at, r.comp_number, r.season_year
  from public.registrations r
  join public.coaches c on lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
  where c.approved = true and c.role_type is distinct from 'timer'
    and (c.is_admin or r.team_code = c.team_code)
    and (c.is_admin or c.team_admin or coalesce(r.sport,'Track & Field') = any(c.sports))
    and (c.is_admin or c.role_type is distinct from 'division_coach' or coalesce(c.division_or_age_group,'') ilike 'all%'
         or ( r.division = any(string_to_array(replace(coalesce(c.division_or_age_group,''),', ',','),','))
              and ( c.coach_gender is null
                    or (case r.gender when 'Boy' then 'Boys' when 'Girl' then 'Girls' end) = any(string_to_array(replace(c.coach_gender,', ',','),',')) ) ))
$$;

create or replace function public.can_manage_athlete(reg uuid)
returns boolean language sql stable security definer as $$
  select exists (
    select 1 from public.registrations r
    where r.id = reg and (
      lower(r.email) = lower(coalesce(auth.jwt()->>'email',''))
      or exists (
        select 1 from public.coaches c
        where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
          and c.approved = true and c.role_type is distinct from 'timer'
          and (c.is_admin or (c.team_code = r.team_code
               and (c.team_admin or coalesce(r.sport,'Track & Field') = any(c.sports))))
      )
    )
  );
$$;

-- ---------- Valley United coaches ----------
create table if not exists public.vus_coaches (
  email text primary key check (email = lower(email)),
  first_name text not null,
  last_name text not null,
  phone text,
  -- Valley United has no head coach: the Team President fills that role and sees every division of their roster(s).
  -- Valley United divisions are AGE GROUPS (vus_age_group): 5/6, 7/8, 9/10, 11/12, 13/14, 15/16, 17/18 (Young Men /
  -- Young Women). Every age group and sex can have its own Division Head Coach and Assistant Coaches; they see only
  -- their age groups (division_or_age_group, e.g. '13/14, 15/16') and boys/girls (coach_gender: 'Boys' | 'Girls' |
  -- 'Boys, Girls'). High school athletes are 15/16 or 17/18 like everyone else.
  -- Field Event Coaches see the athletes who picked their field events (event_specialty, e.g. 'Long Jump, Shot Put').
  role_type text not null default 'assistant_coach'
    check (role_type in ('team_president','division_head_coach','assistant_coach','field_event_coach')),
  division_or_age_group text,
  coach_gender text,
  event_specialty text,
  -- Which Valley United roster(s) they coach: the Postseason team, Developmental, or both.
  squads text[] not null default array['postseason'] check (cardinality(squads) >= 1 and squads <@ array['postseason','developmental']),
  background_check_date date,
  usatf_certified boolean not null default false,
  usatf_cert_date date,
  usatf_member_number text,
  safesport_date date,
  age_21_attested boolean not null default false,
  contract_signed_at timestamptz,
  contract_version text,
  approved boolean not null default false,
  approved_by text,
  approved_at timestamptz,
  season_year integer,
  registered_at timestamptz not null default now()
);
alter table public.vus_coaches enable row level security;

drop policy if exists "sign up" on public.vus_coaches;
create policy "sign up" on public.vus_coaches for insert to anon, authenticated
  with check (approved = false and approved_by is null and approved_at is null);
drop policy if exists "read own" on public.vus_coaches;
create policy "read own" on public.vus_coaches for select to authenticated
  using (email = lower(coalesce(auth.jwt()->>'email','')));
drop policy if exists "vus admins all" on public.vus_coaches;
create policy "vus admins all" on public.vus_coaches for all to authenticated
  using (public.is_vus_admin()) with check (public.is_vus_admin());

-- Approval stamps who approved; nobody approves themself (a site admin still can).
create or replace function public.vus_coaches_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(current_setting('request.jwt.claims', true),'') = '' then return new; end if;
  if new.approved is distinct from old.approved then
    if new.email = lower(coalesce(auth.jwt()->>'email','')) and not public.is_site_admin() then
      raise exception 'You can''t approve your own Valley United coach access.';
    end if;
    new.approved_by := case when new.approved then lower(auth.jwt()->>'email') end;
    new.approved_at := case when new.approved then now() end;
  end if;
  return new;
end $$;
drop trigger if exists vus_coaches_guard_trg on public.vus_coaches;
create trigger vus_coaches_guard_trg before update on public.vus_coaches for each row execute function public.vus_coaches_guard();

create or replace function public.is_vus_coach()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public.is_vus_admin()
      or exists (select 1 from public.vus_coaches v where v.email = lower(coalesce(auth.jwt()->>'email','')) and v.approved)
$$;
grant execute on function public.is_vus_coach() to authenticated;

-- Valley United admins can now add / remove other Valley United admins (site admins always could).
drop policy if exists "site admin all" on public.vus_admins;
drop policy if exists "vus admins manage" on public.vus_admins;
create policy "vus admins manage" on public.vus_admins for all to authenticated
  using (public.is_vus_admin()) with check (public.is_vus_admin());

-- Valley United age group from birth year (age on Dec 31 of the season year, like VYC): 5/6, 7/8, 9/10, 11/12, 13/14,
-- 15/16, 17/18 (17/18 = Young Men / Young Women). VYC's regular-season Intermediates splits into 15/16 and 17/18.
create or replace function public.vus_age_group(p_dob date, p_season integer)
returns text language sql immutable as $$
  select case when p_dob is null or p_season is null then null
    else case when p_season - extract(year from p_dob)::int <= 6 then '5/6'
              when p_season - extract(year from p_dob)::int <= 8 then '7/8'
              when p_season - extract(year from p_dob)::int <= 10 then '9/10'
              when p_season - extract(year from p_dob)::int <= 12 then '11/12'
              when p_season - extract(year from p_dob)::int <= 14 then '13/14'
              when p_season - extract(year from p_dob)::int <= 16 then '15/16'
              else '17/18' end end
$$;
grant execute on function public.vus_age_group(date, integer) to anon, authenticated;

-- The accepted rosters, with contact and medical details, for approved Valley United coaches — only the roster(s)
-- they coach, and for a Division Head Coach / Assistant only their age groups and boys/girls. Valley United admins and
-- site admins see all.
create or replace function public.vus_coach_roster(p_season integer)
returns table(request_id uuid, registration_id uuid, placement text, first_name text, last_name text, gender text, division text,
  age_group text, dob date, team_code text, events jsonb, entries jsonb, relay_ok boolean, shirt_size text, fee_paid boolean,   -- events = parent picks; entries = coach entries
  parent_name text, phone text, email text, parent2_name text, address text, city text, zip text,
  emergency_name text, emergency_phone text, medical_option text, medical_conditions text,
  insurance_carrier text, insurance_policy text, doctor_name text)
language plpgsql stable security definer set search_path to 'public' as $$
declare me public.vus_coaches; adm boolean := public.is_vus_admin();
begin
  if not adm then
    select * into me from public.vus_coaches v where v.email = lower(coalesce(auth.jwt()->>'email','')) and v.approved;
    if me.email is null then raise exception 'Only approved Valley United coaches can see the Valley United roster.'; end if;
  end if;
  return query
    select q.id, q.registration_id, q.placement, q.first_name, q.last_name, q.gender, q.division,
      public.vus_age_group(q.dob, q.season_year), q.dob, q.team_code,
      q.events, q.entries, q.relay_ok, q.shirt_size, q.fee_paid,
      coalesce(q.parent_name, r.parent1_name), coalesce(q.phone, r.phone), coalesce(q.email, r.email), r.parent2_name,
      r.address, r.city, r.zip, r.emergency_name, r.emergency_phone, r.medical_option, r.medical_conditions,
      r.insurance_carrier, r.insurance_policy, r.doctor_name
    from public.vus_requests q left join public.registrations r on r.id = q.registration_id
    where q.season_year = p_season and q.status = 'accepted'
      and (adm or (
        q.placement = any(me.squads)
        and case me.role_type
          when 'team_president' then true
          when 'field_event_coach' then exists (
            select 1 from jsonb_array_elements(coalesce(q.events,'[]'::jsonb) || coalesce(q.entries,'[]'::jsonb)) e   -- parent picked it, or coaches entered it
            where e->>'event_name' = any(string_to_array(replace(coalesce(me.event_specialty,''),', ',','),',')))
          else ( coalesce(me.division_or_age_group,'') ilike 'all%'
                 or public.vus_age_group(q.dob, q.season_year) = any(string_to_array(replace(coalesce(me.division_or_age_group,''),', ',','),',')) )
               and ( me.coach_gender is null
                     or (case q.gender when 'Boy' then 'Boys' when 'Girl' then 'Girls' end)
                        = any(string_to_array(replace(me.coach_gender,', ',','),',')) )
        end))
    order by q.placement, q.last_name, q.first_name;
end $$;
revoke all on function public.vus_coach_roster(integer) from public;
grant execute on function public.vus_coach_roster(integer) to authenticated;

-- ---------- high school sign-ups (postseason_registrations): admins change, Valley United coaches view ----------
-- Before: ANY approved coach on ANY VYC team could read and change every high school sign-up (addresses, phones,
-- signatures, marks). Now only Valley United admins and site admins can read or change them (their existing policies);
-- the public/parent sign-up (insert) is unchanged. Valley United coaches see them read-only through
-- vus_coach_hs_roster below.
drop policy if exists "coaches read postseason" on public.postseason_registrations;
drop policy if exists "coaches update postseason" on public.postseason_registrations;
drop policy if exists "ps_coach_select" on public.postseason_registrations;
drop policy if exists "ps_coach_update" on public.postseason_registrations;

-- High school athletes are in the 15/16 or 17/18 age group like everyone else, so they go to that age group's Division
-- Head Coach and Assistants. Team President sees all; Field Event Coaches see those who listed their events.
-- Read-only — no signatures.
create or replace function public.vus_coach_hs_roster(p_season integer)
returns table(id uuid, first_name text, last_name text, gender text, dob date, age_division text, high_school text,
  cif_season_end date, cif_done boolean, athletic_net_url text, events jsonb, relay_ok boolean, shirt_size text,
  parent_name text, phone text, email text, parent2_name text, address text, city text, zip text, status text, fee_paid boolean)
language plpgsql stable security definer set search_path to 'public' as $$
declare me public.vus_coaches; adm boolean := public.is_vus_admin();
begin
  if not adm then
    select * into me from public.vus_coaches v where v.email = lower(coalesce(auth.jwt()->>'email','')) and v.approved;
    if me.email is null then raise exception 'Only approved Valley United coaches can see the Valley United roster.'; end if;
  end if;
  return query
    select h.id, h.first_name, h.last_name, h.gender, h.dob, h.age_division, h.high_school, h.cif_season_end, h.cif_done,
      h.athletic_net_url, h.events, h.relay_ok, h.shirt_size,
      coalesce(h.parent1_name, h.parent_name), coalesce(h.phone, h.parent_phone), coalesce(h.email, h.parent_email), h.parent2_name,
      h.address, h.city, h.zip, h.status, h.fee_paid
    from public.postseason_registrations h
    where h.season_year = p_season and coalesce(h.status,'') <> 'declined'
      and (adm or case me.role_type
        when 'team_president' then true
        when 'field_event_coach' then exists (
          select 1 from jsonb_array_elements(coalesce(h.events,'[]'::jsonb)) e
          where (case when e->>'event' = 'Javelin' then 'Javelin Throw' else e->>'event' end)
                = any(string_to_array(replace(coalesce(me.event_specialty,''),', ',','),',')))
        else ( coalesce(me.division_or_age_group,'') ilike 'all%'
               or h.age_division = any(string_to_array(replace(coalesce(me.division_or_age_group,''),', ',','),',')) )
             and ( me.coach_gender is null
                   or (case h.gender when 'Boy' then 'Boys' when 'Male' then 'Boys' when 'Girl' then 'Girls' when 'Female' then 'Girls' else h.gender end)
                      = any(string_to_array(replace(me.coach_gender,', ',','),',')) )
        end)
    order by h.last_name, h.first_name;
end $$;
revoke all on function public.vus_coach_hs_roster(integer) from public;
grant execute on function public.vus_coach_hs_roster(integer) to authenticated;

commit;
