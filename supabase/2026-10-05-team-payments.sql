-- ============================================================================
-- Team payment portals (2026-10-05)
-- Each team collects its OWN club fee from parents. Two ways to pay:
--   1. Card, through the team's own Stripe account (Stripe Connect; the money goes straight to the team,
--      VYC never touches it). Pay in full, or a payment plan: deposit now + monthly installments.
--   2. "Other ways": Zelle, Cash App, Venmo, check or cash. The parent tells the app they sent it; the
--      team admin confirms when it arrives.
-- Conference fees (team_charges) are unchanged — that is team → VYC. This is parent → team.
-- Writes happen only through the functions below (and the Stripe edge functions, which use the service role).
-- ============================================================================

-- ---------- who may manage a team's money: that team's team admin, or a site admin ----------
create or replace function public.is_team_money_admin(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.is_site_admin() or public.is_team_admin_of(t)
$$;
grant execute on function public.is_team_money_admin(text) to authenticated;

-- ---------- per-team, per-season fee settings ----------
create table if not exists public.team_payment_settings (
  team_code text not null,
  season_year integer not null,
  fee_amount numeric(10,2) not null default 0 check (fee_amount >= 0),
  sibling_discount numeric(10,2) not null default 0 check (sibling_discount >= 0), -- off each 2nd+ athlete from the same family (same email, same season)
  fee_note text,                                                                   -- what the fee covers (shown to parents)
  plan_enabled boolean not null default false,
  plan_deposit numeric(10,2) not null default 0 check (plan_deposit >= 0),          -- due today
  plan_installments integer not null default 2 check (plan_installments between 1 and 12),
  plan_first_date date,                                                             -- first installment; then monthly
  accept_card boolean not null default true,                                        -- card payments (needs the Stripe account to be active)
  accept_zelle boolean not null default false, zelle_info text,                     -- e.g. "Zelle to treasurer@team.org (Jane Doe)"
  accept_cashapp boolean not null default false, cashapp_info text,                 -- e.g. "$TeamCashtag"
  accept_venmo boolean not null default false, venmo_info text,                     -- e.g. "@Team-Venmo"
  accept_other boolean not null default false, other_info text,                     -- check / cash instructions
  updated_at timestamptz not null default now(), updated_by text,
  primary key (team_code, season_year));
alter table public.team_payment_settings enable row level security;
drop policy if exists "fee settings read" on public.team_payment_settings;
-- Anyone can read: the registration page shows the fee and the ways to pay before a parent even signs in.
create policy "fee settings read" on public.team_payment_settings for select using (true);

-- ---------- the team's Stripe account (one per team, kept across seasons) ----------
create table if not exists public.team_stripe_accounts (
  team_code text primary key,
  stripe_account_id text not null unique,
  status text not null default 'onboarding' check (status in ('onboarding','active','restricted')),
  status_detail text,
  checked_at timestamptz,
  created_by text, created_at timestamptz not null default now());
alter table public.team_stripe_accounts enable row level security;
drop policy if exists "stripe accounts read" on public.team_stripe_accounts;
create policy "stripe accounts read" on public.team_stripe_accounts for select using (public.is_team_money_admin(team_code));
-- Written only by the team-stripe edge function (service role).

-- Is this team ready to take card payments? (public: the pay page needs it before sign-in)
create or replace function public.team_card_ready(p_team text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.team_stripe_accounts a where a.team_code = p_team and a.status = 'active')
$$;
grant execute on function public.team_card_ready(text) to anon, authenticated;

-- ---------- one fee per athlete registration ----------
create table if not exists public.athlete_fees (
  id uuid primary key default gen_random_uuid(),
  registration_id uuid not null unique references public.registrations(id) on delete cascade,
  team_code text not null, season_year integer not null,
  amount_due numeric(10,2) not null check (amount_due >= 0),
  discount numeric(10,2) not null default 0, discount_note text,
  status text not null default 'unpaid' check (status in ('unpaid','pending','plan','paid','waived','void')),
  -- Stripe payment plan (subscription on the team's Stripe account)
  stripe_customer_id text, stripe_subscription_id text,
  plan_installments integer, plan_amount numeric(10,2), plan_paid integer not null default 0, plan_next_on date,
  plan_failed boolean not null default false,
  note text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index if not exists athlete_fees_team_idx on public.athlete_fees (team_code, season_year, status);
alter table public.athlete_fees enable row level security;
drop policy if exists "fees read" on public.athlete_fees;
create policy "fees read" on public.athlete_fees for select to authenticated
  using (public.is_team_money_admin(team_code)
         or exists (select 1 from public.registrations r where r.id = registration_id and lower(r.email) = lower(coalesce(auth.jwt()->>'email',''))));

-- ---------- every payment (or attempted / reported payment) against a fee ----------
create table if not exists public.fee_payments (
  id uuid primary key default gen_random_uuid(),
  fee_id uuid not null references public.athlete_fees(id) on delete cascade,
  team_code text not null,
  method text not null check (method in ('card','zelle','cashapp','venmo','check','cash','other','waiver')),
  kind text not null default 'full' check (kind in ('full','deposit','installment','partial','refund')),
  amount numeric(10,2) not null check (amount >= 0),
  status text not null check (status in ('reported','received','failed','refunded','void')),
  reference text,                       -- Zelle confirmation, check number, etc.
  stripe_checkout_session_id text unique, stripe_payment_intent_id text unique, stripe_invoice_id text unique,
  reported_by text, reported_at timestamptz not null default now(),
  received_on date, recorded_by text, note text);
create index if not exists fee_payments_fee_idx on public.fee_payments (fee_id);
alter table public.fee_payments enable row level security;
drop policy if exists "fee payments read" on public.fee_payments;
create policy "fee payments read" on public.fee_payments for select to authenticated
  using (public.is_team_money_admin(team_code)
         or exists (select 1 from public.athlete_fees f join public.registrations r on r.id = f.registration_id
                    where f.id = fee_id and lower(r.email) = lower(coalesce(auth.jwt()->>'email',''))));

-- ---------- balance + status ----------
create or replace function public.fee_paid_total(p_fee uuid) returns numeric
language sql stable security definer set search_path to 'public' as $$
  select coalesce(sum(case when kind = 'refund' then -amount else amount end), 0)
    from public.fee_payments where fee_id = p_fee and ((status = 'received' and kind <> 'refund') or (status = 'refunded' and kind = 'refund'))
$$;
-- note: a refund row is kind='refund', status='refunded' (negative). A received payment that was later refunded stays 'received'
-- and the refund row offsets it, so the history is complete.

create or replace function public.refresh_fee_status(p_fee uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare f public.athlete_fees; paid numeric; pend boolean;
begin
  select * into f from public.athlete_fees where id = p_fee; if f.id is null then return; end if;
  if f.status in ('waived','void') then return; end if;
  paid := public.fee_paid_total(p_fee);
  pend := exists (select 1 from public.fee_payments where fee_id = p_fee and status = 'reported');
  update public.athlete_fees set updated_at = now(),
    status = case when paid >= amount_due then 'paid'
                  when stripe_subscription_id is not null and plan_paid < coalesce(plan_installments, 0) then 'plan'
                  when pend then 'pending' else 'unpaid' end
   where id = p_fee;
end $$;

create or replace function public.fee_payments_refresh_trg() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin perform public.refresh_fee_status(case when tg_op = 'DELETE' then old.fee_id else new.fee_id end); return null; end $$;
drop trigger if exists fee_payments_refresh on public.fee_payments;
create trigger fee_payments_refresh after insert or update or delete on public.fee_payments for each row execute function public.fee_payments_refresh_trg();

-- ---------- create the fee when an athlete registers ----------
-- Amount = the team's fee for that season, minus the sibling discount when another athlete from the same family
-- (same email) is already registered with that team this season. If the team hasn't set a fee yet, nothing is
-- created; the team admin can add fees for existing athletes later with ensure_athlete_fees().
create or replace function public.make_athlete_fee(p_reg uuid) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; s public.team_payment_settings; amt numeric; disc numeric := 0; dnote text; nid uuid;
begin
  select * into r from public.registrations where id = p_reg;
  if r.id is null or coalesce(r.contract_version,'') = 'ROSTER-2026' or r.status = 'rejected' then return null; end if;
  if exists (select 1 from public.athlete_fees where registration_id = p_reg) then return (select id from public.athlete_fees where registration_id = p_reg); end if;
  select * into s from public.team_payment_settings where team_code = r.team_code and season_year = r.season_year;
  if s.team_code is null or s.fee_amount <= 0 then return null; end if;
  amt := s.fee_amount;
  if s.sibling_discount > 0 and exists (select 1 from public.registrations o where o.id <> r.id and o.team_code = r.team_code and o.season_year = r.season_year
                                          and lower(o.email) = lower(r.email) and o.status <> 'rejected' and coalesce(o.contract_version,'') <> 'ROSTER-2026' and o.created_at < r.created_at) then
    disc := least(s.sibling_discount, amt); dnote := 'Sibling discount';
  end if;
  insert into public.athlete_fees (registration_id, team_code, season_year, amount_due, discount, discount_note)
  values (r.id, r.team_code, r.season_year, amt - disc, disc, dnote) returning id into nid;
  return nid;
end $$;

create or replace function public.reg_make_fee_trg() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin perform public.make_athlete_fee(new.id); return new; end $$;
drop trigger if exists reg_make_fee on public.registrations;
create trigger reg_make_fee after insert on public.registrations for each row execute function public.reg_make_fee_trg();

-- Rejected athletes with nothing paid: fee cancelled (void). Un-rejected: back to unpaid.
create or replace function public.reg_fee_void_trg() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status = 'rejected' and old.status is distinct from 'rejected' then
    update public.athlete_fees set status = 'void', updated_at = now() where registration_id = new.id and status in ('unpaid','pending') and public.fee_paid_total(id) = 0;
  elsif old.status = 'rejected' and new.status <> 'rejected' then
    update public.athlete_fees set status = 'unpaid', updated_at = now() where registration_id = new.id and status = 'void';
    perform public.refresh_fee_status(id) from public.athlete_fees where registration_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists reg_fee_void on public.registrations;
create trigger reg_fee_void after update of status on public.registrations for each row execute function public.reg_fee_void_trg();

-- Team admin: add fees for athletes registered before the fee was set (or after it was raised from 0).
create or replace function public.ensure_athlete_fees(p_team text, p_season integer) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare n integer := 0; r record;
begin
  if not public.is_team_money_admin(p_team) then raise exception 'Only this team''s team admin (or a site admin) can do that.'; end if;
  for r in select id from public.registrations where team_code = p_team and season_year = p_season and status <> 'rejected' and coalesce(contract_version,'') <> 'ROSTER-2026'
           and not exists (select 1 from public.athlete_fees f where f.registration_id = registrations.id) order by created_at loop
    if public.make_athlete_fee(r.id) is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- ---------- team admin: settings ----------
create or replace function public.save_team_payment_settings(p jsonb) returns void
language plpgsql security definer set search_path to 'public' as $$
declare t text := p->>'team_code'; s integer := (p->>'season_year')::int;
begin
  if not public.is_team_money_admin(t) then raise exception 'Only this team''s team admin (or a site admin) can change payment settings.'; end if;
  if s is null then raise exception 'Season missing.'; end if;
  if coalesce((p->>'plan_enabled')::boolean, false) then
    if coalesce((p->>'plan_deposit')::numeric, 0) >= coalesce((p->>'fee_amount')::numeric, 0) then raise exception 'The deposit must be less than the full fee.'; end if;
    if coalesce((p->>'plan_installments')::int, 0) < 1 then raise exception 'Choose how many monthly payments.'; end if;
    if nullif(p->>'plan_first_date','') is null then raise exception 'Choose the date of the first monthly payment.'; end if;
  end if;
  insert into public.team_payment_settings as x (team_code, season_year, fee_amount, sibling_discount, fee_note, plan_enabled, plan_deposit, plan_installments, plan_first_date,
      accept_card, accept_zelle, zelle_info, accept_cashapp, cashapp_info, accept_venmo, venmo_info, accept_other, other_info, updated_at, updated_by)
  values (t, s, coalesce((p->>'fee_amount')::numeric, 0), coalesce((p->>'sibling_discount')::numeric, 0), nullif(trim(p->>'fee_note'),''),
      coalesce((p->>'plan_enabled')::boolean, false), coalesce((p->>'plan_deposit')::numeric, 0), coalesce((p->>'plan_installments')::int, 2), nullif(p->>'plan_first_date','')::date,
      coalesce((p->>'accept_card')::boolean, true),
      coalesce((p->>'accept_zelle')::boolean, false), nullif(trim(p->>'zelle_info'),''),
      coalesce((p->>'accept_cashapp')::boolean, false), nullif(trim(p->>'cashapp_info'),''),
      coalesce((p->>'accept_venmo')::boolean, false), nullif(trim(p->>'venmo_info'),''),
      coalesce((p->>'accept_other')::boolean, false), nullif(trim(p->>'other_info'),''),
      now(), lower(coalesce(auth.jwt()->>'email','')))
  on conflict (team_code, season_year) do update set
      fee_amount = excluded.fee_amount, sibling_discount = excluded.sibling_discount, fee_note = excluded.fee_note,
      plan_enabled = excluded.plan_enabled, plan_deposit = excluded.plan_deposit, plan_installments = excluded.plan_installments, plan_first_date = excluded.plan_first_date,
      accept_card = excluded.accept_card, accept_zelle = excluded.accept_zelle, zelle_info = excluded.zelle_info, accept_cashapp = excluded.accept_cashapp, cashapp_info = excluded.cashapp_info,
      accept_venmo = excluded.accept_venmo, venmo_info = excluded.venmo_info, accept_other = excluded.accept_other, other_info = excluded.other_info,
      updated_at = now(), updated_by = excluded.updated_by;
end $$;

-- Team admin: change one athlete's amount (scholarship, special rate), or waive it.
create or replace function public.set_athlete_fee(p_fee uuid, p_amount numeric, p_note text default null, p_waive boolean default false) returns void
language plpgsql security definer set search_path to 'public' as $$
declare f public.athlete_fees;
begin
  select * into f from public.athlete_fees where id = p_fee; if f.id is null then raise exception 'Fee not found.'; end if;
  if not public.is_team_money_admin(f.team_code) then raise exception 'Only this team''s team admin (or a site admin) can change a fee.'; end if;
  if f.stripe_subscription_id is not null and f.status = 'plan' then raise exception 'This family is on a card payment plan — the amount can''t change while the plan is running.'; end if;
  if p_waive then
    update public.athlete_fees set status = 'waived', note = nullif(trim(p_note),''), updated_at = now() where id = p_fee;
  else
    if p_amount is null or p_amount < 0 then raise exception 'Enter the amount.'; end if;
    update public.athlete_fees set amount_due = p_amount, note = nullif(trim(p_note),''), status = case when status in ('waived','void') then 'unpaid' else status end, updated_at = now() where id = p_fee;
    perform public.refresh_fee_status(p_fee);
  end if;
end $$;

-- ---------- parent: what do I owe, and how can I pay? (works before sign-in: registration id + the email on it) ----------
create or replace function public.fee_for_registration(p_reg uuid, p_email text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; f public.athlete_fees; s public.team_payment_settings; me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  select * into r from public.registrations where id = p_reg;
  if r.id is null then raise exception 'Registration not found.'; end if;
  if lower(r.email) <> lower(coalesce(p_email,'')) and lower(r.email) <> me and not public.is_team_money_admin(r.team_code) then
    raise exception 'That email doesn''t match this registration.'; end if;
  select * into f from public.athlete_fees where registration_id = p_reg;
  select * into s from public.team_payment_settings where team_code = r.team_code and season_year = r.season_year;
  return jsonb_build_object(
    'registration', jsonb_build_object('id', r.id, 'first_name', r.first_name, 'last_name', r.last_name, 'team_code', r.team_code, 'season_year', r.season_year, 'status', r.status, 'email', r.email),
    'team_name', (select name from public.league_teams where code = r.team_code),
    'card_ready', public.team_card_ready(r.team_code),
    'settings', case when s.team_code is null then null else jsonb_build_object('fee_amount', s.fee_amount, 'fee_note', s.fee_note, 'plan_enabled', s.plan_enabled, 'plan_deposit', s.plan_deposit,
        'plan_installments', s.plan_installments, 'plan_first_date', s.plan_first_date, 'accept_card', s.accept_card,
        'accept_zelle', s.accept_zelle, 'zelle_info', s.zelle_info, 'accept_cashapp', s.accept_cashapp, 'cashapp_info', s.cashapp_info,
        'accept_venmo', s.accept_venmo, 'venmo_info', s.venmo_info, 'accept_other', s.accept_other, 'other_info', s.other_info) end,
    'fee', case when f.id is null then null else jsonb_build_object('id', f.id, 'amount_due', f.amount_due, 'discount', f.discount, 'discount_note', f.discount_note, 'status', f.status,
        'paid', public.fee_paid_total(f.id), 'balance', greatest(f.amount_due - public.fee_paid_total(f.id), 0), 'note', f.note,
        'plan_installments', f.plan_installments, 'plan_amount', f.plan_amount, 'plan_paid', f.plan_paid, 'plan_next_on', f.plan_next_on, 'plan_failed', f.plan_failed) end,
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'method', p.method, 'kind', p.kind, 'amount', p.amount, 'status', p.status, 'reference', p.reference,
        'reported_at', p.reported_at, 'received_on', p.received_on, 'note', p.note) order by p.reported_at)
        from public.fee_payments p where p.fee_id = f.id), '[]'::jsonb));
end $$;
grant execute on function public.fee_for_registration(uuid, text) to anon, authenticated;

-- Parent: "I sent it" for Zelle / Cash App / Venmo / check / cash. The team confirms when it arrives.
create or replace function public.report_offline_payment(p_reg uuid, p_email text, p_method text, p_amount numeric, p_reference text default null, p_note text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; f public.athlete_fees; s public.team_payment_settings; nid uuid; me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  select * into r from public.registrations where id = p_reg; if r.id is null then raise exception 'Registration not found.'; end if;
  if lower(r.email) <> lower(coalesce(p_email,'')) and lower(r.email) <> me then raise exception 'That email doesn''t match this registration.'; end if;
  select * into f from public.athlete_fees where registration_id = p_reg; if f.id is null then raise exception 'No fee is set up for this athlete yet.'; end if;
  if f.status in ('paid','waived','void') then raise exception 'Nothing is owed for this athlete.'; end if;
  if p_method not in ('zelle','cashapp','venmo','check','cash') then raise exception 'Unknown payment method.'; end if;
  select * into s from public.team_payment_settings where team_code = r.team_code and season_year = r.season_year;
  if (p_method = 'zelle' and not coalesce(s.accept_zelle,false)) or (p_method = 'cashapp' and not coalesce(s.accept_cashapp,false))
     or (p_method = 'venmo' and not coalesce(s.accept_venmo,false)) or (p_method in ('check','cash') and not coalesce(s.accept_other,false)) then
    raise exception 'This team doesn''t accept that payment method.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter the amount you sent.'; end if;
  insert into public.fee_payments (fee_id, team_code, method, kind, amount, status, reference, reported_by, note)
  values (f.id, f.team_code, p_method, case when p_amount >= f.amount_due - public.fee_paid_total(f.id) then 'full' else 'partial' end, p_amount, 'reported', nullif(trim(p_reference),''), lower(r.email), nullif(trim(p_note),''))
  returning id into nid;
  return nid;
end $$;
grant execute on function public.report_offline_payment(uuid, text, text, numeric, text, text) to anon, authenticated;

-- Team admin: record a payment that arrived (optionally confirming one the parent reported).
create or replace function public.record_fee_payment(p_fee uuid, p_method text, p_amount numeric, p_received_on date default null, p_reference text default null, p_note text default null, p_confirm uuid default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare f public.athlete_fees; nid uuid; me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  select * into f from public.athlete_fees where id = p_fee; if f.id is null then raise exception 'Fee not found.'; end if;
  if not public.is_team_money_admin(f.team_code) then raise exception 'Only this team''s team admin (or a site admin) can record payments.'; end if;
  if p_method not in ('zelle','cashapp','venmo','check','cash','other','card') then raise exception 'Unknown payment method.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter the amount received.'; end if;
  if p_confirm is not null then
    update public.fee_payments set status = 'received', amount = p_amount, method = p_method, received_on = coalesce(p_received_on, (now() at time zone 'America/Los_Angeles')::date),
        reference = coalesce(nullif(trim(p_reference),''), reference), note = coalesce(nullif(trim(p_note),''), note), recorded_by = me
     where id = p_confirm and fee_id = p_fee and status = 'reported' returning id into nid;
    if nid is null then raise exception 'That reported payment was already handled.'; end if;
    return nid;
  end if;
  insert into public.fee_payments (fee_id, team_code, method, kind, amount, status, reference, received_on, recorded_by, reported_by, note)
  values (f.id, f.team_code, p_method, case when p_amount >= f.amount_due - public.fee_paid_total(f.id) then 'full' else 'partial' end, p_amount, 'received', nullif(trim(p_reference),''),
          coalesce(p_received_on, (now() at time zone 'America/Los_Angeles')::date), me, me, nullif(trim(p_note),''))
  returning id into nid;
  return nid;
end $$;

-- Team admin: a reported payment never arrived (void), or an offline payment is being refunded.
create or replace function public.set_fee_payment_status(p_payment uuid, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path to 'public' as $$
declare p public.fee_payments; me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  select * into p from public.fee_payments where id = p_payment; if p.id is null then raise exception 'Payment not found.'; end if;
  if not public.is_team_money_admin(p.team_code) then raise exception 'Only this team''s team admin (or a site admin) can do that.'; end if;
  if p.method = 'card' and p.status = 'received' then raise exception 'Card payments are refunded from the team''s Stripe dashboard; the app updates itself.'; end if;
  if p_status = 'void' then
    if p.status <> 'reported' then raise exception 'Only a payment the parent reported (not yet confirmed) can be marked as not received.'; end if;
    update public.fee_payments set status = 'void', recorded_by = me, note = coalesce(nullif(trim(p_note),''), note) where id = p_payment;
  elsif p_status = 'refunded' then
    if p.status <> 'received' then raise exception 'Only a received payment can be refunded.'; end if;
    insert into public.fee_payments (fee_id, team_code, method, kind, amount, status, reference, received_on, recorded_by, reported_by, note)
    values (p.fee_id, p.team_code, p.method, 'refund', p.amount, 'refunded', p.reference, (now() at time zone 'America/Los_Angeles')::date, me, me, coalesce(nullif(trim(p_note),''), 'Refund'));
  else raise exception 'Unknown status.'; end if;
end $$;

revoke all on function public.ensure_athlete_fees(text, integer) from public;
revoke all on function public.save_team_payment_settings(jsonb) from public;
revoke all on function public.set_athlete_fee(uuid, numeric, text, boolean) from public;
revoke all on function public.record_fee_payment(uuid, text, numeric, date, text, text, uuid) from public;
revoke all on function public.set_fee_payment_status(uuid, text, text) from public;
grant execute on function public.ensure_athlete_fees(text, integer) to authenticated;
grant execute on function public.save_team_payment_settings(jsonb) to authenticated;
grant execute on function public.set_athlete_fee(uuid, numeric, text, boolean) to authenticated;
grant execute on function public.record_fee_payment(uuid, text, numeric, date, text, text, uuid) to authenticated;
grant execute on function public.set_fee_payment_status(uuid, text, text) to authenticated;

-- Team admin overview: every athlete's fee for a team + season (names come from registrations, which team admins can already read).
create or replace view public.team_fee_overview as
  select f.id, f.registration_id, f.team_code, f.season_year, f.amount_due, f.discount, f.discount_note, f.status, f.note,
         f.stripe_subscription_id, f.plan_installments, f.plan_amount, f.plan_paid, f.plan_next_on, f.plan_failed, f.created_at,
         r.first_name, r.last_name, r.email, r.division, r.status as reg_status,
         public.fee_paid_total(f.id) as paid, greatest(f.amount_due - public.fee_paid_total(f.id), 0) as balance,
         (select count(*) from public.fee_payments p where p.fee_id = f.id and p.status = 'reported') as reported_count
    from public.athlete_fees f join public.registrations r on r.id = f.registration_id;
-- The view runs with the caller's rights (security invoker), so RLS on athlete_fees + registrations applies.
alter view public.team_fee_overview set (security_invoker = true);
grant select on public.team_fee_overview to authenticated;
