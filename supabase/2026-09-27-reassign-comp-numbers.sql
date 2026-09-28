-- 2026-09-27: "Reassign numbers from the certified roster" (site admins, run once certification is done).
--   * Blocks are rebuilt from THIS season's roster: each team's size = its athletes now (verified + still under
--     review; rejected excluded), + 20-number cushion. Teams alphabetical by name, starting at 100.
--   * Within each team, athletes are renumbered alphabetically (last name, first name): certified (verified)
--     athletes first, then any still under review. Rejected registrations get no number.
--   * Later registrations keep getting the next open number in their team's (new) cushion.
begin;

alter table public.comp_blocks add column if not exists basis text not null default 'last season';

create or replace function public.reassign_comp_numbers(p_season integer, p_start integer default 100, p_cushion integer default 20)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare t record; nxt integer := p_start; n integer; i integer := 0; done integer := 0;
begin
  if not public.is_site_admin() then raise exception 'Only a site admin can reassign competition numbers.'; end if;
  perform pg_advisory_xact_lock(hashtext('comp_number_' || p_season));
  update public.registrations set comp_number = null where season_year = p_season and comp_number is not null;
  delete from public.comp_blocks where season_year = p_season;
  for t in select lt.code from public.league_teams lt where lt.active order by lt.name loop
    i := i + 1;
    select count(*) into n from public.registrations r
     where r.team_code = t.code and r.season_year = p_season and r.status <> 'rejected';
    insert into public.comp_blocks (season_year, team_code, sort_order, last_season_count, start_no, end_no, basis)
    values (p_season, t.code, i, n, nxt, nxt + n + p_cushion - 1, 'certified roster');
    update public.registrations r set comp_number = x.num
      from (select r2.id, nxt - 1 + row_number() over (order by (r2.status = 'verified') desc, lower(r2.last_name), lower(r2.first_name), r2.created_at) num
              from public.registrations r2
             where r2.team_code = t.code and r2.season_year = p_season and r2.status <> 'rejected') x
     where r.id = x.id;
    get diagnostics n = row_count; done := done + n;
    nxt := nxt + (select count(*) from public.registrations r3 where r3.team_code = t.code and r3.season_year = p_season and r3.status <> 'rejected') + p_cushion;
  end loop;
  return done;
end $$;
revoke all on function public.reassign_comp_numbers(integer,integer,integer) from public, anon;
grant execute on function public.reassign_comp_numbers(integer,integer,integer) to authenticated;

commit;
