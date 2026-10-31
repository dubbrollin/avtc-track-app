-- 2026-10-30: per-division meet entry limits (max events per meet, and whether the last spot must be a relay) move from
-- the app's code (events.js ENTRY_RULES) and the check_entry() trigger into a table, edited on Site Admin > League Setup.
-- Both the app (events.js) and the database trigger read this table, so they can never disagree.
begin;

create table if not exists public.entry_limits (
  division               text primary key,              -- Sub-Gremlin, Gremlin, Bantam, Juniors, Youth, Intermediates
  max_events             integer not null check (max_events between 1 and 20),
  relay_required_for_max boolean not null default false, -- an athlete may only fill the LAST spot with a relay
  sort_order             integer not null default 100
);

alter table public.entry_limits enable row level security;
drop policy if exists "public read entry_limits" on public.entry_limits;
create policy "public read entry_limits" on public.entry_limits for select to anon, authenticated using (true);
drop policy if exists "site admin all" on public.entry_limits;
create policy "site admin all" on public.entry_limits for all to authenticated
  using (public.is_site_admin()) with check (public.is_site_admin());

drop trigger if exists zz_demo_readonly on public.entry_limits;
create trigger zz_demo_readonly before insert or update or delete on public.entry_limits
  for each row execute function public.demo_readonly();

-- Seed with the rules that were in events.js / check_entry(). Only when empty.
insert into public.entry_limits (division, max_events, relay_required_for_max, sort_order)
select * from (values
  ('Sub-Gremlin',   3, false, 10),
  ('Gremlin',       3, false, 20),
  ('Bantam',        4, true,  30),
  ('Juniors',       4, true,  40),
  ('Youth',         4, true,  50),
  ('Intermediates', 4, false, 60)
) as v(division, max_events, relay_required_for_max, sort_order)
where not exists (select 1 from public.entry_limits);

-- The entry check now reads the limits from entry_limits (falling back to the old built-in rules if a division has no row).
create or replace function public.check_entry() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare
  reg record; ev record; m record;
  cnt int; relay_cnt int; maxev int; relay_rule boolean;
begin
  select * into reg from public.registrations where id = new.registration_id;
  select * into ev  from public.meet_events   where id = new.meet_event_id;
  select * into m   from public.meets         where id = new.meet_id;
  if reg is null or ev is null or m is null then raise exception 'Bad entry'; end if;
  if ev.meet_id <> new.meet_id then raise exception 'Event does not belong to this meet'; end if;
  if reg.status <> 'verified' then raise exception 'Athlete is not certified yet'; end if;
  if not public.team_fees_cleared(reg.team_code, coalesce(m.season_year, reg.season_year)) then
    raise exception '%''s certification fees have not been confirmed paid by the Treasurer, so its athletes can''t be entered in meets yet (rule I.E). Only the Commissioner or the Conference President can overrule this.', reg.team_code;
  end if;
  if m.status <> 'open' or now() > m.entries_close then
    if not public.is_coach() then raise exception 'Entries for this meet are closed'; end if;
  end if;
  if (ev.division <> 'ALL' and ev.division <> reg.division) or (ev.gender <> 'Mixed' and ev.gender <> reg.gender) then
    raise exception 'Event is not for this athlete''s division/gender';
  end if;
  select count(*), count(*) filter (where e2.is_relay) into cnt, relay_cnt
    from public.entries e join public.meet_events e2 on e2.id = e.meet_event_id
    where e.registration_id = new.registration_id and e.meet_id = new.meet_id;
  cnt := cnt + 1; if ev.is_relay then relay_cnt := relay_cnt + 1; end if;
  -- Limits come from Site Admin > League Setup > Entry limits (table entry_limits).
  select l.max_events, l.relay_required_for_max into maxev, relay_rule from public.entry_limits l where l.division = reg.division;
  if maxev is null then
    maxev := case when reg.division in ('Sub-Gremlin','Gremlin') then 3 else 4 end;
    relay_rule := reg.division in ('Bantam','Juniors','Youth');
  end if;
  if cnt > maxev then raise exception 'Max % events for %', maxev, reg.division; end if;
  if relay_rule and cnt = maxev and relay_cnt = 0 then
    raise exception '% may only have % events if one is a relay', reg.division, maxev;
  end if;
  return new;
end $$;

commit;
