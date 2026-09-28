-- 2026-09-27: registrations.id had no default, so every form submission failed (null id).
alter table public.registrations alter column id set default gen_random_uuid();
