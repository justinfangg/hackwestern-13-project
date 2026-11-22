-- Several quests per region per day (PRD Q-1 extended 2026-11-22): the Quests sheet lists them and
-- the player picks which one to accept. Existing quests become slot 0; extra quests take slots 1, 2, …
-- verify-quest already checks quests by id and date only, so it needs no change.
alter table daily_quests add column slot smallint not null default 0
  constraint daily_quests_slot_nonnegative check (slot >= 0);

alter table daily_quests drop constraint daily_quests_region_h3_quest_date_key;
alter table daily_quests add constraint daily_quests_region_date_slot_key unique (region_h3, quest_date, slot);
