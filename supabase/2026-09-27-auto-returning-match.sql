-- 2026-09-27: returning athletes are recognized AUTOMATICALLY from the athlete section of the form
-- (first name + last name + date of birth). No picking or re-typing.
--   * find_athlete_record(): exact first + last + DOB match against last season's verified records.
--     Returns only record id, team, division and season. Callable from the public form.
--   * reg_returning_verify(): if the registration isn't linked yet, the database links it itself to a
--     verified record ON THE SAME TEAM with the same first name, last name and birth date, and marks it
--     returning. Then the existing rules apply (same team + match -> no proof; transfer -> new athlete + proof).
begin;

create or replace function public.find_athlete_record(p_first text, p_last text, p_dob date)
returns table (id uuid, team_code text, division text, season_year integer)
language sql stable security definer set search_path to 'public' as $$
  select r.id, r.team_code, r.division, r.season_year
  from public.registrations r
  where p_dob is not null
    and length(public.name_key(p_first)) >= 1 and length(public.name_key(p_last)) >= 2
    and r.status = 'verified'
    and r.season_year < coalesce((select nullif(value,'')::int from public.app_settings where key = 'season_year'), extract(year from now())::int + 1)
    and r.dob = p_dob
    and public.name_key(r.first_name) = public.name_key(p_first)
    and public.name_key(r.last_name) = public.name_key(p_last)
  order by r.season_year desc, r.created_at desc
  limit 5
$$;
revoke all on function public.find_athlete_record(text,text,date) from public;
grant execute on function public.find_athlete_record(text,text,date) to anon, authenticated;

create or replace function public.reg_returning_verify() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare p record; auto_id uuid;
begin
  -- Auto-link: same team, same first + last name + birth date, verified in an earlier season.
  if new.prior_registration_id is null then
    select r.id into auto_id from public.registrations r
     where r.status = 'verified' and r.team_code = new.team_code and r.dob = new.dob
       and r.season_year < coalesce(new.season_year, 9999)
       and public.name_key(r.first_name) = public.name_key(new.first_name)
       and public.name_key(r.last_name) = public.name_key(new.last_name)
     order by r.season_year desc, r.created_at desc limit 1;
    if auto_id is not null then new.prior_registration_id := auto_id; new.is_returning := true; end if;
  end if;

  -- A transfer (declared prior team, or linked record on another team) is a NEW athlete to this team.
  if (new.prior_team_code is not null and new.prior_team_code is distinct from new.team_code)
     or exists (select 1 from public.registrations x where x.id = new.prior_registration_id and x.team_code is distinct from new.team_code) then
    new.is_returning := false;
    if coalesce(trim(new.proof_path),'') = '' then
      raise exception 'This athlete was on a different team last season, so they count as a new athlete to this team. Please upload proof of birth.';
    end if;
  end if;
  if coalesce(trim(new.proof_path),'') <> '' then return new; end if;
  if new.prior_registration_id is null and exists (
       select 1 from public.registrations r where r.status = 'verified' and r.dob = new.dob and r.team_code is distinct from new.team_code
          and public.name_key(r.first_name) = public.name_key(new.first_name) and public.name_key(r.last_name) = public.name_key(new.last_name)) then
    raise exception 'This athlete was on a different team last season, so they count as a new athlete to this team. Please upload proof of birth.';
  end if;
  if not coalesce(new.is_returning,false) or new.prior_registration_id is null then
    raise exception 'Please upload proof of birth. (Only returning athletes whose name and birth date match last season''s records can skip it.)';
  end if;
  select * into p from public.registrations where id = new.prior_registration_id;
  if p.id is null or p.status <> 'verified' then
    raise exception 'We could not find a verified record for this returning athlete. Please upload proof of birth.';
  end if;
  if public.name_key(p.first_name) <> public.name_key(new.first_name)
     or public.name_key(p.last_name) <> public.name_key(new.last_name) then
    raise exception 'The athlete''s name doesn''t match last season''s record. Please upload proof of birth.';
  end if;
  if p.team_code is distinct from new.team_code then
    raise exception 'This athlete was on a different team last season, so they count as a new athlete to this team. Please upload proof of birth.';
  end if;
  if p.dob is distinct from new.dob then
    raise exception 'The birth date doesn''t match last season''s record for this athlete. Check the date, or upload proof of birth.';
  end if;
  new.proof_path := null;
  new.dob_check_status := 'match';
  new.dob_check_note := 'Returning athlete: name and birth date match the verified ' || coalesce(p.season_year::text,'prior') || ' record (' || coalesce(p.team_code,'') || '). No proof of birth needed.';
  return new;
end $$;

commit;
