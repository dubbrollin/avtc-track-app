-- ============================================================================
-- Team fee list (2026-11-11)
-- A team no longer has ONE fee + one sibling discount. It keeps a LIST of fees and discounts, each with its own
-- name, amount and rule for who gets it:
--     athlete   = every athlete            family    = once per family (one child carries it)
--     sibling   = each additional child    new       = athletes new to the team this season
--     returning = returning athletes       choose    = only the athletes the team picks (added by hand)
-- Every athlete's fee (athlete_fees, still one per registration) now has LINES (athlete_fee_lines) and
-- amount_due is always the sum of those lines, so paying, payment plans and Stripe work exactly as before.
-- A family = same email, same team, same season (track only), as the sibling discount always worked.
-- Safe to run more than once.
-- ============================================================================

-- ---------- the team's list ----------
create table if not exists public.team_fee_items (
  id uuid primary key default gen_random_uuid(),
  team_code text not null, season_year integer not null,
  name text not null check (length(trim(name)) > 0),
  kind text not null default 'fee' check (kind in ('fee','discount')),
  amount numeric(10,2) not null default 0 check (amount >= 0),
  is_percent boolean not null default false,          -- discounts only: a % of that athlete's fees instead of dollars
  applies text not null default 'athlete' check (applies in ('athlete','family','sibling','new','returning','choose')),
  note text,                                           -- shown to parents under the line
  sort integer not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), updated_by text,
  check (not is_percent or (kind = 'discount' and amount <= 100)));
create index if not exists team_fee_items_team_idx on public.team_fee_items (team_code, season_year, sort);
alter table public.team_fee_items enable row level security;
drop policy if exists "fee items read" on public.team_fee_items;
-- Anyone can read, like the fee settings: parents see what the team charges before they sign in.
create policy "fee items read" on public.team_fee_items for select using (true);
grant select on public.team_fee_items to anon, authenticated;

-- ---------- one athlete's lines ----------
create table if not exists public.athlete_fee_lines (
  id uuid primary key default gen_random_uuid(),
  fee_id uuid not null references public.athlete_fees(id) on delete cascade,
  item_id uuid references public.team_fee_items(id) on delete set null,
  name text not null,
  kind text not null default 'fee' check (kind in ('fee','discount')),
  amount numeric(10,2) not null default 0 check (amount >= 0),
  percent numeric(5,2),                                -- set on % discounts; amount is re-worked from the fee lines
  family boolean not null default false,               -- a once-per-family line
  auto boolean not null default true,                  -- came from the team's list (false = typed or changed by hand)
  removed boolean not null default false,              -- taken off for this athlete (kept so the family sees why)
  note text,
  sort integer not null default 0,
  created_at timestamptz not null default now(), changed_by text);
create index if not exists athlete_fee_lines_fee_idx on public.athlete_fee_lines (fee_id);
create index if not exists athlete_fee_lines_item_idx on public.athlete_fee_lines (item_id);
alter table public.athlete_fee_lines enable row level security;
drop policy if exists "fee lines read" on public.athlete_fee_lines;
create policy "fee lines read" on public.athlete_fee_lines for select to authenticated
  using (exists (select 1 from public.athlete_fees f where f.id = fee_id and (public.is_team_money_admin(f.team_code)
         or exists (select 1 from public.registrations r where r.id = f.registration_id and lower(r.email) = lower(coalesce(auth.jwt()->>'email',''))))));
grant select on public.athlete_fee_lines to authenticated;

-- ---------- bring the old single fee + sibling discount into the list (once) ----------
insert into public.team_fee_items (team_code, season_year, name, kind, amount, applies, sort)
  select s.team_code, s.season_year, 'Team fee', 'fee', s.fee_amount, 'athlete', 1 from public.team_payment_settings s
   where s.fee_amount > 0 and not exists (select 1 from public.team_fee_items i where i.team_code = s.team_code and i.season_year = s.season_year);
insert into public.team_fee_items (team_code, season_year, name, kind, amount, applies, sort)
  select s.team_code, s.season_year, 'Sibling discount', 'discount', s.sibling_discount, 'sibling', 2 from public.team_payment_settings s
   where s.sibling_discount > 0 and exists (select 1 from public.team_fee_items i where i.team_code = s.team_code and i.season_year = s.season_year and i.name = 'Team fee')
     and not exists (select 1 from public.team_fee_items i where i.team_code = s.team_code and i.season_year = s.season_year and i.applies = 'sibling');
