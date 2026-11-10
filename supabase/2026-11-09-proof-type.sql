-- Proof of birth: the parent says which kind of document they uploaded.
alter table public.registrations add column if not exists proof_type text;
alter table public.registrations add column if not exists proof_type_other text;
alter table public.registrations drop constraint if exists registrations_proof_type_check;
alter table public.registrations add constraint registrations_proof_type_check
  check (proof_type is null or proof_type in ('birth_certificate','state_id','passport','other'));
notify pgrst, 'reload schema';
select 'proof type columns: ' || count(*) from information_schema.columns
 where table_schema='public' and table_name='registrations' and column_name in ('proof_type','proof_type_other');
