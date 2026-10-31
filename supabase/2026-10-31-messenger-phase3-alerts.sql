-- ============================================================================
-- Team Messenger — Phase 3 (2026-10-31): quieter, smarter alerts
--   * MUTE A CHAT  — 1 hour, 8 hours, a week, or until you unmute. A muted chat still shows its unread count;
--                    it just never emails, texts or pushes you.
--   * SMART DEFAULTS (copied from Team App) — direct messages, division groups and announcements alert you;
--                    busy whole-team two-way chats do NOT unless you tick "Whole-team chats too" in My alerts.
--   * APP NOTIFICATIONS (web push) — each phone/computer that turns them on is saved here; the msg-notify server
--                    function pushes to those devices first and only falls back to email when a person has no device
--                    (or asked for "email me as well"). Texts stay a separate opt-in, as before.
-- Run this AFTER 2026-10-31-messenger-phase2-polls.sql.  Needs msg-notify redeployed with VAPID secrets to push.
-- ============================================================================

-- ---------- 1. mutes ----------
create table if not exists public.msg_mutes (
  channel_id uuid not null references public.msg_channels(id) on delete cascade,
  user_id uuid not null,
  email text not null,
  muted_until timestamptz,                         -- null = until I unmute
  created_at timestamptz not null default now(),
  primary key (channel_id, user_id));
create index if not exists msg_mutes_email_idx on public.msg_mutes (channel_id, email);
alter table public.msg_mutes enable row level security;
drop policy if exists "msg mutes own" on public.msg_mutes;
create policy "msg mutes own" on public.msg_mutes for select to authenticated using (user_id = auth.uid());

create or replace function public.msg_mute(p_channel uuid, p_hours integer default null) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'Please sign in.'; end if;
  if not public.msg_can_read(p_channel) then raise exception 'You are not in this group.'; end if;
  if p_hours is not null and (p_hours < 1 or p_hours > 24*90) then raise exception 'Mute for between an hour and 90 days, or until you unmute.'; end if;
  insert into public.msg_mutes (channel_id, user_id, email, muted_until)
    values (p_channel, auth.uid(), public.msg_me(), case when p_hours is null then null else now() + make_interval(hours => p_hours) end)
  on conflict (channel_id, user_id) do update set muted_until = excluded.muted_until, email = excluded.email, created_at = now();
end $$;
revoke all on function public.msg_mute(uuid, integer) from public, anon;
grant execute on function public.msg_mute(uuid, integer) to authenticated;

create or replace function public.msg_unmute(p_channel uuid) returns void
language sql security definer set search_path to 'public' as $$
  delete from public.msg_mutes where channel_id = p_channel and user_id = auth.uid()
$$;
revoke all on function public.msg_unmute(uuid) from public, anon;
grant execute on function public.msg_unmute(uuid) to authenticated;

-- is this person (by email) muting this chat right now?
create or replace function public.msg_is_muted(p_channel uuid, p_email text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.msg_mutes m where m.channel_id = p_channel and m.email = p_email and (m.muted_until is null or m.muted_until > now()))
$$;
revoke all on function public.msg_is_muted(uuid, text) from public, anon, authenticated;

-- ---------- 2. alert preferences: two new choices ----------
alter table public.msg_prefs add column if not exists alert_team_chat boolean not null default false;   -- whole-team two-way chats too
alter table public.msg_prefs add column if not exists email_always boolean not null default false;      -- email even when a device got the push

drop function if exists public.msg_save_prefs(boolean, boolean, text);
create or replace function public.msg_save_prefs(p_email_on boolean, p_sms_on boolean, p_phone text, p_alert_team_chat boolean default false, p_email_always boolean default false) returns void
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.msg_me(); ph text := regexp_replace(coalesce(p_phone,''),'[^0-9]','','g');
begin
  if me = '' then raise exception 'Please sign in.'; end if;
  if length(ph) = 11 and left(ph,1) = '1' then ph := substr(ph,2); end if;
  if coalesce(p_sms_on,false) and length(ph) <> 10 then raise exception 'Enter a 10-digit mobile number for text alerts.'; end if;
  insert into public.msg_prefs (email, email_on, sms_on, sms_phone, sms_consent_at, alert_team_chat, email_always, updated_at)
  values (me, coalesce(p_email_on,true), coalesce(p_sms_on,false), case when length(ph) = 10 then '+1'||ph end, case when coalesce(p_sms_on,false) then now() end,
    coalesce(p_alert_team_chat,false), coalesce(p_email_always,false), now())
  on conflict (email) do update set email_on = excluded.email_on, sms_on = excluded.sms_on, sms_phone = excluded.sms_phone,
    sms_consent_at = case when excluded.sms_on then coalesce(public.msg_prefs.sms_consent_at, now()) end,
    alert_team_chat = excluded.alert_team_chat, email_always = excluded.email_always, updated_at = now();
end $$;
revoke all on function public.msg_save_prefs(boolean, boolean, text, boolean, boolean) from public, anon;
grant execute on function public.msg_save_prefs(boolean, boolean, text, boolean, boolean) to authenticated;

-- ---------- 3. devices that get app notifications (web push subscriptions) ----------
create table if not exists public.msg_push_subs (
  endpoint text primary key,
  user_id uuid not null,
  email text not null,
  p256dh text not null,
  auth text not null,
  device text,                                     -- a short description of the browser/phone, for the person's own list
  created_at timestamptz not null default now(),
  last_ok_at timestamptz);
