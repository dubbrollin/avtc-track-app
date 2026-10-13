-- ============================================================================
-- Team Messenger (2026-10-13) — a PAID team extra
-- Each team gets message groups for its coaches and parents: the whole team, one or more divisions (age groups),
-- optionally boys or girls only, coaches only, or a one-to-one direct message between a coach and one parent.
-- A group is either "announcements" (only coaches post) or a two-way chat (parents can reply).
-- Messages can carry photos and files (private storage bucket "team-messages").
--
-- Paywall: nothing works for a team until a site admin switches the add-on on for it (team_messaging.enabled).
-- When billing is built, the subscription flips that same switch.
--
-- The rules (Riley, 2026-10-13):
--   * A TEAM ADMIN IS IN EVERY CHAT. The team's team admins (and league site admins) can read and post in every
--     group and every direct message on their team, and nobody can make a group or a direct message on a team
--     that has no team admin.
--   * COACHES post only when a team admin has given them permission (msg_coach_access), and only to parents in the
--     divisions (and boys/girls) they are signed up to coach. A Head Coach's divisions are the whole team.
--     Without permission a coach can still read their divisions' groups. Every coach can use "Coaches only".
--   * PARENTS are in a group when their signed-in email matches a registration on that team, this season, that the
--     team has reviewed or certified, in one of the group's divisions. They can reply in two-way chats and in
--     direct messages.
-- Who is in a group is worked out live, never stored. Nobody's email address is shown to other members.
-- All writes go through the functions below; the tables themselves are read-only to the app.
-- ============================================================================

-- ---------- the paid switch, per team ----------
create table if not exists public.team_messaging (
  team_code text primary key,
  enabled boolean not null default false,
  updated_at timestamptz not null default now(), updated_by text);
alter table public.team_messaging enable row level security;
drop policy if exists "team messaging read" on public.team_messaging;
create policy "team messaging read" on public.team_messaging for select using (true);

-- ---------- groups ----------
create table if not exists public.msg_channels (
  id uuid primary key default gen_random_uuid(),
  team_code text not null,
  season_year integer not null,
  name text not null,
  audience text not null default 'team' check (audience in ('team','divisions','coaches','direct')),
  divisions text[],                       -- audience 'divisions': which divisions (age groups)
  genders text[],                         -- null = everyone; else {'Boy'} or {'Girl'}
  mode text not null default 'announce' check (mode in ('announce','chat')),   -- announce = only coaches post
  archived boolean not null default false,
  created_by text, created_at timestamptz not null default now(),
  last_message_at timestamptz);
create index if not exists msg_channels_team_idx on public.msg_channels (team_code, season_year);

-- ---------- who a direct message is between (kept apart from the group so emails stay private) ----------
create table if not exists public.msg_dm (
  channel_id uuid primary key references public.msg_channels(id) on delete cascade,
  team_code text not null,
  coach_email text not null, coach_name text not null,
  parent_email text not null, parent_name text not null, athlete_names text,
  registration_id uuid,
  unique (team_code, coach_email, parent_email));
alter table public.msg_dm enable row level security;   -- no policies: only the functions below read it

-- ---------- which coaches a team admin has allowed to message parents ----------
create table if not exists public.msg_coach_access (
  team_code text not null, email text not null,
  can_post boolean not null default false,
  updated_at timestamptz not null default now(), updated_by text,
  primary key (team_code, email));
alter table public.msg_coach_access enable row level security;

-- ---------- messages ----------
create table if not exists public.msg_messages (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.msg_channels(id) on delete cascade,
  sender_id uuid not null,                -- auth user id (no email stored here on purpose)
  sender_name text not null,
  sender_role text not null check (sender_role in ('coach','parent')),
  sender_label text,                      -- e.g. "Head Coach", "parent of Maya & Jordan"
  body text not null default '',
  attachments jsonb not null default '[]',   -- [{path,name,type,size}] in the team-messages bucket
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  notified_at timestamptz);               -- set once the email/text alerts for this message have gone out
create index if not exists msg_messages_channel_idx on public.msg_messages (channel_id, created_at);

-- ---------- where each person has read up to ----------
create table if not exists public.msg_reads (
  channel_id uuid not null references public.msg_channels(id) on delete cascade,
  user_id uuid not null,
  email text,
  last_read_at timestamptz not null default now(),
  primary key (channel_id, user_id));
