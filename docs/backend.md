# Backend: run, test, deploy

Off-device half of Fog of War IRL: Supabase (Postgres + PostGIS, Auth, Storage, Edge Functions).
API contract: [api.md](api.md). Owner: Justin (schema and contract originally written by Vishaal for Tiger Data, moved to Supabase).

## Prerequisites
- Node 22+ and npm
- Docker Desktop (running)
- Supabase CLI: `brew install supabase/tap/supabase`

## First run (local)
```sh
npm install
supabase start          # local Supabase stack in Docker; applies supabase/migrations/*
npm run db:test         # schema smoke test against the local database (cleans up after itself)
```
`supabase start` prints local URLs and keys. The local database is `postgres://postgres:postgres@127.0.0.1:54322/postgres` (the default for `npm run db:test`).

## Commands
| Command | Does |
|---|---|
| `npm run db:start` / `db:stop` | Start / stop the local Supabase stack |
| `npm run db:reset` | **Local only.** Recreate the local database and reapply every migration |
| `npm run db:push` | Apply new migrations to the linked cloud project (`supabase link --project-ref <ref>` first) |
| `npm run db:test` | Schema smoke test (`DATABASE_URL`, default: local) |

## Migrations
- Files: `supabase/migrations/<timestamp>_name.sql`, applied in order by the Supabase CLI. Create one with `supabase migration new <name>`.
- **Never edit a migration that's been pushed.** Add a new one. Locally, `npm run db:reset` replays everything.
- **Every new table must enable row-level security** and revoke API access (see `20261121000004`). Supabase exposes the `public` schema through its REST API; RLS with no policies is what keeps the app's anon key out.

## Schema at a glance
| Object | Kind | Notes |
|---|---|---|
| `profiles` | table | `id` = `auth.users.id` (cascade delete). Username unique, case-insensitive |
| `cleared_tiles` | table | `(user_id, h3)` primary key. H3 res 11 as bigint |
| `expeditions` | table | Client-generated UUID. `path` built server-side from pings |
| `daily_quests` | table | One per `(region_h3, quest_date)`. GIST index on `target` |
| `quest_completions` | table | One per `(quest_id, user_id)`. Stickers and streak |
| `location_pings` | table | Primary key `(user_id, ts)` so sync retries are no-ops. `segment_m`/`segment_s` computed by `sync` |
| `quest_attempts` | table | One row per vision-model call. 5/day limit |
| `daily_activity` | view | Per user per Toronto day: distance, active minutes, pings |
| `quest_finds_daily` | view | Per quest per Toronto day: finds, attempts |

Views use `security_invoker = on`, so the tables' row-level security also protects them.

## Cloud project
1. Create the project in the Supabase dashboard (region East US). Turn on anonymous sign-ins (Authentication → Sign In / Providers).
2. `supabase login`, then `supabase link --project-ref <ref>`.
3. `npm run db:push`.
4. Edge Function secrets: `supabase secrets set GEMINI_API_KEY=...`. Edge Functions already get `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` and `SUPABASE_DB_URL` automatically.

## Quests
Daily quests come from real objects in OpenStreetMap (PRD §10.4), so the target actually exists.
- `supabase/seed/osm-western-campus.json`: a trimmed Overpass snapshot of Western's main campus (benches, street lamps, trees, mailbox, named buildings).
- `node scripts/db/seed-quests.mjs [--days 7] [--start YYYY-MM-DD] > supabase/seed/quests.sql` picks one object per H3 res 7 region per day, rotating categories, with a hint naming the nearest building. Deterministic, and inserts with `on conflict do nothing`, so re-running never overwrites an existing quest.
- `npm run db:seed-quests` regenerates and applies it to the linked cloud project (the CLI asks for confirmation).
- Campus covers 2 regions. The UC Hill region (`872ab4634ffffff`) has the most variety; the smaller one has few mapped objects, so its quests repeat.
- Seeded so far: 2026-11-21 to 2026-11-27. Re-run with `--start` for later dates.
- For the stage demo (D11), insert a hand-placed quest at the venue for that day before seeding, and it won't be overwritten.


## Demo account
`npm run db:seed-demo -- --user <uuid> [--username name] --apply` gives one existing user two weeks of believable history for the stage demo:
- 6 completed quests with sticker images (`supabase/seed/stickers/`, placeholder emoji art) ending yesterday, so a 4-day streak; a couple of rejected attempts first
- 6 past expeditions (~7 km total) walked along real campus footpaths (`supabase/seed/osm-western-paths.json`), with GPS pings every ~8 m, cleared tiles, route lines and weekly activity
- the account's start date backdated 14 days, so the sticker book shows missed days
- quests for the past 14 days (same generator as `seed-quests`)

Ids are derived from the user id and every insert is `on conflict do nothing`, so re-running is safe. Needs `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in `.env` (stickers are uploaded with the secret key). Without `--apply` it only writes `supabase/seed/.demo.sql` (gitignored) for review.

On the demo phone:
1. Open the app once (creates the anonymous user), then Debug menu (triple-tap) → **Your user ID**: copy it.
2. Run the seed with that id.
3. Debug menu → **Restore fog from server**: the seeded fog appears immediately. Pull the profile to see stickers, streak and history.
