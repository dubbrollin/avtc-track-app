-- "Look around" demo accounts (2026-10-23).
--   Riley: reviewers should be able to open every page WITHOUT signing in, see what a coach / team admin / parent /
--   timer sees, but not change anything unless they sign in with their own account.
--   Four demo accounts (one tap on any sign-in screen signs the reviewer in as one of them, nothing to type):
--     demo-coach@lookaround.demo       head coach of AVTC (sample team)
--     demo-teamadmin@lookaround.demo   team admin of AVTC (Team Admin + Site Admin page, scoped to AVTC)
--     demo-parent@lookaround.demo      parent of two made-up sample athletes on AVTC (one certified with results, one awaiting review)
--     demo-timer@lookaround.demo       approved timer (Timer Dashboard)
--   Every table gets a BEFORE trigger that refuses inserts / updates / deletes from a @lookaround.demo login, so the
--   demo accounts are view-only no matter which page or button is used. (Their own message read-marks / prefs are allowed.)
--   None of them is a SITE admin: a site admin sees every team's athletes, proof-of-birth documents and contact details,
--   which must not be open to the public. A site admin can grant that to the demo team admin in People & Access if wanted.
--   The shared demo password lives in shared.js (public by design; the accounts can't change anything).
--   All names, addresses and numbers below are placeholders, not real people.
begin;

-- ---------- 1. the four logins ----------
create or replace function public._demo_user(p_email text, p_pass text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid;
begin
  select id into uid from auth.users where email = p_email;
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current,
                            phone_change, phone_change_token, reauthentication_token, is_sso_user, is_anonymous)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', p_email, extensions.crypt(p_pass, extensions.gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', '', '', '', '', '', false, false);
    insert into auth.identities (id, user_id, provider, provider_id, identity_data, created_at, updated_at, last_sign_in_at)
    values (gen_random_uuid(), uid, 'email', uid::text,
            jsonb_build_object('sub', uid::text, 'email', p_email, 'email_verified', true, 'phone_verified', false), now(), now(), now());
  else
    update auth.users set encrypted_password = extensions.crypt(p_pass, extensions.gen_salt('bf')), email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now() where id = uid;
  end if;
  return uid;
end $$;
revoke all on function public._demo_user(text, text) from public, anon, authenticated;

