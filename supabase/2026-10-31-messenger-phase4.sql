-- ============================================================================
-- Team Messenger — Phase 4 (2026-10-31): the small stuff from the Team App comparison
--   * VIDEO CLIPS   — short videos (MP4 / iPhone .mov / WebM) can be attached, up to 50 MB each. Other files stay at 10 MB
--                     (the app enforces the per-type limit; the bucket's ceiling is raised to 50 MB).
--   * EXPORT A CHAT — a team admin can download a chat as a spreadsheet (CSV): when, who, what, attachments, polls.
--   In-chat search and the "… is typing" indicator need no database changes.
-- Run this AFTER 2026-10-31-messenger-phase3-alerts.sql.
-- ============================================================================

-- ---------- 1. videos allowed, bucket ceiling 50 MB ----------
update storage.buckets set file_size_limit = 52428800,
  allowed_mime_types = array['image/jpeg','image/png','image/gif','image/webp','image/heic','image/heif',
    'video/mp4','video/quicktime','video/webm',
    'application/pdf','text/plain','text/csv','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']
where id = 'team-messages';

-- ---------- 2. export a chat (team admins and site admins only) ----------
create or replace function public.msg_export(p_channel uuid)
returns table(sent_at timestamptz, sender text, role text, label text, body text, attachments text, reply_to text, poll text, removed boolean)
language plpgsql stable security definer set search_path to 'public' as $$
declare ch public.msg_channels;
begin
  if auth.uid() is null then raise exception 'Please sign in.'; end if;
  select * into ch from public.msg_channels where id = p_channel; if ch.id is null then raise exception 'Group not found.'; end if;
  if not public.msg_can_manage(ch.team_code) then raise exception 'Only a team admin can export a chat.'; end if;
  return query
  select m.created_at, m.sender_name, m.sender_role, m.sender_label,
    case when m.deleted_at is not null then '' else m.body end,
    (select string_agg(a->>'name', '; ' order by o) from jsonb_array_elements(coalesce(m.attachments,'[]')) with ordinality x(a, o)),
    (select left(coalesce(r.sender_name,'')||': '||coalesce(nullif(r.body,''),'(photo or file)'), 120) from public.msg_messages r where r.id = m.reply_to),
    (select p.question||' — '||coalesce((select string_agg((o.v #>> '{}')||' '||coalesce(c.n,0), ' · ' order by o.i)
        from jsonb_array_elements(p.options) with ordinality o(v, i)
        left join (select v.choice, count(*)::int n from public.msg_poll_votes v where v.poll_id = p.id group by v.choice) c on c.choice = o.i - 1), '')
        ||case when p.anonymous then ' (anonymous)' else '' end
      from public.msg_polls p where p.message_id = m.id),
    m.deleted_at is not null
  from public.msg_messages m
  where m.channel_id = p_channel
  order by m.created_at;
end $$;
revoke all on function public.msg_export(uuid) from public, anon;
grant execute on function public.msg_export(uuid) to authenticated;
