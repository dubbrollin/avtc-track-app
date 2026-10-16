-- ============================================================================
-- Season schedule & calendar (2026-10-16)
-- Each scheduled meet is a normal row in public.meets (so entries and results hang off it) with:
--   week_no         Week 1..6 of the regular season (null = Open / League / IEC / other meets)
--   host_team_code  the hosting team; team_codes = host + visiting teams (empty = every team)
--   venue           the school / field name; location stays the street address (opens in Google Maps)
-- A week can have several meets at different schools: one row per host site.
-- league_teams gets each team's home field (venue + address) so picking a host fills the location.
-- season_dates holds the non-meet key dates (first practice, certification, ...).
-- Seeds the 2027 season proposal. Safe to run twice.
-- ============================================================================
begin;

alter table public.meets add column if not exists week_no int;
alter table public.meets add column if not exists host_team_code text;
alter table public.meets add column if not exists venue text;
-- the Results/Schedule pages are public: open the new columns to anon (column grants, like the others)
grant select (week_no, host_team_code, venue) on public.meets to anon;

alter table public.league_teams add column if not exists home_venue text;
alter table public.league_teams add column if not exists home_address text;

create table if not exists public.season_dates (
  id uuid primary key default gen_random_uuid(),
  season_year int not null,
  event_date date not null,
  label text not null,
  note text,
  created_at timestamptz not null default now()
);
alter table public.season_dates enable row level security;
drop policy if exists "public read season_dates" on public.season_dates;
create policy "public read season_dates" on public.season_dates for select to anon, authenticated using (true);
drop policy if exists "site admin all" on public.season_dates;
create policy "site admin all" on public.season_dates for all to authenticated using (public.is_site_admin()) with check (public.is_site_admin());
grant select on public.season_dates to anon, authenticated;
grant insert, update, delete on public.season_dates to authenticated;

-- ---------- 2027 key dates ----------
insert into public.season_dates (season_year, event_date, label)
select 2027, d::date, l from (values ('2027-02-06','First day of practice'), ('2027-03-13','Certification')) v(d,l)
where not exists (select 1 from public.season_dates s where s.season_year = 2027 and s.label = v.l);

-- ---------- 2027 meets: Weeks 1-6, then Open, League, IEC ----------
-- Host, visiting teams and addresses are filled in on Site Admin > Schedule.
-- Entries close the Thursday before at 8:00 PM Pacific (same as the "are you coming?" deadline).
insert into public.meets (name, meet_date, season_year, week_no, location, entries_close, status, is_championship, created_by)
select v.name, v.d::date, 2027, v.wk, v.loc,
       ((v.d::date - 2)::timestamp + time '20:00') at time zone 'America/Los_Angeles', 'open', v.champ, 'season schedule'
from (values
  ('Week 1', '2027-03-20', 1, null, false),
  ('Week 2', '2027-03-27', 2, null, false),
  ('Week 3', '2027-04-03', 3, null, false),
  ('Week 4', '2027-04-10', 4, null, false),
  ('Week 5', '2027-04-17', 5, null, false),
  ('Week 6', '2027-04-24', 6, null, false),
  ('VYC Open', '2027-05-01', null, null, false),
  ('League Championships', '2027-05-08', null, null, true),
  ('IEC Championships', '2027-05-15', null, 'Santa Barbara, CA', true)
) v(name, d, wk, loc, champ)
where not exists (select 1 from public.meets m where m.season_year = 2027 and m.meet_date = v.d::date and m.created_by = 'season schedule');

commit;
