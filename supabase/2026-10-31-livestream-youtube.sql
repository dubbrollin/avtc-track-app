-- ============================================================================
-- Livestream — free YouTube option (2026-10-31, addendum to 2026-10-31-livestream.sql)
-- A second, FREE way to broadcast: the person streams to their own YouTube Live (phone app or OBS,
-- using YouTube's own stream key in YouTube Studio), then pastes the YouTube link into the app. The app
-- embeds that video, shown only to team members. No Cloudflare, no ingest key stored by us, no per-minute
-- cost. Trade-off: an unlisted YouTube link is weaker privacy than Cloudflare's signed, per-user URLs.
-- Everything else (who can broadcast / watch, the switch, listing) is unchanged from the base migration.
-- ============================================================================

-- Create a YouTube-backed stream. p_youtube_id is the 11-char video id (the app strips it from a pasted
-- youtube.com / youtu.be / live link before calling this). Goes straight to 'live' since YouTube runs its
-- own lifecycle; the broadcaster ends it with live_set_status(..., 'ended').
create or replace function public.live_create_youtube(p_team text, p_title text, p_youtube_id text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if not public.live_enabled(p_team) then raise exception 'Livestream is not enabled for this team.'; end if;
  if not public.live_can_broadcast(p_team) then raise exception 'You do not have permission to broadcast for this team.'; end if;
  if coalesce(trim(p_youtube_id),'') !~ '^[A-Za-z0-9_-]{11}$' then
    raise exception 'That does not look like a YouTube video link.'; end if;
  insert into public.live_streams(team_code, title, status, provider, provider_uid, playback_id, require_signed_url, created_by)
    values (p_team, coalesce(nullif(trim(p_title),''),'Live'), 'live', 'youtube', p_youtube_id, p_youtube_id, false, public.live_me())
    returning id into v_id;
  return v_id;
end $$;
grant execute on function public.live_create_youtube(text, text, text) to authenticated;
