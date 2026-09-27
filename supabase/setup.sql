-- Run this ONCE in Supabase: SQL Editor > New query > paste > Run
-- Creates the registrations table, the private file bucket, the coach list, and the security rules.

create table if not exists public.registrations (
  id uuid primary key,
  created_at timestamptz not null default now(),
  season_year int not null,
  sport text not null check (sport in ('Track & Field','Cross Country')),
  gender text not null check (gender in ('Boy','Girl')),
  dob date not null,
  age_on_dec31 int not null check (age_on_dec31 between 5 and 18),
  division text not null,
  first_name text not null,
  last_name text not null,
  address text not null,
  city text not null,
  zip text not null,
  phone text not null,
  email text not null,
  emergency_name text not null,
  emergency_phone text not null,
  is_returning boolean not null default false,
  ran_for_other_team boolean not null default false,
  prior_team text,
  insurance_carrier text,
  insurance_policy text,
  insurance_employer text,
  medical_option text not null check (medical_option in ('clear','conditions')),
  medical_conditions text,
  doctor_name text,
  doctor_date date,
  parent_name text not null,
  athlete_signature text not null,          -- PNG data URL
  athlete_signature_method text not null,   -- drawn | typed
  parent_signature text not null,
  parent_signature_method text not null,
  proof_path text not null,                 -- path inside proof-of-birth bucket
  -- automatic ID check
  dob_check_status text not null default 'pending' check (dob_check_status in ('pending','match','mismatch','unreadable','error')),
  dob_extracted date,
  name_extracted text,
  dob_check_note text,
  dob_checked_at timestamptz,
  -- coach review
  status text not null default 'submitted' check (status in ('submitted','verified','rejected','archived')),
  verified_by text,
  verified_at timestamptz,
  coach_note text
);

-- Coaches allowed into the dashboard. Add each coach's email here (they log in with a magic link).
create table if not exists public.coaches (
  email text primary key,
  name text
);

alter table public.registrations enable row level security;
alter table public.coaches enable row level security;

create or replace function public.is_coach() returns boolean
language sql stable security invoker as $$
  select exists (select 1 from public.coaches c where lower(c.email) = lower(coalesce(auth.jwt()->>'email','')));
$$;

-- Parents (not logged in) may ONLY add a registration. They can never read any.
drop policy if exists "parents can submit" on public.registrations;
create policy "parents can submit" on public.registrations
  for insert to anon with check (true);

-- Coaches can read and update everything.
drop policy if exists "coaches read" on public.registrations;
create policy "coaches read" on public.registrations for select to authenticated using (public.is_coach());
drop policy if exists "coaches update" on public.registrations;
create policy "coaches update" on public.registrations for update to authenticated using (public.is_coach()) with check (public.is_coach());

-- coaches table: a logged-in coach may see the coach list (needed for is_coach to work for them)
drop policy if exists "coaches see coaches" on public.coaches;
create policy "coaches see coaches" on public.coaches for select to authenticated using (lower(email) = lower(coalesce(auth.jwt()->>'email','')));

-- Private file bucket for birth certificates / IDs
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proof-of-birth','proof-of-birth', false, 15728640, array['image/jpeg','image/png','image/webp','image/heic','application/pdf'])
on conflict (id) do nothing;

drop policy if exists "parents upload proof" on storage.objects;
create policy "parents upload proof" on storage.objects
  for insert to anon with check (bucket_id = 'proof-of-birth');
drop policy if exists "coaches view proof" on storage.objects;
create policy "coaches view proof" on storage.objects
  for select to authenticated using (bucket_id = 'proof-of-birth' and public.is_coach());

-- ==== ADD YOUR COACHES HERE (edit the email, run again if you add more) ====
-- insert into public.coaches (email, name) values ('you@example.com', 'Riley') on conflict do nothing;
