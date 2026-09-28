-- 2026-09-27: USATF Coaches Registry verification for coaches who say they're USATF certified.
-- The usatf-verify edge function searches USATF's public Coaches Registry (usatf.sport80.com) by the coach's
-- name (California first, then nationwide) and records what it found here.
--   usatf_registry_status: 'verified' (on the registry, status Current) | 'not_current' (on it, not Current)
--                          | 'not_found' | 'error'
begin;
alter table public.coaches add column if not exists usatf_registry_status text;
alter table public.coaches add column if not exists usatf_registry_checked_at timestamptz;
alter table public.coaches add column if not exists usatf_registry_detail jsonb;
commit;
