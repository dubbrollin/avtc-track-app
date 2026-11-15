-- Santa Clarita Warriors (SCW) belong in the Eastern League (they were Eastern last season; the realignment
-- only moved TT, BV, FP to the East and VRTC, LRR, NVGB to the West). The app had them in the Western League.
-- A team's league is read live (team_conference), so their Conference President, certification and lockouts follow.
-- Also re-sorts the teams so each league's teams are listed together, A-Z.
begin;
update public.league_teams set conference = 'East' where code = 'SCW';
update public.league_teams t set sort_order = s.n
  from (select code, row_number() over (order by conference = 'West', name) n from public.league_teams where conference is not null) s
 where s.code = t.code;
commit;
notify pgrst, 'reload schema';
select string_agg(code || '=' || conference, ', ' order by sort_order) from public.league_teams;
