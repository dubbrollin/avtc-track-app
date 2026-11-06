-- 2026-11-05 (Riley): site admins can delete any athlete; team admins can delete their own team's athletes that
-- are NOT certified yet. Certified athletes: site admins or the Conference President. Fees are voided by reg_charges_void.
-- The athlete's proof-of-birth file is removed by the page right after (policy below: only files no registration points to).
create or replace function public.reg_cert_guard()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare
  claims text := current_setting('request.jwt.claims', true);
  me text := lower(coalesce(auth.jwt()->>'email',''));
  free text[] := array['status','verified_by','verified_at','reviewed_by','reviewed_at','coach_note','comp_number',
    'dob_check_status','dob_extracted','name_extracted','dob_check_note','dob_checked_at','prior_registration_id'];
  c_old text; c_new text; nm text;
begin
  if coalesce(current_setting('vyc.cert_bypass', true),'') = 'on' or coalesce(claims,'') = ''
     or coalesce(claims::jsonb->>'role','') = 'service_role' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if tg_op = 'INSERT' then
    new.status := 'submitted'; new.verified_by := null; new.verified_at := null;
    new.reviewed_by := null; new.reviewed_at := null;
    return new;
  end if;

  if tg_op = 'DELETE' then
    -- Results from a past (locked) season stay linked to the athlete, so that athlete can't be deleted.
    if exists (select 1 from public.results x where x.registration_id = old.id and public.meet_is_locked(x.meet_id)) then
      raise exception '% % has results from a past season. Those results are locked and stay with the athlete, so this athlete can''t be deleted. Use Reject instead.', old.first_name, old.last_name;
    end if;
    if old.contract_version = 'ROSTER-2026' then return old; end if; -- test-roster cleanup button (until go-live)
    if public.is_site_admin() or public.is_president_of(public.team_conference(old.team_code)) then return old; end if;
    if public.is_team_admin_of(old.team_code) then
      if old.status = 'verified' then
        raise exception 'This athlete is certified. Only a site admin or the Conference President can delete a certified athlete.';
      end if;
      return old;
    end if;
    raise exception 'Only a site admin, this team''s team admin, or the Conference President can delete an athlete.';
  end if;

  c_old := public.team_conference(old.team_code); c_new := public.team_conference(new.team_code);
  nm := coalesce(case c_old when 'East' then 'Eastern' when 'West' then 'Western' end,'');

  if (to_jsonb(old) - free) is distinct from (to_jsonb(new) - free)
     and not (public.is_president_of(c_old) and public.is_president_of(c_new)) then
    raise exception 'Only the % Conference President can change athlete information. Site admins: your change is sent to the president for approval from the Athletes tab.', nm;
  end if;

  if new.status is distinct from old.status then
    if new.status = 'verified' or old.status = 'verified' then
      if not (public.is_president_of(c_old) and public.is_president_of(c_new)) then
        raise exception 'Only the % Conference President can certify an athlete (or undo a certification).', nm;
      end if;
    elsif not (public.is_team_admin_of(old.team_code) or public.is_site_admin() or public.is_president_of(c_old)) then
      raise exception 'Only a team admin for this team can review registrations.';
    end if;
    if new.status = 'verified' then new.verified_by := me; new.verified_at := now();
    elsif old.status = 'verified' then new.verified_by := null; new.verified_at := null; end if;
    if new.status = 'reviewed' and old.status is distinct from 'verified' then new.reviewed_by := me; new.reviewed_at := now(); end if;
  else
    new.verified_by := old.verified_by; new.verified_at := old.verified_at;
    new.reviewed_by := old.reviewed_by; new.reviewed_at := old.reviewed_at;
  end if;
  return new;
end $function$;

-- Proof-of-birth files left behind by a deleted athlete (no registration points to them) can be removed by
-- site admins, team admins and presidents. Files still attached to an athlete can't be deleted this way.
drop policy if exists "admins remove orphan proof" on storage.objects;
create policy "admins remove orphan proof" on storage.objects for delete to authenticated
using (bucket_id = 'proof-of-birth'
  and not exists (select 1 from public.registrations r where r.proof_path = storage.objects.name)
  and exists (select 1 from public.coaches c where lower(c.email) = lower(coalesce(auth.jwt()->>'email',''))
              and c.approved and (c.is_admin or c.team_admin or c.president_conference is not null)));
