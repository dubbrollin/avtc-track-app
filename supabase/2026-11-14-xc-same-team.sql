-- Cross country proof of birth now follows the same rule as track:
-- skip it only when the name + birth date match a verified VYC registration (track or cross country) on the SAME team.
-- An athlete moving to a different team counts as new to that team and uploads proof.

create or replace function public.reg_xc_verify()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare p record;
begin
  if coalesce(trim(new.proof_path),'') <> '' then return new; end if;
  select r.* into p from public.registrations r
   where r.id <> new.id and r.status = 'verified' and r.dob = new.dob and r.team_code = new.team_code
     and public.name_key(r.first_name) = public.name_key(new.first_name)
     and public.name_key(r.last_name) = public.name_key(new.last_name)
   order by r.season_year desc, r.created_at desc limit 1;
  if p.id is null then
    if exists (select 1 from public.registrations r
                where r.status = 'verified' and r.dob = new.dob and r.team_code is distinct from new.team_code
                  and public.name_key(r.first_name) = public.name_key(new.first_name)
                  and public.name_key(r.last_name) = public.name_key(new.last_name)) then
      raise exception 'This athlete was on a different team, so they count as a new athlete to this team. Please upload proof of birth.';
    end if;
    raise exception 'Please upload proof of birth. (Only returning athletes whose name and birth date match a verified VYC record on this team can skip it.)';
  end if;
  new.proof_path := null;
  new.dob_check_status := 'match';
  new.dob_check_note := 'Returning athlete: name and birth date match the verified ' || coalesce(p.season_year::text,'') || ' ' || coalesce(p.sport,'') ||
                        ' record (' || coalesce(p.team_code,'') || '). No proof of birth needed.';
  return new;
end $$;

-- The form asks this as the name, birth date and team are filled in: true = no proof of birth needed (yes/no only).
drop function if exists public.xc_birth_verified(text,text,date);
create or replace function public.xc_birth_verified(p_first text, p_last text, p_dob date, p_team text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select p_dob is not null and coalesce(p_team,'') <> '' and length(public.name_key(p_first)) >= 1 and length(public.name_key(p_last)) >= 2
     and exists (select 1 from public.registrations r where r.status = 'verified' and r.dob = p_dob and r.team_code = p_team
                  and public.name_key(r.first_name) = public.name_key(p_first) and public.name_key(r.last_name) = public.name_key(p_last))
$$;
revoke all on function public.xc_birth_verified(text,text,date,text) from public;
grant execute on function public.xc_birth_verified(text,text,date,text) to authenticated;

notify pgrst, 'reload schema';
select 'xc same-team rule: ' || count(*) from pg_proc where proname = 'xc_birth_verified' and pronargs = 4;
