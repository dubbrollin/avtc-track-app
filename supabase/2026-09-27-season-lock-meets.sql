-- 2026-09-27: meets belong to a season; last season is read-only history.
--   * meets.season_year: every existing meet = 2026. New meets get the current season (app_settings.season_year).
--   * Anything tied to a PAST-season meet (the meet itself, its events, entries and results) can't be added,
--     changed or deleted by anyone using the app — site admins included. Results stay visible on the Results page.
--   * Direct database maintenance (postgres role) is still allowed, for emergencies only.
begin;

alter table public.meets add column if not exists season_year integer;
update public.meets set season_year = 2026 where season_year is null;

create or replace function public.current_season() returns integer
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select nullif(value,'')::int from public.app_settings where key = 'season_year'), extract(year from now())::int)
$$;

create or replace function public.meet_is_locked(p_meet uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.meets m where m.id = p_meet and coalesce(m.season_year, 0) < public.current_season())
$$;

create or replace function public.season_lock_guard() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare mid uuid;
begin
  if session_user in ('postgres','supabase_admin') and current_setting('request.jwt.claims', true) is null then
    return coalesce(new, old); -- direct database maintenance only
  end if;
  if tg_table_name = 'meets' then
    if tg_op = 'INSERT' then
      if new.season_year is null then new.season_year := public.current_season(); end if;
      if new.season_year < public.current_season() then raise exception 'Meets can only be created for the current season.'; end if;
      return new;
    end if;
    if coalesce(old.season_year,0) < public.current_season() then
      raise exception 'This is a past-season meet. Last season''s meets and results are locked and can''t be changed.';
    end if;
    if tg_op = 'UPDATE' and new.season_year is distinct from old.season_year then
      raise exception 'A meet''s season can''t be changed.';
    end if;
    return coalesce(new, old);
  end if;
  mid := coalesce(new.meet_id, old.meet_id);
  if public.meet_is_locked(mid) or (tg_op = 'UPDATE' and public.meet_is_locked(old.meet_id)) then
    raise exception 'This belongs to a past-season meet. Last season''s meets and results are locked and can''t be changed.';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists season_lock_meets on public.meets;
create trigger season_lock_meets before insert or update or delete on public.meets
  for each row execute function public.season_lock_guard();
drop trigger if exists season_lock_events on public.meet_events;
create trigger season_lock_events before insert or update or delete on public.meet_events
  for each row execute function public.season_lock_guard();
drop trigger if exists season_lock_entries on public.entries;
create trigger season_lock_entries before insert or update or delete on public.entries
  for each row execute function public.season_lock_guard();
drop trigger if exists season_lock_results on public.results;
create trigger season_lock_results before insert or update or delete on public.results
  for each row execute function public.season_lock_guard();

commit;