create index if not exists msg_reads_email_idx on public.msg_reads (channel_id, email);

-- ---------- each person's alert choices (email is on unless they turn it off; texts only if they ask for them) ----------
create table if not exists public.msg_prefs (
  email text primary key,
  email_on boolean not null default true,
  sms_on boolean not null default false,
  sms_phone text,
  sms_consent_at timestamptz,
  updated_at timestamptz not null default now());
alter table public.msg_prefs enable row level security;

-- One alert per group until the person opens it again (so a busy chat doesn't send 40 emails).
create table if not exists public.msg_notify_state (
  channel_id uuid not null references public.msg_channels(id) on delete cascade,
  email text not null,
  last_notified_at timestamptz not null default now(),
  primary key (channel_id, email));
alter table public.msg_notify_state enable row level security;   -- no policies: alert function only

-- ============================ who may do what ============================
create or replace function public.msg_me() returns text
language sql stable as $$ select lower(coalesce(auth.jwt()->>'email','')) $$;

create or replace function public.msg_enabled(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select m.enabled from public.team_messaging m where m.team_code = t), false)
$$;

create or replace function public.msg_has_team_admin(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.coaches c where c.team_code = t and c.approved is true and c.team_admin is true)
$$;

create or replace function public.msg_can_manage(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.is_site_admin() or public.is_team_admin_of(t)
$$;

-- Does this coach's sign-up cover that division and sex? (Same rule the roster uses: only Division Coaches are
-- limited; a Head Coach or an "All divisions" coach covers the whole team.)
create or replace function public.msg_coach_covers(c public.coaches, p_division text, p_gender text) returns boolean
language sql immutable as $$
  select c.role_type is distinct from 'division_coach' or coalesce(c.division_or_age_group,'') ilike 'all%'
    or ( p_division = any(string_to_array(replace(coalesce(c.division_or_age_group,''),', ',','),','))
         and ( c.coach_gender is null or p_gender is null
               or (case p_gender when 'Boy' then 'Boys' when 'Girl' then 'Girls' end) = any(string_to_array(replace(c.coach_gender,', ',','),',')) ) )
$$;
create or replace function public.msg_coach_covers_team(c public.coaches) returns boolean
language sql immutable as $$
  select c.role_type is distinct from 'division_coach' or coalesce(c.division_or_age_group,'') ilike 'all%'
$$;

