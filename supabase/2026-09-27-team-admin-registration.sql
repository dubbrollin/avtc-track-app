-- 2026-09-27: "Team Admin" tab on the registration page.
-- A person asks to be a team admin for one team. It lands in coaches as a pending request
-- (requested_team_admin = true, approved = false, team_admin = false). A site admin, or an existing
-- team admin of that team, approves it, which is what actually grants team_admin.
-- Non-coaching admins (president, registrar...) get role_type 'team_staff'.
begin;

alter table public.coaches add column if not exists requested_team_admin boolean not null default false;
alter table public.coaches add column if not exists admin_title text;

alter table public.coaches drop constraint if exists coaches_role_type_check;
alter table public.coaches add constraint coaches_role_type_check
  check (role_type is null or role_type in ('head_age_group','head_coach','division_coach','event_specialist','team_staff'));

create or replace function public.submit_team_admin_request(
  p_first text, p_last text, p_phone text, p_team text, p_title text,
  p_bg_date date default null, p_usatf boolean default false, p_usatf_date date default null, p_contract boolean default false)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_email text := coalesce(auth.jwt()->>'email','');
begin
  if v_email = '' then raise exception 'Please sign in first.'; end if;
  if coalesce(trim(p_first),'') = '' or coalesce(trim(p_last),'') = '' or coalesce(trim(p_team),'') = '' then
    raise exception 'Name and team are required.'; end if;
  if coalesce(trim(p_title),'') = '' then raise exception 'Please choose your role on the team.'; end if;
  if exists (select 1 from public.coaches where lower(email) = lower(v_email)) then
    raise exception 'You already have a coach or team admin request on file. Ask your site admin to update it.'; end if;
  insert into public.coaches (email, first_name, last_name, phone, team_code, role_type, admin_title, requested_team_admin,
    background_check_date, usatf_certified, usatf_cert_date, contract_signed_at, contract_version, approved, season_year)
  values (v_email, trim(p_first), trim(p_last), trim(p_phone), trim(p_team),
    case when p_title = 'Head Coach' then 'head_coach' else 'team_staff' end, trim(p_title), true,
    p_bg_date, coalesce(p_usatf,false), p_usatf_date,
    case when p_contract then now() end, case when p_contract then 'VYC-2026' end, false,
    coalesce((select nullif(value,'')::int from public.app_settings where key = 'season_year'), 2027));
end $$;
revoke all on function public.submit_team_admin_request(text,text,text,text,text,date,boolean,date,boolean) from public;
grant execute on function public.submit_team_admin_request(text,text,text,text,text,date,boolean,date,boolean) to authenticated;

commit;
