-- ============================================================================
-- Team hub (2026-10-18): every team gets its own page — the one place parents and coaches look for the team's
-- information — plus a photo gallery, a team store, and meet-day volunteer duties.
--
--   TEAM PAGE   team.html?team=AVTC  (public, no sign-in). About the team, practice info, contact, coaches, news posts,
--               the team's schedule, and the sign-in-only parts below. The team admin edits it (a site admin can too).
--   GALLERY     albums of photos for the team's parents and coaches. Coaches and team admins add photos; the team admin
--               can let parents add photos too. Private bucket "team-gallery". PART OF THE PAID TEAM EXTRAS.
--   STORE       the team sells its gear (shirts, hoodies, ...). Parents order and pay the team the same ways they pay
--               the team fee (card when the team's Stripe is on, or Zelle / Cash App / Venmo / check / cash with
--               "I sent it"); the team admin confirms, marks it ready, and hands it over. PART OF THE PAID TEAM EXTRAS.
--   VOLUNTEERS  for each meet the HOST team lists the duties that need people (clerk, starter, finish line, snack bar,
--               and the field events — long jump, high jump, shot put, javelin — which the VISITING teams run).
--               The host can hand a duty to a visiting team, or leave it open for a visiting team to pick. Then each
--               team fills its duties: parents sign themselves up, and coaches can add people by name. FREE (league
--               workflow).
-- Images for the public team page and the store live in the PUBLIC bucket "team-public" (<team code>/...).
-- Safe to run twice.
-- ============================================================================
begin;

-- ============================ who is who on a team ============================
create or replace function public.hub_me() returns text
language sql stable as $$ select lower(coalesce(auth.jwt()->>'email','')) $$;

create or replace function public.hub_season() returns integer
language sql stable security definer set search_path to 'public' as $$
  select nullif(value,'')::integer from public.app_settings where key = 'season_year'
$$;

