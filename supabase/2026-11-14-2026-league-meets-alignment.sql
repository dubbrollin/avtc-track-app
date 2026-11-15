-- Last season's (2026) league meets keep LAST season's alignment (from valleyconference.org, 2026 schedule, Week 7-8).
-- The realignment (TT, BV, FP -> East; VRTC, LRR, NVGB -> West) starts with the next season; league_teams holds the
-- new alignment. The 2026 Eastern/Western Open and League meets had been built from the new alignment by mistake.
--   2026 East: AVTC, LRR, NVGB, NPTC, PB, SCW, VRTC, VC, WVE
--   2026 West: BV, CAL, FP, L5, LAF, SFR, SCTC, TT   (plus Hawks Track Club, which isn't in the app)
begin;
update public.meets set team_codes = array['AVTC','LRR','NVGB','NPTC','PB','SCW','VRTC','VC','WVE']
 where season_year = 2026 and name in ('Eastern Open','Eastern League');
update public.meets set team_codes = array['BV','CAL','FP','L5','LAF','SFR','SCTC','TT']
 where season_year = 2026 and name in ('Western Open','Western League');
commit;
select string_agg(name || ': ' || array_to_string(team_codes, ','), ' | ' order by name) from public.meets
 where season_year = 2026 and name ~ '^(Eastern|Western) (Open|League)$';
