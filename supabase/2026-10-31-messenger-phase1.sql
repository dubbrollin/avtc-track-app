-- ============================================================================
-- Team Messenger — Phase 1 polish (2026-10-31): reactions, "reply to", and "seen by"
-- The three things people notice in Stack Team App's chat (see teamapp-chat-rea/REA-TEAMAPP-CHAT.md):
--   * REACTIONS  — tap 👍 ❤️ 🙏 … on any message; everyone in the chat sees the counts and who reacted.
--                  Anyone who can READ a chat may react (so parents can "thumbs-up" an announcement), up to
--                  three different emoji per person per message. A closed chat can't be reacted to.
--   * REPLY TO   — a message can quote an earlier message from the same chat.
--   * SEEN BY    — who has read up to where (the little avatars under the last message each person has seen).
--                  Built from msg_reads, which already records each person's last read time per chat.
-- Nothing about who is in a chat, who may post, or the paywall changes.
-- Run this AFTER 2026-10-13-team-messenger.sql, -2.sql and -3.sql.
-- ============================================================================

-- ---------- 1. reply to an earlier message ----------
alter table public.msg_messages add column if not exists reply_to uuid references public.msg_messages(id) on delete set null;
create index if not exists msg_messages_reply_idx on public.msg_messages (reply_to) where reply_to is not null;

-- ---------- 2. reactions ----------
create table if not exists public.msg_reactions (
  message_id uuid not null references public.msg_messages(id) on delete cascade,
  channel_id uuid not null references public.msg_channels(id) on delete cascade,
  user_id uuid not null,                  -- auth user id (no email stored, same as messages)
  name text not null,                     -- display name at the time they reacted
  emoji text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji));
create index if not exists msg_reactions_channel_idx on public.msg_reactions (channel_id, created_at);
alter table public.msg_reactions enable row level security;
drop policy if exists "msg reactions read" on public.msg_reactions;
create policy "msg reactions read" on public.msg_reactions for select to authenticated using (public.msg_can_read(channel_id));
-- No insert/update/delete policies: reactions change only through msg_react below.

-- ---------- who is this person in this chat: display name, coach/parent, and the little label ----------
-- (The same words msg_post has always used; pulled out so reactions and "seen by" show the same names.)
create or replace function public.msg_person(ch public.msg_channels, p_email text)
returns table(name text, role text, label text)
language plpgsql stable security definer set search_path to 'public' as $$
declare v_role text; c public.coaches; kids text;
begin
  v_role := public.msg_role_for(ch, p_email);
  if v_role in ('admin','coach_post','coach_read') then
    select * into c from public.coaches x where lower(x.email) = p_email and x.approved is true order by (x.team_code = ch.team_code) desc limit 1;
    return query select
      coalesce(nullif(trim(c.name),''), nullif(trim(coalesce(c.first_name,'')||' '||coalesce(c.last_name,'')),''), 'Coach'),
      'coach'::text,
      case when c.team_code is distinct from ch.team_code then 'League admin'
           when c.team_admin then coalesce(nullif(trim(c.admin_title),''),'Team admin')
           when c.role_type = 'head_coach' then 'Head Coach'
           when c.role_type = 'division_coach' then trim(coalesce(c.division_or_age_group,'')||' Coach')
           else 'Coach' end;
  elsif v_role = 'parent' then
    return query select coalesce(nullif(trim(max(r.parent1_name)),''),'Parent'), 'parent'::text,
      'parent of '||coalesce(string_agg(distinct r.first_name, ' & '),'an athlete')
      from public.registrations r
      where lower(r.email) = p_email and r.team_code = ch.team_code and r.season_year = ch.season_year and r.status in ('reviewed','verified');
  end if;
end $$;
revoke all on function public.msg_person(public.msg_channels, text) from public, anon, authenticated;

