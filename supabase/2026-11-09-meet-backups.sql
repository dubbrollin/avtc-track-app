-- Meet Manager backups (2026-11-09).
--   When a meet's results go up, the uploader (site admin, team admin or timer) also uploads the Meet Manager backup
--   (the .zip from Meet Manager's File > Backup). Every team at that meet — host and visitors — can then download it
--   for their own files from the Coach Dashboard's "Our schedule" box or the Meet Admin page.
--   Files live in the PRIVATE storage bucket meet-backups at <meet id>/<time>-<file name>; this table lists them.
--   Who can download: site admins, timers, and approved coaches / team admins whose team is at that meet
--   (the host, a team in team_codes, or any team when the meet has no team list — Invitational, League, IEC).
--   Parents can't. Uploads are add-only; site admins can remove one uploaded by mistake.
begin;

create table if not exists public.meet_backups (
  id uuid primary key default gen_random_uuid(),
  meet_id uuid not null references public.meets(id) on delete cascade,
  path text not null unique,
  file_name text not null,
  size_bytes bigint,
  uploaded_at timestamptz not null default now(),
  uploaded_by text not null default lower(coalesce(auth.jwt()->>'email',''))
);
create index if not exists meet_backups_meet_idx on public.meet_backups (meet_id, uploaded_at desc);

-- Is the signed-in person allowed to download this meet's backup?
create or replace function public.can_get_meet_backup(p_meet uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.is_site_admin() or public.is_timer() or exists (
    select 1 from public.coaches c join public.meets m on m.id = p_meet
    where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
      and c.approved is true and c.role_type is distinct from 'timer' and c.team_code is not null
      and ( c.team_code = m.host_team_code
         or c.team_code = any(coalesce(m.team_codes,'{}'))
         or coalesce(array_length(m.team_codes,1),0) = 0 ))
$$;
grant execute on function public.can_get_meet_backup(uuid) to authenticated;

-- The meet id is the first folder of the file's path; anything that isn't a meet id gets no access.
create or replace function public.meet_backup_meet(p_name text) returns uuid
language sql immutable as $$
  select case when split_part(p_name,'/',1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then split_part(p_name,'/',1)::uuid end
$$;

alter table public.meet_backups enable row level security;
drop policy if exists "meet teams read backups" on public.meet_backups;
create policy "meet teams read backups" on public.meet_backups for select to authenticated
  using (public.can_get_meet_backup(meet_id));
drop policy if exists "uploaders add backups" on public.meet_backups;
create policy "uploaders add backups" on public.meet_backups for insert to authenticated
  with check (public.can_upload_results() and uploaded_by = lower(coalesce(auth.jwt()->>'email',''))
              and public.meet_backup_meet(path) = meet_id);
drop policy if exists "site admins remove backups" on public.meet_backups;
create policy "site admins remove backups" on public.meet_backups for delete to authenticated
  using (public.is_site_admin());
revoke all on public.meet_backups from anon;
revoke all on public.meet_backups from authenticated;
grant select, insert, delete on public.meet_backups to authenticated;

-- Private bucket, up to 50 MB per file (Meet Manager backups are usually well under 5 MB).
insert into storage.buckets (id, name, public, file_size_limit)
values ('meet-backups', 'meet-backups', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

drop policy if exists "meet backups read" on storage.objects;
create policy "meet backups read" on storage.objects for select to authenticated
  using (bucket_id = 'meet-backups' and public.meet_backup_meet(name) is not null
         and public.can_get_meet_backup(public.meet_backup_meet(name)));
drop policy if exists "meet backups add" on storage.objects;
create policy "meet backups add" on storage.objects for insert to authenticated
  with check (bucket_id = 'meet-backups' and public.can_upload_results()
              and exists (select 1 from public.meets m where m.id = public.meet_backup_meet(storage.objects.name)));
drop policy if exists "meet backups remove" on storage.objects;
create policy "meet backups remove" on storage.objects for delete to authenticated
  using (bucket_id = 'meet-backups' and public.is_site_admin());

commit;
