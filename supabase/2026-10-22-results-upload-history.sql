-- Results upload history (2026-10-22).
--   A meet's results can be uploaded more than once: the first file from the timing team, then corrected ones after they
--   fix mistakes. The NEWEST upload is always what's posted — the upload itself still goes through replace_meet_results
--   (2026-10-14), which swaps out every event that is in the file. Before saving, the Meet Admin / Timer page compares the
--   file with what's already posted and asks "are you sure?" when posted results would change (different mark or place,
--   or a posted result that isn't in the new file). This table records every file upload — who, when, which file, and
--   what it changed — so admins can see the versions a meet has gone through. confirmed_changes = the uploader was shown
--   the differences and said yes.
--   The live connection (which re-posts every 30 seconds during a meet) is NOT logged here — that would be hundreds of rows.
begin;

create table if not exists public.results_uploads (
  id uuid primary key default gen_random_uuid(),
  meet_id uuid not null references public.meets(id) on delete cascade,
  uploaded_at timestamptz not null default now(),
  uploaded_by text not null default lower(coalesce(auth.jwt()->>'email','')),
  file_name text,
  all_teams boolean not null default true,           -- semicolon file with every team (true) or one team's .tcl file (false)
  rows_in_file int not null default 0,
  added int not null default 0,                      -- results that were not posted before
  changed int not null default 0,                    -- posted results whose mark / place changed
  removed int not null default 0,                    -- posted results (in the file's events) that the new file no longer has
  unchanged int not null default 0,
  confirmed_changes boolean not null default false,  -- the uploader saw the differences and said "yes, replace"
  changes jsonb                                      -- up to 200 of the changed/removed results: {event, athlete, from, to}
);
create index if not exists results_uploads_meet_idx on public.results_uploads (meet_id, uploaded_at desc);

alter table public.results_uploads enable row level security;
-- Anyone signed in can see a meet's upload history (results themselves are public); only uploaders can add to it,
-- and only as themselves.
drop policy if exists "signed in read upload history" on public.results_uploads;
create policy "signed in read upload history" on public.results_uploads for select to authenticated using (true);
drop policy if exists "uploaders log uploads" on public.results_uploads;
create policy "uploaders log uploads" on public.results_uploads for insert to authenticated
  with check (public.can_upload_results() and uploaded_by = lower(coalesce(auth.jwt()->>'email','')));
revoke all on public.results_uploads from anon;
grant select, insert on public.results_uploads to authenticated;

commit;
