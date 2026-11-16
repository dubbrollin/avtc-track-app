-- Valley United, 2026-11-16:
--  1. Valley United Track & Field President and Valley United Cross Country President are VYC board positions (Site Admin >
--     People & Access > Board positions). One person per season each, set by a site admin, on their Valley United coach
--     record (vus_coaches.track_president_season / xc_president_season).
--  2. Each Valley United team (Track & Field, Cross Country) has its own homepage (vus.html): a welcome message and posts
--     to parents. Anyone can read them; that sport's president for the current season, Valley United admins and site
--     admins write them.
--  3. Requests are open all year: no opening date unless one is set in Settings (the closing date still applies).
--  4. Track & Field: parents can pick any individual event (up to 3) before the athlete has a mark. Those show as "needs a
--     season mark"; Re-check fills marks in as results come in. Valley United decides at the end of the season.
begin;

-- ---------- 1. presidents ----------
alter table public.vus_coaches add column if not exists track_president_season integer;
alter table public.vus_coaches add column if not exists xc_president_season integer;

create or replace function public.vus_coaches_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(current_setting('request.jwt.claims', true),'') = '' then return new; end if;
  if (new.track_president_season is distinct from old.track_president_season
      or new.xc_president_season is distinct from old.xc_president_season) and not public.is_site_admin() then
    raise exception 'Only a site admin can confirm a Valley United president.';
  end if;
  if new.approved is distinct from old.approved then
    if new.email = lower(coalesce(auth.jwt()->>'email','')) and not public.is_site_admin() then
      raise exception 'You can''t approve your own Valley United coach access.';
    end if;
    new.approved_by := case when new.approved then lower(auth.jwt()->>'email') end;
    new.approved_at := case when new.approved then now() end;
  end if;
  return new;
end $$;

create or replace function public.vus_current_season()
returns integer language sql stable security definer set search_path to 'public' as $$
  select coalesce((select nullif(value,'')::integer from public.app_settings where key = 'season_year'),
                  extract(year from now())::integer)
$$;
grant execute on function public.vus_current_season() to anon, authenticated;

