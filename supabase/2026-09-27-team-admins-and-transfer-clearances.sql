-- 2026-09-27: Team admins + prior-team fee clearance.
--   * Site admin (coaches.is_admin): everything, every team (unchanged).
--   * Team admin (coaches.team_admin, NEW): full admin power for their own team only.
--   * Everyone else (head / division / field-event coaches): basic coaching only.
--   * Registrations that name a different prior VYC team create a transfer_clearances
--     request the prior team's admins answer (cleared / owes fees).
-- No one loses access: site admins keep everything; Leeza + Justin stay site admins
-- during testing and are ALSO marked team admins, so go-live = just "Remove admin".
begin;

-- ---------- team admin flag ----------
alter table public.coaches add column if not exists team_admin boolean not null default false;
-- Leeza (NPTC) + Justin (BV): stay site admins for testing, also team admins for go-live.
-- (Runs before coaches_guard is replaced below, since the new guard would block it here.)
update public.coaches set team_admin = true
  where lower(email) in ('pacerstrackteam@gmail.com','bvtrackteam@gmail.com');

create or replace function public.is_team_admin_of(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select t is not null and exists (
    select 1 from public.coaches c
    where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
      and c.approved is true and c.team_admin is true and c.team_code = t)
$$;

create or replace function public.is_team_admin() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.coaches c
    where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
      and c.approved is true and c.team_admin is true)
$$;

-- ---------- coaches ----------
alter policy coaches_head_update on public.coaches
  using (public.is_team_admin_of(team_code)) with check (public.is_team_admin_of(team_code));
alter policy coaches_read_scoped on public.coaches
  using (lower(email) = lower(coalesce(auth.jwt()->>'email','')) or public.is_team_admin_of(team_code));
alter policy coaches_register on public.coaches
  with check (coalesce(approved,false) = false and coalesce(is_admin,false) = false and coalesce(team_admin,false) = false);

create or replace function public.coaches_guard() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if public.is_site_admin() then return new; end if;
  if new.is_admin is distinct from old.is_admin then
    raise exception 'Only a site admin can change site-admin access';
  end if;
  if new.team_code is distinct from old.team_code or lower(new.email) is distinct from lower(old.email) then
    raise exception 'Only a site admin can change a coach team or email';
  end if;
  if new.approved is distinct from old.approved
     or new.role_type is distinct from old.role_type
     or new.team_admin is distinct from old.team_admin then
    if lower(old.email) = lower(coalesce(auth.jwt()->>'email',''))
       or not public.is_team_admin_of(old.team_code) then
      raise exception 'Only an admin for this team can approve coaches, change roles, or grant team-admin access (and not for yourself)';
    end if;
  end if;
  return new;
end $$;

-- ---------- registrations: private records = site admins + that team's admins ----------
drop policy if exists "head coaches read full" on public.registrations;
drop policy if exists "head coaches update" on public.registrations;
drop policy if exists "admins read full" on public.registrations;
drop policy if exists "admins update" on public.registrations;
create policy "team admins read full" on public.registrations for select to authenticated
  using (public.is_team_admin_of(team_code));
create policy "team admins update" on public.registrations for update to authenticated
  using (public.is_team_admin_of(team_code)) with check (public.is_team_admin_of(team_code));
create policy "team admins delete" on public.registrations for delete to authenticated
  using (public.is_team_admin_of(team_code));

-- ---------- meets & events: site admins + any team admin ----------
drop policy if exists "head coaches manage meets" on public.meets;
create policy "team admins manage meets" on public.meets for all to authenticated
  using (public.is_team_admin()) with check (public.is_team_admin());
drop policy if exists "head coaches manage events" on public.meet_events;
create policy "team admins manage events" on public.meet_events for all to authenticated
  using (public.is_team_admin()) with check (public.is_team_admin());

-- ---------- prior-team fee clearance ----------
alter table public.registrations add column if not exists prior_team_code text;

create table if not exists public.transfer_clearances (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  registration_id uuid references public.registrations(id) on delete cascade,
  athlete_first text, athlete_last text, dob date, division text,
  from_team text not null,
  to_team text,
  status text not null default 'pending' check (status in ('pending','cleared','owes_fees')),
  note text,
  responded_by text,
  responded_at timestamptz
);
alter table public.transfer_clearances enable row level security;
create policy "site admin all" on public.transfer_clearances for all to authenticated
  using (public.is_site_admin()) with check (public.is_site_admin());
create policy "team admins read clearances" on public.transfer_clearances for select to authenticated
  using (public.is_team_admin_of(from_team) or public.is_team_admin_of(to_team));
create policy "old team answers clearance" on public.transfer_clearances for update to authenticated
  using (public.is_team_admin_of(from_team)) with check (public.is_team_admin_of(from_team));

-- Only the answer (status + note) can change; who/when is stamped automatically.
create or replace function public.clearance_guard() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.registration_id is distinct from old.registration_id or new.from_team is distinct from old.from_team
     or new.to_team is distinct from old.to_team or new.athlete_first is distinct from old.athlete_first
     or new.athlete_last is distinct from old.athlete_last or new.dob is distinct from old.dob then
    raise exception 'Only the clearance answer and note can be changed';
  end if;
  new.responded_by := coalesce(auth.jwt()->>'email', new.responded_by);
  new.responded_at := now();
  return new;
end $$;
drop trigger if exists clearance_guard_trg on public.transfer_clearances;
create trigger clearance_guard_trg before update on public.transfer_clearances
  for each row execute function public.clearance_guard();

-- New registration naming a different prior VYC team -> open a clearance request.
create or replace function public.reg_make_clearance() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.prior_team_code is not null and new.prior_team_code is distinct from new.team_code then
    insert into public.transfer_clearances (registration_id, athlete_first, athlete_last, dob, division, from_team, to_team)
    values (new.id, new.first_name, new.last_name, new.dob, new.division, new.prior_team_code, new.team_code);
  end if;
  return new;
end $$;
drop trigger if exists reg_clearance_trg on public.registrations;
create trigger reg_clearance_trg after insert on public.registrations
  for each row execute function public.reg_make_clearance();

commit;
