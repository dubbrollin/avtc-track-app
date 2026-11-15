-- Valley United CROSS COUNTRY (Riley, 2026-11-15). Run after the two other 2026-11-15 files.
--  * A Valley United request is either Valley United Track & Field or Valley United Cross Country (vus_requests.sport).
--    It comes from the athlete's registration for that sport: a track registration asks for VU Track, a cross country
--    registration asks for VU Cross Country.
--  * Cross country is ONE Valley United cross country team: no Postseason/Developmental split (placement
--    'cross_country'), no results check, no event picks, no relays question.
--  * VU Cross Country requests are open during the cross country league's registration window (League Setup:
--    app_settings xc_registration_open_<season> / xc_registration_close_<season>; blank = no limit).
--  * High school sign-ups also say Track & Field or Cross Country (postseason_registrations.sport); cross country
--    sign-ups have no events.
--  * Valley United coaches say which sport(s) they coach (vus_coaches.sports: Track & Field, Cross Country or both,
--    set by Valley United admins); each coach only sees that sport's athletes.
begin;

-- ---------- columns ----------
alter table public.vus_requests add column if not exists sport text not null default 'Track & Field';
alter table public.vus_requests drop constraint if exists vus_requests_sport_check;
alter table public.vus_requests add constraint vus_requests_sport_check check (sport in ('Track & Field','Cross Country'));
alter table public.vus_requests drop constraint if exists vus_requests_placement_check;
alter table public.vus_requests add constraint vus_requests_placement_check check (placement in ('postseason','developmental','cross_country'));

alter table public.postseason_registrations add column if not exists sport text not null default 'Track & Field';
alter table public.postseason_registrations drop constraint if exists postseason_registrations_sport_check;
alter table public.postseason_registrations add constraint postseason_registrations_sport_check check (sport in ('Track & Field','Cross Country'));

alter table public.vus_coaches add column if not exists sports text[] not null default array['Track & Field'];
alter table public.vus_coaches drop constraint if exists vus_coaches_sports_check;
alter table public.vus_coaches add constraint vus_coaches_sports_check
  check (cardinality(sports) >= 1 and sports <@ array['Track & Field','Cross Country']);

-- ---------- cross country request window = the cross country league's registration window ----------
create or replace function public.vus_xc_window(p_season integer)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'opens',  (select nullif(value,'')::date from public.app_settings where key = 'xc_registration_open_'  || p_season),
    'closes', (select nullif(value,'')::date from public.app_settings where key = 'xc_registration_close_' || p_season))
$$;
grant execute on function public.vus_xc_window(integer) to anon, authenticated;

-- ---------- requests: track (as before) or cross country (one team, no picks) ----------
create or replace function public.vus_request_fill()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; e jsonb; w jsonb; today date := (now() at time zone 'America/Los_Angeles')::date;
  picked text[]; allowed text[]; adm boolean := public.is_vus_admin();
begin
  select * into r from public.registrations where id = new.registration_id;
  if r.id is null or r.status = 'rejected' then raise exception 'Athlete not found.'; end if;
  if not (lower(r.email) = lower(coalesce(auth.jwt()->>'email','')) or adm) then
    raise exception 'Only the parent who registered this athlete can ask for Valley United.';
  end if;

  new.season_year := r.season_year; new.team_code := r.team_code;
  new.first_name := r.first_name; new.last_name := r.last_name; new.gender := r.gender; new.dob := r.dob; new.division := r.division;
  new.email := lower(r.email);
  new.entries := null; new.entries_by := null; new.entries_at := null;
  new.status := 'submitted'; new.reviewed_by := null; new.reviewed_at := null; new.fee_paid := false; new.fee_paid_at := null;
  new.checked_at := now();

  if coalesce(r.sport,'Track & Field') = 'Cross Country' then
    -- Valley United Cross Country: one team; open during the cross country league registration window.
    w := public.vus_xc_window(r.season_year);
    if not adm then
      if w->>'opens' is not null and today < (w->>'opens')::date then
        raise exception 'Valley United Cross Country requests open on %.', to_char((w->>'opens')::date, 'FMMonth FMDD, YYYY');
      end if;
      if w->>'closes' is not null and today > (w->>'closes')::date then
        raise exception 'Valley United Cross Country requests closed on %.', to_char((w->>'closes')::date, 'FMMonth FMDD, YYYY');
      end if;
    end if;
    new.sport := 'Cross Country'; new.placement := 'cross_country';
    new.events := '[]'::jsonb; new.best_marks := '[]'::jsonb; new.relay_ok := null;
    new.qualified := false; new.ran_league_final := false; new.ran_iec := false;
    return new;
  end if;

  -- Valley United Track & Field
  e := public.vus_compute(r.id); w := e->'window';
  if not adm then
    if w->>'opens' is null then raise exception 'Valley United requests aren''t open yet — the opening date isn''t set.'; end if;
    if today < (w->>'opens')::date then
      raise exception 'Valley United requests open on %.', to_char((w->>'opens')::date, 'FMMonth FMDD, YYYY');
    end if;
    if w->>'closes' is not null and today > (w->>'closes')::date then
      raise exception 'Valley United requests closed on %.', to_char((w->>'closes')::date, 'FMMonth FMDD, YYYY');
    end if;
  end if;
  select coalesce(array_agg(x->>'event_code'), '{}') into allowed from jsonb_array_elements(coalesce(e->'bests','[]'::jsonb)) x;
  select coalesce(array_agg(distinct x->>'event_code'), '{}') into picked from jsonb_array_elements(coalesce(new.events,'[]'::jsonb)) x;
  if cardinality(picked) = 0 then raise exception 'Please pick at least one individual event.'; end if;
  if new.relay_ok is null and not adm then raise exception 'Please answer whether your athlete is willing to run on relays.'; end if;
  if cardinality(picked) > 3 then raise exception 'Pick up to 3 individual events.'; end if;
  if not picked <@ allowed then
    raise exception 'Every Valley United event needs a mark from this season. Pick events the athlete competed in.';
  end if;
  new.sport := 'Track & Field';
  new.qualified := (e->>'qualified')::boolean; new.ran_league_final := (e->>'ran_league_final')::boolean; new.ran_iec := (e->>'ran_iec')::boolean;
  new.placement := e->>'placement'; new.best_marks := e->'bests';
  new.events := (select jsonb_agg(b) from jsonb_array_elements(e->'bests') b where b->>'event_code' = any(picked));
  return new;
