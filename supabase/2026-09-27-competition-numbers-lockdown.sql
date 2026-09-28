-- 2026-09-27: only site admins can rebuild number blocks; the internal numbering functions can't be called directly.
begin;

alter function public.build_comp_blocks(integer,integer,integer,integer) rename to _build_comp_blocks;
revoke all on function public._build_comp_blocks(integer,integer,integer,integer) from public, anon, authenticated;

create or replace function public.build_comp_blocks(p_season integer)
returns integer language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_site_admin() then raise exception 'Only a site admin can rebuild competition-number blocks.'; end if;
  return public._build_comp_blocks(p_season);
end $$;
revoke all on function public.build_comp_blocks(integer) from public, anon;
grant execute on function public.build_comp_blocks(integer) to authenticated;

create or replace function public.next_comp_number(p_team text, p_season integer) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare b record; n integer; top integer;
begin
  if not exists (select 1 from public.comp_blocks where season_year = p_season) then perform public._build_comp_blocks(p_season); end if;
  select * into b from public.comp_blocks where season_year = p_season and team_code = p_team;
  if b.team_code is not null then
    select g into n from generate_series(b.start_no, b.end_no) g
     where not exists (select 1 from public.registrations r where r.season_year = p_season and r.comp_number = g)
     order by g limit 1;
    if n is not null then return n; end if;
  end if;
  select coalesce(max(end_no), 99) + 21 into top from public.comp_blocks where season_year = p_season;
  select g into n from generate_series(top, top + 5000) g
   where not exists (select 1 from public.registrations r where r.season_year = p_season and r.comp_number = g)
   order by g limit 1;
  return n;
end $$;
revoke all on function public.next_comp_number(text,integer) from public, anon, authenticated;

commit;