-- The team's team admins, and league site admins, run the team page.
create or replace function public.team_can_manage(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select t is not null and (public.is_site_admin() or public.is_team_admin_of(t))
$$;
grant execute on function public.team_can_manage(text) to anon, authenticated;

-- What is the signed-in person to this team?  'admin' | 'coach' | 'parent' | null
--   admin  = the team's team admin, or a league site admin
--   coach  = an approved coach on the team (timers are not coaches)
--   parent = their email is on a registration for this team, this season, that the team has reviewed or certified
create or replace function public.team_member_role(t text) returns text
language plpgsql stable security definer set search_path to 'public' as $$
declare me text := public.hub_me(); season integer := public.hub_season();
begin
  if me = '' or t is null then return null; end if;
  if public.team_can_manage(t) then return 'admin'; end if;
  if exists (select 1 from public.coaches c where lower(c.email) = me and c.approved is true and c.team_code = t and c.role_type is distinct from 'timer') then return 'coach'; end if;
  if exists (select 1 from public.registrations r where lower(r.email) = me and r.team_code = t and r.season_year = season and r.status in ('reviewed','verified')) then return 'parent'; end if;
  return null;
end $$;
grant execute on function public.team_member_role(text) to anon, authenticated;

-- Every team the signed-in person belongs to (any role), for the dashboards.
create or replace function public.hub_my_teams() returns table(team_code text, role text)
language sql stable security definer set search_path to 'public' as $$
  select t.code, public.team_member_role(t.code) from public.league_teams t where t.active is distinct from false and public.team_member_role(t.code) is not null
$$;
grant execute on function public.hub_my_teams() to authenticated;

-- ============================ the team page ============================
create table if not exists public.team_pages (
  team_code text primary key,
  tagline text,
  about text,
  practice_info text,               -- where and when the team practices
  contact_name text, contact_email text, contact_phone text,
  website text, instagram text, facebook text,
  logo_path text,                   -- in bucket team-public
  banner_path text,
  gallery_parents_upload boolean not null default false,   -- parents may add photos to the gallery
  store_open boolean not null default false,
  store_note text,                  -- shown at the top of the store ("Orders close March 1 — pickup at practice")
  store_pickup text,                -- how orders are handed over
  updated_at timestamptz not null default now(), updated_by text);
alter table public.team_pages enable row level security;
drop policy if exists "team pages public read" on public.team_pages;
create policy "team pages public read" on public.team_pages for select to anon, authenticated using (true);
drop policy if exists "team pages manage" on public.team_pages;
create policy "team pages manage" on public.team_pages for all to authenticated using (public.team_can_manage(team_code)) with check (public.team_can_manage(team_code));
grant select on public.team_pages to anon, authenticated;
grant insert, update on public.team_pages to authenticated;

create or replace function public.team_pages_touch() returns trigger
language plpgsql as $$ begin new.updated_at := now(); new.updated_by := public.hub_me(); return new; end $$;
drop trigger if exists team_pages_touch on public.team_pages;
create trigger team_pages_touch before insert or update on public.team_pages for each row execute function public.team_pages_touch();

-- News / announcements on the team page. 'public' = anyone can read it on the page; 'team' = the team's parents and coaches only.
create table if not exists public.team_posts (
  id uuid primary key default gen_random_uuid(),
  team_code text not null,
  title text not null,
  body text not null default '',
  audience text not null default 'public' check (audience in ('public','team')),
  pinned boolean not null default false,
  created_by text, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index if not exists team_posts_team_idx on public.team_posts (team_code, pinned desc, created_at desc);
alter table public.team_posts enable row level security;
drop policy if exists "team posts read" on public.team_posts;
create policy "team posts read" on public.team_posts for select to anon, authenticated using (audience = 'public' or public.team_member_role(team_code) is not null);
drop policy if exists "team posts manage" on public.team_posts;
create policy "team posts manage" on public.team_posts for all to authenticated using (public.team_can_manage(team_code)) with check (public.team_can_manage(team_code));
grant select on public.team_posts to anon, authenticated;
grant insert, update, delete on public.team_posts to authenticated;
create or replace function public.team_posts_touch() returns trigger
language plpgsql as $$ begin new.updated_at := now(); if tg_op = 'INSERT' then new.created_by := public.hub_me(); end if; return new; end $$;
drop trigger if exists team_posts_touch on public.team_posts;
create trigger team_posts_touch before insert or update on public.team_posts for each row execute function public.team_posts_touch();

-- The coaches shown on the team page: names and roles only — never emails or phone numbers.
create or replace function public.team_page_coaches(p_team text) returns table(first_name text, last_name text, role_type text, admin_title text, division_or_age_group text, team_admin boolean)
language sql stable security definer set search_path to 'public' as $$
  select c.first_name, c.last_name, c.role_type, c.admin_title, c.division_or_age_group, c.team_admin
  from public.coaches c where c.team_code = p_team and c.approved is true and c.role_type is distinct from 'timer'
  order by c.team_admin desc, (c.role_type = 'head_coach') desc, c.last_name, c.first_name
$$;
grant execute on function public.team_page_coaches(text) to anon, authenticated;

-- Public pictures (team logo, banner, store item photos): bucket team-public, path <team code>/<anything>.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('team-public', 'team-public', true, 8388608, array['image/jpeg','image/png','image/gif','image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
create or replace function public.hub_path_team(p_name text) returns text
language sql immutable as $$ select nullif(split_part(p_name,'/',1),'') $$;
drop policy if exists "team public files read" on storage.objects;
create policy "team public files read" on storage.objects for select to anon, authenticated using (bucket_id = 'team-public');
drop policy if exists "team public files manage" on storage.objects;
create policy "team public files manage" on storage.objects for all to authenticated
  using (bucket_id = 'team-public' and public.team_can_manage(public.hub_path_team(name)))
  with check (bucket_id = 'team-public' and public.team_can_manage(public.hub_path_team(name)));

-- ============================ gallery (paid team extra) ============================
create or replace function public.gallery_on(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$ select public.team_has_extras(t) $$;
grant execute on function public.gallery_on(text) to anon, authenticated;

create table if not exists public.team_albums (
  id uuid primary key default gen_random_uuid(),
  team_code text not null,
  season_year integer not null,
  name text not null,
  description text,
  meet_id uuid references public.meets(id) on delete set null,
  cover_path text,
  created_by text, created_at timestamptz not null default now());
create index if not exists team_albums_team_idx on public.team_albums (team_code, season_year, created_at desc);
create table if not exists public.team_photos (
  id uuid primary key default gen_random_uuid(),
  album_id uuid not null references public.team_albums(id) on delete cascade,
  team_code text not null,
  path text not null,               -- in bucket team-gallery: <team code>/<album id>/<file>
  caption text,
  uploaded_by uuid not null default auth.uid(),
  uploader_name text,
  created_at timestamptz not null default now());
create index if not exists team_photos_album_idx on public.team_photos (album_id, created_at desc);
alter table public.team_albums enable row level security;
alter table public.team_photos enable row level security;

-- May this person add photos to the team's gallery?
create or replace function public.gallery_can_add(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce(public.gallery_on(t) and (public.team_member_role(t) in ('admin','coach')
    or (public.team_member_role(t) = 'parent' and coalesce((select p.gallery_parents_upload from public.team_pages p where p.team_code = t), false))), false)
$$;
grant execute on function public.gallery_can_add(text) to authenticated;

drop policy if exists "albums read" on public.team_albums;
create policy "albums read" on public.team_albums for select to authenticated using (public.gallery_on(team_code) and public.team_member_role(team_code) is not null);
drop policy if exists "albums manage" on public.team_albums;
create policy "albums manage" on public.team_albums for all to authenticated
  using (public.gallery_on(team_code) and public.team_member_role(team_code) in ('admin','coach'))
  with check (public.gallery_on(team_code) and public.team_member_role(team_code) in ('admin','coach'));
drop policy if exists "photos read" on public.team_photos;
create policy "photos read" on public.team_photos for select to authenticated using (public.gallery_on(team_code) and public.team_member_role(team_code) is not null);
drop policy if exists "photos add" on public.team_photos;
create policy "photos add" on public.team_photos for insert to authenticated
  with check (public.gallery_can_add(team_code) and uploaded_by = auth.uid()
    and exists (select 1 from public.team_albums a where a.id = album_id and a.team_code = team_photos.team_code));
drop policy if exists "photos edit own" on public.team_photos;
create policy "photos edit own" on public.team_photos for update to authenticated
  using (uploaded_by = auth.uid() or public.team_member_role(team_code) in ('admin','coach'))
  with check (uploaded_by = auth.uid() or public.team_member_role(team_code) in ('admin','coach'));
drop policy if exists "photos remove" on public.team_photos;
create policy "photos remove" on public.team_photos for delete to authenticated
  using (uploaded_by = auth.uid() or public.team_member_role(team_code) in ('admin','coach'));
grant select, insert, update, delete on public.team_albums to authenticated;
grant select, insert, update, delete on public.team_photos to authenticated;

create or replace function public.team_albums_touch() returns trigger
language plpgsql as $$ begin new.created_by := public.hub_me(); if new.season_year is null then new.season_year := public.hub_season(); end if; return new; end $$;
drop trigger if exists team_albums_touch on public.team_albums;
create trigger team_albums_touch before insert on public.team_albums for each row execute function public.team_albums_touch();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('team-gallery', 'team-gallery', false, 15728640, array['image/jpeg','image/png','image/gif','image/webp','image/heic','image/heif'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "gallery files read" on storage.objects;
create policy "gallery files read" on storage.objects for select to authenticated
  using (bucket_id = 'team-gallery' and public.gallery_on(public.hub_path_team(name)) and public.team_member_role(public.hub_path_team(name)) is not null);
drop policy if exists "gallery files add" on storage.objects;
create policy "gallery files add" on storage.objects for insert to authenticated
  with check (bucket_id = 'team-gallery' and public.gallery_can_add(public.hub_path_team(name)));
drop policy if exists "gallery files remove" on storage.objects;
create policy "gallery files remove" on storage.objects for delete to authenticated
  using (bucket_id = 'team-gallery' and (owner = auth.uid() or public.team_member_role(public.hub_path_team(name)) in ('admin','coach')));

-- ============================ team store (paid team extra) ============================
create or replace function public.store_is_open(t text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.team_has_extras(t) and coalesce((select p.store_open from public.team_pages p where p.team_code = t), false)
$$;
grant execute on function public.store_is_open(text) to anon, authenticated;

create table if not exists public.store_items (
  id uuid primary key default gen_random_uuid(),
  team_code text not null,
  name text not null,
  description text,
  price numeric(10,2) not null default 0 check (price >= 0),
  image_path text,                  -- in bucket team-public
  options jsonb not null default '[]',   -- [{"name":"Size","choices":["YS","YM","YL","S","M","L","XL"]}, ...]
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index if not exists store_items_team_idx on public.store_items (team_code, sort_order);
alter table public.store_items enable row level security;
drop policy if exists "store items read" on public.store_items;
create policy "store items read" on public.store_items for select to anon, authenticated using (public.team_can_manage(team_code) or (active and public.store_is_open(team_code)));
drop policy if exists "store items manage" on public.store_items;
create policy "store items manage" on public.store_items for all to authenticated using (public.team_can_manage(team_code)) with check (public.team_can_manage(team_code));
grant select on public.store_items to anon, authenticated;
grant insert, update, delete on public.store_items to authenticated;
create or replace function public.store_items_touch() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists store_items_touch on public.store_items;
create trigger store_items_touch before update on public.store_items for each row execute function public.store_items_touch();

create sequence if not exists public.store_order_no_seq;
create table if not exists public.store_orders (
  id uuid primary key default gen_random_uuid(),
  order_no integer not null default nextval('public.store_order_no_seq'),
  team_code text not null,
  season_year integer,
  email text not null,
  buyer_name text not null,
  phone text,
  athlete_name text,                -- which athlete / family the order is for (pickup)
  lines jsonb not null default '[]',    -- [{item_id,name,choices:{Size:"YM"},qty,unit_price}]
  total numeric(10,2) not null default 0,
  status text not null default 'new' check (status in ('new','sent','paid','ready','done','cancelled')),
     -- new = ordered, not paid · sent = parent says they paid · paid = team confirmed · ready = ready for pickup · done = handed over
  method text,                      -- card | zelle | cashapp | venmo | check | cash | other
  reference text,                   -- confirmation number / last 4 / "gave it to Coach T"
  paid_amount numeric(10,2),
  note text,                        -- from the parent
  admin_note text,                  -- from the team
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), updated_by text);
create index if not exists store_orders_team_idx on public.store_orders (team_code, created_at desc);
create index if not exists store_orders_email_idx on public.store_orders (lower(email));
alter table public.store_orders enable row level security;
drop policy if exists "store orders read" on public.store_orders;
create policy "store orders read" on public.store_orders for select to authenticated using (lower(email) = public.hub_me() or public.team_can_manage(team_code));
grant select on public.store_orders to authenticated;
-- No insert/update policies: orders change only through the functions below.

-- A parent places an order. Prices and the total come from the store, never from the browser.
create or replace function public.store_place_order(p_team text, p_lines jsonb, p_buyer_name text, p_phone text default null, p_athlete_name text default null, p_note text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.hub_me(); ln jsonb; q integer; ch jsonb; opt jsonb; v text; i integer; j integer;
  it_id uuid; it_name text; it_price numeric; it_options jsonb;
  outl jsonb := '[]'; tot numeric := 0; nid uuid; nm text := nullif(trim(coalesce(p_buyer_name,'')),'');
begin
  if me = '' then raise exception 'Please sign in to order.'; end if;
  if not public.store_is_open(p_team) then raise exception 'This team''s store is not open right now.'; end if;
  if nm is null then raise exception 'Add your name.'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Your cart is empty.'; end if;
  for i in 0 .. jsonb_array_length(p_lines) - 1 loop
    ln := p_lines -> i;
    it_id := null;
    select s.id, s.name, s.price, s.options into it_id, it_name, it_price, it_options
      from public.store_items s where s.id = (ln->>'item_id')::uuid and s.team_code = p_team and s.active;
    if it_id is null then raise exception 'One of the items is no longer available.'; end if;
    q := coalesce((ln->>'qty')::integer, 1);
    if q < 1 or q > 50 then raise exception 'Quantity for % must be 1 to 50.', it_name; end if;
    ch := coalesce(ln->'choices', '{}'::jsonb);
    -- every option the item has must be picked, with one of its choices
    if jsonb_typeof(it_options) = 'array' then
      for j in 0 .. jsonb_array_length(it_options) - 1 loop
        opt := it_options -> j;
        v := ch ->> (opt->>'name');
        if v is null or not exists (select 1 from jsonb_array_elements_text(coalesce(opt->'choices','[]'::jsonb)) c where c = v) then
          raise exception 'Pick a % for %.', lower(opt->>'name'), it_name; end if;
      end loop;
    end if;
    outl := outl || jsonb_build_array(jsonb_build_object('item_id', it_id, 'name', it_name, 'choices', ch, 'qty', q, 'unit_price', it_price));
    tot := tot + it_price * q;
  end loop;
  insert into public.store_orders (team_code, season_year, email, buyer_name, phone, athlete_name, lines, total, note, updated_by)
  values (p_team, public.hub_season(), me, nm, nullif(trim(coalesce(p_phone,'')),''), nullif(trim(coalesce(p_athlete_name,'')),''), outl, tot, nullif(trim(coalesce(p_note,'')),''), me)
  returning id into nid;
  return nid;
end $$;
revoke all on function public.store_place_order(text, jsonb, text, text, text, text) from public;
grant execute on function public.store_place_order(text, jsonb, text, text, text, text) to authenticated;

-- The parent says how they paid (Zelle, Cash App, ...). Card payments will be recorded by Stripe when that is switched on.
create or replace function public.store_report_payment(p_order uuid, p_method text, p_reference text default null) returns void
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.hub_me(); o public.store_orders;
begin
  select * into o from public.store_orders where id = p_order;
  if o.id is null or lower(o.email) <> me then raise exception 'Order not found.'; end if;
  if o.status not in ('new','sent') then raise exception 'This order is already %.', o.status; end if;
  if coalesce(p_method,'') not in ('zelle','cashapp','venmo','check','cash','other') then raise exception 'Pick how you paid.'; end if;
  update public.store_orders set status = 'sent', method = p_method, reference = nullif(trim(coalesce(p_reference,'')),''), updated_at = now(), updated_by = me where id = p_order;
end $$;
revoke all on function public.store_report_payment(uuid, text, text) from public;
grant execute on function public.store_report_payment(uuid, text, text) to authenticated;

-- A parent can cancel an order that hasn't been paid yet.
create or replace function public.store_cancel_order(p_order uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.hub_me(); o public.store_orders;
begin
  select * into o from public.store_orders where id = p_order;
  if o.id is null or lower(o.email) <> me then raise exception 'Order not found.'; end if;
  if o.status not in ('new','sent') then raise exception 'This order has been paid — ask the team to cancel it.'; end if;
  update public.store_orders set status = 'cancelled', updated_at = now(), updated_by = me where id = p_order;
end $$;
revoke all on function public.store_cancel_order(uuid) from public;
grant execute on function public.store_cancel_order(uuid) to authenticated;

-- The team moves an order along: paid (money arrived) → ready (for pickup) → done (handed over); or cancels it.
create or replace function public.store_update_order(p_order uuid, p_status text, p_admin_note text default null, p_paid_amount numeric default null, p_method text default null) returns void
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.hub_me(); o public.store_orders;
begin
  select * into o from public.store_orders where id = p_order;
  if o.id is null then raise exception 'Order not found.'; end if;
  if not public.team_can_manage(o.team_code) then raise exception 'Only this team''s team admin (or a site admin) can update orders.'; end if;
  if p_status not in ('new','sent','paid','ready','done','cancelled') then raise exception 'Unknown status.'; end if;
  update public.store_orders set status = p_status,
    admin_note = coalesce(nullif(trim(coalesce(p_admin_note,'')),''), admin_note),
    paid_amount = case when p_status in ('paid','ready','done') then coalesce(p_paid_amount, paid_amount, total) else paid_amount end,
    method = coalesce(nullif(p_method,''), method),
    updated_at = now(), updated_by = me where id = p_order;
end $$;
revoke all on function public.store_update_order(uuid, text, text, numeric, text) from public;
grant execute on function public.store_update_order(uuid, text, text, numeric, text) to authenticated;

-- ============================ meet volunteers (free — league workflow) ============================
-- A duty is one job at one meet: "Long jump" (3 people), "Starter" (1), "Snack bar" (4).
--   team_code         the team responsible for filling it; null = open for a visiting team to take
--   assigned_by_host  true when the host handed it to that team, false when the team picked it themselves
--   host_only         a host-team duty (not offered to visiting teams)
create table if not exists public.meet_duties (
  id uuid primary key default gen_random_uuid(),
  meet_id uuid not null references public.meets(id) on delete cascade,
  name text not null,
  category text not null default 'field' check (category in ('field','track','meet','hospitality','setup','other')),
  slots integer not null default 1 check (slots between 1 and 50),
  team_code text,
  assigned_by_host boolean not null default false,
  host_only boolean not null default false,
  time_note text,                   -- "8:00 AM – done" / "after the 400s"
  notes text,
  sort_order integer not null default 0,
  created_by text, created_at timestamptz not null default now());
create index if not exists meet_duties_meet_idx on public.meet_duties (meet_id, sort_order);

create table if not exists public.meet_volunteers (
  id uuid primary key default gen_random_uuid(),
  duty_id uuid not null references public.meet_duties(id) on delete cascade,
  meet_id uuid not null references public.meets(id) on delete cascade,
  team_code text not null,
  name text not null,
  phone text,
  email text,                       -- the signed-in email when a parent signs themselves up
  registration_id uuid references public.registrations(id) on delete set null,
  athlete_name text,                -- "parent of Maya Jones"
  added_by text,
  created_at timestamptz not null default now());
create unique index if not exists meet_volunteers_name_idx on public.meet_volunteers (duty_id, lower(name));
create index if not exists meet_volunteers_duty_idx on public.meet_volunteers (duty_id);
create index if not exists meet_volunteers_team_idx on public.meet_volunteers (meet_id, team_code);
alter table public.meet_duties enable row level security;
alter table public.meet_volunteers enable row level security;

create or replace function public.meet_host_team(p_meet uuid) returns text
language sql stable security definer set search_path to 'public' as $$ select m.host_team_code from public.meets m where m.id = p_meet $$;
grant execute on function public.meet_host_team(uuid) to anon, authenticated;

-- The host team's admins and coaches (and site admins) set up the meet's duties.
create or replace function public.meet_can_host_manage(p_meet uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.is_site_admin() or coalesce(public.team_member_role(public.meet_host_team(p_meet)) in ('admin','coach'), false)
$$;
grant execute on function public.meet_can_host_manage(uuid) to authenticated;

-- May this person run a team's side of the volunteering at this meet (claim duties, add people by name)?
create or replace function public.meet_team_can_manage(p_meet uuid, p_team text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.meet_can_host_manage(p_meet) or coalesce(public.meet_includes_team(p_meet, p_team) and public.team_member_role(p_team) in ('admin','coach'), false)
$$;
grant execute on function public.meet_team_can_manage(uuid, text) to authenticated;

-- Is any of my teams at this meet?
create or replace function public.meet_is_mine(p_meet uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.is_site_admin() or exists (select 1 from public.hub_my_teams() t where public.meet_includes_team(p_meet, t.team_code))
$$;
grant execute on function public.meet_is_mine(uuid) to authenticated;

drop policy if exists "duties read" on public.meet_duties;
create policy "duties read" on public.meet_duties for select to authenticated using (public.meet_is_mine(meet_id));
drop policy if exists "volunteers read" on public.meet_volunteers;
create policy "volunteers read" on public.meet_volunteers for select to authenticated
  using (lower(coalesce(email,'')) = public.hub_me() or public.meet_team_can_manage(meet_id, team_code));
grant select on public.meet_duties to authenticated;
grant select on public.meet_volunteers to authenticated;
-- No insert/update/delete policies: all changes go through the functions below.

-- How many people each duty has (parents see counts; names are only for their team's coaches and the host).
create or replace function public.duty_counts(p_meet uuid) returns table(duty_id uuid, taken integer)
language sql stable security definer set search_path to 'public' as $$
  select d.id, (select count(*)::integer from public.meet_volunteers v where v.duty_id = d.id) from public.meet_duties d where d.meet_id = p_meet and public.meet_is_mine(p_meet)
$$;
grant execute on function public.duty_counts(uuid) to authenticated;

-- Host: add or change a duty. Setting p_team hands the duty to that team (it must be competing at the meet).
create or replace function public.duty_save(p_id uuid, p_meet uuid, p_name text, p_category text, p_slots integer, p_team text default null, p_time text default null, p_notes text default null, p_host_only boolean default false, p_sort integer default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.hub_me(); nm text := nullif(trim(coalesce(p_name,'')),''); nid uuid; t text := nullif(trim(coalesce(p_team,'')),''); mid uuid := p_meet; host text; cur public.meet_duties;
begin
  if p_id is not null then select * into cur from public.meet_duties where id = p_id; if cur.id is null then raise exception 'Duty not found.'; end if; mid := cur.meet_id; end if;
  if not public.meet_can_host_manage(mid) then raise exception 'Only the host team''s coaches and team admin (or a site admin) can set up this meet''s duties.'; end if;
  if nm is null then raise exception 'Name the duty.'; end if;
  if coalesce(p_category,'') not in ('field','track','meet','hospitality','setup','other') then raise exception 'Pick a category.'; end if;
  if coalesce(p_slots,0) < 1 or p_slots > 50 then raise exception 'How many people? (1 to 50)'; end if;
  host := public.meet_host_team(mid);
  if t is not null and not public.meet_includes_team(mid, t) then raise exception 'That team is not competing at this meet.'; end if;
  if p_host_only then t := host; end if;
  if p_id is null then
    insert into public.meet_duties (meet_id, name, category, slots, team_code, assigned_by_host, host_only, time_note, notes, sort_order, created_by)
    values (mid, nm, p_category, p_slots, t, t is not null and t <> host, coalesce(p_host_only,false), nullif(trim(coalesce(p_time,'')),''), nullif(trim(coalesce(p_notes,'')),''),
            coalesce(p_sort, (select coalesce(max(sort_order),0)+10 from public.meet_duties where meet_id = mid)), me)
    returning id into nid;
  else
    update public.meet_duties set name = nm, category = p_category, slots = p_slots, host_only = coalesce(p_host_only,false),
      team_code = t, assigned_by_host = (t is not null and t <> host),
      time_note = nullif(trim(coalesce(p_time,'')),''), notes = nullif(trim(coalesce(p_notes,'')),''), sort_order = coalesce(p_sort, sort_order)
    where id = p_id returning id into nid;
    -- people from a team that no longer has this duty come off it
    delete from public.meet_volunteers v where v.duty_id = p_id and (t is null or v.team_code <> t);
  end if;
  return nid;
end $$;
revoke all on function public.duty_save(uuid, uuid, text, text, integer, text, text, text, boolean, integer) from public;
grant execute on function public.duty_save(uuid, uuid, text, text, integer, text, text, text, boolean, integer) to authenticated;

create or replace function public.duty_delete(p_id uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare mid uuid;
begin
  select meet_id into mid from public.meet_duties where id = p_id; if mid is null then return; end if;
  if not public.meet_can_host_manage(mid) then raise exception 'Only the host team can remove this meet''s duties.'; end if;
  delete from public.meet_duties where id = p_id;
end $$;
revoke all on function public.duty_delete(uuid) from public;
grant execute on function public.duty_delete(uuid) to authenticated;

-- Host: start from the standard VYC meet list (host jobs + the field events for the visiting teams). Adds only when the meet has no duties yet.
create or replace function public.duties_add_standard(p_meet uuid) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.hub_me(); host text; n integer := 0;
begin
  if not public.meet_can_host_manage(p_meet) then raise exception 'Only the host team can set up this meet''s duties.'; end if;
  if exists (select 1 from public.meet_duties where meet_id = p_meet) then return 0; end if;
  host := public.meet_host_team(p_meet);
  insert into public.meet_duties (meet_id, name, category, slots, team_code, assigned_by_host, host_only, time_note, notes, sort_order, created_by)
  select p_meet, v.name, v.cat, v.slots, case when v.is_host then host end, false, v.is_host, v.t, v.notes, v.ord, me
  from (values
    ('Set-up crew',            'setup',       4, true,  '7:00 AM',           'Hurdles, blocks, pits, tents, tables', 10),
    ('Clerk of the course',    'meet',        2, true,  '8:15 AM – done',    'Check athletes in and line up the heats', 20),
    ('Starter',                'track',       1, true,  '8:45 AM – done',    null, 30),
    ('Finish line & timing',   'track',       3, true,  '8:45 AM – done',    'Help the timers; hand off results', 40),
    ('Hurdle crew',            'track',       3, true,  'Hurdle races',      'Set and clear hurdles', 50),
    ('Announcer',              'meet',        1, true,  'All day',           null, 60),
    ('Awards table',           'meet',        2, true,  '10:00 AM – done',   'Ribbons and results posting', 70),
    ('Snack bar',              'hospitality', 4, true,  'Shifts',            null, 80),
    ('First aid',              'meet',        1, true,  'All day',           null, 90),
    ('Clean-up crew',          'setup',       4, true,  'After the last race', null, 100),
    ('Long jump',              'field',       3, false, '8:30 AM – done',    'Visiting team: measure, rake, record', 200),
    ('High jump',              'field',       3, false, '8:30 AM – done',    'Visiting team: set the bar, judge, record', 210),
    ('Shot put',               'field',       3, false, '8:30 AM – done',    'Visiting team: measure, return the shots, record', 220),
    ('Javelin',                'field',       3, false, '8:30 AM – done',    'Visiting team: measure, retrieve, record', 230)
  ) v(name, cat, slots, is_host, t, notes, ord);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.duties_add_standard(uuid) from public;
grant execute on function public.duties_add_standard(uuid) to authenticated;

-- A visiting team takes an open duty (or gives back one it took). The host can't be overruled: a duty the host assigned stays put.
create or replace function public.duty_claim(p_duty uuid, p_team text, p_take boolean default true) returns void
language plpgsql security definer set search_path to 'public' as $$
declare d public.meet_duties; host text;
begin
  select * into d from public.meet_duties where id = p_duty; if d.id is null then raise exception 'Duty not found.'; end if;
  if not public.meet_team_can_manage(d.meet_id, p_team) then raise exception 'Only a coach or team admin of that team can take duties for it.'; end if;
  host := public.meet_host_team(d.meet_id);
  if d.host_only and not public.meet_can_host_manage(d.meet_id) then raise exception 'That is a host-team duty.'; end if;
  if p_take then
    if d.team_code is not null and d.team_code <> p_team then raise exception 'Another team already has this duty.'; end if;
    update public.meet_duties set team_code = p_team, assigned_by_host = public.meet_can_host_manage(d.meet_id) and p_team <> host where id = p_duty;
  else
    if d.team_code is distinct from p_team then return; end if;
    if d.assigned_by_host and not public.meet_can_host_manage(d.meet_id) then raise exception 'The host assigned this duty to your team — ask the host team to change it.'; end if;
    if d.host_only then raise exception 'Host-team duties stay with the host.'; end if;
    update public.meet_duties set team_code = null, assigned_by_host = false where id = p_duty;
    delete from public.meet_volunteers where duty_id = p_duty;
  end if;
end $$;
revoke all on function public.duty_claim(uuid, text, boolean) from public;
grant execute on function public.duty_claim(uuid, text, boolean) to authenticated;

-- Sign up for a duty. A parent signs THEMSELVES up for their own team's duties; a coach / team admin (or the host) can
-- add anyone by name for their team. Every signed-up person is tied to the team the duty belongs to.
create or replace function public.volunteer_add(p_duty uuid, p_name text, p_phone text default null, p_registration uuid default null, p_athlete_name text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me text := public.hub_me(); d public.meet_duties; nm text := nullif(trim(coalesce(p_name,'')),''); taken integer; nid uuid; mgr boolean; em text;
begin
  if me = '' then raise exception 'Please sign in.'; end if;
  select * into d from public.meet_duties where id = p_duty; if d.id is null then raise exception 'Duty not found.'; end if;
  if d.team_code is null then raise exception 'No team has taken this duty yet.'; end if;
  if nm is null then raise exception 'Whose name goes on it?'; end if;
  mgr := public.meet_team_can_manage(d.meet_id, d.team_code);
  if not mgr then
    if public.team_member_role(d.team_code) is distinct from 'parent' then raise exception 'This duty belongs to another team.'; end if;
    em := me;   -- a parent signs themselves (or their household) up: it stays tied to their login so they can take it back off
  else em := null; end if;
  select count(*) into taken from public.meet_volunteers where duty_id = p_duty;
  if taken >= d.slots then raise exception 'This duty is full — thank you! Pick another one.'; end if;
  if exists (select 1 from public.meet_volunteers v where v.duty_id = p_duty and lower(v.name) = lower(nm)) then raise exception '% is already signed up for this.', nm; end if;
  insert into public.meet_volunteers (duty_id, meet_id, team_code, name, phone, email, registration_id, athlete_name, added_by)
  values (p_duty, d.meet_id, d.team_code, nm, nullif(trim(coalesce(p_phone,'')),''), em, p_registration, nullif(trim(coalesce(p_athlete_name,'')),''), me)
  returning id into nid;
  return nid;
end $$;
revoke all on function public.volunteer_add(uuid, text, text, uuid, text) from public;
grant execute on function public.volunteer_add(uuid, text, text, uuid, text) to authenticated;

create or replace function public.volunteer_remove(p_id uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v public.meet_volunteers;
begin
  select * into v from public.meet_volunteers where id = p_id; if v.id is null then return; end if;
  if lower(coalesce(v.email,'')) <> public.hub_me() and not public.meet_team_can_manage(v.meet_id, v.team_code) then raise exception 'You can only take yourself off a duty.'; end if;
  delete from public.meet_volunteers where id = p_id;
end $$;
revoke all on function public.volunteer_remove(uuid) from public;
grant execute on function public.volunteer_remove(uuid) to authenticated;

commit;
