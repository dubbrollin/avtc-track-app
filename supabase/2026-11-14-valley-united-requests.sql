-- Valley United Striders: parents request the postseason team from the TRACK side of the app.
--  * The athlete's regular-season team never changes; Valley United is not a transfer.
--  * When the parent asks, the athlete's season bests (every event they competed in) carry over.
--  * The database answers three questions from the season's results:
--      met a VYC qualifying standard in any event?  ran at league finals?  ran at IECs?
--    Any YES  -> Postseason team.   NO to all three -> Developmental only (its own roster).
--  * A Valley United admin (or site admin) accepts or declines each request.
--  * Requests open on the IEC meet date; they close on the "Valley United requests close" date in
--    League Setup (app_settings key vus_request_close_<season>; blank = no closing date).
--  * High school athletes with no VYC season still sign up on the separate Valley United form
--    (postseason_registrations).
begin;

-- ---------- which meets are league finals / IECs ----------
alter table public.meets add column if not exists postseason_kind text;
alter table public.meets drop constraint if exists meets_postseason_kind_check;
alter table public.meets add constraint meets_postseason_kind_check check (postseason_kind is null or postseason_kind in ('league_final','iec'));
update public.meets set postseason_kind = 'league_final'
 where postseason_kind is null and is_championship and name ~* 'league';
update public.meets set postseason_kind = 'iec'
 where postseason_kind is null and is_championship and (name ~* 'individual event' or name ~* '\miec\M');

-- ---------- Valley United admins (set by site admins on the Valley United tab) ----------
create table if not exists public.vus_admins (
  email text primary key check (email = lower(email)),
  name text,
  added_by text,
  created_at timestamptz not null default now()
);
alter table public.vus_admins enable row level security;
drop policy if exists "site admin all" on public.vus_admins;
create policy "site admin all" on public.vus_admins for all to authenticated using (public.is_site_admin()) with check (public.is_site_admin());
drop policy if exists "vus admins read own" on public.vus_admins;
create policy "vus admins read own" on public.vus_admins for select to authenticated
  using (email = lower(coalesce(auth.jwt()->>'email','')));

create or replace function public.is_vus_admin()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public.is_site_admin()
      or exists (select 1 from public.vus_admins a where a.email = lower(coalesce(auth.jwt()->>'email','')))
$$;
grant execute on function public.is_vus_admin() to authenticated;

-- ---------- the request window ----------
create or replace function public.vus_window(p_season integer)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'opens',  (select min(m.meet_date) from public.meets m where m.season_year = p_season and m.postseason_kind = 'iec'),
    'closes', (select nullif(value,'')::date from public.app_settings where key = 'vus_request_close_' || p_season))
$$;
grant execute on function public.vus_window(integer) to anon, authenticated;

-- ---------- eligibility + season bests, worked out from the results ----------
-- Qualifying standards are stored by age range; results carry the division they ran in.
create or replace function public.vus_std_ages(p_division text)
returns int[] language sql immutable as $$
  select case p_division when 'Gremlin' then array[7,8] when 'Bantam' then array[9,10] when 'Juniors' then array[11,12]
                         when 'Youth' then array[13,14] when 'Intermediates' then array[0,99] end
$$;