create index if not exists msg_push_subs_email_idx on public.msg_push_subs (email);
alter table public.msg_push_subs enable row level security;
drop policy if exists "msg push own" on public.msg_push_subs;
create policy "msg push own" on public.msg_push_subs for select to authenticated using (user_id = auth.uid());

create or replace function public.msg_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_device text default null) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'Please sign in.'; end if;
  if coalesce(p_endpoint,'') !~ '^https://' or coalesce(p_p256dh,'') = '' or coalesce(p_auth,'') = '' then raise exception 'That device subscription looks incomplete.'; end if;
  if (select count(*) from public.msg_push_subs s where s.user_id = auth.uid()) >= 10 and not exists (select 1 from public.msg_push_subs s where s.endpoint = p_endpoint) then
    raise exception 'Ten devices at most — turn notifications off on an old one first.'; end if;
  insert into public.msg_push_subs (endpoint, user_id, email, p256dh, auth, device)
    values (p_endpoint, auth.uid(), public.msg_me(), p_p256dh, p_auth, left(coalesce(p_device,''),120))
  on conflict (endpoint) do update set user_id = excluded.user_id, email = excluded.email, p256dh = excluded.p256dh, auth = excluded.auth, device = excluded.device, created_at = now();
end $$;
revoke all on function public.msg_push_subscribe(text, text, text, text) from public, anon;
grant execute on function public.msg_push_subscribe(text, text, text, text) to authenticated;

create or replace function public.msg_push_unsubscribe(p_endpoint text) returns void
language sql security definer set search_path to 'public' as $$
  delete from public.msg_push_subs where endpoint = p_endpoint and user_id = auth.uid()
$$;
revoke all on function public.msg_push_unsubscribe(text) from public, anon;
grant execute on function public.msg_push_unsubscribe(text) to authenticated;

-- the server function reports each push: a dead endpoint (404/410 from the browser's push service) is dropped
create or replace function public.msg_push_result(p_endpoint text, p_ok boolean) returns void
language sql security definer set search_path to 'public' as $$
  delete from public.msg_push_subs where endpoint = p_endpoint and not p_ok;
  update public.msg_push_subs set last_ok_at = now() where endpoint = p_endpoint and p_ok;
$$;
revoke all on function public.msg_push_result(text, boolean) from public, anon, authenticated;
grant execute on function public.msg_push_result(text, boolean) to service_role;

-- ---------- 4. my chats now say whether I've muted each one ----------
drop function if exists public.msg_my_channels(text);
create or replace function public.msg_my_channels(p_team text default null)
returns table(id uuid, team_code text, name text, audience text, divisions text[], genders text[], mode text, archived boolean,
  my_role text, can_post boolean, can_manage boolean, families integer, last_at timestamptz, last_sender text, last_body text, unread integer, muted boolean)
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
       and m.created_at > coalesce((select rd.last_read_at from public.msg_reads rd where rd.channel_id = ch.id and rd.user_id = auth.uid()), '-infinity')),
    exists (select 1 from public.msg_mutes mu where mu.channel_id = ch.id and mu.user_id = auth.uid() and (mu.muted_until is null or mu.muted_until > now()))
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
revoke all on function public.msg_my_channels(text) from public, anon;
grant execute on function public.msg_my_channels(text) to authenticated;

-- ---------- 5. who to alert: now skips muted people and (by default) whole-team chats, and hands over each person's devices ----------
drop function if exists public.msg_notify_targets(uuid);
create or replace function public.msg_notify_targets(p_message uuid)
returns table(to_email text, send_email boolean, email_always boolean, to_phone text, push jsonb, team_name text, group_name text, sender_name text, preview text, is_direct boolean)
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
      and not public.msg_is_muted(ch.id, cand.e)
      -- a whole-team two-way chat only alerts people who asked for it (announcements, division groups and DMs always alert)
      and (ch.audience <> 'team' or ch.mode <> 'chat' or coalesce((select p.alert_team_chat from public.msg_prefs p where p.email = cand.e), false))
      and not exists (select 1 from public.msg_notify_state s where s.channel_id = ch.id and s.email = cand.e
        and s.last_notified_at > coalesce((select max(rd.last_read_at) from public.msg_reads rd where rd.channel_id = ch.id and rd.email = cand.e), '-infinity'))
  ), mark as (
    insert into public.msg_notify_state as s (channel_id, email, last_notified_at) select ch.id, who.e, now() from who
    on conflict on constraint msg_notify_state_pkey do update set last_notified_at = now() returning s.email as e
  )
  select mark.e, coalesce(p.email_on, true), coalesce(p.email_always, false), case when p.sms_on and p.sms_phone is not null then p.sms_phone end,
    coalesce((select jsonb_agg(jsonb_build_object('endpoint', ps.endpoint, 'p256dh', ps.p256dh, 'auth', ps.auth)) from public.msg_push_subs ps where ps.email = mark.e), '[]'::jsonb),
    tn, case when ch.audience = 'direct' then 'a direct message' else ch.name end, m.sender_name,
    case when m.body = '' then '(sent a photo or file)' else left(m.body, 300) end, ch.audience = 'direct'
  from mark left join public.msg_prefs p on p.email = mark.e;
end $$;
revoke all on function public.msg_notify_targets(uuid) from public, anon, authenticated;
grant execute on function public.msg_notify_targets(uuid) to service_role;
