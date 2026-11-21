-- 003: time-series tables (hypertables) and the columnstore (compression) policy.
--
-- We call create_hypertable() explicitly instead of CREATE TABLE ... WITH (tsdb.hypertable):
-- on TimescaleDB 2.32 the WITH form silently enables the columnstore with a "compress after one
-- chunk interval" policy. We want to choose those settings ourselves (7 days for pings, none for
-- attempts).

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
  -- FIX vs PRD: distance and time since this user's previous accepted fix, computed by `sync`
  -- (including the last ping already stored, so it works across batches). Continuous aggregates
  -- can't use window functions like lag(), so daily distance has to be sum(segment_m) over
  -- precomputed values. Rule (implemented in sync): if the gap from the previous fix is > 5 min
  -- (or this is the user's first fix), both are 0, so a pause doesn't count as a teleport.
  segment_m      real        not null default 0,
  segment_s      real        not null default 0,
  constraint location_pings_segment_nonnegative check (segment_m >= 0 and segment_s >= 0)
);
-- 1-day chunks: small data, and it gives the compression policy whole days to convert.
select create_hypertable('location_pings', by_range('ts', interval '1 day'));

-- FIX vs PRD: unique (user_id, ts) makes sync idempotent (ON CONFLICT DO NOTHING on retries).
-- Unique indexes on a hypertable must include the partitioning column (ts), which this does.
-- It also serves "this user's pings in a time range" queries.
create unique index location_pings_user_ts_key on location_pings (user_id, ts desc);
-- Building an expedition's route line (ordered by time) when it ends.
create index location_pings_expedition_ts_idx on location_pings (expedition_id, ts)
  where expedition_id is not null;

-- Columnstore (TimescaleDB's new name for native compression since 2.18; this is 2.32, so we use
-- the columnstore API rather than the deprecated add_compression_policy). Segment by user so a
-- user's pings stay together; order by time so range scans stay cheap.
alter table location_pings set (
  timescaledb.enable_columnstore = true,
  timescaledb.segmentby = 'user_id',
  timescaledb.orderby = 'ts desc'
);
call add_columnstore_policy('location_pings', after => interval '7 days');

-- ---------------------------------------------------------------- quest_attempts
-- FIX vs PRD: one row per verify-quest call that reached the vision model.
--  * Enforces the 5-attempts-per-day limit (Q-12): count rows for (user, quest).
--  * Source for the quest_finds_daily continuous aggregate. A continuous aggregate must be built
--    on a hypertable, so it can't sit on the plain quest_completions table as the PRD had it.
-- Geofence failures and vision-model errors are not stored (they don't use up an attempt).
-- verify-quest inserts the verified attempt in the same transaction as quest_completions, so a
-- user has at most one verified=true attempt per quest (keeps found_today = distinct users).
create table quest_attempts (
  user_id     uuid        not null references profiles (id) on delete cascade,
  quest_id    uuid        not null references daily_quests (id) on delete cascade,
  ts          timestamptz not null default now(),
  verified    boolean     not null,
  confidence  real,
  -- Short user-facing reason from the model (shown in the retry UI).
  reason      text,
  constraint quest_attempts_confidence check (confidence is null or confidence between 0 and 1)
);
-- 7-day chunks: very low volume. No columnstore: rows are tiny and recent ones are hot.
select create_hypertable('quest_attempts', by_range('ts', interval '7 days'));
-- attempts_left = 5 - count(*) for (user, quest).
create index quest_attempts_user_quest_idx on quest_attempts (user_id, quest_id, ts desc);
