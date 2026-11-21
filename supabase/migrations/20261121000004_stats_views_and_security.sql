-- Stats views and access control.
--
-- These replace the TimescaleDB continuous aggregates from the Tiger Data version. They are plain
-- views computed on read, which is fast enough at hackathon scale. Days are calendar days in
-- America/Toronto (docs/api.md D2). `day` is a date.
--
-- security_invoker = on: the views run with the caller's permissions, so the row-level security
-- on the underlying tables also protects the views from the public REST API.

-- ---------------------------------------------------------------- daily_activity
-- Per user per local day: distance, active minutes, ping count. Feeds lifetime stats (P-3) and the
-- weekly activity chart (P-5).
create view daily_activity with (security_invoker = on) as
select
  user_id,
  (ts at time zone 'America/Toronto')::date as day,
  sum(segment_m)::double precision          as distance_m,
  (sum(segment_s) / 60.0)::double precision as active_minutes,  -- gaps > 5 min contribute 0
  count(*)                                  as pings
from location_pings
group by user_id, day;

-- ---------------------------------------------------------------- quest_finds_daily
-- Per quest per local day: successful finds and total attempts. Feeds "N explorers found today's
-- quest" (Q-11). verify-quest guarantees at most one verified attempt per (user, quest), so
-- finds = distinct users.
create view quest_finds_daily with (security_invoker = on) as
select
  quest_id,
  (ts at time zone 'America/Toronto')::date as day,
  count(*) filter (where verified) as finds,
  count(*)                         as attempts
from quest_attempts
group by quest_id, day;

-- ---------------------------------------------------------------- access control
-- RLS on with no policies = the anon/authenticated roles (the app's anon key and user JWTs) can't
-- read or write any row through Supabase's REST API. Edge Functions connect with the database URL
-- or the service role, which bypass RLS, and filter by the verified user id themselves.
alter table profiles          enable row level security;
alter table cleared_tiles     enable row level security;
alter table expeditions       enable row level security;
alter table daily_quests      enable row level security;
alter table quest_completions enable row level security;
alter table location_pings    enable row level security;
alter table quest_attempts    enable row level security;

-- Belt and braces: remove the table/view privileges Supabase grants to API roles by default.
revoke all on profiles, cleared_tiles, expeditions, daily_quests, quest_completions,
              location_pings, quest_attempts, daily_activity, quest_finds_daily
  from anon, authenticated;