-- Is this email a parent with an athlete in this group?
create or replace function public.msg_parent_in(ch public.msg_channels, p_email text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce(p_email,'') <> '' and ch.audience in ('team','divisions') and exists (select 1 from public.registrations r
    where lower(r.email) = p_email and r.team_code = ch.team_code and r.season_year = ch.season_year and r.status in ('reviewed','verified')
      and (ch.audience = 'team' or r.division = any(coalesce(ch.divisions,'{}')))
      and (ch.genders is null or r.gender = any(ch.genders)))
$$;

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
    if d.parent_email = p_email and not ch.archived then return 'parent'; end if;
    return null;
  end if;
  if c.email is not null then
    if ch.audience = 'coaches' then return 'coach_post'; end if;
    if ch.audience = 'team' then return case when perm and public.msg_coach_covers_team(c) then 'coach_post' else 'coach_read' end; end if;
    if exists (select 1 from unnest(ch.divisions) dv, unnest(coalesce(ch.genders, array['Boy','Girl'])) g where public.msg_coach_covers(c, dv, g)) then
      return case when perm then 'coach_post' else 'coach_read' end; end if;
  end if;
  if not ch.archived and public.msg_parent_in(ch, p_email) then return 'parent'; end if;
  return null;
end $$;

create or replace function public.msg_role(p_channel uuid) returns text
language sql stable security definer set search_path to 'public' as $$
  select public.msg_role_for(ch, public.msg_me()) from public.msg_channels ch where ch.id = p_channel
$$;
create or replace function public.msg_can_read(p_channel uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.msg_role(p_channel) is not null
$$;
create or replace function public.msg_can_post(p_channel uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select not ch.archived and (rl in ('admin','coach_post') or (rl = 'parent' and ch.mode = 'chat'))
    from public.msg_channels ch, lateral (select public.msg_role_for(ch, public.msg_me()) as rl) x where ch.id = p_channel), false)
$$;

alter table public.msg_channels enable row level security;
alter table public.msg_messages enable row level security;
alter table public.msg_reads enable row level security;
drop policy if exists "msg channels read" on public.msg_channels;
create policy "msg channels read" on public.msg_channels for select to authenticated using (public.msg_can_read(id));
drop policy if exists "msg messages read" on public.msg_messages;
create policy "msg messages read" on public.msg_messages for select to authenticated using (public.msg_can_read(channel_id));
drop policy if exists "msg reads own" on public.msg_reads;
create policy "msg reads own" on public.msg_reads for select to authenticated using (user_id = auth.uid());
drop policy if exists "msg coach access read" on public.msg_coach_access;
create policy "msg coach access read" on public.msg_coach_access for select to authenticated using (public.msg_can_manage(team_code) or lower(email) = public.msg_me());
drop policy if exists "msg prefs own" on public.msg_prefs;
create policy "msg prefs own" on public.msg_prefs for select to authenticated using (email = public.msg_me());
-- No insert/update/delete policies anywhere: writes only through the functions below.

-- ============================ photos & attachments ============================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('team-messages', 'team-messages', false, 10485760, array['image/jpeg','image/png','image/gif','image/webp','image/heic','image/heif',
  'application/pdf','text/plain','text/csv','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Files live at  <group id>/<random>-<file name>
create or replace function public.msg_file_channel(p_name text) returns uuid
language sql immutable as $$
  select case when split_part(p_name,'/',1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(p_name,'/',1)::uuid end
$$;
-- A file can be removed by whoever sent the message it is on, or by the team's admins.
create or replace function public.msg_can_delete_file(p_name text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.msg_messages m join public.msg_channels ch on ch.id = m.channel_id
    where m.channel_id = public.msg_file_channel(p_name) and m.attachments @> jsonb_build_array(jsonb_build_object('path', p_name))
      and (m.sender_id = auth.uid() or public.msg_can_manage(ch.team_code)))
$$;
drop policy if exists "team messages files read" on storage.objects;
create policy "team messages files read" on storage.objects for select to authenticated
  using (bucket_id = 'team-messages' and public.msg_can_read(public.msg_file_channel(name)));
drop policy if exists "team messages files add" on storage.objects;
create policy "team messages files add" on storage.objects for insert to authenticated
  with check (bucket_id = 'team-messages' and public.msg_can_post(public.msg_file_channel(name)));
drop policy if exists "team messages files remove" on storage.objects;
create policy "team messages files remove" on storage.objects for delete to authenticated
  using (bucket_id = 'team-messages' and public.msg_can_delete_file(name));

-- ============================ the paid switch (site admin only, until billing flips it) ============================
create or replace function public.msg_set_enabled(p_team text, p_on boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.msg_me(); season integer;
begin
  if not public.is_site_admin() then raise exception 'Only a site admin can switch the Team Messenger add-on on or off.'; end if;
  if not exists (select 1 from public.league_teams t where t.code = p_team) then raise exception 'Team not found.'; end if;
  insert into public.team_messaging (team_code, enabled, updated_at, updated_by) values (p_team, coalesce(p_on,false), now(), me)
  on conflict (team_code) do update set enabled = excluded.enabled, updated_at = now(), updated_by = excluded.updated_by;
  -- First time on: give the team its two starter groups.
  if coalesce(p_on,false) then
    select nullif(value,'')::integer into season from public.app_settings where key = 'season_year';
    if season is not null and not exists (select 1 from public.msg_channels where team_code = p_team and season_year = season) then
      insert into public.msg_channels (team_code, season_year, name, audience, mode, created_by) values
        (p_team, season, 'Team announcements', 'team', 'announce', me),
        (p_team, season, 'Coaches only', 'coaches', 'chat', me);
    end if;
  end if;
end $$;
revoke all on function public.msg_set_enabled(text, boolean) from public;
grant execute on function public.msg_set_enabled(text, boolean) to authenticated;

-- ============================ team admin: let a coach message parents (or stop) ============================
create or replace function public.msg_set_coach_access(p_team text, p_email text, p_on boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
declare e text := lower(trim(coalesce(p_email,'')));
begin
  if not public.msg_can_manage(p_team) then raise exception 'Only this team''s team admin (or a site admin) can give coaches permission to message parents.'; end if;
  if not exists (select 1 from public.coaches c where lower(c.email) = e and c.team_code = p_team and c.approved is true and c.role_type is distinct from 'timer') then
    raise exception 'That person is not an approved coach on this team.'; end if;
  insert into public.msg_coach_access (team_code, email, can_post, updated_at, updated_by) values (p_team, e, coalesce(p_on,false), now(), public.msg_me())
  on conflict (team_code, email) do update set can_post = excluded.can_post, updated_at = now(), updated_by = excluded.updated_by;
end $$;
revoke all on function public.msg_set_coach_access(text, text, boolean) from public;
grant execute on function public.msg_set_coach_access(text, text, boolean) to authenticated;

-- ============================ create / change a group (team admin of that team, or site admin) ============================
create or replace function public.msg_save_channel(p_id uuid, p_team text, p_name text, p_audience text, p_divisions text[], p_genders text[], p_mode text, p_archived boolean default false) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.msg_me(); season integer; nid uuid; t text := p_team; cur_aud text;
  nm text := nullif(trim(p_name),''); divs text[] := p_divisions; gen text[] := p_genders;
begin
  if p_id is not null then select team_code, audience into t, cur_aud from public.msg_channels where id = p_id; if t is null then raise exception 'Group not found.'; end if; end if;
  if not public.msg_can_manage(t) then raise exception 'Only this team''s team admin (or a site admin) can set up message groups.'; end if;
  if not public.msg_enabled(t) then raise exception 'Team Messenger is not switched on for this team.'; end if;
  if not public.msg_has_team_admin(t) then raise exception 'This team needs a team admin first — every chat must have a team admin in it.'; end if;
  if cur_aud = 'direct' then   -- a direct message can only be closed or re-opened
    update public.msg_channels set archived = coalesce(p_archived,false) where id = p_id; return p_id; end if;
  if nm is null then raise exception 'Give the group a name.'; end if;
  if length(nm) > 60 then raise exception 'Keep the group name under 60 characters.'; end if;
  if p_audience not in ('team','divisions','coaches') then raise exception 'Pick who the group is for.'; end if;
  if p_mode not in ('announce','chat') then raise exception 'Pick announcements or two-way chat.'; end if;
  if p_audience = 'divisions' then
    if divs is null or cardinality(divs) = 0 then raise exception 'Pick at least one division.'; end if;
  else divs := null; end if;
  if p_audience = 'coaches' or gen is null or cardinality(gen) = 0 or gen @> array['Boy','Girl'] then gen := null; end if;
  if gen is not null and not (gen <@ array['Boy','Girl']) then raise exception 'Boys, girls, or both.'; end if;
  if p_id is null then
    select nullif(value,'')::integer into season from public.app_settings where key = 'season_year';
    insert into public.msg_channels (team_code, season_year, name, audience, divisions, genders, mode, created_by)
    values (t, season, nm, p_audience, divs, gen, case when p_audience = 'coaches' then 'chat' else p_mode end, me) returning id into nid;
  else
    update public.msg_channels set name = nm, audience = p_audience, divisions = divs, genders = gen,
      mode = case when p_audience = 'coaches' then 'chat' else p_mode end, archived = coalesce(p_archived,false) where id = p_id returning id into nid;
  end if;
  return nid;
end $$;
revoke all on function public.msg_save_channel(uuid, text, text, text, text[], text[], text, boolean) from public;
grant execute on function public.msg_save_channel(uuid, text, text, text, text[], text[], text, boolean) to authenticated;

-- ============================ start (or re-open) a direct message with one athlete's parent ============================
-- Team admins can message any parent on their team; a coach needs permission and the athlete must be in their divisions.
-- The team's admins can always see the conversation.
create or replace function public.msg_start_dm(p_registration uuid) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.msg_me(); r public.registrations; c public.coaches; season integer; pe text; cn text; pn text; kids text; cid uuid; is_mgr boolean;
begin
  if me = '' then raise exception 'Please sign in.'; end if;
  select * into r from public.registrations where id = p_registration; if r.id is null then raise exception 'Athlete not found.'; end if;
  select nullif(value,'')::integer into season from public.app_settings where key = 'season_year';
  if not public.msg_enabled(r.team_code) then raise exception 'Team Messenger is not switched on for this team.'; end if;
  if not public.msg_has_team_admin(r.team_code) then raise exception 'This team needs a team admin first — every chat must have a team admin in it.'; end if;
  if r.season_year is distinct from season or r.status not in ('reviewed','verified') then raise exception 'You can message this parent once the team has reviewed the athlete''s registration.'; end if;
  pe := lower(trim(coalesce(r.email,''))); if pe = '' then raise exception 'There is no parent email on this registration.'; end if;
  if pe = me then raise exception 'That is your own athlete.'; end if;
  is_mgr := public.msg_can_manage(r.team_code);
  select * into c from public.coaches x where lower(x.email) = me and x.approved is true order by (x.team_code = r.team_code) desc limit 1;
  if not is_mgr then
    if c.email is null or c.team_code is distinct from r.team_code or c.role_type = 'timer' then raise exception 'Only this team''s coaches can message its parents.'; end if;
    if not exists (select 1 from public.msg_coach_access a where a.team_code = r.team_code and lower(a.email) = me and a.can_post) then
      raise exception 'Your team admin hasn''t given you permission to message parents yet.'; end if;
    if not public.msg_coach_covers(c, r.division, r.gender) then raise exception 'You can only message parents of athletes in your own division.'; end if;
  end if;
  select d.channel_id into cid from public.msg_dm d where d.team_code = r.team_code and d.coach_email = me and d.parent_email = pe;
  if cid is not null then update public.msg_channels set archived = false where id = cid; return cid; end if;
  cn := coalesce(nullif(trim(c.name),''), nullif(trim(coalesce(c.first_name,'')||' '||coalesce(c.last_name,'')),''), 'Coach');
  select coalesce(nullif(trim(max(x.parent1_name)),''),'Parent'), string_agg(distinct x.first_name, ' & ') into pn, kids
    from public.registrations x where lower(x.email) = pe and x.team_code = r.team_code and x.season_year = season and x.status in ('reviewed','verified');
  insert into public.msg_channels (team_code, season_year, name, audience, mode, created_by)
  values (r.team_code, season, left(cn||' ↔ '||pn, 60), 'direct', 'chat', me) returning id into cid;
  insert into public.msg_dm (channel_id, team_code, coach_email, coach_name, parent_email, parent_name, athlete_names, registration_id)
  values (cid, r.team_code, me, cn, pe, pn, kids, r.id);
  return cid;
end $$;
revoke all on function public.msg_start_dm(uuid) from public;
grant execute on function public.msg_start_dm(uuid) to authenticated;

-- ============================ send a message (text, photos/files, or both) ============================
create or replace function public.msg_post(p_channel uuid, p_body text, p_attachments jsonb default '[]') returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.msg_me(); uid uuid := auth.uid(); ch public.msg_channels; c public.coaches; v_role text;
  v_body text := trim(coalesce(p_body,'')); nm text; lab text; rl text; kids text; nid uuid; att jsonb := '[]'; a jsonb;
begin
  if uid is null then raise exception 'Please sign in.'; end if;
  select * into ch from public.msg_channels where id = p_channel; if ch.id is null then raise exception 'Group not found.'; end if;
  if not public.msg_enabled(ch.team_code) then raise exception 'Team Messenger is not switched on for this team.'; end if;
  if ch.archived then raise exception 'This group is closed.'; end if;
  if jsonb_typeof(coalesce(p_attachments,'[]')) <> 'array' then raise exception 'Bad attachment list.'; end if;
  if jsonb_array_length(coalesce(p_attachments,'[]')) > 6 then raise exception 'Six photos or files at most per message.'; end if;
  for a in select * from jsonb_array_elements(coalesce(p_attachments,'[]')) loop
    if coalesce(a->>'path','') not like ch.id::text||'/%' or not exists (select 1 from storage.objects o where o.bucket_id = 'team-messages' and o.name = a->>'path') then
      raise exception 'One of the attachments didn''t upload — try again.'; end if;
    att := att || jsonb_build_array(jsonb_build_object('path', a->>'path', 'name', left(coalesce(a->>'name','file'),120), 'type', left(coalesce(a->>'type',''),100), 'size', coalesce((a->>'size')::bigint,0)));
  end loop;
  if v_body = '' and jsonb_array_length(att) = 0 then raise exception 'Type a message first.'; end if;
  if length(v_body) > 2000 then raise exception 'That message is too long (2,000 characters at most).'; end if;
  if (select count(*) from public.msg_messages m where m.sender_id = uid and m.created_at > now() - interval '1 minute') >= 20 then
    raise exception 'You''re sending messages very fast — wait a minute and try again.'; end if;
  v_role := public.msg_role_for(ch, me);
  if v_role in ('admin','coach_post') then
    select * into c from public.coaches x where lower(x.email) = me and x.approved is true order by (x.team_code = ch.team_code) desc limit 1;
    rl := 'coach';
    nm := coalesce(nullif(trim(c.name),''), nullif(trim(coalesce(c.first_name,'')||' '||coalesce(c.last_name,'')),''), 'Coach');
    lab := case when c.team_code is distinct from ch.team_code then 'League admin'
                when c.team_admin then coalesce(nullif(trim(c.admin_title),''),'Team admin')
                when c.role_type = 'head_coach' then 'Head Coach'
                when c.role_type = 'division_coach' then trim(coalesce(c.division_or_age_group,'')||' Coach')
                else 'Coach' end;
  elsif v_role = 'parent' and ch.mode = 'chat' then
    rl := 'parent';
    select coalesce(nullif(trim(max(r.parent1_name)),''),'Parent'), string_agg(distinct r.first_name, ' & ')
      into nm, kids from public.registrations r
      where lower(r.email) = me and r.team_code = ch.team_code and r.season_year = ch.season_year and r.status in ('reviewed','verified');
    lab := 'parent of '||coalesce(kids,'an athlete');
  elsif v_role = 'coach_read' then
    raise exception 'Your team admin hasn''t given you permission to message parents%', case when ch.audience = 'team' then ' (only a Head Coach or team admin can post to the whole team).' else ' yet.' end;
  elsif v_role = 'parent' then raise exception 'Only the coaches can post in this group.';
  else raise exception 'You are not in this group.';
  end if;
  insert into public.msg_messages (channel_id, sender_id, sender_name, sender_role, sender_label, body, attachments) values (ch.id, uid, nm, rl, lab, v_body, att) returning id into nid;
  update public.msg_channels set last_message_at = now() where id = ch.id;
  insert into public.msg_reads (channel_id, user_id, email, last_read_at) values (ch.id, uid, me, now())
  on conflict (channel_id, user_id) do update set last_read_at = now(), email = excluded.email;
  return nid;
end $$;
revoke all on function public.msg_post(uuid, text, jsonb) from public;
grant execute on function public.msg_post(uuid, text, jsonb) to authenticated;

-- ============================ remove a message (your own, or any message if you manage the team) ============================
create or replace function public.msg_delete(p_message uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare m public.msg_messages; t text;
begin
  select * into m from public.msg_messages where id = p_message; if m.id is null then raise exception 'Message not found.'; end if;
  select team_code into t from public.msg_channels where id = m.channel_id;
  if not (m.sender_id = auth.uid() or public.msg_can_manage(t)) then raise exception 'You can only remove your own messages.'; end if;
  update public.msg_messages set body = '', attachments = '[]', deleted_at = now() where id = p_message;
end $$;
revoke all on function public.msg_delete(uuid) from public;
grant execute on function public.msg_delete(uuid) to authenticated;

-- ============================ mark a group as read ============================
create or replace function public.msg_mark_read(p_channel uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null or not public.msg_can_read(p_channel) then return; end if;
  insert into public.msg_reads (channel_id, user_id, email, last_read_at) values (p_channel, auth.uid(), public.msg_me(), now())
  on conflict (channel_id, user_id) do update set last_read_at = now(), email = excluded.email;
end $$;
revoke all on function public.msg_mark_read(uuid) from public;
grant execute on function public.msg_mark_read(uuid) to authenticated;

-- ============================ my alert choices ============================
create or replace function public.msg_save_prefs(p_email_on boolean, p_sms_on boolean, p_phone text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.msg_me(); ph text := regexp_replace(coalesce(p_phone,''),'[^0-9]','','g');
begin
  if me = '' then raise exception 'Please sign in.'; end if;
  if length(ph) = 11 and left(ph,1) = '1' then ph := substr(ph,2); end if;
  if coalesce(p_sms_on,false) and length(ph) <> 10 then raise exception 'Enter a 10-digit mobile number for text alerts.'; end if;
  insert into public.msg_prefs (email, email_on, sms_on, sms_phone, sms_consent_at, updated_at)
  values (me, coalesce(p_email_on,true), coalesce(p_sms_on,false), case when length(ph) = 10 then '+1'||ph end, case when coalesce(p_sms_on,false) then now() end, now())
  on conflict (email) do update set email_on = excluded.email_on, sms_on = excluded.sms_on, sms_phone = excluded.sms_phone,
    sms_consent_at = case when excluded.sms_on then coalesce(public.msg_prefs.sms_consent_at, now()) end, updated_at = now();
end $$;
revoke all on function public.msg_save_prefs(boolean, boolean, text) from public;
grant execute on function public.msg_save_prefs(boolean, boolean, text) to authenticated;

-- ============================ my teams: am I a coach or a parent there, and is the add-on on? ============================
create or replace function public.msg_my_teams() returns table(team_code text, is_coach boolean, can_manage boolean, can_post boolean, enabled boolean, waiting boolean, has_admin boolean)
language sql stable security definer set search_path to 'public' as $$
  with me as (select public.msg_me() as email),
  season as (select nullif(value,'')::integer as y from public.app_settings where key = 'season_year'),
  t as (
    select c.team_code, true as is_coach, false as waiting from public.coaches c, me
      where me.email <> '' and lower(c.email) = me.email and c.approved is true and c.role_type is distinct from 'timer' and c.team_code is not null
    union all
    select r.team_code, false, bool_and(r.status not in ('reviewed','verified')) from public.registrations r, me, season
      where me.email <> '' and lower(r.email) = me.email and r.season_year = season.y and r.status <> 'rejected' and r.team_code is not null
      group by r.team_code)
  select t.team_code, bool_or(t.is_coach), public.msg_can_manage(t.team_code),
    public.msg_can_manage(t.team_code) or (bool_or(t.is_coach) and exists (select 1 from public.msg_coach_access a, me where a.team_code = t.team_code and lower(a.email) = me.email and a.can_post)),
    public.msg_enabled(t.team_code), bool_and(t.waiting), public.msg_has_team_admin(t.team_code)
  from t group by t.team_code
$$;
revoke all on function public.msg_my_teams() from public;
grant execute on function public.msg_my_teams() to authenticated;

-- ============================ my groups, with the latest message and how many I haven't read ============================
-- p_team: one team's groups (a site admin can look at any team). Left empty: every group I'm in on my own teams.
create or replace function public.msg_my_channels(p_team text default null)
returns table(id uuid, team_code text, name text, audience text, divisions text[], genders text[], mode text, archived boolean,
  my_role text, can_post boolean, can_manage boolean, families integer, last_at timestamptz, last_sender text, last_body text, unread integer)
language sql stable security definer set search_path to 'public' as $$
  select ch.id, ch.team_code,
    case when ch.audience <> 'direct' then ch.name
         when x.rl = 'parent' then 'Coach '||d.coach_name
         when d.coach_email = public.msg_me() then d.parent_name||coalesce(' ('||d.athlete_names||')','')
         else d.coach_name||' ↔ '||d.parent_name||coalesce(' ('||d.athlete_names||')','') end,
    ch.audience, ch.divisions, ch.genders, ch.mode, ch.archived, x.rl,
    not ch.archived and (x.rl in ('admin','coach_post') or (x.rl = 'parent' and ch.mode = 'chat')),
    public.msg_can_manage(ch.team_code),
    case ch.audience when 'coaches' then 0 when 'direct' then 1 else (select count(distinct lower(r.email))::integer from public.registrations r
      where r.team_code = ch.team_code and r.season_year = ch.season_year and r.status in ('reviewed','verified')
        and (ch.audience = 'team' or r.division = any(coalesce(ch.divisions,'{}'))) and (ch.genders is null or r.gender = any(ch.genders))) end,
    lm.created_at, lm.sender_name, case when lm.body = '' and lm.n_att > 0 then '📎 '||lm.n_att||' attachment'||case when lm.n_att > 1 then 's' else '' end else lm.body end,
    (select count(*)::integer from public.msg_messages m where m.channel_id = ch.id and m.deleted_at is null and m.sender_id <> auth.uid()
       and m.created_at > coalesce((select rd.last_read_at from public.msg_reads rd where rd.channel_id = ch.id and rd.user_id = auth.uid()), '-infinity'))
  from public.msg_channels ch
  cross join lateral (select public.msg_role_for(ch, public.msg_me()) as rl) x
  left join public.msg_dm d on d.channel_id = ch.id
  left join lateral (select m.created_at, m.sender_name, m.body, jsonb_array_length(m.attachments) as n_att from public.msg_messages m
    where m.channel_id = ch.id and m.deleted_at is null order by m.created_at desc limit 1) lm on true
  where ch.season_year = (select nullif(value,'')::integer from public.app_settings where key = 'season_year')
    and x.rl is not null
    and case when p_team is not null then ch.team_code = p_team
             else (x.rl = 'parent' or exists (select 1 from public.coaches c where lower(c.email) = public.msg_me() and c.approved is true and c.team_code = ch.team_code)) end
  order by ch.archived, (ch.audience = 'coaches'), coalesce(lm.created_at, ch.created_at) desc
$$;
revoke all on function public.msg_my_channels(text) from public;
grant execute on function public.msg_my_channels(text) to authenticated;

-- ============================ alerts: who should be emailed / texted about a new message ============================
-- Called only by the msg-notify server function (service role). Returns each person to alert ONCE per group until
-- they open the group again, and records that the alert went out.
create or replace function public.msg_notify_targets(p_message uuid)
returns table(to_email text, send_email boolean, to_phone text, team_name text, group_name text, sender_name text, preview text, is_direct boolean)
language plpgsql security definer set search_path to 'public' as $$
#variable_conflict use_column
declare m public.msg_messages; ch public.msg_channels; sender text; tn text;
begin
  update public.msg_messages x set notified_at = now() where x.id = p_message and x.notified_at is null and x.deleted_at is null returning x.* into m;
  if m.id is null then return; end if;
  select * into ch from public.msg_channels c where c.id = m.channel_id;
  select lower(u.email) into sender from auth.users u where u.id = m.sender_id;
  select coalesce(t.name, ch.team_code) into tn from (select 1) one left join public.league_teams t on t.code = ch.team_code;
  return query
  with cand as (
    select lower(r.email) as e from public.registrations r where ch.audience in ('team','divisions') and r.team_code = ch.team_code
      and r.season_year = ch.season_year and r.status in ('reviewed','verified') and r.email is not null
    union select lower(c.email) from public.coaches c where c.team_code = ch.team_code and c.approved is true and c.role_type is distinct from 'timer'
    union select d.parent_email from public.msg_dm d where d.channel_id = ch.id
  ), who as (
    select cand.e from cand where coalesce(cand.e,'') <> '' and cand.e is distinct from sender and public.msg_role_for(ch, cand.e) is not null
      and not exists (select 1 from public.msg_notify_state s where s.channel_id = ch.id and s.email = cand.e
        and s.last_notified_at > coalesce((select max(rd.last_read_at) from public.msg_reads rd where rd.channel_id = ch.id and rd.email = cand.e), '-infinity'))
  ), mark as (
    insert into public.msg_notify_state as s (channel_id, email, last_notified_at) select ch.id, who.e, now() from who
    on conflict on constraint msg_notify_state_pkey do update set last_notified_at = now() returning s.email as e
  )
  select mark.e, coalesce(p.email_on, true), case when p.sms_on and p.sms_phone is not null then p.sms_phone end,
    tn, case when ch.audience = 'direct' then 'a direct message' else ch.name end, m.sender_name,
    case when m.body = '' then '(sent a photo or file)' else left(m.body, 300) end, ch.audience = 'direct'
  from mark left join public.msg_prefs p on p.email = mark.e;
end $$;
revoke all on function public.msg_notify_targets(uuid) from public, anon, authenticated;
grant execute on function public.msg_notify_targets(uuid) to service_role;

-- Who sent this message? (the server function checks the caller is the sender before alerting anyone)
create or replace function public.msg_is_my_message(p_message uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.msg_messages m where m.id = p_message and m.sender_id = auth.uid())
$$;
revoke all on function public.msg_is_my_message(uuid) from public;
grant execute on function public.msg_is_my_message(uuid) to authenticated;

-- ============================ live updates: new messages appear without refreshing ============================
do $$ begin
  alter publication supabase_realtime add table public.msg_messages;
exception when duplicate_object then null; when undefined_object then null; end $$;
