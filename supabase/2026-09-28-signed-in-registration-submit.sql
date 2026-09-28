-- Registrations + proof-of-birth uploads failed with "new row violates row-level
-- security policy" whenever the browser was signed in (the insert policies only
-- covered anon). Same rule for signed-in users; read access is unchanged.
alter policy "parents can submit" on public.registrations to anon, authenticated;
alter policy "parents upload proof" on storage.objects to anon, authenticated;
