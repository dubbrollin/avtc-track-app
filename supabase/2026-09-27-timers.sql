-- 2026-09-27: Timers + results upload is admin/timer only.
--   * New role_type 'timer'. An approved timer can ONLY upload results to existing meets
--     (insert into results). No rosters, no entries, no meets, no postseason, no coach dashboard.
--   * Uploading results: site admins, team admins, approved timers. Fixing/deleting results:
--     site admins and team admins only. Regular coaches (head/division/field event) can no longer upload.
--   * Timers register on their own tab; a site admin or that team's team admin approves them.
begin;

alter table public.coaches drop constraint if exists coaches_role_type_check;
alter table public.coaches add constraint coaches_role_type_check
  check (role_type is null or role_type in ('head_age_group','head_coach','division_coach','event_specialist','team_staff','timer'));

-- Timers are not coaches: keep them out of every coach permission.
create or replace function public.is_coach() returns boolean
language sql stable as $$
  select exists (
    select 1 from public.coaches c
    where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
      and c.approved = true
      and c.role_type is distinct from 'timer'
  );
$$;

create or replace function public.can_manage_athlete(reg uuid) returns boolean
language sql stable security definer as $$
  select exists (
    select 1 from public.registrations r
    where r.id = reg and (
      lower(r.email) = lower(coalesce(auth.jwt()->>'email',''))
      or exists (
        select 1 from public.coaches c
        where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
          and c.approved = true
          and c.role_type is distinct from 'timer'
          and (c.is_admin or c.team_code = r.team_code)
      )
    )
  );
$$;

create or replace function public.team_roster()
returns table(id uuid, team_code text, first_name text, last_name text, gender text, division text, sport text, status text, age_on_dec31 integer, created_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select r.id, r.team_code, r.first_name, r.last_name, r.gender, r.division, r.sport, r.status, r.age_on_dec31, r.created_at
  from public.registrations r
  join public.coaches c on lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
  where c.approved = true
    and c.role_type is distinct from 'timer'
    and (c.is_admin or r.team_code = c.team_code)
    and (c.is_admin or c.role_type is distinct from 'division_coach'
         or coalesce(c.division_or_age_group,'') ilike 'all%'
         or ( r.division = any(string_to_array(replace(coalesce(c.division_or_age_group,''),', ',','),','))
              and ( c.coach_gender is null
                    or (case r.gender when 'Boy' then 'Boys' when 'Girl' then 'Girls' end)
                       = any(string_to_array(replace(c.coach_gender,', ',','),',')) ) ) )
$$;

create or replace function public.is_timer() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.coaches c
    where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
      and c.approved is true and c.role_type = 'timer')
$$;

create or replace function public.can_upload_results() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.is_site_admin() or public.is_team_admin() or public.is_timer()
$$;

-- results: upload = admins + timers; fix/delete = admins only (site admin already has "site admin all").
drop policy if exists "coaches manage results" on public.results;
drop policy if exists "uploaders add results" on public.results;
drop policy if exists "team admins fix results" on public.results;
drop policy if exists "team admins delete results" on public.results;
create policy "uploaders add results" on public.results for insert to authenticated
  with check (public.can_upload_results());
create policy "team admins fix results" on public.results for update to authenticated
  using (public.is_team_admin()) with check (public.is_team_admin());
create policy "team admins delete results" on public.results for delete to authenticated
  using (public.is_team_admin());

-- Athlete list used ONLY to match uploaded results to athletes: name, gender, division, team. Admins + timers.
create or replace function public.results_athletes()
returns table(id uuid, first_name text, last_name text, gender text, division text, team_code text)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.can_upload_results() then raise exception 'Only admins and approved timers can upload results.'; end if;
  return query select r.id, r.first_name, r.last_name, r.gender, r.division, r.team_code
    from public.registrations r where r.status = 'verified' order by r.last_name, r.first_name;
end $$;
revoke all on function public.results_athletes() from public;
grant execute on function public.results_athletes() to authenticated;

-- Timer sign-up (signed-in route; the password route inserts the same pending row directly).
create or replace function public.submit_timer_request(p_first text, p_last text, p_phone text, p_team text, p_contract boolean default false)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_email text := coalesce(auth.jwt()->>'email','');
begin
  if v_email = '' then raise exception 'Please sign in first.'; end if;
  if coalesce(trim(p_first),'') = '' or coalesce(trim(p_last),'') = '' or coalesce(trim(p_team),'') = '' then
    raise exception 'Name and team are required.'; end if;
  if exists (select 1 from public.coaches where lower(email) = lower(v_email)) then
    raise exception 'You already have a registration on file with this email. Ask your site admin to update it.'; end if;
  insert into public.coaches (email, first_name, last_name, phone, team_code, role_type, contract_signed_at, contract_version, approved, season_year)
  values (v_email, trim(p_first), trim(p_last), trim(p_phone), trim(p_team), 'timer',
    case when p_contract then now() end, case when p_contract then 'VYC-2026' end, false,
    coalesce((select nullif(value,'')::int from public.app_settings where key = 'season_year'), 2027));
end $$;
revoke all on function public.submit_timer_request(text,text,text,text,boolean) from public;
grant execute on function public.submit_timer_request(text,text,text,text,boolean) to authenticated;

commit;
