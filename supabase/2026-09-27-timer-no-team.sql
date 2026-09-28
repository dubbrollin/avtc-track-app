-- 2026-09-27: timers work across teams, so the sign-up no longer asks for a team (team_code stays empty).
-- Approval is by a site admin. An approved timer can download entries / upload results for ANY current meet
-- (can_upload_results() never looked at the team).
begin;

create or replace function public.submit_timer_request(p_first text, p_last text, p_phone text, p_team text default null, p_contract boolean default false)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_email text := coalesce(auth.jwt()->>'email','');
begin
  if v_email = '' then raise exception 'Please sign in first.'; end if;
  if coalesce(trim(p_first),'') = '' or coalesce(trim(p_last),'') = '' then raise exception 'First and last name are required.'; end if;
  if exists (select 1 from public.coaches where lower(email) = lower(v_email)) then
    raise exception 'You already have a registration on file with this email. Ask your site admin to update it.'; end if;
  insert into public.coaches (email, first_name, last_name, phone, team_code, role_type, contract_signed_at, contract_version, approved, season_year)
  values (v_email, trim(p_first), trim(p_last), trim(p_phone), nullif(trim(coalesce(p_team,'')),''), 'timer',
    case when p_contract then now() end, case when p_contract then 'VYC-2026' end, false, public.current_season());
end $$;

commit;
