-- 2026-09-27: returning athletes don't upload proof of birth; they're verified against the system instead.
-- A registration may skip proof of birth ONLY if it is marked returning AND linked (prior_registration_id)
-- to a VERIFIED earlier registration ON THE SAME TEAM with the same first name, last name and birth date.
-- Transfers (record on another team) are new athletes to the new team and must upload proof. Anything else
-- without proof is refused. A qualifying registration's birth-date check is marked 'match' with a note.
begin;

alter table public.registrations alter column proof_path drop not null;

create or replace function public.reg_returning_verify() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare p record;
begin
  if coalesce(trim(new.proof_path),'') <> '' then return new; end if;
  if not coalesce(new.is_returning,false) or new.prior_registration_id is null then
    raise exception 'Please upload proof of birth. (Only returning athletes matched to last season''s records can skip it.)';
  end if;
  select * into p from public.registrations where id = new.prior_registration_id;
  if p.id is null or p.status <> 'verified' then
    raise exception 'We could not find a verified record for this returning athlete. Please upload proof of birth.';
  end if;
  if public.name_key(p.first_name) <> public.name_key(new.first_name)
     or public.name_key(p.last_name) <> public.name_key(new.last_name) then
    raise exception 'The athlete''s name doesn''t match last season''s record. Please upload proof of birth.';
  end if;
  -- A transfer is a new athlete to the new team: proof of birth is required even if verified elsewhere.
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
drop trigger if exists reg_returning_verify_trg on public.registrations;
create trigger reg_returning_verify_trg before insert on public.registrations
  for each row execute function public.reg_returning_verify();

commit;
