-- 2026-11-26 fix (Riley hit it testing the practice meet): "DELETE requires a WHERE clause".
-- The live database refuses a DELETE with no WHERE (safeupdate). stage_sync_entries and staging_save_heat cleared their
-- temporary scratch tables with a bare DELETE; they now say "where true". Nothing else changes.
begin;

create or replace function public.stage_sync_entries(p_meet uuid, p_code text, p_relay boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
declare r record; evid uuid; who text := 'staging:' || coalesce(auth.jwt()->>'email','');
begin
  -- who should be entered in this event (individual athletes, and relay runners with their team letter + leg)
  create temp table if not exists _want (reg uuid, relay text, leg int, code text, name text, is_relay boolean, seed text) on commit drop;
  delete from _want where true;   -- (live database requires a WHERE on every DELETE)
  insert into _want
    select l.registration_id, null, null, h.event_code, h.event_name, false, l.seed_mark
      from public.stage_heats h join public.stage_lanes l on l.heat_id = h.id
     where h.meet_id = p_meet and h.event_code = p_code and not p_relay and not h.is_relay and l.registration_id is not null
    union all
    select u.reg, l.relay_letter, u.ord::int, h.event_code, h.event_name, true, null
      from public.stage_heats h join public.stage_lanes l on l.heat_id = h.id
      cross join lateral unnest(l.runners) with ordinality as u(reg, ord)
     where h.meet_id = p_meet and h.event_code = p_code and p_relay and h.is_relay;
  -- drop staging-made entries that are no longer in a heat
  delete from public.entries e using public.meet_events ev
   where ev.id = e.meet_event_id and e.meet_id = p_meet and ev.code = p_code
     and e.entered_by like 'staging:%'
     and ev.is_relay = p_relay and ev.is_field = false
     and not exists (select 1 from _want w where w.reg = e.registration_id);
  -- add / update the rest (check_entry refuses anything over the rule IV.C.1 limits)
  for r in select w.*, g.division, g.gender, g.first_name, g.last_name from _want w join public.registrations g on g.id = w.reg loop
    evid := public.stage_meet_event(p_meet, r.code, r.name, r.division, r.gender, r.is_relay);
    begin
      -- already entered: just update (check_entry runs BEFORE INSERT and would count the existing entry twice)
      update public.entries set relay_team = r.relay, leg = r.leg where registration_id = r.reg and meet_event_id = evid;
      if not found then
        insert into public.entries (meet_id, registration_id, meet_event_id, entered_by, seed_mark, relay_team, leg)
        values (p_meet, r.reg, evid, who, r.seed, r.relay, r.leg);
      end if;
    exception when others then
      raise exception '% % can''t be entered in the %: %', r.first_name, r.last_name, r.name, sqlerrm;
    end;
  end loop;
end $$;
revoke all on function public.stage_sync_entries(uuid,text,boolean) from public, anon, authenticated;

create or replace function public.staging_save_heat(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare hid uuid; v int; m uuid := (p->>'meet_id')::uuid; code text := p->>'event_code'; x jsonb; old record; who text := auth.jwt()->>'email';
begin
  perform public.stage_guard();
  if public.meet_is_locked(m) then raise exception 'This meet''s season is locked.'; end if;
  insert into public.stage_heats (meet_id, race_key, event_code, event_name, is_relay, groups, heat_no, lanes_total, status, updated_by)
  values (m, p->>'race_key', code, p->>'event_name', coalesce((p->>'is_relay')::boolean,false), p->'groups', (p->>'heat_no')::int,
          (p->>'lanes_total')::int, coalesce(p->>'status','draft'), who)
  on conflict (meet_id, race_key, heat_no) do update
     set event_name = excluded.event_name, groups = excluded.groups, lanes_total = excluded.lanes_total,
         status = excluded.status, version = public.stage_heats.version + 1, updated_by = who, updated_at = now()
  returning id, version into hid, v;

  -- keep "already in Meet Manager" for athletes/relays who stay in this heat; tell the laptop to scratch any that leave
  create temp table if not exists _old (lane int, registration_id uuid, relay_letter text, team_code text, runners uuid[], exported_at timestamptz) on commit drop;
  delete from _old where true;
  insert into _old select l.lane, l.registration_id, l.relay_letter, l.team_code, l.runners, l.exported_at from public.stage_lanes l where l.heat_id = hid;
  delete from public.stage_lanes where heat_id = hid;
  for x in select * from jsonb_array_elements(coalesce(p->'lanes','[]'::jsonb)) loop
    insert into public.stage_lanes (heat_id, lane, registration_id, team_code, relay_letter, runners, seed_mark, seed_value, exported_at)
    values (hid, (x->>'lane')::int, nullif(x->>'registration_id','')::uuid, x->>'team_code', nullif(x->>'relay_letter',''),
            case when x ? 'runners' and jsonb_typeof(x->'runners') = 'array' then array(select jsonb_array_elements_text(x->'runners')::uuid) end,
            nullif(x->>'seed_mark',''), nullif(x->>'seed_value','')::numeric,
            (select o.exported_at from _old o
              where (o.registration_id is not null and o.registration_id = nullif(x->>'registration_id','')::uuid)
                 or (o.relay_letter is not null and o.relay_letter = x->>'relay_letter' and o.team_code = x->>'team_code'
                     and o.runners = array(select jsonb_array_elements_text(coalesce(x->'runners','[]'::jsonb))::uuid))
              limit 1));
  end loop;
  -- a relay is 4 different runners from that team; nobody (and no relay team) is in the same race twice
  if exists (select 1 from public.stage_lanes l where l.heat_id = hid and l.runners is not null
              and ((select count(distinct u) from unnest(l.runners) u) <> 4
                   or exists (select 1 from unnest(l.runners) u left join public.registrations g on g.id = u where g.id is null or g.team_code <> l.team_code))) then
    raise exception 'A relay needs 4 different runners from its own team.';
  end if;
  if exists (select 1 from public.stage_lanes l join public.stage_heats h on h.id = l.heat_id
              where h.meet_id = m and h.race_key = p->>'race_key' and l.registration_id is not null
              group by l.registration_id having count(*) > 1)
     or exists (select 1 from public.stage_lanes l join public.stage_heats h on h.id = l.heat_id
              where h.meet_id = m and h.race_key = p->>'race_key' and l.relay_letter is not null
              group by l.team_code, l.relay_letter having count(*) > 1)
     or exists (select 1 from public.stage_lanes l join public.stage_heats h on h.id = l.heat_id cross join unnest(l.runners) u
              where h.meet_id = m and h.race_key = p->>'race_key' group by u having count(*) > 1) then
    raise exception 'Someone is in this race twice (another heat already has them).';
  end if;
  -- moved to another heat of the same race = still in Meet Manager: carry exported_at across
  update public.stage_lanes l set exported_at = o.exported_at
    from _old o
   where l.heat_id = hid and l.exported_at is null and o.exported_at is not null and o.registration_id = l.registration_id;
  insert into public.stage_scratches (meet_id, event_code, event_name, who, team_code, scratched_by)
  select m, code, p->>'event_name',
         case when o.registration_id is not null then (select g.first_name || ' ' || g.last_name from public.registrations g where g.id = o.registration_id)
              else o.team_code || ' relay ' || o.relay_letter end,
         o.team_code, who
    from _old o
   where o.exported_at is not null
     and not exists (select 1 from public.stage_lanes l join public.stage_heats h on h.id = l.heat_id
                      where h.meet_id = m and h.race_key = p->>'race_key'
                        and ((o.registration_id is not null and l.registration_id = o.registration_id)
                          or (o.relay_letter is not null and l.relay_letter = o.relay_letter and l.team_code = o.team_code)));
  perform public.stage_sync_entries(m, code, coalesce((p->>'is_relay')::boolean,false));
  return jsonb_build_object('id', hid, 'version', v);
end $$;
revoke all on function public.staging_save_heat(jsonb) from public, anon;
grant execute on function public.staging_save_heat(jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
