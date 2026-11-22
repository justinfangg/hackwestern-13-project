-- Adds 'flower' to the quest categories (hand-placed quests; the campus OSM snapshot has no flower beds).
-- Keep in sync with docs/api.md §1 and QuestCategory.known in FogCore.
alter table daily_quests drop constraint daily_quests_category;
alter table daily_quests add constraint daily_quests_category check (category in
  ('bench', 'lamppost', 'tree', 'fire_hydrant', 'mural', 'statue', 'mailbox', 'chair', 'flower'));
