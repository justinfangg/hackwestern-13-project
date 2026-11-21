#!/usr/bin/env node
// Schema smoke test against the LOCAL Supabase database (npm run db:start, then npm run db:test).
// Inserts sample rows for two throwaway users, checks constraints, idempotent sync inserts, the
// PostGIS geofence query, the stats views (including the Toronto day boundary), that the app's
// API roles can't read tables, and cascading deletes. Cleans up after itself.
// Originally written by Vishaal for Tiger Data; adapted for Supabase Postgres.
import { randomUUID } from "node:crypto";
import { connect } from "./connect.mjs";

const { sql, label } = connect();
const A = randomUUID(), B = randomUUID(), EXP = randomUUID();
const REGION = BigInt("0x872ab4634ffffff").toString(); // Western campus res 7 region (docs/mocks)
const TZ = "America/Toronto";
let failures = 0;
const check = (ok, msg) => { console.log(`${ok ? "PASS" : "FAIL"}  ${msg}`); if (!ok) failures++; };
const rejects = async (p) => { try { await p; return null; } catch (e) { return e.code ?? e.message; } };
// PostGIS points are (lng, lat).
const pt = (lat, lng) => sql`st_setsrid(st_makepoint(${lng}, ${lat}), 4326)::geography`;

let questId;
try {
  console.log(`db:test on ${label}\n`);
  const [{ pv }] = await sql`select extversion as pv from pg_extension where extname = 'postgis'`;
  console.log(`PostGIS ${pv}\n`);

  // ---------------------------------------------------------------- profiles (need auth users first)
  await sql`insert into auth.users (id) values (${A}), (${B})`;
  await sql`insert into profiles (id, username) values (${A}, ${"Test_" + A.slice(0, 8)}), (${B}, null)`;
  check(await rejects(sql`insert into profiles (id, username) values (${randomUUID()}, 'nobody_here')`) === "23503",
    "profiles.id must be an existing auth user (23503 foreign_key_violation)");
  const C = randomUUID();
  await sql`insert into auth.users (id) values (${C})`;
  check(await rejects(sql`insert into profiles (id, username) values (${C}, ${"test_" + A.slice(0, 8)})`) === "23505",
    "username uniqueness is case-insensitive (23505 unique_violation)");
  check(await rejects(sql`insert into profiles (id, username) values (${C}, 'no spaces!')`) === "23514",
    "username format rule enforced (23514 check_violation)");
  await sql`delete from auth.users where id = ${C}`;

  // ---------------------------------------------------------------- tiles, expedition, pings
  const tiles = ["8b2ab4634633fff", "8b2ab4634613fff", "8b2ab4634611fff"].map((h) => BigInt("0x" + h).toString());
  for (const h of tiles) await sql`insert into cleared_tiles values (${A}, ${h}, now()) on conflict do nothing`;
  const again = await sql`insert into cleared_tiles values (${A}, ${tiles[0]}, now()) on conflict do nothing`;
  check(again.count === 0, "re-sending a tile is a no-op (idempotent sync)");

  await sql`insert into expeditions (id, user_id, started_at) values (${EXP}, ${A}, now() - interval '20 minutes')`;

  // Toronto midnight boundary: 23:50 yesterday vs 00:10 today (local) must land in different days.
  const [{ midnight }] = await sql`select (date_trunc('day', now() at time zone ${TZ}) at time zone ${TZ}) as midnight`;
  const rows = [
    // [user, expedition, offset from local midnight, lat, lng, segment_m, segment_s]
    [A, null, "-10 minutes", 43.0105, -81.2745, 0, 0],
    [A, EXP, "10 minutes", 43.0095, -81.2738, 0, 0],
    [A, EXP, "10 minutes 7 seconds", 43.00944, -81.27375, 10.2, 7],
    [A, EXP, "10 minutes 14 seconds", 43.00938, -81.2737, 9.8, 7],
    [A, EXP, "10 minutes 21 seconds", 43.00931, -81.27364, 10.0, 7],
    [B, null, "10 minutes", 43.0087, -81.2731, 0, 0],
  ];
  for (const [u, e, off, lat, lng, m, s] of rows) {
    await sql`insert into location_pings (user_id, expedition_id, ts, location, accuracy_m, speed_mps, segment_m, segment_s)
              values (${u}, ${e}, ${midnight}::timestamptz + ${off}::interval, ${pt(lat, lng)}, 5, 1.4, ${m}, ${s})`;
  }
  const dup = await sql`insert into location_pings (user_id, ts, location) values (${A}, ${midnight}::timestamptz + interval '10 minutes', ${pt(43, -81)})
                        on conflict do nothing`;
  check(dup.count === 0, "duplicate (user_id, ts) ping is ignored (idempotent sync)");

  // ---------------------------------------------------------------- quest + attempts + completion
  [{ id: questId }] = await sql`
    insert into daily_quests (region_h3, quest_date, category, target, hint, place_name)
    values (${REGION}, (now() at time zone ${TZ})::date + 3650, 'bench', ${pt(43.0087, -81.2731)},
            'A wooden bench facing the hill.', 'University College Hill')
    returning id`;
  await sql`insert into quest_attempts (user_id, quest_id, ts, verified, confidence, reason) values
    (${A}, ${questId}, ${midnight}::timestamptz + interval '1 hour', false, 0.31, 'Looks like a screen.'),
    (${A}, ${questId}, ${midnight}::timestamptz + interval '1 hour 1 minute', true, 0.94, 'Real wooden bench.'),
    (${B}, ${questId}, ${midnight}::timestamptz + interval '2 hours', true, 0.88, 'A bench in a park.')`;
  await sql`insert into quest_completions (quest_id, user_id, sticker_url, confidence) values
    (${questId}, ${A}, 'https://example/stickers/a.png', 0.94), (${questId}, ${B}, 'https://example/stickers/b.png', 0.88)`;
  check(await rejects(sql`insert into quest_completions (quest_id, user_id) values (${questId}, ${A})`) === "23505",
    "one completion per (quest, user)");

  // ---------------------------------------------------------------- geofence (verify-quest's check)
  const [g] = await sql`
    select st_distance(target, ${pt(43.00885, -81.273)})::numeric(6,1) as near_m,
           st_dwithin(target, ${pt(43.00885, -81.273)}, 40) as near_ok,
           st_distance(target, ${pt(43.00935, -81.2725)})::numeric(6,1) as far_m,
           st_dwithin(target, ${pt(43.00935, -81.2725)}, 40) as far_ok
    from daily_quests where id = ${questId}`;
  check(g.near_ok && !g.far_ok, `geofence ST_DWithin 40 m: ${g.near_m} m -> ${g.near_ok}, ${g.far_m} m -> ${g.far_ok}`);

  // ---------------------------------------------------------------- stats views
  const activity = await sql`
    select day::text as local_day, round(distance_m::numeric, 1)::float as distance_m,
           round(active_minutes::numeric, 2)::float as active_min, pings::int
    from daily_activity where user_id = ${A} order by day`;
  console.log("\ndaily_activity for user A:");
  console.table(activity);
  check(activity.length === 2, "2 local days: yesterday 23:50 and today 00:10 Toronto");
  check(activity[0].pings === 1 && activity[1].pings === 4, "23:50 and 00:10 Toronto land on different days");
  check(Math.abs(activity[1].distance_m - 30) < 0.01, "distance = sum(segment_m)");
  await sql`insert into location_pings (user_id, expedition_id, ts, location, segment_m, segment_s)
            values (${A}, ${EXP}, ${midnight}::timestamptz + interval '10 minutes 28 seconds', ${pt(43.00925, -81.27358)}, 9.9, 7)`;
  const [late] = (await sql`select pings::int, distance_m from daily_activity where user_id = ${A} order by day desc limit 1`);
  check(late.pings === 5 && Math.abs(late.distance_m - 39.9) < 0.01, "a newly synced ping shows up immediately");

  const [f] = await sql`select finds::int, attempts::int from quest_finds_daily where quest_id = ${questId}`;
  check(f.finds === 2 && f.attempts === 3, "found_today = 2 users, 3 attempts");

  // ---------------------------------------------------------------- API roles are locked out
  for (const role of ["anon", "authenticated"]) {
    const err = await rejects(sql.begin(async (tx) => {
      await tx.unsafe(`set local role ${role}`);
      await tx`select count(*) from location_pings`;
    }));
    check(err === "42501", `${role} role can't read location_pings (42501 insufficient_privilege)`);
  }
  const viewErr = await rejects(sql.begin(async (tx) => {
    await tx.unsafe("set local role anon");
    await tx`select * from daily_activity`;
  }));
  check(viewErr === "42501", "anon role can't read the daily_activity view");
  const [rls] = await sql`
    select count(*) filter (where not relrowsecurity)::int as off from pg_class
    where relnamespace = 'public'::regnamespace and relkind = 'r'
      and relname in ('profiles','cleared_tiles','expeditions','daily_quests','quest_completions','location_pings','quest_attempts')`;
  check(rls.off === 0, "row-level security is on for every table");
} catch (err) {
  failures++;
  console.error("ERROR", err);
} finally {
  // ---------------------------------------------------------------- cleanup (also tests cascades)
  try {
    await sql`delete from auth.users where id in (${A}, ${B})`;
    const [{ left }] = await sql`
      select (select count(*) from profiles where id in (${A}, ${B}))
           + (select count(*) from location_pings where user_id in (${A}, ${B}))
           + (select count(*) from quest_attempts where user_id in (${A}, ${B}))
           + (select count(*) from cleared_tiles where user_id in (${A}, ${B}))
           + (select count(*) from expeditions where user_id in (${A}, ${B}))
           + (select count(*) from quest_completions where user_id in (${A}, ${B})) as left`;
    check(Number(left) === 0, "deleting an auth user cascades through profiles and every table");
    if (questId) await sql`delete from daily_quests where id = ${questId}`;
  } catch (err) {
    failures++;
    console.error("CLEANUP ERROR", err);
  }
  await sql.end();
  console.log(`\n${failures ? `${failures} FAILED` : "All checks passed"}`);
  process.exitCode = failures ? 1 : 0;
}
