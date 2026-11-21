# Backend: run, test, deploy

Off-device half of Fog of War IRL: Tiger Data (Postgres + TimescaleDB + PostGIS) behind Supabase Edge Functions.
API contract: [api.md](api.md). Owner: Vishaal.

## Prerequisites
- Node 22+ and npm
- Docker Desktop (running)
- No local `psql` needed: `npm run db:psql` opens one inside the container

## First run
```sh
npm install
cp .env.example .env        # optional for local work: the defaults point at the Docker database
npm run db:up               # start TimescaleDB + PostGIS on localhost:5432
npm run db:migrate          # apply db/migrations/*.sql
npm run db:test             # schema smoke test (cleans up after itself)
```

## Commands
| Command | Does |
|---|---|
| `npm run db:up` / `db:down` | Start / stop the local database (data kept in the `pgdata` volume) |
| `npm run db:migrate` | Apply new migrations to `DATABASE_URL` (default: local Docker). Safe to rerun |
| `npm run db:migrate:tiger` | Apply new migrations to Tiger Cloud (`TIGER_DATABASE_URL`, SSL) |
| `npm run db:reset` | **Local only.** Delete the volume, recreate the database, migrate |
| `npm run db:psql` | psql shell inside the container |
| `npm run db:test` | Schema smoke test against the local database |

## Migrations
- Files: `db/migrations/NNN_name.sql`, applied in name order. Each runs in a transaction and is recorded in `schema_migrations` with a checksum.
- **Never edit an applied migration.** Add a new `NNN_` file. The runner refuses to continue if an applied file's checksum changes. Locally you can `db:reset` instead.
- A file starting with `-- migrate:no-transaction` runs outside a transaction (needed for `CALL refresh_continuous_aggregate`).
- We don't use `supabase/migrations`: Supabase's database isn't used at all.

## Schema at a glance
| Object | Kind | Notes |
|---|---|---|
| `profiles` | table | `id` = Supabase Auth user id. Username unique, case-insensitive |
| `cleared_tiles` | table | `(user_id, h3)` primary key. H3 res 11 as bigint |
| `expeditions` | table | Client-generated UUID. `path` built server-side from pings |
| `daily_quests` | table | One per `(region_h3, quest_date)`. GIST index on `target` |
| `quest_completions` | table | One per `(quest_id, user_id)`. Stickers and streak |
| `location_pings` | **hypertable** (1-day chunks) | Unique `(user_id, ts)`. `segment_m`/`segment_s` computed by `sync`. Columnstore after 7 days |
| `quest_attempts` | **hypertable** (7-day chunks) | One row per vision-model call. 5/day limit |
| `daily_activity` | **continuous aggregate** | Per user per Toronto day: distance, active minutes, pings. Real-time on |
| `quest_finds_daily` | **continuous aggregate** | Per quest per Toronto day: finds, attempts. Real-time on |

### Continuous aggregate gotchas
- Today's bucket is always computed live from raw rows. The refresh policies (every 5 min) materialize only finished days.
- **Don't run `refresh_continuous_aggregate(view, null, null)`.** It materializes today too, and today's new rows then stay hidden until tomorrow. Use `CALL run_job(<policy job id>)`, or end the window at local midnight (see the comment at the top of `004_continuous_aggregates.sql`).
- Rows inserted with old timestamps (an offline backlog, seed data) appear in the aggregates after the next refresh, so within about 5 minutes.

## Tiger Cloud (once the service exists)
1. Put the connection string in `.env` as `TIGER_DATABASE_URL` (don't paste it anywhere else).
2. `npm run db:migrate:tiger`.
3. Check TimescaleDB is ≥ 2.18 (the columnstore API): `select extversion from pg_extension where extname = 'timescaledb';`. Local Docker runs 2.32.1.
