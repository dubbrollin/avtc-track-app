-- 2026-09-27: auto-fill a returning athlete's registration from their last verified record.
-- Found by exact first + last name + birth date (the parent types those).
--   * Always returned: gender, division, team (not sensitive once the parent knows name + birth date).
--   * Family/contact details (address, phones, email, emergency contact, parents, insurance, doctor) are
--     returned ONLY when p_contact matches the phone or email on that record, so strangers can't read a
--     child's home address. Placeholder data (roster imports) is never returned; has_contact tells the form
--     whether real details exist. Medical conditions are never returned (declared fresh every season).
begin;

create or replace function public.returning_details(p_first text, p_last text, p_dob date, p_contact text default null)
returns json language plpgsql stable security definer set search_path to 'public' as $$
declare r record; real_contact boolean; ok boolean := false; digits text := regexp_replace(coalesce(p_contact,''), '\D', '', 'g');
begin
  if p_dob is null or length(public.name_key(p_first)) < 1 or length(public.name_key(p_last)) < 2 then return null; end if;
  select * into r from public.registrations x
   where x.status = 'verified' and x.dob = p_dob
     and x.season_year < public.current_season()
     and public.name_key(x.first_name) = public.name_key(p_first)
     and public.name_key(x.last_name) = public.name_key(p_last)
   order by x.season_year desc, x.created_at desc limit 1;
  if r.id is null then return null; end if;
  real_contact := coalesce(r.address,'') !~* '^roster import' and coalesce(r.email,'') !~* 'example\.invalid$'
                  and regexp_replace(coalesce(r.phone,''), '\D', '', 'g') !~ '^0*$' and coalesce(r.phone,'') !~ '555-01';
  if real_contact and coalesce(trim(p_contact),'') <> '' then
    ok := (length(digits) >= 7 and right(regexp_replace(coalesce(r.phone,''), '\D', '', 'g'), 10) = right(digits, 10))
       or lower(trim(p_contact)) = lower(trim(coalesce(r.email,'')));
  end if;
  return json_build_object(
    'gender', r.gender, 'division', r.division, 'team_code', r.team_code, 'season_year', r.season_year,
    'has_contact', real_contact, 'contact_ok', ok,
    'details', case when ok then json_build_object(
      'address', r.address, 'city', r.city, 'zip', r.zip, 'phone', r.phone, 'email', r.email,
      'emergency_name', r.emergency_name, 'emergency_phone', r.emergency_phone,
      'parent1_name', r.parent1_name, 'parent1_relationship', r.parent1_relationship,
      'parent2_name', r.parent2_name, 'parent2_relationship', r.parent2_relationship,
      'insurance_carrier', r.insurance_carrier, 'doctor_name', r.doctor_name) end);
end $$;
revoke all on function public.returning_details(text,text,date,text) from public;
grant execute on function public.returning_details(text,text,date,text) to anon, authenticated;

commit;
