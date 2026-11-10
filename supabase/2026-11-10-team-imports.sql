-- Team imports of already-registered athletes (2026-11-10).
--   Some teams registered athletes somewhere else (Team Manager, another app) before the app. A team admin imports
--   that list; each athlete waits in reg_imports ("waiting for parent") — NOT in registrations, so the roster never
--   holds placeholder addresses or fake signatures. Each family gets one short link code.
--   The parent connects either automatically (the imported parent email = their sign-in email) or by entering the
--   code + the athlete's birthday. Then they finish a short confirm-and-sign version of the registration form
--   (everything the team sent is filled in). That insert is an ordinary registration with import_id set, so comp
--   numbers, fees, transfer checks, proof-of-birth rules and certification all work as usual.
--   On-time rule (Riley 2026-11-10): an athlete the team imported on or before the certification date counts as on
--   time even if the parent finishes later — reg_late_check uses the import date.
begin;

create table if not exists public.reg_imports (
  id uuid primary key default gen_random_uuid(),
  season_year integer not null,
  team_code text not null,
  family_code text not null,
  first_name text not null,
  last_name text not null,
  gender text check (gender in ('Boy','Girl')),
  dob date,
  guardian_name text,
  guardian_email text,
  guardian_phone text,
  address text, city text, zip text,
  source text,                                         -- 'Team Manager' / 'CSV' / file name
  imported_at timestamptz not null default now(),
  imported_by text not null default lower(coalesce(auth.jwt()->>'email','')),
  status text not null default 'waiting' check (status in ('waiting','completed','removed')),
  claimed_email text,                                  -- set when a parent links with the family code
  claimed_at timestamptz,
  registration_id uuid references public.registrations(id) on delete set null,
  completed_at timestamptz
);
create index if not exists reg_imports_team_idx on public.reg_imports (team_code, season_year, status);
create index if not exists reg_imports_code_idx on public.reg_imports (family_code) where status = 'waiting';
create index if not exists reg_imports_email_idx on public.reg_imports (lower(guardian_email)) where status = 'waiting';

alter table public.registrations add column if not exists import_id uuid references public.reg_imports(id) on delete set null;

alter table public.reg_imports enable row level security;
-- Team admins see their own team's list; site admins see all. Parents never read the table directly (my_imports()).
drop policy if exists "team admins read imports" on public.reg_imports;
create policy "team admins read imports" on public.reg_imports for select to authenticated
  using (public.is_site_admin() or public.is_team_admin_of(team_code));
revoke all on public.reg_imports from anon;
revoke all on public.reg_imports from authenticated;
grant select on public.reg_imports to authenticated;   -- every change goes through the functions below

create or replace function public.import_me() returns text
language sql stable as $$ select lower(coalesce(auth.jwt()->>'email','')) $$;

-- A short code that's easy to read out or text: no 0/O, 1/I/L.
create or replace function public.import_new_code() returns text
language plpgsql volatile as $$
declare a text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; b bytea; c text; i int;
begin
  loop
    b := decode(md5(gen_random_uuid()::text || clock_timestamp()::text), 'hex'); c := '';
    for i in 0..5 loop c := c || substr(a, 1 + (get_byte(b, i) % length(a)), 1); end loop;
    exit when not exists (select 1 from public.reg_imports where family_code = c and status = 'waiting');
  end loop;
  return c;
end $$;

