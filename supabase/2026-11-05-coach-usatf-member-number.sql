-- Coaches can record their USATF membership number (edited from Site Admin "Edit info" or the coach's own "My info").
alter table public.coaches add column if not exists usatf_member_number text;
