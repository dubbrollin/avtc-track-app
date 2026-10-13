-- Team Messenger follow-up (2026-10-13), found while checking the install:
-- 1. Two internal helper functions could be called directly by anyone to ask "is this email a parent/coach on that
--    team?". They are only needed inside the other messenger functions, so direct calls are now blocked.
-- 2. Nobody who isn't signed in needs any messenger function — block those too (they already refused, this is belt and braces).
-- 3. "Every chat must have a team admin": a site admin who belongs to that team counts as its team admin
--    (the People & Access dropdown makes someone EITHER team admin OR site admin, so a team run by a site admin
--    otherwise looked like it had no admin).

revoke all on function public.msg_role_for(public.msg_channels, text) from public, anon, authenticated;
revoke all on function public.msg_parent_in(public.msg_channels, text) from public, anon, authenticated;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'msg\_%' loop
    execute format('revoke all on function %s from anon', f.sig);
  end loop;
end $$;

create or replace function public.msg_has_team_admin(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.coaches c where c.team_code = t and c.approved is true and (c.team_admin is true or c.is_admin is true))
$$;
revoke all on function public.msg_has_team_admin(text) from anon;
