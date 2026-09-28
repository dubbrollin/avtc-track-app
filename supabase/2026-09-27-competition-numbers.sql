-- 2026-09-27: competition (bib) numbers in team blocks.
--   * Blocks per season, teams in alphabetical order by team NAME, first block starts at 100.
--   * Block size = the team's certified (verified) athletes LAST season, plus a 20-number cushion; the next team
--     starts right after. Teams with no athletes last season get a starting size of 20 (+20 cushion).
--   * Each new registration gets the lowest open number in its team's block. If a team fills its block and
--     cushion, extra athletes get numbers from an overflow range after the last block (never another team's).
begin;

alter table public.registrations add column if not exists comp_number integer;
create unique index if not exists registrations_season_comp_number on public.registrations (season_year, comp_number) where comp_number is not null;

create table if not exists public.comp_blocks (
  season_year integer not null,
  team_code text not null,
  sort_order integer not null,
  last_season_count integer not null,
  start_no integer not null,
  end_no integer not null,      -- includes the 20-number cushion
  primary key (season_year, team_code)
);
alter table public.comp_blocks enable row level security;
drop policy if exists "anyone reads comp blocks" on public.comp_blocks;
create policy "anyone reads comp blocks" on public.comp_blocks for select to anon, authenticated using (true);
drop policy if exists "site admin all" on public.comp_blocks;
create policy "site admin all" on public.comp_blocks for all to authenticated using (public.is_site_admin()) with check (public.is_site_admin());

-- (Re)build a season's blocks from last season's certified counts. Safe to re-run before numbers are handed out.
create or replace function public.build_comp_blocks(p_season integer, p_start integer default 100, p_cushion integer default 20, p_min integer default 20)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare t record; nxt integer := p_start; n integer; i integer := 0;
begin
  delete from public.comp_blocks where season_year = p_season;
  for t in select lt.code, lt.name from public.league_teams lt where lt.active order by lt.name loop
    i := i + 1;
    select count(*) into n from public.registrations r where r.team_code = t.code and r.season_year = p_season - 1 and r.status = 'verified';
    insert into public.comp_blocks values (p_season, t.code, i, n, nxt, nxt + greatest(n, p_min) + p_cushion - 1);
    nxt := nxt + greatest(n, p_min) + p_cushion;
  end loop;
  return i;
end $$;

create or replace function public.next_comp_number(p_team text, p_season integer) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare b record; n integer; top integer;
begin
  if not exists (select 1 from public.comp_blocks where season_year = p_season) then perform public.build_comp_blocks(p_season); end if;
  select * into b from public.comp_blocks where season_year = p_season and team_code = p_team;
  if b.team_code is not null then
    select g into n from generate_series(b.start_no, b.end_no) g
     where not exists (select 1 from public.registrations r where r.season_year = p_season and r.comp_number = g)
     order by g limit 1;
    if n is not null then return n; end if;
  end if;
  -- Overflow: after the last block, plus the cushion.
  select coalesce(max(end_no), 99) + 21 into top from public.comp_blocks where season_year = p_season;
  select g into n from generate_series(top, top + 5000) g
   where not exists (select 1 from public.registrations r where r.season_year = p_season and r.comp_number = g)
   order by g limit 1;
  return n;
end $$;

create or replace function public.reg_assign_comp_number() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.comp_number is null and new.team_code is not null and new.season_year >= public.current_season() then
    perform pg_advisory_xact_lock(hashtext('comp_number_' || new.season_year));
    new.comp_number := public.next_comp_number(new.team_code, new.season_year);
  end if;
  return new;
end $$;
drop trigger if exists reg_comp_number_trg on public.registrations;
create trigger reg_comp_number_trg before insert on public.registrations
  for each row execute function public.reg_assign_comp_number();

-- 2027 blocks now, and numbers for any 2027 registrations already in.
select public.build_comp_blocks(2027);
do $$ declare r record; begin
  for r in select id, team_code, season_year from public.registrations where season_year = 2027 and comp_number is null order by created_at loop
    perform pg_advisory_xact_lock(hashtext('comp_number_2027'));
    update public.registrations set comp_number = public.next_comp_number(r.team_code, 2027) where id = r.id;
  end loop;
end $$;

commit;
