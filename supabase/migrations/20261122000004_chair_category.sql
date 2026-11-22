-- Adds 'chair' to the quest categories (hand-placed test quests indoors; OSM doesn't map chairs).
-- Keep in sync with docs/api.md §1 and QuestCategory.known in FogCore.
alter table daily_quests drop constraint daily_quests_category;
alter table daily_quests add constraint daily_quests_category check (category in
  ('bench', 'lamppost', 'tree', 'fire_hydrant', 'mural', 'statue', 'mailbox', 'chair'));
