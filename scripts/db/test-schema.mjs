#!/usr/bin/env node
// Schema smoke test against the LOCAL database only (npm run db:test).
// Inserts sample rows for two throwaway users, checks constraints, both continuous aggregates
// (real-time and after refresh), the columnstore policy (runs it for real on 10-day-old pings),
// the PostGIS geofence query, and cascading deletes. Cleans up after itself.
import { randomUUID } from "node:crypto";
import { connect } from "./connect.mjs";

if (process.argv.includes("--tiger")) {
  console.error("db:test only runs against the local database.");
  process.exit(1);
}
const { sql, label } = connect();
const A = randomUUID(), B = randomUUID(), EXP = randomUUID();
const REGION = BigInt("0x872ab4634ffffff").toString(); // Western campus res 7 region (docs/mocks)
const TZ = "America/Toronto";
let failures = 0;
const check = (ok, msg) => { console.log(`${ok ? "PASS" : "FAIL"}  ${msg}`); if (!ok) failures++; };
const rejects = async (p) => { try { await p; return null; } catch (e) { return e.code ?? e.message; } };
async function runRefreshPolicies() {
  const jobs = await sql`select job_id from timescaledb_information.jobs where proc_name = 'policy_refresh_continuous_aggregate'`;
  for (const { job_id } of jobs) await sql`call run_job(${job_id})`;
}
async function caggWatermark(view) {
  const [{ w }] = await sql`
    select _timescaledb_functions.to_timestamp(_timescaledb_functions.cagg_watermark(mat_hypertable_id)) as w
    from _timescaledb_catalog.continuous_agg where user_view_name = ${view}`;
  return w;
}
// PostGIS points are (lng, lat).
const pt = (lat, lng) => sql`st_setsrid(st_makepoint(${lng}, ${lat}), 4326)::geography`;

