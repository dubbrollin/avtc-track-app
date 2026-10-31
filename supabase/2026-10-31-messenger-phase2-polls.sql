-- ============================================================================
-- Team Messenger — Phase 2 (2026-10-31): POLLS in chat
-- The Team App feature coaches use most after plain messages: "Who can make Saturday's meet?" with a tap-to-answer
-- card right in the chat (see teamapp-chat-rea/REA-TEAMAPP-CHAT.md).
--   * Anyone who may POST in a chat may start a poll (so parents can in two-way chats, only coaches in announcements).
--   * Anyone who may READ the chat may vote — parents answer polls in announcement groups too.
--   * 2–6 answers, single or multiple choice, open for 15 minutes to 30 days (the picker offers Team App's
--     15 min / 1 h / 8 h / 24 h / 3 days / 1 week), optionally anonymous. A vote can be changed until the poll closes;
--     the poll's author or a team admin can close it early.
--   * Results (counts, who picked what unless anonymous, my own picks) come through one function per chat, so
--     the vote table itself is never readable — anonymous really is anonymous.
-- A poll is also an ordinary message ("📊 Poll: …"), so previews, the All-messages history, alerts, replies,
-- reactions and Remove all keep working. Run this AFTER 2026-10-31-messenger-phase1.sql.
-- ============================================================================

create table if not exists public.msg_polls (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null unique references public.msg_messages(id) on delete cascade,
  channel_id uuid not null references public.msg_channels(id) on delete cascade,
  question text not null,
  options jsonb not null,                              -- ["Yes","No","Maybe"]
  anonymous boolean not null default false,
  multi boolean not null default false,                -- may pick more than one answer
  closes_at timestamptz not null,
  closed_at timestamptz,                               -- set when closed early
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());      -- bumped on every vote so the chat refreshes live
create index if not exists msg_polls_channel_idx on public.msg_polls (channel_id, created_at);
alter table public.msg_polls enable row level security;
drop policy if exists "msg polls read" on public.msg_polls;
create policy "msg polls read" on public.msg_polls for select to authenticated using (public.msg_can_read(channel_id));

create table if not exists public.msg_poll_votes (
  poll_id uuid not null references public.msg_polls(id) on delete cascade,
  user_id uuid not null,
  name text not null,                                  -- display name at the time of voting
  choice integer not null,                             -- index into options
  created_at timestamptz not null default now(),
  primary key (poll_id, user_id, choice));
alter table public.msg_poll_votes enable row level security;
-- No policies at all on the votes: they are only ever read through msg_polls_in below.
revoke all on table public.msg_poll_votes from public, anon, authenticated;

-- ---------- start a poll (it is posted as a message through msg_post, so every posting rule applies) ----------
create or replace function public.msg_poll_create(p_channel uuid, p_question text, p_options jsonb, p_minutes integer default 1440,
  p_anonymous boolean default false, p_multi boolean default false) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare q text := trim(coalesce(p_question,'')); opts jsonb := '[]'; o text; mid uuid; pid uuid;