-- Fees that already exist keep their exact amount: one "Team fee" line (+ the discount they were given).
insert into public.athlete_fee_lines (fee_id, item_id, name, kind, amount, auto, sort)
  select f.id, (select i.id from public.team_fee_items i where i.team_code = f.team_code and i.season_year = f.season_year and i.name = 'Team fee' and i.applies = 'athlete' limit 1),
         'Team fee', 'fee', f.amount_due + f.discount, (f.note is null), 1
    from public.athlete_fees f where not exists (select 1 from public.athlete_fee_lines l where l.fee_id = f.id);
insert into public.athlete_fee_lines (fee_id, item_id, name, kind, amount, auto, sort)
  select f.id, (select i.id from public.team_fee_items i where i.team_code = f.team_code and i.season_year = f.season_year and i.applies = 'sibling' limit 1),
         coalesce(f.discount_note, 'Discount'), 'discount', f.discount, (f.note is null), 2
    from public.athlete_fees f where f.discount > 0 and not exists (select 1 from public.athlete_fee_lines l where l.fee_id = f.id and l.kind = 'discount');

-- ---------- helpers ----------
-- The athletes that count for team fees (track registrations of real, non-rejected athletes).
create or replace function public.fee_reg_counts(r public.registrations) returns boolean
language sql immutable as $$
  select r.status <> 'rejected' and coalesce(r.contract_version,'') <> 'ROSTER-2026' and coalesce(r.sport,'') <> 'Cross Country'
$$;

-- What a first child normally pays: kept in team_payment_settings.fee_amount so every page that asks
-- "has this team posted a fee?" keeps working.
create or replace function public.fee_list_sync(p_team text, p_season integer) returns void
language plpgsql security definer set search_path to 'public' as $$
declare fees numeric; disc numeric; n integer;
begin
  select coalesce(sum(amount) filter (where kind = 'fee' and applies in ('athlete','family')), 0),
         coalesce(sum(amount) filter (where kind = 'discount' and applies in ('athlete','family') and not is_percent), 0), count(*)
    into fees, disc, n from public.team_fee_items where team_code = p_team and season_year = p_season;
  select fees - disc - coalesce(sum(round(fees * amount / 100, 2)), 0) into fees from public.team_fee_items
   where team_code = p_team and season_year = p_season and kind = 'discount' and applies in ('athlete','family') and is_percent;
  insert into public.team_payment_settings (team_code, season_year, fee_amount, sibling_discount) values (p_team, p_season, greatest(fees, 0), 0)
  on conflict (team_code, season_year) do update set fee_amount = excluded.fee_amount, sibling_discount = 0, updated_at = now();
end $$;
revoke all on function public.fee_list_sync(text, integer) from public;

