-- ============================================================================
-- Payment plan: the team chooses how often installments come due — weekly, every two weeks, or monthly (2026-10-06)
-- ============================================================================
alter table public.team_payment_settings add column if not exists plan_interval text not null default 'month';
alter table public.team_payment_settings drop constraint if exists team_payment_settings_plan_interval_check;
alter table public.team_payment_settings add constraint team_payment_settings_plan_interval_check check (plan_interval in ('week','2weeks','month'));

create or replace function public.save_team_payment_settings(p jsonb) returns void
language plpgsql security definer set search_path to 'public' as $$
declare t text := p->>'team_code'; s integer := (p->>'season_year')::int; iv text := coalesce(nullif(p->>'plan_interval',''), 'month');
begin
  if not public.is_team_money_admin(t) then raise exception 'Only this team''s team admin (or a site admin) can change payment settings.'; end if;
  if s is null then raise exception 'Season missing.'; end if;
  if iv not in ('week','2weeks','month') then raise exception 'Choose weekly, every two weeks, or monthly.'; end if;
  if coalesce((p->>'plan_enabled')::boolean, false) then
    if coalesce((p->>'plan_deposit')::numeric, 0) >= coalesce((p->>'fee_amount')::numeric, 0) then raise exception 'The deposit must be less than the full fee.'; end if;
    if coalesce((p->>'plan_installments')::int, 0) < 1 then raise exception 'Choose how many payments.'; end if;
    if nullif(p->>'plan_first_date','') is null then raise exception 'Choose the date of the first payment.'; end if;
  end if;
  insert into public.team_payment_settings as x (team_code, season_year, fee_amount, sibling_discount, fee_note, plan_enabled, plan_deposit, plan_installments, plan_first_date, plan_interval,
      accept_card, accept_zelle, zelle_info, accept_cashapp, cashapp_info, accept_venmo, venmo_info, accept_other, other_info, updated_at, updated_by)
  values (t, s, coalesce((p->>'fee_amount')::numeric, 0), coalesce((p->>'sibling_discount')::numeric, 0), nullif(trim(p->>'fee_note'),''),
      coalesce((p->>'plan_enabled')::boolean, false), coalesce((p->>'plan_deposit')::numeric, 0), coalesce((p->>'plan_installments')::int, 2), nullif(p->>'plan_first_date','')::date, iv,
      coalesce((p->>'accept_card')::boolean, true),
      coalesce((p->>'accept_zelle')::boolean, false), nullif(trim(p->>'zelle_info'),''),
      coalesce((p->>'accept_cashapp')::boolean, false), nullif(trim(p->>'cashapp_info'),''),
      coalesce((p->>'accept_venmo')::boolean, false), nullif(trim(p->>'venmo_info'),''),
      coalesce((p->>'accept_other')::boolean, false), nullif(trim(p->>'other_info'),''),
      now(), lower(coalesce(auth.jwt()->>'email','')))
  on conflict (team_code, season_year) do update set
      fee_amount = excluded.fee_amount, sibling_discount = excluded.sibling_discount, fee_note = excluded.fee_note,
      plan_enabled = excluded.plan_enabled, plan_deposit = excluded.plan_deposit, plan_installments = excluded.plan_installments, plan_first_date = excluded.plan_first_date, plan_interval = excluded.plan_interval,
      accept_card = excluded.accept_card, accept_zelle = excluded.accept_zelle, zelle_info = excluded.zelle_info, accept_cashapp = excluded.accept_cashapp, cashapp_info = excluded.cashapp_info,
      accept_venmo = excluded.accept_venmo, venmo_info = excluded.venmo_info, accept_other = excluded.accept_other, other_info = excluded.other_info,
      updated_at = now(), updated_by = excluded.updated_by;
end $$;

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
        'plan_installments', s.plan_installments, 'plan_first_date', s.plan_first_date, 'plan_interval', s.plan_interval, 'accept_card', s.accept_card,
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
