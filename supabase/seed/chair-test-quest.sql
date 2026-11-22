-- Hand-placed "chair" quest for real-world testing of the quest camera flow, pinned at the centre
-- of Amit Chakma Engineering Building (OSM way 626520018), Nov 22–28. Needs migration
-- 20261122000004_chair_category.
--
-- The app only lists quests for the H3 res 7 region it's in at launch, so the same pin is listed in
-- three regions: the building's own (608737217606582271, slot 0) and the two main-campus regions
-- (608737217673691135, 608737217707245567, slot 2, after their OSM quests). verify-quest checks the
-- quest id, date and distance only, so any of them completes at the building.
--
--   supabase db query --remote -f supabase/seed/chair-test-quest.sql
--
-- ON CONFLICT DO NOTHING: re-running never touches a quest that already exists.
insert into public.daily_quests (region_h3, quest_date, slot, category, target, hint, place_name, osm_id)
select r.region_h3, d::date, r.slot, 'chair',
       extensions.st_setsrid(extensions.st_makepoint(-81.2763062, 43.004231), 4326)::extensions.geography,
       'Find a chair inside Amit Chakma Engineering Building.', 'Amit Chakma Engineering Building', null
from generate_series(date '2026-11-22', date '2026-11-28', interval '1 day') as d
cross join (values (608737217606582271::bigint, 0::smallint),
                   (608737217673691135::bigint, 2::smallint),
                   (608737217707245567::bigint, 2::smallint)) as r (region_h3, slot)
on conflict (region_h3, quest_date, slot) do nothing;
