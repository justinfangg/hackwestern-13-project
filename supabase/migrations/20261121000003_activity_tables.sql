-- Activity tables: GPS pings and quest verification attempts.
-- Plain Postgres tables (no TimescaleDB on Supabase Postgres 17). At hackathon scale, ordinary
-- B-tree indexes on (user_id, ts) are all these need.

-- ---------------------------------------------------------------- location_pings
-- Every accepted GPS fix (after the client's FixFilter). Source of truth for routes and distance.
create table location_pings (
  user_id        uuid        not null references profiles (id) on delete cascade,
  -- null for fixes outside an expedition (they count toward distance but aren't drawn as routes).
  expedition_id  uuid        references expeditions (id) on delete set null,
  ts             timestamptz not null,
  location       geography(Point, 4326) not null,
  accuracy_m     real,
  speed_mps      real,
  -- Distance and time since this user's previous accepted fix, computed by `sync` (including the
  -- last ping already stored, so it works across batches). Precomputing keeps the stats views a
  -- simple sum. Rule (implemented in sync): if the gap from the previous fix is > 5 min (or this is
  -- the user's first fix), both are 0, so a pause doesn't count as a teleport.
  segment_m      real        not null default 0,
  segment_s      real        not null default 0,
  -- (user_id, ts) is unique so sync is idempotent (ON CONFLICT DO NOTHING on retries). It also
  -- serves "this user's pings in a time range" queries.
  primary key (user_id, ts),
  constraint location_pings_segment_nonnegative check (segment_m >= 0 and segment_s >= 0)
);
-- Building an expedition's route line (ordered by time) when it ends.
create index location_pings_expedition_ts_idx on location_pings (expedition_id, ts)
  where expedition_id is not null;

-- ---------------------------------------------------------------- quest_attempts
-- One row per verify-quest call that reached the vision model.
--  * Enforces the 5-attempts-per-day limit (Q-12): count rows for (user, quest).
--  * Source for "N found today" (Q-11) via the quest_finds_daily view.
-- Geofence failures and vision-model errors are not stored (they don't use up an attempt).
-- verify-quest inserts the verified attempt in the same transaction as quest_completions, so a
-- user has at most one verified=true attempt per quest (keeps found_today = distinct users).
create table quest_attempts (
  id          bigint generated always as identity primary key,
  user_id     uuid        not null references profiles (id) on delete cascade,
  quest_id    uuid        not null references daily_quests (id) on delete cascade,
  ts          timestamptz not null default now(),
  verified    boolean     not null,
  confidence  real,
  -- Short user-facing reason from the model (shown in the retry UI).
  reason      text,
  constraint quest_attempts_confidence check (confidence is null or confidence between 0 and 1)
);
-- attempts_left = 5 - count(*) for (user, quest).
create index quest_attempts_user_quest_idx on quest_attempts (user_id, quest_id, ts desc);
create index quest_attempts_quest_ts_idx on quest_attempts (quest_id, ts);