create or replace function public.vus_compute(p_reg uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r public.registrations; bests jsonb; q boolean; lf boolean; iec boolean;
begin
  select * into r from public.registrations where id = p_reg;
  if r.id is null then return null; end if;

  with mine as (   -- the athlete's individual marks this season
    select x.*, m.name meet_name, m.meet_date
      from public.results x join public.meets m on m.id = x.meet_id
     where x.registration_id = r.id and not x.is_relay and x.mark_value > 0 and m.season_year = r.season_year
  ), best as (
    select distinct on (event_code) *
      from mine order by event_code, case when is_time then mark_value else -mark_value end, meet_date desc
  ), marked as (
    select b.*, exists (
             select 1 from public.qualifying_standards s
              where s.gender = b.gender and s.event_code = b.event_code and not s.is_relay
                and array[s.age_low, s.age_high] = public.vus_std_ages(b.division)
                and (b.mark_value = s.mark_value or (b.is_time and b.mark_value < s.mark_value) or (not b.is_time and b.mark_value > s.mark_value))
           ) met
      from best b
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_code', event_code, 'event_name', event_name, 'mark', mark, 'mark_value', mark_value, 'is_time', is_time,
           'wind', wind, 'meet', meet_name, 'meet_date', meet_date, 'division', division, 'q', met)
           order by is_time desc, event_code), '[]'::jsonb),
         coalesce(bool_or(met), false)
    into bests, q from marked;

  -- Ran at a league final / IEC: an individual result, or a named runner on their team's relay.
  select exists (
           select 1 from public.results x join public.meets m on m.id = x.meet_id
            where m.season_year = r.season_year and m.postseason_kind = 'league_final'
              and (x.registration_id = r.id or (x.is_relay and x.team_code = r.team_code and exists (
                     select 1 from regexp_split_to_table(coalesce(x.relay_runners,''), ',') n
                      where public.name_key(n) = public.name_key(r.first_name || r.last_name))))),
         exists (
           select 1 from public.results x join public.meets m on m.id = x.meet_id
            where m.season_year = r.season_year and m.postseason_kind = 'iec'
              and (x.registration_id = r.id or (x.is_relay and x.team_code = r.team_code and exists (
                     select 1 from regexp_split_to_table(coalesce(x.relay_runners,''), ',') n
                      where public.name_key(n) = public.name_key(r.first_name || r.last_name)))))
    into lf, iec;

  return jsonb_build_object(
    'registration_id', r.id, 'season_year', r.season_year, 'team_code', r.team_code,
    'qualified', q, 'ran_league_final', lf, 'ran_iec', iec,
    'placement', case when q or lf or iec then 'postseason' else 'developmental' end,
    'max_events', case when r.division in ('Youth','Intermediates') then 4 else 3 end,
    'bests', bests,
    'window', public.vus_window(r.season_year));
end $$;
revoke all on function public.vus_compute(uuid) from public;

