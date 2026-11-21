-- Core tables. PRD §10.6, plus the fixes noted inline. Originally written by Vishaal for Tiger Data;
-- moved to Supabase Postgres (same schema, no TimescaleDB).
--
-- H3 cells are stored as bigint. H3 ids are unsigned 64-bit, but the top (reserved) bit is always 0,
-- so every valid cell fits in a signed bigint as a positive number. JSON carries them as lowercase hex
-- strings (docs/api.md); convert at the Edge Function boundary.
--
-- Access control: Supabase exposes the public schema through its auto-generated REST API, so every
-- table has row-level security ON with NO policies (see the end of 20261121000004). The app can't
-- read or write tables directly; Edge Functions are the only client and filter every query by the
-- user_id from the verified JWT (PRD §10.1).

-- ---------------------------------------------------------------- profiles
create table profiles (
  -- = Supabase Auth user id. The row is created on the first call to any Edge Function.
  id          uuid primary key references auth.users (id) on delete cascade,
  -- null until POST profile sets it (docs/api.md §6).
  username    text,
  avatar_url  text,
  created_at  timestamptz not null default now(),
  -- Username rules (docs/api.md D1): 3–20 chars of A-Z a-z 0-9 _.
  constraint profiles_username_format check (username ~ '^[A-Za-z0-9_]{3,20}$')
);
-- Unique, case-insensitive ("Vishaal" blocks "vishaal"). Multiple null usernames are allowed.
create unique index profiles_username_lower_key on profiles (lower(username));

-- ---------------------------------------------------------------- cleared_tiles
-- One row per (user, res 11 cell), forever. Upsert-only: tiles never un-clear, so sync has no conflicts.
-- Keyed by cell, not by time; rows are deduplicated on (user_id, h3).
create table cleared_tiles (
  user_id           uuid        not null references profiles (id) on delete cascade,
  h3                bigint      not null,
  first_cleared_at  timestamptz not null,
  primary key (user_id, h3)
);
-- Weekly "new tiles" (P-5) groups a user's tiles by first_cleared_at.
create index cleared_tiles_user_time_idx on cleared_tiles (user_id, first_cleared_at);

-- ---------------------------------------------------------------- expeditions
create table expeditions (
  -- Client-generated UUID so sync retries are idempotent (docs/api.md §1). Default only for seeds.
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references profiles (id) on delete cascade,
  started_at  timestamptz not null,
  -- null while the expedition is running. Once set, sync never clears it again.
  ended_at    timestamptz,
  -- Client's running totals (last write wins during sync).
  distance_m  double precision not null default 0,
  new_tiles   integer          not null default 0,
  -- Built by the server from location_pings when ended_at arrives. Used for routes in GET profile.
  path        geography(LineString, 4326),
  constraint expeditions_time_order check (ended_at is null or ended_at >= started_at),
  constraint expeditions_nonnegative check (distance_m >= 0 and new_tiles >= 0)
);
-- Expedition history (P-4) and routes: a user's expeditions, newest first.
create index expeditions_user_started_idx on expeditions (user_id, started_at desc);

-- ---------------------------------------------------------------- daily_quests
create table daily_quests (
  id          uuid primary key default gen_random_uuid(),
  -- H3 res 7 region that shares this quest (PRD §6).
  region_h3   bigint not null,
  -- Calendar day in America/Toronto (docs/api.md D2).
  quest_date  date   not null,
  -- Same enum as docs/api.md §1. Extend both together.
  category    text   not null
    constraint daily_quests_category check (category in
      ('bench', 'lamppost', 'tree', 'fire_hydrant', 'mural', 'statue', 'mailbox')),
  target      geography(Point, 4326) not null,
  hint        text   not null,
  -- Added for the API (quest card + sticker detail): short label like 'University College Hill'.
  place_name  text,
  -- OpenStreetMap node/way id the target came from (null for hand-placed targets).
  osm_id      bigint,
  unique (region_h3, quest_date)
);
-- verify-quest's 40 m check is ST_DWithin(target, user_point, radius) on a single row, but a GIST
-- index also serves "quests near me" lookups and keeps the planner on the spatial index as data grows.
create index daily_quests_target_gist on daily_quests using gist (target);

-- ---------------------------------------------------------------- quest_completions
-- One row per user per quest they verified. The source of truth for stickers and the streak.
create table quest_completions (
  id            uuid primary key default gen_random_uuid(),
  quest_id      uuid not null references daily_quests (id) on delete cascade,
  user_id       uuid not null references profiles (id) on delete cascade,
  -- Object path in the private quest-photos bucket (never returned to clients, docs/api.md D10).
  photo_url     text,
  -- Public URL in the stickers bucket: <user_id>/<completion_id>.png.
  sticker_url   text,
  confidence    real,
  completed_at  timestamptz not null default now(),
  unique (quest_id, user_id),
  constraint quest_completions_confidence check (confidence is null or confidence between 0 and 1)
);
-- Sticker book (newest first) and streak, both per user.
create index quest_completions_user_time_idx on quest_completions (user_id, completed_at desc);