-- The sign-in widget asks for the login of the role the reviewer picked. The shared password lives only here (not in the pages);
-- change it in both places below and re-run this file to rotate it.
create or replace function public.look_around_login(p_role text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select case when p_role in ('coach','teamadmin','parent','timer')
              then jsonb_build_object('email', 'demo-' || p_role || '@lookaround.demo', 'password', 'look-around-2027')
              else null end
$$;
grant execute on function public.look_around_login(text) to anon, authenticated;

select public._demo_user('demo-coach@lookaround.demo', 'look-around-2027');
select public._demo_user('demo-teamadmin@lookaround.demo', 'look-around-2027');
select public._demo_user('demo-parent@lookaround.demo', 'look-around-2027');
select public._demo_user('demo-timer@lookaround.demo', 'look-around-2027');

-- ---------- 2. who they are in the app ----------
insert into public.coaches (email, name, first_name, last_name, phone, team_code, role_type, division_or_age_group, approved, season_year,
                            background_check_date, contract_signed_at, contract_version, admin_title, team_admin, age_21_attested)
values
  ('demo-coach@lookaround.demo', 'Demo Coach', 'Demo', 'Coach', 'n/a (demo)', 'AVTC', 'head_coach', 'All', true, 2027, current_date - 30, now(), 'demo', null, false, true),
  ('demo-teamadmin@lookaround.demo', 'Demo Team Admin', 'Demo', 'Team Admin', 'n/a (demo)', 'AVTC', 'team_staff', null, true, 2027, current_date - 30, now(), 'demo', 'Team Admin (look-around)', true, true),
  ('demo-timer@lookaround.demo', 'Demo Timer', 'Demo', 'Timer', 'n/a (demo)', null, 'timer', null, true, 2027, current_date - 30, now(), 'demo', null, false, true)
on conflict (email) do update set approved = true, team_code = excluded.team_code, role_type = excluded.role_type, team_admin = excluded.team_admin,
  division_or_age_group = excluded.division_or_age_group, admin_title = excluded.admin_title, is_admin = false;

-- The demo parent's athletes (made-up sample kids, AVTC, this season). One certified (so Season bests + meet sign-up show), one waiting for review.
insert into public.registrations (id, season_year, sport, gender, dob, age_on_dec31, division, first_name, last_name, address, city, zip, phone, email,
  emergency_name, emergency_phone, is_returning, medical_option, parent1_name, parent1_relationship, athlete_signature, athlete_signature_method,
  parent_signature, parent_signature_method, dob_check_status, status, verified_by, verified_at, team_code, contract_signed_at, contract_version, registered_via_email, proof_path, in_high_school)
select x.* from (values
  ('11111111-1111-4111-8111-000000000001'::uuid, 2027, 'Track & Field', 'Girl', date '2017-05-04', 10, 'Bantam', 'Demo', 'Athlete', 'Sample address (demo)', 'Demo City', '00000', 'n/a (demo)', 'demo-parent@lookaround.demo',
   'Demo Contact', 'n/a (demo)', false, 'clear', 'Demo Parent', 'Mother', 'Demo Athlete', 'typed', 'Demo Parent', 'typed', 'match', 'verified', 'demo', now(), 'AVTC', now(), 'demo', 'demo-parent@lookaround.demo', 'demo/sample-proof.txt', false),
  ('11111111-1111-4111-8111-000000000002'::uuid, 2027, 'Track & Field', 'Boy', date '2014-03-15', 13, 'Youth', 'Sample', 'Runner', 'Sample address (demo)', 'Demo City', '00000', 'n/a (demo)', 'demo-parent@lookaround.demo',
   'Demo Contact', 'n/a (demo)', false, 'clear', 'Demo Parent', 'Mother', 'Sample Runner', 'typed', 'Demo Parent', 'typed', 'pending', 'submitted', null, null, 'AVTC', now(), 'demo', 'demo-parent@lookaround.demo', 'demo/sample-proof.txt', false)
) as x(id, season_year, sport, gender, dob, age_on_dec31, division, first_name, last_name, address, city, zip, phone, email,
  emergency_name, emergency_phone, is_returning, medical_option, parent1_name, parent1_relationship, athlete_signature, athlete_signature_method,
  parent_signature, parent_signature_method, dob_check_status, status, verified_by, verified_at, team_code, contract_signed_at, contract_version, registered_via_email, proof_path, in_high_school)
where not exists (select 1 from public.registrations r where r.id = x.id);
-- (proof_path is a placeholder so the proof-of-birth rule lets these made-up athletes in; the registration triggers create their fee rows and numbers as usual)

-- A couple of results for the certified sample athlete at this season's first meet, so the parent's Season bests box has something to show.
insert into public.results (meet_id, registration_id, athlete_name, gender, division, team_code, event_code, event_name, is_relay, round, mark, mark_value, is_time, place, heat, source, entered_by)
select m.id, '11111111-1111-4111-8111-000000000001', 'Demo Athlete', 'Girl', 'Bantam', 'AVTC', x.code, x.name, false, 'F', x.mark, x.mv, true, x.pl, 1, 'manual', 'demo'
from (select id from public.meets where season_year = 2027 and status is distinct from 'archived' order by meet_date limit 1) m
cross join (values ('100', '100 Meter Dash', '16.42', 16.42, 3), ('800', '800 Meter Run', '3:05.80', 185.80, 2)) as x(code, name, mark, mv, pl)
where not exists (select 1 from public.results r where r.registration_id = '11111111-1111-4111-8111-000000000001');

-- ---------- 3. view-only: a demo login can't insert, update or delete anywhere ----------
create or replace function public.demo_readonly() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if lower(coalesce(auth.jwt()->>'email','')) like '%@lookaround.demo' then
    raise exception 'You are looking around as a demo user, so changes are turned off. Sign in with your own account to make changes.'
      using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end $$;
do $$
declare t text;
begin
  for t in select table_name from information_schema.tables
           where table_schema = 'public' and table_type = 'BASE TABLE'
             and table_name not in ('msg_reads', 'msg_notify_state', 'msg_prefs')   -- a demo user's own "read" marks are harmless
  loop
    execute format('drop trigger if exists zz_demo_readonly on public.%I', t);
    execute format('create trigger zz_demo_readonly before insert or update or delete on public.%I for each row execute function public.demo_readonly()', t);
  end loop;
end $$;

commit;