begin
  if auth.uid() is null then raise exception 'Please sign in.'; end if;
  if q = '' then raise exception 'Type the question first.'; end if;
  if length(q) > 300 then raise exception 'That question is too long (300 characters at most).'; end if;
  if jsonb_typeof(coalesce(p_options,'[]')) <> 'array' then raise exception 'Bad answer list.'; end if;
  for o in select trim(coalesce(x #>> '{}','')) from jsonb_array_elements(p_options) x loop
    if o = '' then continue; end if;
    if length(o) > 80 then raise exception 'Keep each answer under 80 characters.'; end if;
    if opts @> to_jsonb(array[o]) then raise exception 'Two answers are the same: "%".', o; end if;
    opts := opts || to_jsonb(array[o]);
  end loop;
  if jsonb_array_length(opts) < 2 then raise exception 'A poll needs at least two answers.'; end if;
  if jsonb_array_length(opts) > 6 then raise exception 'Six answers at most.'; end if;
  if coalesce(p_minutes,0) < 15 or p_minutes > 43200 then raise exception 'A poll can stay open from 15 minutes to 30 days.'; end if;
  mid := public.msg_post(p_channel, '📊 Poll: '||q, '[]', null);   -- raises if this person may not post here
  insert into public.msg_polls (message_id, channel_id, question, options, anonymous, multi, closes_at, created_by)
    values (mid, p_channel, q, opts, coalesce(p_anonymous,false), coalesce(p_multi,false), now() + make_interval(mins => p_minutes), auth.uid())
    returning id into pid;
  return mid;
end $$;
revoke all on function public.msg_poll_create(uuid, text, jsonb, integer, boolean, boolean) from public, anon;
grant execute on function public.msg_poll_create(uuid, text, jsonb, integer, boolean, boolean) to authenticated;

-- ---------- vote: tap an answer to pick it, tap again to take it back. Single-choice polls swap the pick. Returns true when a vote was added. ----------
create or replace function public.msg_poll_vote(p_poll uuid, p_choice integer) returns boolean
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.msg_me(); uid uuid := auth.uid(); p public.msg_polls; m public.msg_messages; ch public.msg_channels; nm text;
begin
  if uid is null then raise exception 'Please sign in.'; end if;
  select * into p from public.msg_polls where id = p_poll; if p.id is null then raise exception 'Poll not found.'; end if;
  select * into m from public.msg_messages where id = p.message_id;
  if m.deleted_at is not null then raise exception 'That poll was removed.'; end if;
  select * into ch from public.msg_channels where id = p.channel_id;
  if public.msg_role_for(ch, me) is null then raise exception 'You are not in this group.'; end if;
  if ch.archived then raise exception 'This chat is closed.'; end if;
  if p.closed_at is not null or p.closes_at <= now() then raise exception 'This poll has closed.'; end if;
  if p_choice is null or p_choice < 0 or p_choice >= jsonb_array_length(p.options) then raise exception 'Pick one of the answers.'; end if;
  delete from public.msg_poll_votes where poll_id = p.id and user_id = uid and choice = p_choice;
  if found then update public.msg_polls set updated_at = now() where id = p.id; return false; end if;
  if not p.multi then delete from public.msg_poll_votes where poll_id = p.id and user_id = uid; end if;
  select x.name into nm from public.msg_person(ch, me) x;
  insert into public.msg_poll_votes (poll_id, user_id, name, choice) values (p.id, uid, coalesce(nm,'Someone'), p_choice);
  update public.msg_polls set updated_at = now() where id = p.id;
  return true;
end $$;
revoke all on function public.msg_poll_vote(uuid, integer) from public, anon;
grant execute on function public.msg_poll_vote(uuid, integer) to authenticated;

-- ---------- close a poll early (its author, or a team admin) ----------
create or replace function public.msg_poll_close(p_poll uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare p public.msg_polls; t text;
begin
  select * into p from public.msg_polls where id = p_poll; if p.id is null then raise exception 'Poll not found.'; end if;
  select team_code into t from public.msg_channels where id = p.channel_id;
  if not (p.created_by = auth.uid() or public.msg_can_manage(t)) then raise exception 'Only the person who started the poll or a team admin can close it.'; end if;
  update public.msg_polls set closed_at = coalesce(closed_at, now()), updated_at = now() where id = p.id;
end $$;
revoke all on function public.msg_poll_close(uuid) from public, anon;
grant execute on function public.msg_poll_close(uuid) to authenticated;

-- ---------- every poll in a chat with its results: counts per answer, who picked what (unless anonymous), and my own picks ----------
create or replace function public.msg_polls_in(p_channel uuid)
returns table(poll_id uuid, message_id uuid, question text, options jsonb, anonymous boolean, multi boolean, closes_at timestamptz, closed_at timestamptz,
  created_by uuid, counts integer[], who jsonb, mine integer[], voters integer)
language sql stable security definer set search_path to 'public' as $$
  select p.id, p.message_id, p.question, p.options, p.anonymous, p.multi, p.closes_at, p.closed_at, p.created_by,
    (select coalesce(array_agg(coalesce(c.n,0) order by i.i), '{}')
       from generate_series(0, jsonb_array_length(p.options)-1) i(i)
       left join (select v.choice, count(*)::int n from public.msg_poll_votes v where v.poll_id = p.id group by v.choice) c on c.choice = i.i),
    case when p.anonymous then '{}'::jsonb else
      (select coalesce(jsonb_object_agg(x.choice::text, x.names), '{}')
         from (select v.choice, jsonb_agg(v.name order by v.created_at) names from public.msg_poll_votes v where v.poll_id = p.id group by v.choice) x) end,
    (select coalesce(array_agg(v.choice order by v.choice), '{}') from public.msg_poll_votes v where v.poll_id = p.id and v.user_id = auth.uid()),
    (select count(distinct v.user_id)::int from public.msg_poll_votes v where v.poll_id = p.id)
  from public.msg_polls p
  join public.msg_messages m on m.id = p.message_id
  where p.channel_id = p_channel and public.msg_can_read(p_channel) and m.deleted_at is null
  order by p.created_at
$$;
revoke all on function public.msg_polls_in(uuid) from public, anon;
grant execute on function public.msg_polls_in(uuid) to authenticated;

-- ---------- live updates: a vote bumps the poll row, which everyone in the chat can see change ----------
do $$ begin
  alter publication supabase_realtime add table public.msg_polls;
exception when duplicate_object then null; when undefined_object then null; end $$;
