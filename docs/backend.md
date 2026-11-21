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
