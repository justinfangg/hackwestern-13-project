-- 004: continuous aggregates (the Tiger Data showcase: PRD §10.6).
--
-- Both are created WITH NO DATA (creating WITH DATA can't run inside the migration's transaction)
-- and filled by their refresh policies.
--
-- Real-time aggregation is ON (materialized_only = false, which is no longer the default): queries
-- combine the materialized buckets with live raw rows newer than the last refresh, so today's
-- numbers are always current in the demo even between policy runs.
--
-- Buckets are calendar days in America/Toronto (docs/api.md D2), using time_bucket's timezone
-- argument so day boundaries follow local midnight, including DST changes. `day` is the timestamptz
-- of that local midnight. Get the calendar date with (day at time zone 'America/Toronto')::date.
--
-- Refresh caveats:
--  * Real-time aggregation only reads raw rows NEWER than the watermark (end of materialized data).
--    Rows inserted below the watermark stay invisible until the next refresh covers them.
--  * The policies never materialize today's unfinished bucket (window ends 1 hour ago), so today's
--    numbers are always live. DON'T run refresh_continuous_aggregate('<view>', null, null): a null end
--    materializes today too, moves the watermark to tonight's midnight, and today's new data then
--    stays hidden until tomorrow. To backfill older seed data (V9), stop at local midnight:
--      CALL refresh_continuous_aggregate('daily_activity', null,
--        date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto');
--    or run the policy job: CALL run_job(<job_id>); (both outside a transaction).
--  * The policies only look back start_offset (60 / 30 days). Older backfills need the manual call.

-- ---------------------------------------------------------------- daily_activity
-- Per user per local day: distance, active minutes, ping count. Feeds lifetime stats (P-3) and the
-- weekly activity chart (P-5) without scanning raw pings.
create materialized view daily_activity
with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  user_id,
  time_bucket(interval '1 day', ts, 'America/Toronto') as day,
  sum(segment_m)::double precision          as distance_m,      -- needs segment_m: no lag() in caggs
  (sum(segment_s) / 60.0)::double precision as active_minutes,  -- gaps > 5 min contribute 0
  count(*)                                  as pings
from location_pings
group by user_id, day
with no data;

-- Re-materialize the last 60 days every 5 minutes (only invalidated buckets are recomputed, so this
-- is cheap). end_offset 1 hour keeps the in-progress day on the real-time path.
select add_continuous_aggregate_policy('daily_activity',
  start_offset      => interval '60 days',
  end_offset        => interval '1 hour',
  schedule_interval => interval '5 minutes');

create index daily_activity_user_day_idx on daily_activity (user_id, day desc);

-- ---------------------------------------------------------------- quest_finds_daily
-- Per quest per local day: successful finds and total attempts. Feeds "N explorers found today's
-- quest" (Q-11). finds counts verified attempts; verify-quest guarantees at most one verified
-- attempt per (user, quest), so finds = distinct users. (A cagg can't use count(distinct).)
create materialized view quest_finds_daily
with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  quest_id,
  time_bucket(interval '1 day', ts, 'America/Toronto') as day,
  count(*) filter (where verified) as finds,
  count(*)                         as attempts
from quest_attempts
group by quest_id, day
with no data;

select add_continuous_aggregate_policy('quest_finds_daily',
  start_offset      => interval '30 days',
  end_offset        => interval '1 hour',
  schedule_interval => interval '5 minutes');

create index quest_finds_daily_quest_day_idx on quest_finds_daily (quest_id, day desc);