end $$;

-- Cross country has no results check or coach entries.
create or replace function public.vus_recheck(p_id uuid)
returns public.vus_requests language plpgsql security definer set search_path to 'public' as $$
declare q public.vus_requests; e jsonb;
begin
  if not public.is_vus_admin() then raise exception 'Only a Valley United admin can re-check a request.'; end if;
  select * into q from public.vus_requests where id = p_id;
  if q.id is null then raise exception 'Request not found.'; end if;
  if q.sport = 'Cross Country' then return q; end if;
  e := public.vus_compute(q.registration_id);
  perform set_config('vus.recheck', 'on', true);
  update public.vus_requests set
    qualified = (e->>'qualified')::boolean, ran_league_final = (e->>'ran_league_final')::boolean, ran_iec = (e->>'ran_iec')::boolean,
    placement = e->>'placement', best_marks = e->'bests',
    events = coalesce((select jsonb_agg(coalesce(
               (select b from jsonb_array_elements(coalesce(e->'bests','[]'::jsonb)) b where b->>'event_code' = x->>'event_code' limit 1), x))
             from jsonb_array_elements(coalesce(q.events,'[]'::jsonb)) x), '[]'::jsonb),
    entries = case when q.entries is null then null else public.vus_build_entries(e->'bests',
               array(select x->>'event_code' from jsonb_array_elements(q.entries) x where x->>'kind' = 'event'),
               array(select x->>'relay' from jsonb_array_elements(q.entries) x where x->>'kind' = 'relay'), q.entries) end,
    checked_at = now()
   where id = p_id returning * into q;
  perform set_config('vus.recheck', 'off', true);
  return q;
end $$;

create or replace function public.vus_set_entries(p_id uuid, p_codes text[], p_relays text[])
returns public.vus_requests language plpgsql security definer set search_path to 'public' as $$
declare q public.vus_requests; codes text[]; rl text[]; allowed text[];
begin
  if not public.is_vus_admin() then raise exception 'Only a Valley United admin can enter athletes.'; end if;
  select * into q from public.vus_requests where id = p_id;
  if q.id is null then raise exception 'Request not found.'; end if;
  if q.sport = 'Cross Country' then raise exception 'Cross country athletes run the race for their age group — there are no event entries.'; end if;
  codes := coalesce((select array_agg(distinct c) from unnest(p_codes) c where c is not null), '{}');
  rl := coalesce((select array_agg(distinct r) from unnest(p_relays) r where r is not null), '{}');
  if not rl <@ array['4x100','4x400','4x800'] then raise exception 'Unknown relay.'; end if;
  if cardinality(codes) + cardinality(rl) > 3 then raise exception 'Up to 3 entries in total — a relay counts as one.'; end if;
  select coalesce(array_agg(x->>'event_code'), '{}') into allowed from jsonb_array_elements(coalesce(q.best_marks,'[]'::jsonb)) x;
  if not codes <@ allowed then
    raise exception 'Every individual event needs a mark from this season. Pick events the athlete competed in.';
  end if;
  perform set_config('vus.entries', 'on', true);
  update public.vus_requests set
    entries = case when cardinality(codes) + cardinality(rl) = 0 then null else public.vus_build_entries(q.best_marks, codes, rl, q.entries) end,
    entries_by = lower(coalesce(auth.jwt()->>'email','')), entries_at = now()
   where id = p_id returning * into q;
  perform set_config('vus.entries', 'off', true);
  return q;