-- amount_due = fee lines − discount lines (never below 0). % discounts are re-worked from the fee lines first.
create or replace function public.fee_recalc(p_fee uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare base numeric; disc numeric;
begin
  select coalesce(sum(amount), 0) into base from public.athlete_fee_lines where fee_id = p_fee and kind = 'fee' and not removed;
  update public.athlete_fee_lines set amount = round(base * percent / 100, 2) where fee_id = p_fee and kind = 'discount' and percent is not null and not removed;
  select coalesce(sum(amount), 0) into disc from public.athlete_fee_lines where fee_id = p_fee and kind = 'discount' and not removed;
  update public.athlete_fees set amount_due = greatest(base - disc, 0), discount = least(disc, base),
         discount_note = (select string_agg(name, ', ' order by sort, created_at) from public.athlete_fee_lines where fee_id = p_fee and kind = 'discount' and not removed),
         updated_at = now()
   where id = p_fee;
  perform public.refresh_fee_status(p_fee);
end $$;
revoke all on function public.fee_recalc(uuid) from public;

-- Nothing received yet and no plan running: the list may still re-work this fee.
create or replace function public.fee_is_open(f public.athlete_fees) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select f.status in ('unpaid','pending','paid') and f.stripe_subscription_id is null and public.fee_paid_total(f.id) = 0
     and not exists (select 1 from public.fee_payments p where p.fee_id = f.id and p.status = 'reported')
$$;

-- Put the list's lines on ONE fee. Lines changed or removed by hand stay as they are.
create or replace function public.fee_build_lines(p_fee uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare f public.athlete_fees; r public.registrations; it public.team_fee_items; has_older boolean; want boolean;
begin
  select * into f from public.athlete_fees where id = p_fee; if f.id is null then return; end if;
  select * into r from public.registrations where id = f.registration_id;
  delete from public.athlete_fee_lines where fee_id = p_fee and auto and not removed;
  has_older := exists (select 1 from public.registrations o where o.id <> r.id and o.team_code = r.team_code and o.season_year = r.season_year
                        and lower(o.email) = lower(r.email) and public.fee_reg_counts(o) and (o.created_at, o.id) < (r.created_at, r.id));
  for it in select * from public.team_fee_items where team_code = f.team_code and season_year = f.season_year order by (kind = 'discount'), sort, created_at loop
    if exists (select 1 from public.athlete_fee_lines l where l.fee_id = p_fee and l.item_id = it.id) then continue; end if;   -- already here (changed/removed by hand)
    want := case it.applies
      when 'athlete' then true
      when 'sibling' then has_older
      when 'new' then not coalesce(r.is_returning, false)
      when 'returning' then coalesce(r.is_returning, false)
      when 'family' then not exists (select 1 from public.athlete_fee_lines l join public.athlete_fees o on o.id = l.fee_id join public.registrations g on g.id = o.registration_id
                                       where l.item_id = it.id and o.id <> p_fee and o.status <> 'void' and o.team_code = f.team_code and o.season_year = f.season_year
                                         and lower(g.email) = lower(r.email))
      else false end;
    if want then
      insert into public.athlete_fee_lines (fee_id, item_id, name, kind, amount, percent, family, auto, note, sort)
      values (p_fee, it.id, it.name, it.kind, case when it.is_percent then 0 else it.amount end, case when it.is_percent then it.amount end, it.applies = 'family', true, it.note, it.sort);
    end if;
  end loop;
  perform public.fee_recalc(p_fee);
end $$;
revoke all on function public.fee_build_lines(uuid) from public;

-- Re-work a whole family in sign-up order, so the once-per-family lines sit on the first child who can carry them.
-- Fees with money received, a plan, or a waiver are left exactly as they are.
create or replace function public.fee_rebuild_family(p_team text, p_season integer, p_email text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare f public.athlete_fees;
begin
  -- clear first, so a family line can move from a later child to an earlier one
  delete from public.athlete_fee_lines l using public.athlete_fees a, public.registrations g
   where l.fee_id = a.id and g.id = a.registration_id and a.team_code = p_team and a.season_year = p_season and lower(g.email) = lower(p_email)
     and l.auto and not l.removed and (a.status = 'void' or public.fee_is_open(a));
  for f in select a.* from public.athlete_fees a join public.registrations g on g.id = a.registration_id
            where a.team_code = p_team and a.season_year = p_season and lower(g.email) = lower(p_email) and public.fee_reg_counts(g)
            order by g.created_at, g.id loop
    if public.fee_is_open(f) then perform public.fee_build_lines(f.id); end if;
  end loop;
end $$;
revoke all on function public.fee_rebuild_family(text, integer, text) from public;

-- ---------- create the fee when an athlete registers (replaces the single-amount version) ----------
create or replace function public.make_athlete_fee(p_reg uuid) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare r public.registrations; nid uuid;
begin
  select * into r from public.registrations where id = p_reg;
  if r.id is null or not public.fee_reg_counts(r) then return null; end if;
  select id into nid from public.athlete_fees where registration_id = p_reg; if nid is not null then return nid; end if;
  if not exists (select 1 from public.team_fee_items where team_code = r.team_code and season_year = r.season_year) then return null; end if;
  insert into public.athlete_fees (registration_id, team_code, season_year, amount_due) values (r.id, r.team_code, r.season_year, 0) returning id into nid;
  perform public.fee_build_lines(nid);
  return nid;
end $$;

-- Rejected athlete with nothing paid: fee cancelled, and the family's lines are re-worked (a once-per-family fee
-- moves to the next child). Un-rejected: back on.
create or replace function public.reg_fee_void_trg() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status = 'rejected' and old.status is distinct from 'rejected' then
    update public.athlete_fees set status = 'void', updated_at = now() where registration_id = new.id and status in ('unpaid','pending','paid') and public.fee_paid_total(id) = 0;
    perform public.fee_rebuild_family(new.team_code, new.season_year, new.email);
  elsif old.status = 'rejected' and new.status <> 'rejected' then
    update public.athlete_fees set status = 'unpaid', updated_at = now() where registration_id = new.id and status = 'void';
    perform public.fee_rebuild_family(new.team_code, new.season_year, new.email);
    perform public.refresh_fee_status(id) from public.athlete_fees where registration_id = new.id;
  end if;
  return new;
end $$;

create or replace function public.ensure_athlete_fees(p_team text, p_season integer) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare n integer := 0; r record;
begin
  if not public.is_team_money_admin(p_team) then raise exception 'Only this team''s team admin (or a site admin) can do that.'; end if;
  for r in select g.id from public.registrations g where g.team_code = p_team and g.season_year = p_season and public.fee_reg_counts(g)
           and not exists (select 1 from public.athlete_fees f where f.registration_id = g.id) order by g.created_at, g.id loop
    if public.make_athlete_fee(r.id) is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- ---------- team admin: save the whole list in one go ----------
-- p_items = [{id?, name, kind, amount, is_percent, applies, note}] in the order shown. Rows left out are deleted.
create or replace function public.save_fee_list(p_team text, p_season integer, p_items jsonb) returns void
language plpgsql security definer set search_path to 'public' as $$
declare x jsonb; i integer := 0; keep uuid[] := '{}'; nid uuid; me text := lower(coalesce(auth.jwt()->>'email',''));
        k text; ap text; amt numeric; pc boolean;
begin
  if not public.is_team_money_admin(p_team) then raise exception 'Only this team''s team admin (or a site admin) can change the team''s fees.'; end if;
  if p_season is null then raise exception 'Season missing.'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    i := i + 1; k := coalesce(nullif(x->>'kind',''), 'fee'); ap := coalesce(nullif(x->>'applies',''), 'athlete');
    amt := coalesce((x->>'amount')::numeric, 0); pc := coalesce((x->>'is_percent')::boolean, false) and k = 'discount';
    if nullif(trim(x->>'name'),'') is null then raise exception 'Every fee and discount needs a name.'; end if;
    if k not in ('fee','discount') or ap not in ('athlete','family','sibling','new','returning','choose') then raise exception 'Unknown fee type.'; end if;
    if amt < 0 then raise exception '"%": the amount can''t be negative. To take money off, add it as a discount.', trim(x->>'name'); end if;
    if pc and amt > 100 then raise exception '"%": a percent discount can''t be more than 100.', trim(x->>'name'); end if;
    nid := nullif(x->>'id','')::uuid;
    if nid is not null and exists (select 1 from public.team_fee_items where id = nid and team_code = p_team and season_year = p_season) then
      update public.team_fee_items set name = trim(x->>'name'), kind = k, amount = amt, is_percent = pc, applies = ap, note = nullif(trim(x->>'note'),''), sort = i, updated_at = now(), updated_by = me where id = nid;
    else
      insert into public.team_fee_items (team_code, season_year, name, kind, amount, is_percent, applies, note, sort, updated_by)
      values (p_team, p_season, trim(x->>'name'), k, amt, pc, ap, nullif(trim(x->>'note'),''), i, me) returning id into nid;
    end if;
    keep := keep || nid;
  end loop;
  delete from public.team_fee_items where team_code = p_team and season_year = p_season and not (id = any(keep));
  perform public.fee_list_sync(p_team, p_season);
end $$;

-- Team admin: put the current list on the athletes. Adds a fee to anyone without one and re-works everyone who
-- hasn't paid anything yet. Returns how many athletes' totals changed (or were added).
create or replace function public.apply_fee_list(p_team text, p_season integer) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare fam record; n integer := 0;
begin
  if not public.is_team_money_admin(p_team) then raise exception 'Only this team''s team admin (or a site admin) can do that.'; end if;
  create temp table if not exists _fee_before (id uuid primary key, amt numeric) on commit drop;
  delete from _fee_before;
  insert into _fee_before select id, amount_due from public.athlete_fees where team_code = p_team and season_year = p_season;
  perform public.ensure_athlete_fees(p_team, p_season);
  for fam in select distinct lower(g.email) as email from public.registrations g where g.team_code = p_team and g.season_year = p_season and public.fee_reg_counts(g) loop
    perform public.fee_rebuild_family(p_team, p_season, fam.email);
  end loop;
  select count(*) into n from public.athlete_fees a left join _fee_before b on b.id = a.id
   where a.team_code = p_team and a.season_year = p_season and (b.id is null or b.amt is distinct from a.amount_due);
  return n;
end $$;

-- ---------- team admin: one athlete's lines ----------
create or replace function public.fee_line_guard(p_fee uuid) returns public.athlete_fees
language plpgsql security definer set search_path to 'public' as $$
declare f public.athlete_fees;
begin
  select * into f from public.athlete_fees where id = p_fee; if f.id is null then raise exception 'Fee not found.'; end if;
  if not public.is_team_money_admin(f.team_code) then raise exception 'Only this team''s team admin (or a site admin) can change a fee.'; end if;
  if f.stripe_subscription_id is not null and f.status = 'plan' then raise exception 'This family is on a card payment plan — the amount can''t change while the plan is running.'; end if;
  if f.status = 'void' then raise exception 'This athlete was rejected, so there is no fee to change.'; end if;
  return f;
end $$;
revoke all on function public.fee_line_guard(uuid) from public;

-- Add a line: one from the team's list (p_item) or a one-off (name + kind + amount).
create or replace function public.fee_line_add(p_fee uuid, p_item uuid default null, p_name text default null, p_kind text default 'fee', p_amount numeric default null, p_note text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare f public.athlete_fees; it public.team_fee_items; nid uuid; me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  f := public.fee_line_guard(p_fee);
  if p_item is not null then
    select * into it from public.team_fee_items where id = p_item and team_code = f.team_code and season_year = f.season_year;
    if it.id is null then raise exception 'That fee isn''t on this team''s list any more.'; end if;
    if exists (select 1 from public.athlete_fee_lines where fee_id = p_fee and item_id = it.id and not removed) then raise exception 'This athlete already has "%".', it.name; end if;
    delete from public.athlete_fee_lines where fee_id = p_fee and item_id = it.id and removed;
    insert into public.athlete_fee_lines (fee_id, item_id, name, kind, amount, percent, family, auto, note, sort, changed_by)
    values (p_fee, it.id, it.name, it.kind, case when it.is_percent then 0 else coalesce(p_amount, it.amount) end, case when it.is_percent then it.amount end, it.applies = 'family', false, coalesce(nullif(trim(p_note),''), it.note), it.sort, me)
    returning id into nid;
  else
    if nullif(trim(p_name),'') is null then raise exception 'Give the line a name.'; end if;
    if p_kind not in ('fee','discount') then raise exception 'Unknown line type.'; end if;
    if p_amount is null or p_amount < 0 then raise exception 'Enter the amount.'; end if;
    insert into public.athlete_fee_lines (fee_id, name, kind, amount, auto, note, sort, changed_by)
    values (p_fee, trim(p_name), p_kind, p_amount, false, nullif(trim(p_note),''), 900, me) returning id into nid;
  end if;
  update public.athlete_fees set status = 'unpaid' where id = p_fee and status = 'waived';
  perform public.fee_recalc(p_fee);
  return nid;
end $$;

-- Change a line's amount, take it off for this athlete (p_removed = true) or put it back, with a reason the family sees.
create or replace function public.fee_line_set(p_line uuid, p_amount numeric default null, p_removed boolean default null, p_note text default null) returns void
language plpgsql security definer set search_path to 'public' as $$
declare l public.athlete_fee_lines; f public.athlete_fees; me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  select * into l from public.athlete_fee_lines where id = p_line; if l.id is null then raise exception 'Line not found.'; end if;
  f := public.fee_line_guard(l.fee_id);
  if p_amount is not null and p_amount < 0 then raise exception 'The amount can''t be negative.'; end if;
  update public.athlete_fee_lines set
     amount = case when p_amount is not null and percent is null then p_amount else amount end,
     percent = case when p_amount is not null and percent is not null then least(p_amount, 100) else percent end,
     removed = coalesce(p_removed, removed), note = case when p_note is null then note else nullif(trim(p_note),'') end,
     auto = false, changed_by = me
   where id = p_line;
  -- a one-off line that is taken off just goes away; a line from the team's list stays (crossed out) so it isn't put back
  delete from public.athlete_fee_lines where id = p_line and removed and item_id is null and nullif(trim(coalesce(note,'')),'') is null;
  perform public.fee_recalc(l.fee_id);
end $$;

-- "Adjust" from older pages: the difference becomes an Adjustment line, so the lines always add up.
create or replace function public.set_athlete_fee(p_fee uuid, p_amount numeric, p_note text default null, p_waive boolean default false) returns void
language plpgsql security definer set search_path to 'public' as $$
declare f public.athlete_fees; diff numeric; me text := lower(coalesce(auth.jwt()->>'email',''));
begin
  select * into f from public.athlete_fees where id = p_fee; if f.id is null then raise exception 'Fee not found.'; end if;
  if not public.is_team_money_admin(f.team_code) then raise exception 'Only this team''s team admin (or a site admin) can change a fee.'; end if;
  if f.stripe_subscription_id is not null and f.status = 'plan' then raise exception 'This family is on a card payment plan — the amount can''t change while the plan is running.'; end if;
  if p_waive then
    update public.athlete_fees set status = 'waived', note = nullif(trim(p_note),''), updated_at = now() where id = p_fee;
  else
    if p_amount is null or p_amount < 0 then raise exception 'Enter the amount.'; end if;
    update public.athlete_fees set note = nullif(trim(p_note),''), status = case when status in ('waived','void') then 'unpaid' else status end, updated_at = now() where id = p_fee;
    perform public.fee_recalc(p_fee);
    select p_amount - amount_due into diff from public.athlete_fees where id = p_fee;
    if diff <> 0 then
      insert into public.athlete_fee_lines (fee_id, name, kind, amount, auto, note, sort, changed_by)
      values (p_fee, 'Adjustment', case when diff > 0 then 'fee' else 'discount' end, abs(diff), false, nullif(trim(p_note),''), 950, me);
      perform public.fee_recalc(p_fee);
    end if;
  end if;
end $$;

-- ---------- settings: the fee itself now comes from the list ----------
create or replace function public.save_team_payment_settings(p jsonb) returns void
language plpgsql security definer set search_path to 'public' as $$
declare t text := p->>'team_code'; s integer := (p->>'season_year')::int; iv text := coalesce(nullif(p->>'plan_interval',''), 'month'); total numeric;
begin
  if not public.is_team_money_admin(t) then raise exception 'Only this team''s team admin (or a site admin) can change payment settings.'; end if;
  if s is null then raise exception 'Season missing.'; end if;
  if iv not in ('week','2weeks','month') then raise exception 'Choose weekly, every two weeks, or monthly.'; end if;
  perform public.fee_list_sync(t, s);
  select fee_amount into total from public.team_payment_settings where team_code = t and season_year = s;
  if coalesce((p->>'plan_enabled')::boolean, false) then
    if coalesce((p->>'plan_deposit')::numeric, 0) >= coalesce(total, 0) then raise exception 'The deposit must be less than what one athlete pays in full.'; end if;
    if coalesce((p->>'plan_installments')::int, 0) < 1 then raise exception 'Choose how many payments.'; end if;
    if nullif(p->>'plan_first_date','') is null then raise exception 'Choose the date of the first payment.'; end if;
  end if;
  update public.team_payment_settings set fee_note = nullif(trim(p->>'fee_note'),''),
      plan_enabled = coalesce((p->>'plan_enabled')::boolean, false), plan_deposit = coalesce((p->>'plan_deposit')::numeric, 0),
      plan_installments = coalesce((p->>'plan_installments')::int, 2), plan_first_date = nullif(p->>'plan_first_date','')::date, plan_interval = iv,
      accept_card = coalesce((p->>'accept_card')::boolean, true),
      accept_zelle = coalesce((p->>'accept_zelle')::boolean, false), zelle_info = nullif(trim(p->>'zelle_info'),''),
      accept_cashapp = coalesce((p->>'accept_cashapp')::boolean, false), cashapp_info = nullif(trim(p->>'cashapp_info'),''),
      accept_venmo = coalesce((p->>'accept_venmo')::boolean, false), venmo_info = nullif(trim(p->>'venmo_info'),''),
      accept_other = coalesce((p->>'accept_other')::boolean, false), other_info = nullif(trim(p->>'other_info'),''),
      updated_at = now(), updated_by = lower(coalesce(auth.jwt()->>'email',''))
   where team_code = t and season_year = s;
end $$;

-- ---------- parent: what do I owe — now with the breakdown and the team's list ----------
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
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.name, 'kind', i.kind, 'amount', i.amount, 'is_percent', i.is_percent, 'applies', i.applies, 'note', i.note) order by i.sort, i.created_at)
        from public.team_fee_items i where i.team_code = r.team_code and i.season_year = r.season_year), '[]'::jsonb),
    'fee', case when f.id is null then null else jsonb_build_object('id', f.id, 'amount_due', f.amount_due, 'discount', f.discount, 'discount_note', f.discount_note, 'status', f.status,
        'paid', public.fee_paid_total(f.id), 'balance', greatest(f.amount_due - public.fee_paid_total(f.id), 0), 'note', f.note,
        'plan_installments', f.plan_installments, 'plan_amount', f.plan_amount, 'plan_paid', f.plan_paid, 'plan_next_on', f.plan_next_on, 'plan_failed', f.plan_failed) end,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'kind', l.kind, 'amount', l.amount, 'percent', l.percent, 'family', l.family, 'removed', l.removed, 'note', l.note)
        order by (l.kind = 'discount'), l.sort, l.created_at) from public.athlete_fee_lines l where l.fee_id = f.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'method', p.method, 'kind', p.kind, 'amount', p.amount, 'status', p.status, 'reference', p.reference,
        'reported_at', p.reported_at, 'received_on', p.received_on, 'note', p.note) order by p.reported_at)
        from public.fee_payments p where p.fee_id = f.id), '[]'::jsonb));
