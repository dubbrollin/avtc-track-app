-- No results typed in by hand (Riley, 2026-11-10): the league only allows results that come from Meet Manager —
-- the backup, a results file, or the live connection. All of those post through replace_meet_results (a checked
-- server function), so uploaders no longer need to add or edit single result rows directly.
--   * "uploaders add results" (insert) and "team admins fix results" (update) are removed.
--   * Team admins can still delete a meet's results (the "Delete all results for this meet" button), and site admins
--     keep their full access for repairs.
--   There were no hand-typed results (source 'manual') in the database when this was applied.
begin;

drop policy if exists "uploaders add results" on public.results;
drop policy if exists "team admins fix results" on public.results;

commit;
