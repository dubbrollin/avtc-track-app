-- Fix: Meet Manager backup uploads were always refused ("new row violates row-level security policy") (2026-11-10).
--   The storage insert rule in 2026-11-09-meet-backups.sql checked
--     exists (select 1 from public.meets m where m.id = public.meet_backup_meet(name))
--   but inside that sub-select "name" is the MEET's name column (meets has one), not the uploaded file's path, so the
--   meet was never found. The rule now names storage.objects.name explicitly.
begin;

drop policy if exists "meet backups add" on storage.objects;
create policy "meet backups add" on storage.objects for insert to authenticated
  with check (bucket_id = 'meet-backups' and public.can_upload_results()
              and exists (select 1 from public.meets m where m.id = public.meet_backup_meet(storage.objects.name)));

commit;
