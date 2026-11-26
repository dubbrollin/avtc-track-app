-- ============================================================================
-- Live field marks (2026-11-26, Riley: "as they enter them, they also go as part of the live results").
-- Field event marks typed at the pit on staging.html (table field_marks) show on the Results page's live meet view right
-- away, labelled "live from the field" and unofficial. The Results page drops them for an event as soon as Meet Manager's
-- official results for that event (same event code, division and gender) are posted, so nothing shows twice.
-- Read-only and public, like results: name, team, division, best mark and attempts only.
-- ============================================================================
begin;

create or replace function public.live_field_marks(p_meet uuid)
returns table(registration_id uuid, athlete_name text, team_code text, division text, gender text, event_code text, event_name text,
              mark text, mark_value numeric, attempts jsonb, created_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select f.registration_id, r.first_name || ' ' || r.last_name, r.team_code, f.division, f.gender, f.event_code,
         case f.event_code when 'LJ' then 'Long Jump' when 'HJ' then 'High Jump' when 'SP' then 'Shot Put' when 'JT' then 'Javelin Throw' else f.event_code end,
         f.best_mark, f.best_value, f.attempts, f.updated_at
    from public.field_marks f
    join public.registrations r on r.id = f.registration_id
   where f.meet_id = p_meet and f.checked_in and jsonb_array_length(coalesce(f.attempts,'[]'::jsonb)) > 0
$$;
revoke all on function public.live_field_marks(uuid) from public;
grant execute on function public.live_field_marks(uuid) to anon, authenticated;

notify pgrst, 'reload schema';
commit;