-- What the parent (or a Valley United admin) sees before asking.
create or replace function public.vus_eligibility(p_reg uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r public.registrations;
begin
  select * into r from public.registrations where id = p_reg;
  if r.id is null or not (lower(r.email) = lower(coalesce(auth.jwt()->>'email','')) or public.is_vus_admin()) then
    raise exception 'Athlete not found.';
  end if;
  return public.vus_compute(p_reg);
end $$;
grant execute on function public.vus_eligibility(uuid) to authenticated;

-- ---------- the requests ----------
create table if not exists public.vus_requests (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  registration_id uuid not null unique references public.registrations(id) on delete cascade,
  season_year integer not null,
  team_code text,                         -- regular-season team (unchanged by Valley United)
  first_name text, last_name text, gender text, dob date, division text,
  placement text not null check (placement in ('postseason','developmental')),
  qualified boolean not null default false,
  ran_league_final boolean not null default false,
  ran_iec boolean not null default false,
  best_marks jsonb not null default '[]'::jsonb,   -- every event's season best, carried over
  events jsonb not null default '[]'::jsonb,       -- the events the parent picked (from best_marks)
  shirt_size text,
  returns_to_team boolean not null default true,   -- acknowledged: back to the regular-season team next season
  parent_name text, email text, phone text,
  signature text, signature_method text, signed_at timestamptz,
  fee_amount_cents integer not null default 25000,
  fee_paid boolean not null default false,
  fee_paid_at timestamptz,
  status text not null default 'submitted' check (status in ('submitted','accepted','declined')),
  reviewed_by text, reviewed_at timestamptz, review_note text,
  checked_at timestamptz
);
create index if not exists vus_requests_season on public.vus_requests (season_year, placement, status);
alter table public.vus_requests enable row level security;

drop policy if exists "parents read own" on public.vus_requests;
create policy "parents read own" on public.vus_requests for select to authenticated
  using (lower(email) = lower(coalesce(auth.jwt()->>'email','')));
drop policy if exists "parents ask" on public.vus_requests;
create policy "parents ask" on public.vus_requests for insert to authenticated
  with check (lower(email) = lower(coalesce(auth.jwt()->>'email','')) or public.is_vus_admin());
drop policy if exists "parents withdraw" on public.vus_requests;
create policy "parents withdraw" on public.vus_requests for delete to authenticated
  using (lower(email) = lower(coalesce(auth.jwt()->>'email','')) and status = 'submitted');
drop policy if exists "team admins read" on public.vus_requests;
create policy "team admins read" on public.vus_requests for select to authenticated
  using (public.is_team_admin_of(team_code));
drop policy if exists "vus admins all" on public.vus_requests;
create policy "vus admins all" on public.vus_requests for all to authenticated
  using (public.is_vus_admin()) with check (public.is_vus_admin());

-- On a new request the database fills in the athlete, the three answers, the placement and the season bests
-- itself (whatever the page sent), checks the window, and checks the picked events.
create or replace function public.vus_request_fill()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; e jsonb; w jsonb; today date := (now() at time zone 'America/Los_Angeles')::date;
  picked text[]; allowed text[];
begin
  select * into r from public.registrations where id = new.registration_id;
  if r.id is null or r.status = 'rejected' then raise exception 'Athlete not found.'; end if;
  if coalesce(r.sport,'Track & Field') = 'Cross Country' then
    raise exception 'Valley United requests come from the athlete''s track & field registration.';
  end if;
  if not (lower(r.email) = lower(coalesce(auth.jwt()->>'email','')) or public.is_vus_admin()) then
    raise exception 'Only the parent who registered this athlete can ask for Valley United.';
  end if;
  e := public.vus_compute(r.id); w := e->'window';
  if not public.is_vus_admin() then
    if w->>'opens' is null then raise exception 'Valley United requests open after the IEC meet, which isn''t on the schedule yet.'; end if;
    if today < (w->>'opens')::date then
      raise exception 'Valley United requests open on %, the day of the IEC meet.', to_char((w->>'opens')::date, 'FMMonth FMDD, YYYY');
    end if;
    if w->>'closes' is not null and today > (w->>'closes')::date then
      raise exception 'Valley United requests closed on %.', to_char((w->>'closes')::date, 'FMMonth FMDD, YYYY');
    end if;
  end if;

  select coalesce(array_agg(x->>'event_code'), '{}') into allowed from jsonb_array_elements(e->'bests') x;
  select coalesce(array_agg(x->>'event_code'), '{}') into picked from jsonb_array_elements(coalesce(new.events,'[]'::jsonb)) x;
  if cardinality(picked) = 0 then raise exception 'Please pick at least one event.'; end if;
  if cardinality(picked) > (e->>'max_events')::int then
    raise exception 'This age division may enter up to % events.', e->>'max_events';
  end if;
  if not picked <@ allowed then raise exception 'Pick events from the athlete''s season bests.'; end if;
  if cardinality(picked) <> (select count(distinct p) from unnest(picked) p) then raise exception 'Each event can only be picked once.'; end if;

  new.season_year := r.season_year; new.team_code := r.team_code;
  new.first_name := r.first_name; new.last_name := r.last_name; new.gender := r.gender; new.dob := r.dob; new.division := r.division;
  new.email := lower(r.email);
  new.qualified := (e->>'qualified')::boolean; new.ran_league_final := (e->>'ran_league_final')::boolean; new.ran_iec := (e->>'ran_iec')::boolean;
  new.placement := e->>'placement'; new.best_marks := e->'bests';
  new.events := (select jsonb_agg(b) from jsonb_array_elements(e->'bests') b where b->>'event_code' = any(picked));
  new.status := 'submitted'; new.reviewed_by := null; new.reviewed_at := null; new.fee_paid := false; new.fee_paid_at := null;
  new.checked_at := now();
  return new;
end $$;
drop trigger if exists vus_request_fill_trg on public.vus_requests;
create trigger vus_request_fill_trg before insert on public.vus_requests for each row execute function public.vus_request_fill();

-- After a request, only a Valley United admin changes it; the carried-over facts stay as the database worked them out
-- (use vus_recheck to refresh them after late results).
create or replace function public.vus_request_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(current_setting('request.jwt.claims', true),'') = '' then return new; end if;
  if not public.is_vus_admin() then raise exception 'Only a Valley United admin can change a request.'; end if;
  if (new.registration_id, new.season_year, new.team_code, new.placement, new.qualified, new.ran_league_final, new.ran_iec, new.best_marks)
     is distinct from (old.registration_id, old.season_year, old.team_code, old.placement, old.qualified, old.ran_league_final, old.ran_iec, old.best_marks)
     and current_setting('vus.recheck', true) is distinct from 'on' then
    raise exception 'The placement and season bests come from the results. Use "Re-check results" to refresh them.';
  end if;
  if new.status is distinct from old.status then
    new.reviewed_by := lower(coalesce(auth.jwt()->>'email','')); new.reviewed_at := now();
  end if;
  if new.fee_paid and not old.fee_paid then new.fee_paid_at := now(); end if;
  if not new.fee_paid then new.fee_paid_at := null; end if;
  return new;
end $$;
drop trigger if exists vus_request_guard_trg on public.vus_requests;
create trigger vus_request_guard_trg before update on public.vus_requests for each row execute function public.vus_request_guard();

-- Re-work the answers, placement and bests from the latest results (e.g. IEC results posted after the request).
create or replace function public.vus_recheck(p_id uuid)
returns public.vus_requests language plpgsql security definer set search_path to 'public' as $$
declare q public.vus_requests; e jsonb;
begin
  if not public.is_vus_admin() then raise exception 'Only a Valley United admin can re-check a request.'; end if;
  select * into q from public.vus_requests where id = p_id;
  if q.id is null then raise exception 'Request not found.'; end if;
  e := public.vus_compute(q.registration_id);
  perform set_config('vus.recheck', 'on', true);
  update public.vus_requests set
    qualified = (e->>'qualified')::boolean, ran_league_final = (e->>'ran_league_final')::boolean, ran_iec = (e->>'ran_iec')::boolean,
    placement = e->>'placement', best_marks = e->'bests',
    events = coalesce((select jsonb_agg(b) from jsonb_array_elements(e->'bests') b
                        where b->>'event_code' in (select x->>'event_code' from jsonb_array_elements(q.events) x)), '[]'::jsonb),
    checked_at = now()
   where id = p_id returning * into q;
  perform set_config('vus.recheck', 'off', true);
  return q;
end $$;
grant execute on function public.vus_recheck(uuid) to authenticated;

-- "Look around" demo logins stay view-only here too.
-- (Only where the demo logins exist: the server copy never had them.)
drop trigger if exists zz_demo_readonly on public.vus_requests;
drop trigger if exists zz_demo_readonly on public.vus_admins;
do $demo$ begin
  if to_regprocedure('public.demo_readonly()') is not null then
    execute 'create trigger zz_demo_readonly before insert or update or delete on public.vus_requests for each row execute function public.demo_readonly()';
    execute 'create trigger zz_demo_readonly before insert or update or delete on public.vus_admins for each row execute function public.demo_readonly()';
  end if;
end $demo$;

-- Valley United admins set the request closing date (only that setting).
drop policy if exists "vus admins set vus dates" on public.app_settings;
create policy "vus admins set vus dates" on public.app_settings for all to authenticated
  using (public.is_vus_admin() and key like 'vus\_request\_close\_%') with check (public.is_vus_admin() and key like 'vus\_request\_close\_%');

-- ---------- high school sign-up (no VYC season): Valley United admins see and manage it too ----------
drop policy if exists "vus admins all" on public.postseason_registrations;
create policy "vus admins all" on public.postseason_registrations for all to authenticated
  using (public.is_vus_admin()) with check (public.is_vus_admin());
-- The page signs in parents, so a signed-in parent may submit too (not only anonymous visitors).
drop policy if exists "signed in can submit postseason" on public.postseason_registrations;
create policy "signed in can submit postseason" on public.postseason_registrations for insert to authenticated with check (true);

commit;
notify pgrst, 'reload schema';

select 'valley united: ' ||
  (select count(*) from public.meets where postseason_kind = 'league_final') || ' league finals, ' ||
  (select count(*) from public.meets where postseason_kind = 'iec') || ' IECs, ' ||
  (case when to_regclass('public.vus_requests') is not null then 'requests table ok' else 'requests table MISSING' end);
