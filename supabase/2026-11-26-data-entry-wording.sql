-- 2026-11-26 (Riley): the people on staging.html are "data entry" (at staging and at each field event), not "staging helpers".
-- Wording only. The table keeps its name (public.staging_helpers).
begin;
create or replace function public.stage_guard() returns void
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.can_stage() then raise exception 'Only admins, timers and data entry people can use Meet Day Staging.'; end if;
end $$;
comment on table public.staging_helpers is 'Data entry people for Meet Day Staging (staging area and field events). Page-only access; not coaches.';
notify pgrst, 'reload schema';
commit;
