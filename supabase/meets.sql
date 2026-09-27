-- Meet entries add-on. Run AFTER setup.sql in the same Supabase project.
-- Adds: meets, meet_events, entries. Parents log in with the email they registered with.

create table if not exists public.meets (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text not null,
  meet_date date not null,
  location text,
  entries_close timestamptz not null,       -- parents/coaches can't enter after this
  status text not null default 'open' check (status in ('open','closed','archived')),
  created_by text
);

create table if not exists public.meet_events (
  id uuid primary key default gen_random_uuid(),
  meet_id uuid not null references public.meets(id) on delete cascade,
  code text not null,          -- Hy-Tek event code (100, 80H, LJ, 400 for 4x100...)
  name text not null,
  division text not null,
  gender text not null check (gender in ('Boy','Girl')),
  is_relay boolean not null default false,
  is_field boolean not null default false,
  unique (meet_id, code, division, gender, is_relay)
);

create table if not exists public.entries (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  meet_id uuid not null references public.meets(id) on delete cascade,
  registration_id uuid not null references public.registrations(id) on delete cascade,
  meet_event_id uuid not null references public.meet_events(id) on delete cascade,
  entered_by text not null,
  seed_mark text,                    -- auto-filled from results; write-in allowed only if no result exists
  seed_source text check (seed_source in ('result','writein')),
  unique (registration_id, meet_event_id)
);

-- Parents may read only their own athletes (matched by registration email)
drop policy if exists "parents read own" on public.registrations;
create policy "parents read own" on public.registrations for select to authenticated
  using (lower(email) = lower(coalesce(auth.jwt()->>'email','')));

-- Is this athlete mine (parent) or am I a coach?
create or replace function public.can_manage_athlete(reg uuid) returns boolean
language sql security definer stable as $$
  select public.is_coach() or exists (
    select 1 from public.registrations r where r.id = reg
      and lower(r.email) = lower(coalesce(auth.jwt()->>'email','')));
$$;

-- Server-side rule check: division/gender match, meet open, entry limits.
create or replace function public.check_entry() returns trigger
language plpgsql security definer as $$
declare
  reg record; ev record; m record;
  cnt int; relay_cnt int; maxev int; relay_rule boolean;
begin
  select * into reg from public.registrations where id = new.registration_id;
  select * into ev  from public.meet_events   where id = new.meet_event_id;
  select * into m   from public.meets         where id = new.meet_id;
  if reg is null or ev is null or m is null then raise exception 'Bad entry'; end if;
  if ev.meet_id <> new.meet_id then raise exception 'Event does not belong to this meet'; end if;
  if reg.status <> 'verified' then raise exception 'Athlete is not verified yet'; end if;
  if m.status <> 'open' or now() > m.entries_close then
    if not public.is_coach() then raise exception 'Entries for this meet are closed'; end if;
  end if;
  if ev.division <> reg.division or ev.gender <> reg.gender then
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
end $$;
drop trigger if exists entries_check on public.entries;
create trigger entries_check before insert on public.entries for each row execute function public.check_entry();

alter table public.meets enable row level security;
alter table public.meet_events enable row level security;
alter table public.entries enable row level security;

create policy "anyone logged in reads meets"  on public.meets       for select to authenticated using (true);
create policy "anyone logged in reads events" on public.meet_events for select to authenticated using (true);
create policy "coaches manage meets"  on public.meets       for all to authenticated using (public.is_coach()) with check (public.is_coach());
create policy "coaches manage events" on public.meet_events for all to authenticated using (public.is_coach()) with check (public.is_coach());

create policy "read own or coach"   on public.entries for select to authenticated using (public.can_manage_athlete(registration_id));
create policy "insert own or coach" on public.entries for insert to authenticated with check (public.can_manage_athlete(registration_id) and lower(entered_by) = lower(coalesce(auth.jwt()->>'email','')));
create policy "delete own or coach" on public.entries for delete to authenticated
  using (public.can_manage_athlete(registration_id) and (public.is_coach() or exists (select 1 from public.meets m where m.id = meet_id and m.status = 'open' and now() <= m.entries_close)));

-- ---------------- Results ----------------
create table if not exists public.results (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  meet_id uuid not null references public.meets(id) on delete cascade,
  registration_id uuid references public.registrations(id) on delete set null,  -- null = couldn't match to a registered athlete
  athlete_name text not null,        -- "First Last" or relay team label
  gender text not null check (gender in ('Boy','Girl','Mixed')),
  division text,                     -- our division name, if known
  event_code text not null,          -- Hy-Tek code (100, LJ, 400 relay...)
  event_name text not null,
  is_relay boolean not null default false,
  relay_runners text,                -- "First Last, First Last, ..." for relays
  round text not null default 'F',   -- P/Q/S/F
  mark text not null,                -- as shown, e.g. 14.52 or 3.45 or 12'10.25
  mark_value numeric,                -- seconds for running, metres for field (for ranking)
  is_time boolean not null default true,
  place int,
  wind text,
  source text not null default 'hytek',
  entered_by text
);
alter table public.results enable row level security;
create policy "logged in read results" on public.results for select to authenticated using (true);
create policy "coaches manage results" on public.results for all to authenticated using (public.is_coach()) with check (public.is_coach());
-- Season rankings: best mark per athlete per event/division/gender
create or replace view public.season_best as
  select distinct on (r.event_code, r.is_relay, coalesce(r.division,''), r.gender, coalesce(r.registration_id::text, r.athlete_name))
    r.*, m.name as meet_name, m.meet_date
  from public.results r join public.meets m on m.id = r.meet_id
  where r.mark_value is not null
  order by r.event_code, r.is_relay, coalesce(r.division,''), r.gender, coalesce(r.registration_id::text, r.athlete_name),
           case when r.is_time then r.mark_value else -r.mark_value end asc;

-- Seed lock: if the athlete has a recorded result for this event, the seed is ALWAYS that best mark and can't be overwritten.
create or replace function public.seed_lock() returns trigger
language plpgsql security definer as $$
declare ev record; best text;
begin
  select * into ev from public.meet_events where id = new.meet_event_id;
  if ev.is_relay then new.seed_mark := null; new.seed_source := null; return new; end if;
  select sb.mark into best from public.season_best sb
    where sb.registration_id = new.registration_id and sb.event_code = ev.code and sb.is_relay = false limit 1;
  if best is not null then
    new.seed_mark := best; new.seed_source := 'result';
  elsif new.seed_mark is not null and btrim(new.seed_mark) <> '' then
    new.seed_source := 'writein';
  else
    new.seed_mark := null; new.seed_source := null;
  end if;
  return new;
end $$;
drop trigger if exists entries_seed on public.entries;
create trigger entries_seed before insert or update on public.entries for each row execute function public.seed_lock();
create policy "update own or coach" on public.entries for update to authenticated
  using (public.can_manage_athlete(registration_id)) with check (public.can_manage_athlete(registration_id));
