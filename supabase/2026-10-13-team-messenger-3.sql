-- Team Messenger follow-up 3 (2026-10-13): parents can ALWAYS go back and read past messages.
-- Before: when a team admin closed a group or a direct message, it vanished for the parents.
-- Now: a closed chat stays on the parent's dashboard as read-only history (nobody can post in it any more).

-- What is this person in this group?  'admin' | 'coach_post' | 'coach_read' | 'parent' | null (not in it)
create or replace function public.msg_role_for(ch public.msg_channels, p_email text) returns text
language plpgsql stable security definer set search_path to 'public' as $$
declare c public.coaches; d public.msg_dm; perm boolean;
begin
  if coalesce(p_email,'') = '' or ch.id is null or not public.msg_enabled(ch.team_code) then return null; end if;
  -- team admins of this team, and league site admins, are in everything
  if exists (select 1 from public.coaches x where lower(x.email) = p_email and x.approved is true
             and (x.is_admin is true or (x.team_admin is true and x.team_code = ch.team_code))) then return 'admin'; end if;
  select * into c from public.coaches x where lower(x.email) = p_email and x.approved is true
    and x.role_type is distinct from 'timer' and x.team_code = ch.team_code limit 1;
  perm := c.email is not null and exists (select 1 from public.msg_coach_access a where a.team_code = ch.team_code and lower(a.email) = p_email and a.can_post);
  if ch.audience = 'direct' then
    select * into d from public.msg_dm where channel_id = ch.id;
    if d.coach_email = p_email and c.email is not null then return case when perm then 'coach_post' else 'coach_read' end; end if;
    if d.parent_email = p_email then return 'parent'; end if;
    return null;
  end if;
  if c.email is not null then
    if ch.audience = 'coaches' then return 'coach_post'; end if;
    if ch.audience = 'team' then return case when perm and public.msg_coach_covers_team(c) then 'coach_post' else 'coach_read' end; end if;
    if exists (select 1 from unnest(ch.divisions) dv, unnest(coalesce(ch.genders, array['Boy','Girl'])) g where public.msg_coach_covers(c, dv, g)) then
      return case when perm then 'coach_post' else 'coach_read' end; end if;
  end if;
  if public.msg_parent_in(ch, p_email) then return 'parent'; end if;
  return null;
end $$;
revoke all on function public.msg_role_for(public.msg_channels, text) from public, anon, authenticated;