-- Can the signed-in person write that Valley United team's homepage?
create or replace function public.can_post_vus(p_sport text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public.is_vus_admin() or exists (
    select 1 from public.vus_coaches v
     where v.email = lower(coalesce(auth.jwt()->>'email',''))
       and case when p_sport = 'Cross Country' then v.xc_president_season else v.track_president_season end
           = public.vus_current_season())
$$;
grant execute on function public.can_post_vus(text) to authenticated;

-- ---------- 2. homepages ----------
create table if not exists public.vus_pages (
  sport text primary key check (sport in ('Track & Field','Cross Country')),
  welcome_title text,
  welcome text,
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table public.vus_pages enable row level security;
drop policy if exists "anyone reads" on public.vus_pages;
create policy "anyone reads" on public.vus_pages for select to anon, authenticated using (true);
drop policy if exists "writers write" on public.vus_pages;
create policy "writers write" on public.vus_pages for all to authenticated
  using (public.can_post_vus(sport)) with check (public.can_post_vus(sport));
grant select on public.vus_pages to anon, authenticated;
grant insert, update, delete on public.vus_pages to authenticated;

create table if not exists public.vus_posts (
  id uuid primary key default gen_random_uuid(),
  sport text not null check (sport in ('Track & Field','Cross Country')),
  title text not null,
  body text not null,
  pinned boolean not null default false,
  author_email text,
  author_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
create index if not exists vus_posts_sport_idx on public.vus_posts (sport, created_at desc);
alter table public.vus_posts enable row level security;
drop policy if exists "anyone reads" on public.vus_posts;
create policy "anyone reads" on public.vus_posts for select to anon, authenticated using (true);
drop policy if exists "writers write" on public.vus_posts;
create policy "writers write" on public.vus_posts for all to authenticated
  using (public.can_post_vus(sport)) with check (public.can_post_vus(sport));
grant select on public.vus_posts to anon, authenticated;
grant insert, update, delete on public.vus_posts to authenticated;

create or replace function public.vus_page_stamp()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if tg_table_name = 'vus_posts' then
    if tg_op = 'INSERT' then new.author_email := lower(coalesce(auth.jwt()->>'email','')); new.created_at := now();
    else new.author_email := old.author_email; new.created_at := old.created_at; new.updated_at := now(); end if;
  else
    new.updated_by := lower(coalesce(auth.jwt()->>'email','')); new.updated_at := now();
  end if;
  return new;
end $$;
drop trigger if exists vus_posts_stamp on public.vus_posts;
create trigger vus_posts_stamp before insert or update on public.vus_posts for each row execute function public.vus_page_stamp();
drop trigger if exists vus_pages_stamp on public.vus_pages;
create trigger vus_pages_stamp before insert or update on public.vus_pages for each row execute function public.vus_page_stamp();

-- Who's who on a Valley United homepage: names and roles only (no contact details), anyone can see.
create or replace function public.vus_public_staff(p_sport text)
returns table(first_name text, last_name text, role_type text, division_or_age_group text, coach_gender text,
              event_specialty text, is_president boolean)
language sql stable security definer set search_path to 'public' as $$
  select v.first_name, v.last_name, v.role_type, v.division_or_age_group, v.coach_gender, v.event_specialty,
         (case when p_sport = 'Cross Country' then v.xc_president_season else v.track_president_season end)
           = public.vus_current_season()
    from public.vus_coaches v
   where (v.approved and p_sport = any(coalesce(v.sports, array['Track & Field'])))
      or (case when p_sport = 'Cross Country' then v.xc_president_season else v.track_president_season end)
           = public.vus_current_season()
   order by 7 desc, case v.role_type when 'team_president' then 0 when 'division_head_coach' then 1
                     when 'assistant_coach' then 2 else 3 end, v.last_name, v.first_name
$$;
grant execute on function public.vus_public_staff(text) to anon, authenticated;

-- ---------- 3. open all year ----------
create or replace function public.vus_window(p_season integer)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with s as (select nullif(value,'')::date d from public.app_settings where key = 'vus_request_open_' || p_season)
  select jsonb_build_object(
    'opens', (select d from s),
    'opens_from', case when (select d from s) is not null then 'date' else 'always' end,
    'closes', (select nullif(value,'')::date from public.app_settings where key = 'vus_request_close_' || p_season),
    'relay_deadline_meet', (select nullif(value,'') from public.app_settings where key = 'vus_relay_deadline_meet_' || p_season),
    'relay_deadline_date', (select nullif(value,'')::date from public.app_settings where key = 'vus_relay_deadline_date_' || p_season))
$$;
grant execute on function public.vus_window(integer) to anon, authenticated;

-- ---------- 4. requests: open all year; events may be picked before there's a mark ----------
create or replace function public.vus_request_fill()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; e jsonb; w jsonb; today date := (now() at time zone 'America/Los_Angeles')::date;
  picked text[]; adm boolean := public.is_vus_admin();
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

  -- Valley United Track & Field: open all year unless Settings has an opening date; the closing date still applies.
  e := public.vus_compute(r.id); w := e->'window';
  if not adm then
    if w->>'opens' is not null and today < (w->>'opens')::date then
      raise exception 'Valley United requests open on %.', to_char((w->>'opens')::date, 'FMMonth FMDD, YYYY');
    end if;
    if w->>'closes' is not null and today > (w->>'closes')::date then
      raise exception 'Valley United requests closed on %.', to_char((w->>'closes')::date, 'FMMonth FMDD, YYYY');
    end if;
  end if;
  select coalesce(array_agg(distinct x->>'event_code'), '{}') into picked
    from jsonb_array_elements(coalesce(new.events,'[]'::jsonb)) x where coalesce(x->>'event_code','') <> '';
  if cardinality(picked) = 0 then raise exception 'Please pick at least one individual event.'; end if;
  if new.relay_ok is null and not adm then raise exception 'Please answer whether your athlete is willing to run on relays.'; end if;
  if cardinality(picked) > 3 then raise exception 'Pick up to 3 individual events.'; end if;
  new.sport := 'Track & Field';
  new.qualified := (e->>'qualified')::boolean; new.ran_league_final := (e->>'ran_league_final')::boolean; new.ran_iec := (e->>'ran_iec')::boolean;
  new.placement := e->>'placement'; new.best_marks := e->'bests';
  -- Each pick: the season best if there is one, else "needs a season mark" (Re-check fills it in later).
  new.events := (select jsonb_agg(coalesce(
                    (select b from jsonb_array_elements(coalesce(e->'bests','[]'::jsonb)) b where b->>'event_code' = c limit 1),
                    jsonb_build_object('event_code', c,
                      'event_name', coalesce((select x->>'event_name' from jsonb_array_elements(new.events) x where x->>'event_code' = c limit 1), c),
                      'mark', null, 'needs_mark', true)))
                   from unnest(picked) c);
  return new;
end $$;

commit;
notify pgrst, 'reload schema';
