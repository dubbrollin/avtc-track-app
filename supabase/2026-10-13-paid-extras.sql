-- Paid team extras (2026-10-13): ONE switch per team covers everything that is not required to run a team.
--   FREE (always on):  registration, proof review, certification, rosters, coach approval, meet entries,
--                      "is your athlete coming?" (and letting parents pick events), and posting the team fee so
--                      parents can see what they owe.
--   PAID ($99 per team per season, switched on by a site admin):
--                      Team Messenger (groups, direct messages, photos/files, alerts)
--                      Taking payments online AND the app tracking them: card payments through the team's Stripe,
--                      payment plans, Zelle / Cash App / Venmo / check with "I sent it", recording payments,
--                      balances and payment history.
-- The switch is the team_messaging.enabled flag that Team Messenger already uses (msg_set_enabled flips it).

create or replace function public.team_has_extras(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select m.enabled from public.team_messaging m where m.team_code = t), false)
$$;
grant execute on function public.team_has_extras(text) to anon, authenticated;

-- Card payments (and so payment plans) are offered to parents only when the team has the paid extras
-- AND has finished its Stripe setup.
create or replace function public.team_card_ready(p_team text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.team_has_extras(p_team)
     and exists (select 1 from public.team_stripe_accounts a where a.team_code = p_team and a.status = 'active')
$$;
grant execute on function public.team_card_ready(text) to anon, authenticated;

-- No payment can be reported or recorded for a team without the paid extras (a parent's "I sent it", or a team
-- admin recording one). Card payments are stopped earlier, at checkout; one that Stripe has ALREADY charged
-- (e.g. a payment-plan instalment after the extras were switched off) is still recorded so no money goes missing.
create or replace function public.fee_payments_extras_guard() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.method is distinct from 'card' and not public.team_has_extras(new.team_code) then
    raise exception 'Taking and tracking payments in the app is part of the paid team extras, which aren''t switched on for this team.';
  end if;
  return new;
end $$;
drop trigger if exists fee_payments_extras_guard on public.fee_payments;
create trigger fee_payments_extras_guard before insert on public.fee_payments
  for each row execute function public.fee_payments_extras_guard();
