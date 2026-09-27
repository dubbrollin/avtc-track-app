-- 2026-09-27: catch undeclared transfers.
-- Every new registration is compared to registrations on OTHER teams: same birth date AND same
-- first or last name (ignoring case, spaces, punctuation). A match the parent didn't declare opens
-- a "possible transfer" request (flagged = true) that the matching team must answer:
--   same athlete, OK to transfer (cleared) / same athlete, issue (owes_fees) / not the same athlete (not_same).
begin;

alter table public.transfer_clearances add column if not exists flagged boolean not null default false;
alter table public.transfer_clearances add column if not exists match_registration_id uuid references public.registrations(id) on delete set null;
alter table public.transfer_clearances drop constraint if exists transfer_clearances_status_check;
alter table public.transfer_clearances add constraint transfer_clearances_status_check
  check (status in ('pending','cleared','owes_fees','not_same'));

create or replace function public.name_key(s text) returns text
language sql immutable as $$ select regexp_replace(lower(coalesce(s,'')), '[^a-z]', '', 'g') $$;

create or replace function public.reg_make_clearance() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare m record;
begin
  -- Declared by the parent.
  if new.prior_team_code is not null and new.prior_team_code is distinct from new.team_code then
    insert into public.transfer_clearances (registration_id, athlete_first, athlete_last, dob, division, from_team, to_team)
    values (new.id, new.first_name, new.last_name, new.dob, new.division, new.prior_team_code, new.team_code);
  end if;
  -- Not declared: look for the same athlete on another team (one request per team found).
  for m in
    select distinct on (r.team_code) r.id, r.team_code
    from public.registrations r
    where r.id <> new.id
      and r.team_code is not null and r.team_code is distinct from new.team_code
      and r.team_code is distinct from new.prior_team_code
      and r.dob = new.dob
      and (public.name_key(r.last_name) = public.name_key(new.last_name)
           or public.name_key(r.first_name) = public.name_key(new.first_name))
    order by r.team_code, r.season_year desc nulls last, r.created_at desc
  loop
    insert into public.transfer_clearances (registration_id, athlete_first, athlete_last, dob, division, from_team, to_team, flagged, match_registration_id)
    values (new.id, new.first_name, new.last_name, new.dob, new.division, m.team_code, new.team_code, true, m.id);
  end loop;
  return new;
end $$;

commit;