-- ---------- post a message (now with an optional "reply to") ----------
-- The old 3-argument version is removed so the app's call can't match two functions at once.
drop function if exists public.msg_post(uuid, text, jsonb);
create or replace function public.msg_post(p_channel uuid, p_body text, p_attachments jsonb default '[]', p_reply_to uuid default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.msg_me(); uid uuid := auth.uid(); ch public.msg_channels; v_role text;
  v_body text := trim(coalesce(p_body,'')); nm text; lab text; rl text; nid uuid; att jsonb := '[]'; a jsonb;
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
  if p_reply_to is not null and not exists (select 1 from public.msg_messages r where r.id = p_reply_to and r.channel_id = ch.id) then
    raise exception 'The message you''re replying to isn''t in this chat.'; end if;
  if (select count(*) from public.msg_messages m where m.sender_id = uid and m.created_at > now() - interval '1 minute') >= 20 then
    raise exception 'You''re sending messages very fast — wait a minute and try again.'; end if;
  v_role := public.msg_role_for(ch, me);
  if v_role in ('admin','coach_post') or (v_role = 'parent' and ch.mode = 'chat') then
    select p.name, p.role, p.label into nm, rl, lab from public.msg_person(ch, me) p;
  elsif v_role = 'coach_read' then
    raise exception 'Your team admin hasn''t given you permission to message parents%', case when ch.audience = 'team' then ' (only a Head Coach or team admin can post to the whole team).' else ' yet.' end;
  elsif v_role = 'parent' then raise exception 'Only the coaches can post in this group.';
  else raise exception 'You are not in this group.';
  end if;
  insert into public.msg_messages (channel_id, sender_id, sender_name, sender_role, sender_label, body, attachments, reply_to)
    values (ch.id, uid, nm, rl, lab, v_body, att, p_reply_to) returning id into nid;
  update public.msg_channels set last_message_at = now() where id = ch.id;
  insert into public.msg_reads (channel_id, user_id, email, last_read_at) values (ch.id, uid, me, now())
  on conflict (channel_id, user_id) do update set last_read_at = now(), email = excluded.email;
  return nid;
end $$;
revoke all on function public.msg_post(uuid, text, jsonb, uuid) from public, anon;
grant execute on function public.msg_post(uuid, text, jsonb, uuid) to authenticated;

-- ---------- react to a message: tap once to add, tap again to take it back. Returns true when added. ----------
create or replace function public.msg_react(p_message uuid, p_emoji text) returns boolean
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.msg_me(); uid uuid := auth.uid(); m public.msg_messages; ch public.msg_channels; e text := trim(coalesce(p_emoji,'')); nm text;
begin
  if uid is null then raise exception 'Please sign in.'; end if;
  select * into m from public.msg_messages where id = p_message; if m.id is null then raise exception 'Message not found.'; end if;
  if m.deleted_at is not null then raise exception 'That message was removed.'; end if;
  select * into ch from public.msg_channels where id = m.channel_id;
  if public.msg_role_for(ch, me) is null then raise exception 'You are not in this group.'; end if;
  if ch.archived then raise exception 'This chat is closed.'; end if;
  -- an emoji (or a short emoji sequence), never plain text: nothing from the keyboard's ASCII range
  if e = '' or char_length(e) > 12 or octet_length(e) > 40 or e ~ '[ -~]' then raise exception 'Pick an emoji.'; end if;
  delete from public.msg_reactions where message_id = m.id and user_id = uid and emoji = e;
  if found then return false; end if;
  if (select count(*) from public.msg_reactions r where r.message_id = m.id and r.user_id = uid) >= 3 then
    raise exception 'Three reactions per message is plenty 🙂'; end if;
  select p.name into nm from public.msg_person(ch, me) p;
  insert into public.msg_reactions (message_id, channel_id, user_id, name, emoji) values (m.id, ch.id, uid, coalesce(nm,'Someone'), e);
  return true;
end $$;
revoke all on function public.msg_react(uuid, text) from public, anon;
grant execute on function public.msg_react(uuid, text) to authenticated;

-- ---------- who has read this chat, and up to when (everyone in it except me) ----------
create or replace function public.msg_seen(p_channel uuid)
returns table(user_id uuid, name text, role text, last_read_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select rd.user_id, p.name, p.role, rd.last_read_at
  from public.msg_reads rd
  join public.msg_channels ch on ch.id = rd.channel_id
  cross join lateral public.msg_person(ch, rd.email) p
  where rd.channel_id = p_channel and public.msg_can_read(p_channel)
    and rd.user_id <> auth.uid() and coalesce(rd.email,'') <> ''
  order by rd.last_read_at desc
$$;
revoke all on function public.msg_seen(uuid) from public, anon;
grant execute on function public.msg_seen(uuid) to authenticated;

-- ---------- removing a message also clears its reactions ----------
create or replace function public.msg_delete(p_message uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare m public.msg_messages; t text;
begin
  select * into m from public.msg_messages where id = p_message; if m.id is null then raise exception 'Message not found.'; end if;
  select team_code into t from public.msg_channels where id = m.channel_id;
  if not (m.sender_id = auth.uid() or public.msg_can_manage(t)) then raise exception 'You can only remove your own messages.'; end if;
  update public.msg_messages set body = '', attachments = '[]', deleted_at = now() where id = p_message;
  delete from public.msg_reactions where message_id = p_message;
end $$;
revoke all on function public.msg_delete(uuid) from public, anon;
grant execute on function public.msg_delete(uuid) to authenticated;

-- ---------- live updates: reactions appear without refreshing ----------
do $$ begin
  alter publication supabase_realtime add table public.msg_reactions;
exception when duplicate_object then null; when undefined_object then null; end $$;