let questId;
try {
  console.log(`db:test on ${label}\n`);
  const [{ v }] = await sql`select extversion as v from pg_extension where extname = 'timescaledb'`;
  const [{ pv }] = await sql`select extversion as pv from pg_extension where extname = 'postgis'`;
  console.log(`TimescaleDB ${v}, PostGIS ${pv}\n`);

  // ---------------------------------------------------------------- profiles
  await sql`insert into profiles (id, username) values (${A}, ${"Test_" + A.slice(0, 8)}), (${B}, null)`;
  check(await rejects(sql`insert into profiles (id, username) values (${randomUUID()}, ${"test_" + A.slice(0, 8)})`) === "23505",
    "username uniqueness is case-insensitive (23505 unique_violation)");
  check(await rejects(sql`insert into profiles (id, username) values (${randomUUID()}, 'no spaces!')`) === "23514",
    "username format rule enforced (23514 check_violation)");

  // ---------------------------------------------------------------- tiles, expedition, pings
  const tiles = ["8b2ab4634633fff", "8b2ab4634613fff", "8b2ab4634611fff"].map((h) => BigInt("0x" + h).toString());
  for (const h of tiles) await sql`insert into cleared_tiles values (${A}, ${h}, now()) on conflict do nothing`;
  const again = await sql`insert into cleared_tiles values (${A}, ${tiles[0]}, now()) on conflict do nothing`;
  check(again.count === 0, "re-sending a tile is a no-op (idempotent sync)");

  await sql`insert into expeditions (id, user_id, started_at) values (${EXP}, ${A}, now() - interval '20 minutes')`;

  // Toronto midnight boundary: 23:50 yesterday vs 00:10 today (local) must land in different days.
  const [{ midnight }] = await sql`select (date_trunc('day', now() at time zone ${TZ}) at time zone ${TZ}) as midnight`;
  const rows = [
    // [user, expedition, ts expression offset from local midnight, lat, lng, segment_m, segment_s]
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
  // 10-day-old pings for user A: these are what the columnstore policy should compress.
  for (let i = 0; i < 50; i++) {
    await sql`insert into location_pings (user_id, ts, location, accuracy_m, speed_mps, segment_m, segment_s)
              values (${A}, now() - interval '10 days' + ${i * 7 + " seconds"}::interval,
                      ${pt(43.0078 + i * 0.00006, -81.272)}, 6, 1.3, ${i ? 6.7 : 0}, ${i ? 7 : 0})`;
  }
  const dup = await sql`insert into location_pings (user_id, ts, location) values (${A}, ${midnight}::timestamptz + interval '10 minutes', ${pt(43, -81)})
                        on conflict do nothing`;
  check(dup.count === 0, "duplicate (user_id, ts) ping is ignored (idempotent sync)");

  // ---------------------------------------------------------------- quest + attempts + completion
  [{ id: questId }] = await sql`
    insert into daily_quests (region_h3, quest_date, category, target, hint, place_name)
    values (${REGION}, (now() at time zone ${TZ})::date, 'bench', ${pt(43.0087, -81.2731)},
            'A wooden bench facing the hill.', 'University College Hill')
    on conflict (region_h3, quest_date) do update set hint = excluded.hint
    returning id`;
  await sql`insert into quest_attempts (user_id, quest_id, verified, confidence, reason) values
    (${A}, ${questId}, false, 0.31, 'Looks like a screen.'),
    (${A}, ${questId}, true, 0.94, 'Real wooden bench.'),
    (${B}, ${questId}, true, 0.88, 'A bench in a park.')`;
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

  // ---------------------------------------------------------------- continuous aggregates
  const activity = () => sql`
    select (day at time zone ${TZ})::date::text as local_day, round(distance_m::numeric, 1)::float as distance_m,
           round(active_minutes::numeric, 2)::float as active_min, pings::int
    from daily_activity where user_id = ${A} order by day`;
  const finds = () => sql`
    select (day at time zone ${TZ})::date::text as local_day, finds::int, attempts::int
    from quest_finds_daily where quest_id = ${questId}`;

  console.log("\ndaily_activity for user A (real-time, before any refresh):");
  const rt = await activity();
  console.table(rt);
  console.log("quest_finds_daily for today's quest (real-time):");
  console.table(await finds());

  // Run the real refresh policies (not a manual refresh with a null end, which would also
  // materialize today's unfinished bucket and hide new rows until tomorrow).
  await runRefreshPolicies();
  console.log("daily_activity for user A (after running the refresh policy):");
  const mat = await activity();
  console.table(mat);

  const today = mat.at(-1), yesterday = mat.at(-2), old = mat[0];
  check(mat.length === 3, "3 local days: 10 days ago, yesterday 23:50, today 00:10");
  check(yesterday.pings === 1 && today.pings === 4, "23:50 and 00:10 Toronto land on different days");
  check(Math.abs(today.distance_m - 30) < 0.01 && Math.abs(old.distance_m - 49 * 6.7) < 0.1, "distance = sum(segment_m)");
  // Only today is guaranteed identical: older buckets may have been materialized by the background
  // policy mid-test, and rows backfilled below the watermark only appear after the next refresh.
  check(JSON.stringify(rt.at(-1)) === JSON.stringify(mat.at(-1)), "today's row: real-time == after refresh");
  check(old.pings === 50, "after the refresh, all 50 backfilled pings are counted");
  const [f] = await finds();
  check(f.finds === 2 && f.attempts === 3, "found_today = 2 users, 3 attempts");

  const watermark = await caggWatermark("daily_activity");
  console.log(`daily_activity watermark (end of materialized data): ${watermark.toISOString()}, local midnight: ${midnight.toISOString()}`);
  check(watermark <= midnight, "refresh policy leaves today's bucket on the real-time path (watermark <= local midnight)");
  await sql`insert into location_pings (user_id, expedition_id, ts, location, segment_m, segment_s)
            values (${A}, ${EXP}, ${midnight}::timestamptz + interval '10 minutes 28 seconds', ${pt(43.00925, -81.27358)}, 9.9, 7)`;
  const [late] = (await activity()).slice(-1);
  check(late.pings === 5 && Math.abs(late.distance_m - 39.9) < 0.01, "a ping synced after the refresh shows up immediately (real-time)");
  const cagg = await sql`select view_name, materialized_only from timescaledb_information.continuous_aggregates order by 1`;
  check(cagg.length === 2 && cagg.every((c) => !c.materialized_only), "both caggs have real-time aggregation on");

  // ---------------------------------------------------------------- columnstore (compression)
  console.log("\nBackground jobs:");
  const jobs = await sql`
    select job_id, proc_name, hypertable_name, schedule_interval::text, config::text
    from timescaledb_information.jobs where hypertable_name is not null order by job_id`;
  console.table(jobs);
  const policy = jobs.find((j) => j.proc_name === "policy_compression" && j.hypertable_name === "location_pings");
  check(policy && JSON.parse(policy.config).compress_after === "7 days", "columnstore policy on location_pings after 7 days");
  check(jobs.filter((j) => j.proc_name === "policy_refresh_continuous_aggregate").length === 2, "2 cagg refresh policies");

  await sql`call run_job(${policy.job_id})`;
  const chunks = await sql`
    select chunk_name, range_start::date::text as range_start, is_compressed
    from timescaledb_information.chunks where hypertable_name = 'location_pings' order by range_start`;
  console.log("location_pings chunks after running the policy:");
  console.table(chunks);
  const oldChunk = chunks[0];
  check(oldChunk.is_compressed && chunks.slice(1).every((c) => !c.is_compressed),
    "10-day-old chunk compressed, recent chunks untouched");
  const stats = await sql`
    select chunk_name, before_compression_total_bytes::int as before_bytes, after_compression_total_bytes::int as after_bytes
    from chunk_columnstore_stats('location_pings') where after_compression_total_bytes is not null`;
  console.table(stats);
  const [{ n }] = await sql`select count(*)::int as n from location_pings where user_id = ${A} and ts < now() - interval '9 days'`;
  check(n === 50, "compressed pings are still queryable");
  // Read the timestamp as text: a JS Date would drop the microseconds and miss the duplicate.
  const [{ oldTs }] = await sql`select min(ts)::text as "oldTs" from location_pings where user_id = ${A}`;
  const dupOld = await sql`insert into location_pings (user_id, ts, location) values (${A}, ${oldTs}::timestamptz, ${pt(43, -81)})
                           on conflict do nothing`;
  check(dupOld.count === 0, "re-sent ping that now lives in a compressed chunk is still ignored (unique enforced)");
} catch (err) {
  failures++;
  console.error("ERROR", err);
} finally {
  // ---------------------------------------------------------------- cleanup (also tests cascades)
  try {
    await sql`delete from profiles where id in (${A}, ${B})`;
    const [{ left }] = await sql`
      select (select count(*) from location_pings where user_id in (${A}, ${B}))
           + (select count(*) from quest_attempts where user_id in (${A}, ${B}))
           + (select count(*) from cleared_tiles where user_id in (${A}, ${B}))
           + (select count(*) from expeditions where user_id in (${A}, ${B}))
           + (select count(*) from quest_completions where user_id in (${A}, ${B})) as left`;
    check(Number(left) === 0, "deleting a profile cascades through tables and hypertables (incl. compressed chunk)");
    if (questId) await sql`delete from daily_quests where id = ${questId}`;
    await runRefreshPolicies();
  } catch (err) {
    failures++;
    console.error("CLEANUP ERROR", err);
  }
  await sql.end();
  console.log(`\n${failures ? `${failures} FAILED` : "All checks passed"}`);
  process.exitCode = failures ? 1 : 0;
}
