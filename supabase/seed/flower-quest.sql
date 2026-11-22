-- Hand-placed "flower" quest, pinned at the Natural Sciences Building (OSM way 116779542), Nov 22–28.
-- Needs migration 20261122000005_flower_category.
--
-- The app only lists quests for the H3 res 7 region it's in at launch, so the same pin is listed in
-- the three campus regions, after their existing quests: main campus (608737217673691135, where the
-- pin is) and its neighbours (608737217707245567, 608737217606582271). verify-quest checks the quest
-- id, date and distance only, so any of them completes at the pin.
--
--   supabase db query --remote -f supabase/seed/flower-quest.sql
--
-- ON CONFLICT DO NOTHING: re-running never touches a quest that already exists.
insert into public.daily_quests (region_h3, quest_date, slot, category, target, hint, place_name, osm_id)
select r.region_h3, d::date, r.slot, 'flower',
       extensions.st_setsrid(extensions.st_makepoint(-81.2731287, 43.0105771), 4326)::extensions.geography,
       'Find a flower near the Natural Sciences Building.', 'Natural Sciences Building', null
from generate_series(date '2026-11-22', date '2026-11-28', interval '1 day') as d
cross join (values (608737217673691135::bigint, 3::smallint),
                   (608737217707245567::bigint, 3::smallint),
                   (608737217606582271::bigint, 1::smallint)) as r (region_h3, slot)
on conflict (region_h3, quest_date, slot) do nothing;