end $$;

-- ---------- high school sign-ups: track or cross country (cross country = no events) ----------
create or replace function public.ps_hs_fill()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.sport = 'Cross Country' then new.events := '[]'::jsonb; new.relay_ok := null; end if;
  if public.is_vus_admin() then return new; end if;
  if coalesce(new.vyc_home_team,'') = 'HS' then
    if coalesce(new.athletic_net_url,'') <> '' and new.athletic_net_url !~* '^https?://([a-z0-9-]+\.)*athletic\.net/' then
      raise exception 'That link isn''t an Athletic.net link (it starts with https://www.athletic.net/). Leave it blank if you don''t have it.';
    end if;
    if coalesce(trim(new.high_school),'') = '' then raise exception 'Please enter the athlete''s high school.'; end if;
    if new.cif_season_end is null and not new.cif_done then
      raise exception 'Please tell us when the athlete''s high school (CIF) season ends, or that it''s already over.';
    end if;
  end if;
  new.events := (select coalesce(jsonb_agg(x - 'verified' - 'verified_by' - 'verified_at'), '[]'::jsonb)
                   from jsonb_array_elements(coalesce(new.events,'[]'::jsonb)) x);
  return new;
end $$;

-- ---------- coach rosters by sport ----------
drop function if exists public.vus_coach_roster(integer);
create or replace function public.vus_coach_roster(p_season integer)
returns table(request_id uuid, registration_id uuid, sport text, placement text, first_name text, last_name text, gender text, division text,
  age_group text, dob date, team_code text, events jsonb, entries jsonb, relay_ok boolean, shirt_size text, fee_paid boolean,
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
    select q.id, q.registration_id, q.sport, q.placement, q.first_name, q.last_name, q.gender, q.division,
      -- cross country registrations carry the cross country season year; age group from it the same way
      public.vus_age_group(q.dob, q.season_year), q.dob, q.team_code,
      q.events, q.entries, q.relay_ok, q.shirt_size, q.fee_paid,
      coalesce(q.parent_name, r.parent1_name), coalesce(q.phone, r.phone), coalesce(q.email, r.email), r.parent2_name,
      r.address, r.city, r.zip, r.emergency_name, r.emergency_phone, r.medical_option, r.medical_conditions,
      r.insurance_carrier, r.insurance_policy, r.doctor_name
    from public.vus_requests q left join public.registrations r on r.id = q.registration_id
    where q.season_year = p_season and q.status = 'accepted'
      and (adm or (
        q.sport = any(me.sports)
        and (q.sport = 'Cross Country' or q.placement = any(me.squads))
        and case me.role_type
          when 'team_president' then true
          when 'field_event_coach' then q.sport = 'Track & Field' and exists (
            select 1 from jsonb_array_elements(coalesce(q.events,'[]'::jsonb) || coalesce(q.entries,'[]'::jsonb)) e
            where e->>'event_name' = any(string_to_array(replace(coalesce(me.event_specialty,''),', ',','),',')))
          else ( coalesce(me.division_or_age_group,'') ilike 'all%'
                 or public.vus_age_group(q.dob, q.season_year) = any(string_to_array(replace(coalesce(me.division_or_age_group,''),', ',','),',')) )
               and ( me.coach_gender is null
                     or (case q.gender when 'Boy' then 'Boys' when 'Girl' then 'Girls' end)
                        = any(string_to_array(replace(me.coach_gender,', ',','),',')) )
        end))
    order by q.sport, q.placement, q.last_name, q.first_name;
end $$;
revoke all on function public.vus_coach_roster(integer) from public;
grant execute on function public.vus_coach_roster(integer) to authenticated;

drop function if exists public.vus_coach_hs_roster(integer);
create or replace function public.vus_coach_hs_roster(p_season integer)
returns table(id uuid, sport text, first_name text, last_name text, gender text, dob date, age_division text, high_school text,
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
    select h.id, h.sport, h.first_name, h.last_name, h.gender, h.dob, h.age_division, h.high_school, h.cif_season_end, h.cif_done,
      h.athletic_net_url, h.events, h.relay_ok, h.shirt_size,
      coalesce(h.parent1_name, h.parent_name), coalesce(h.phone, h.parent_phone), coalesce(h.email, h.parent_email), h.parent2_name,
      h.address, h.city, h.zip, h.status, h.fee_paid
    from public.postseason_registrations h
    where h.season_year = p_season and coalesce(h.status,'') <> 'declined'
      and (adm or (h.sport = any(me.sports) and case me.role_type
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
        end))
    order by h.sport, h.last_name, h.first_name;
end $$;
revoke all on function public.vus_coach_hs_roster(integer) from public;
grant execute on function public.vus_coach_hs_roster(integer) to authenticated;

commit;