end $$;
grant execute on function public.fee_for_registration(uuid, text) to anon, authenticated;

revoke all on function public.save_fee_list(text, integer, jsonb) from public;
revoke all on function public.apply_fee_list(text, integer) from public;
revoke all on function public.fee_line_add(uuid, uuid, text, text, numeric, text) from public;
revoke all on function public.fee_line_set(uuid, numeric, boolean, text) from public;
revoke all on function public.ensure_athlete_fees(text, integer) from public;
revoke all on function public.save_team_payment_settings(jsonb) from public;
revoke all on function public.set_athlete_fee(uuid, numeric, text, boolean) from public;
grant execute on function public.save_fee_list(text, integer, jsonb) to authenticated;
grant execute on function public.apply_fee_list(text, integer) to authenticated;
grant execute on function public.fee_line_add(uuid, uuid, text, text, numeric, text) to authenticated;
grant execute on function public.fee_line_set(uuid, numeric, boolean, text) to authenticated;
grant execute on function public.ensure_athlete_fees(text, integer) to authenticated;
grant execute on function public.save_team_payment_settings(jsonb) to authenticated;
grant execute on function public.set_athlete_fee(uuid, numeric, text, boolean) to authenticated;

-- Team admin overview: each athlete's fee, now with the lines.
create or replace view public.team_fee_overview as
  select f.id, f.registration_id, f.team_code, f.season_year, f.amount_due, f.discount, f.discount_note, f.status, f.note,
         f.stripe_subscription_id, f.plan_installments, f.plan_amount, f.plan_paid, f.plan_next_on, f.plan_failed, f.created_at,
         r.first_name, r.last_name, r.email, r.division, r.status as reg_status,
         public.fee_paid_total(f.id) as paid, greatest(f.amount_due - public.fee_paid_total(f.id), 0) as balance,
         (select count(*) from public.fee_payments p where p.fee_id = f.id and p.status = 'reported') as reported_count,
         coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'item_id', l.item_id, 'name', l.name, 'kind', l.kind, 'amount', l.amount, 'percent', l.percent, 'family', l.family, 'removed', l.removed, 'note', l.note)
            order by (l.kind = 'discount'), l.sort, l.created_at) from public.athlete_fee_lines l where l.fee_id = f.id), '[]'::jsonb) as lines
    from public.athlete_fees f join public.registrations r on r.id = f.registration_id;
alter view public.team_fee_overview set (security_invoker = true);
grant select on public.team_fee_overview to authenticated;

-- every existing team: keep "what a first child pays" in step with its list
do $$ declare t record; begin
  for t in select distinct team_code, season_year from public.team_fee_items loop perform public.fee_list_sync(t.team_code, t.season_year); end loop;
end $$;
