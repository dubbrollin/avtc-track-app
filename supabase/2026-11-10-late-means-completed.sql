-- 2026-11-10: Late = COMPLETED after the certification date.
-- A registration counts as on time only if it is fully completed (all documents uploaded and both
-- signatures done — the form will not submit without them) on or before the certification date.
-- Starting early, or a team importing the athlete early, does not count. This puts back the plain rule:
-- the late check uses the moment the registration is submitted, with no exception for imported athletes.
begin;
create or replace function public.reg_late_check()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare s integer := coalesce(new.season_year, public.current_season());
  cd date := public.certification_date(coalesce(new.season_year, public.current_season()));
  cutoff date; today date := (now() at time zone 'America/Los_Angeles')::date; p record;
begin
  new.late_pass_id := null;
  if cd is null or today <= cd then new.is_late := false; return new; end if;
  new.is_late := true;
  cutoff := public.late_cutoff(s);
  if today > cutoff then
    select * into p from public.late_registration_passes x
     where x.season_year = s and x.team_code = new.team_code and x.status = 'approved'
       and not x.revoked and x.used_registration_id is null and x.expires_on >= today
       and public.name_key(x.athlete_first) = public.name_key(new.first_name)
       and public.name_key(x.athlete_last) = public.name_key(new.last_name)
     order by x.created_at limit 1 for update;
    if p.id is null then
      raise exception 'Registration for the % season closed on % (athletes may be added until the 2nd meet). A late addition needs a late pass requested by your Conference President and approved by the Commissioner — ask your team admin.',
        s, to_char(cutoff, 'FMMonth FMDD, YYYY');
    end if;
    new.late_pass_id := p.id;
  end if;
  return new;
end $$;
commit;
notify pgrst, 'reload schema';
