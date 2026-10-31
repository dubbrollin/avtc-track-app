-- 2026-10-30: the standard event list (which events each division runs, copied from Team Manager) moves from the
-- app's code (events.js) into the database, so site admins can edit it on Site Admin > League Setup > Event list.
-- events.js keeps the built-in list as a fallback for when the database can't be reached; otherwise this table wins.
-- Same security as league_teams: anyone can read it, only site admins can change it.
begin;

create table if not exists public.standard_events (
  id         uuid primary key default gen_random_uuid(),
  code       text not null,                      -- Hy-Tek event code (100, 80H, LJ, SP ...). Relays use the total distance (400 = 4x100).
  name       text not null,                      -- what people see: "100m Dash", "4x100m Relay"
  divs       text not null default '',           -- which divisions run it, space-separated keys: SG G B J Y I
  is_relay   boolean not null default false,
  is_field   boolean not null default false,     -- field events are measured (higher is better); everything else is timed
  gender     text check (gender in ('Boy','Girl')),  -- null = both boys and girls
  note       text,                               -- hurdle height, implement weight, etc. (shown to admins only)
  active     boolean not null default true,      -- untick instead of deleting to hide an event
  sort_order integer not null default 100,
  created_at timestamptz not null default now()
);
create unique index if not exists standard_events_key on public.standard_events (code, is_relay, coalesce(gender, ''));

alter table public.standard_events enable row level security;
drop policy if exists "public read standard_events" on public.standard_events;
create policy "public read standard_events" on public.standard_events for select to anon, authenticated using (true);
drop policy if exists "site admin all" on public.standard_events;
create policy "site admin all" on public.standard_events for all to authenticated
  using (public.is_site_admin()) with check (public.is_site_admin());

-- Look-around (demo) logins are view-only everywhere, this table included.
drop trigger if exists zz_demo_readonly on public.standard_events;
create trigger zz_demo_readonly before insert or update or delete on public.standard_events
  for each row execute function public.demo_readonly();

-- Seed with the list that was in events.js (Riley's Hy-Tek Team Manager Event List export, 2026-09-23). Only when empty.
insert into public.standard_events (sort_order, code, name, divs, is_relay, is_field, gender, note)
select * from (values
  (10,  '100',  '100m Dash',     'SG G B J Y I', false, false, null,   null),
  (20,  '200',  '200m Dash',     'SG G B J Y I', false, false, null,   null),
  (30,  '400',  '400m Dash',     'SG G B J Y I', false, false, null,   null),
  (40,  '800',  '800m Run',      'SG G B J Y I', false, false, null,   null),
  (50,  '1500', '1500m Run',     'G B J Y I',    false, false, null,   null),
  (60,  '3000', '3000m Run',     'J Y I',        false, false, null,   null),
  (70,  '80H',  '80m Hurdles',   'J',            false, false, null,   '30" hurdles'),
  (80,  '100H', '100m Hurdles',  'Y I',          false, false, 'Girl', 'Youth 30", Intermediates 33"'),
  (90,  '100H', '100m Hurdles',  'Y',            false, false, 'Boy',  '36" hurdles'),
  (100, '110H', '110m Hurdles',  'I',            false, false, 'Boy',  '39" hurdles'),
  (110, '400',  '4x100m Relay',  'SG G B J Y I', true,  false, null,   null),
  (120, '1600', '4x400m Relay',  'G B J Y I',    true,  false, null,   null),
  (130, 'LJ',   'Long Jump',     'SG G B J Y I', false, true,  null,   null),
  (140, 'HJ',   'High Jump',     'B J Y I',      false, true,  null,   null),
  (150, 'SP',   'Shot Put',      'B J Y I',      false, true,  null,   '6lb (Bantam/Juniors); 4kg or 10lb by gender (Youth/Intermediates)'),
  (160, 'JT',   'Javelin Throw', 'G B J Y I',    false, true,  null,   '300g (Gremlin/Bantam), 450g (Juniors), 600g (Youth/Intermediates)')
) as v(sort_order, code, name, divs, is_relay, is_field, gender, note)
where not exists (select 1 from public.standard_events);

commit;