-- Import a list for one team. p_rows: [{first_name,last_name,gender,dob,guardian_name,guardian_email,guardian_phone,
-- address,city,zip,family_key}] — family_key groups siblings (the page uses parent email, else phone).
-- Skips athletes already registered on the team this season, or already waiting. Returns {added, skipped:[names]}.
create or replace function public.import_athletes(p_team text, p_rows jsonb, p_source text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s integer := public.current_season(); r jsonb; fam jsonb := '{}'::jsonb; k text; code text;
  added int := 0; skipped jsonb := '[]'::jsonb; fn text; ln text; d date; em text;
begin
  if not (public.is_site_admin() or public.is_team_admin_of(p_team)) then
    raise exception 'Only this team''s team admin can import its athletes.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'Nothing to import.'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    fn := nullif(trim(r->>'first_name'),''); ln := nullif(trim(r->>'last_name'),'');
    d := nullif(r->>'dob','')::date; em := lower(nullif(trim(r->>'guardian_email'),''));
    if fn is null or ln is null then skipped := skipped || to_jsonb(coalesce(fn,'')||' '||coalesce(ln,'')||' (no name)'); continue; end if;
    if exists (select 1 from public.registrations g where g.team_code = p_team and g.season_year = s and g.status is distinct from 'rejected'
                and public.name_key(g.first_name) = public.name_key(fn) and public.name_key(g.last_name) = public.name_key(ln)
                and (d is null or g.dob = d))
       or exists (select 1 from public.reg_imports x where x.team_code = p_team and x.season_year = s and x.status = 'waiting'
                and public.name_key(x.first_name) = public.name_key(fn) and public.name_key(x.last_name) = public.name_key(ln)
                and (d is null or x.dob is null or x.dob = d)) then
      skipped := skipped || to_jsonb(fn||' '||ln||' (already registered or already imported)'); continue;
    end if;
    k := coalesce(nullif(r->>'family_key',''), gen_random_uuid()::text);
    code := fam->>k;
    if code is null and em is not null then   -- a sibling imported earlier with the same parent email shares that code
      select x.family_code into code from public.reg_imports x
       where x.team_code = p_team and x.season_year = s and x.status = 'waiting' and lower(x.guardian_email) = em limit 1;
    end if;
    if code is null then code := public.import_new_code(); end if;
    fam := fam || jsonb_build_object(k, code);
    insert into public.reg_imports (season_year, team_code, family_code, first_name, last_name, gender, dob,
                                    guardian_name, guardian_email, guardian_phone, address, city, zip, source)
    values (s, p_team, code, fn, ln, case when r->>'gender' in ('Boy','Girl') then r->>'gender' end, d,
            nullif(trim(r->>'guardian_name'),''), em, nullif(trim(r->>'guardian_phone'),''),
            nullif(trim(r->>'address'),''), nullif(trim(r->>'city'),''), nullif(trim(r->>'zip'),''), p_source);
    added := added + 1;
  end loop;
  return jsonb_build_object('added', added, 'skipped', skipped);
end $$;

-- Team admin takes a row off the list (wrong person, left the team...).
create or replace function public.import_remove(p_id uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare t text;
begin
  select team_code into t from public.reg_imports where id = p_id and status = 'waiting';
  if t is null then raise exception 'That athlete isn''t waiting any more.'; end if;
  if not (public.is_site_admin() or public.is_team_admin_of(t)) then raise exception 'Only this team''s team admin can do that.'; end if;
  update public.reg_imports set status = 'removed' where id = p_id;
end $$;

-- Team admin fixes the parent email on a waiting row (so that parent links automatically when they sign in).
create or replace function public.import_set_email(p_id uuid, p_email text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare t text;
begin
  select team_code into t from public.reg_imports where id = p_id and status = 'waiting';
  if t is null then raise exception 'That athlete isn''t waiting any more.'; end if;
  if not (public.is_site_admin() or public.is_team_admin_of(t)) then raise exception 'Only this team''s team admin can do that.'; end if;
  update public.reg_imports set guardian_email = lower(nullif(trim(p_email),'')) where id = p_id;
end $$;

-- Parent links their family with the code from the team + one of the athletes' birthdays. Returns how many athletes.
create or replace function public.claim_import(p_code text, p_dob date) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.import_me(); c text := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g')); n int;
begin
  if me = '' then raise exception 'Please sign in first.'; end if;
  if not exists (select 1 from public.reg_imports where family_code = c and status = 'waiting' and dob = p_dob) then
    raise exception 'That code and birthday don''t match an athlete waiting to be registered. Check the code from your team and the athlete''s date of birth.';
  end if;
  update public.reg_imports set claimed_email = me, claimed_at = now() where family_code = c and status = 'waiting';
  get diagnostics n = row_count;
  return n;
end $$;

-- The signed-in parent's athletes waiting to be finished (imported with their email, or linked with a code).
create or replace function public.my_imports()
returns table(id uuid, team_code text, first_name text, last_name text, gender text, dob date, guardian_name text,
              guardian_phone text, address text, city text, zip text, season_year integer)
language sql stable security definer set search_path to 'public' as $$
  select x.id, x.team_code, x.first_name, x.last_name, x.gender, x.dob, x.guardian_name, x.guardian_phone, x.address, x.city, x.zip, x.season_year
  from public.reg_imports x
  where x.status = 'waiting' and public.import_me() <> ''
    and (lower(x.guardian_email) = public.import_me() or x.claimed_email = public.import_me())
  order by x.last_name, x.first_name
$$;

-- A registration that finishes an import: only the linked parent can finish it, and it stays on the importing team.
create or replace function public.reg_import_guard() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare x record; me text := public.import_me();
begin
  if new.import_id is null then return new; end if;
  select * into x from public.reg_imports where id = new.import_id;
  if x.id is null or x.status <> 'waiting' then raise exception 'This athlete''s registration was already finished (or removed by the team).'; end if;
  if me = '' or not (lower(coalesce(x.guardian_email,'')) = me or coalesce(x.claimed_email,'') = me) then
    raise exception 'Please sign in with the email your team has on file, or link your athlete with the code from your team.';
  end if;
  new.team_code := x.team_code; new.season_year := x.season_year; new.email := me;
  return new;
end $$;
-- Named reg_a_... so it runs FIRST among the before-insert triggers (Postgres runs them alphabetically): team and season
-- are fixed before comp numbers, late checks and proof-of-birth checks look at them.
drop trigger if exists reg_import_guard_trg on public.registrations;
drop trigger if exists reg_a_import_guard_trg on public.registrations;
create trigger reg_a_import_guard_trg before insert on public.registrations for each row execute function public.reg_import_guard();

create or replace function public.reg_import_done() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.import_id is not null then
    update public.reg_imports set status = 'completed', registration_id = new.id, completed_at = now() where id = new.import_id;
  end if;
  return null;
end $$;
drop trigger if exists reg_import_done_trg on public.registrations;
create trigger reg_import_done_trg after insert on public.registrations for each row execute function public.reg_import_done();

-- Late registration: same rule as 2026-09-27-conference-president-certification.sql, except an imported athlete is
-- judged by the day the TEAM imported them (Riley 2026-11-10).
create or replace function public.reg_late_check()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare s integer := coalesce(new.season_year, public.current_season());
  cd date := public.certification_date(coalesce(new.season_year, public.current_season()));
  cutoff date; today date := (now() at time zone 'America/Los_Angeles')::date; p record; idate date;
begin
  new.late_pass_id := null;
  if new.import_id is not null then
    select (imported_at at time zone 'America/Los_Angeles')::date into idate from public.reg_imports where id = new.import_id;
    if idate is not null and idate < today then today := idate; end if;
  end if;
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

revoke all on function public.import_athletes(text, jsonb, text) from public, anon;
revoke all on function public.import_remove(uuid) from public, anon;
revoke all on function public.import_set_email(uuid, text) from public, anon;
revoke all on function public.claim_import(text, date) from public, anon;
revoke all on function public.my_imports() from public, anon;
grant execute on function public.import_athletes(text, jsonb, text) to authenticated;
grant execute on function public.import_remove(uuid) to authenticated;
grant execute on function public.import_set_email(uuid, text) to authenticated;
grant execute on function public.claim_import(text, date) to authenticated;
grant execute on function public.my_imports() to authenticated;

commit;
notify pgrst, 'reload schema';
