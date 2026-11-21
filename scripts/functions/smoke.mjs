#!/usr/bin/env node
// End-to-end smoke test of the four Edge Functions against the LOCAL Supabase stack.
//   supabase start
//   supabase functions serve --env-file <file with GEMINI_API_KEY>   (in another terminal)
//   npm run functions:smoke
// Signs in anonymously, seeds today's quest, exercises every endpoint and the main error codes,
// then deletes the test user (cascades) and the seeded quest.
import { execSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { latLngToCell } from "h3-js";
import postgres from "postgres";

const env = Object.fromEntries(
  execSync("supabase status -o env", { encoding: "utf8" })
    .split("\n").filter((l) => l.includes("=")).map((l) => {
      const i = l.indexOf("=");
      return [l.slice(0, i), l.slice(i + 1).replace(/^"|"$/g, "")];
    }),
);
const API = env.API_URL, ANON = env.ANON_KEY ?? env.PUBLISHABLE_KEY, DB = env.DB_URL;
const sql = postgres(DB, { max: 1, onnotice: () => {} });
const TZ = "America/Toronto";

let failures = 0;
const check = (ok, msg, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${msg}${extra ? `  (${extra})` : ""}`); if (!ok) failures++; };

async function call(token, name, { method = "GET", query = "", body } = {}) {
  const res = await fetch(`${API}/functions/v1/${name}${query}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, apikey: ANON, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: res.status, json };
}

// A target near University College, Western, and a point 87 m away.
const TARGET = { lat: 43.0087, lng: -81.2731 };
const FAR = { lat: 43.00935, lng: -81.2725 };
let userId, questId;
try {
  // ---- anonymous sign-in
  const signup = await fetch(`${API}/auth/v1/signup`, {
    method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" }, body: "{}",
  }).then((r) => r.json());
  const token = signup.access_token;
  userId = signup.user?.id;
  check(!!token && !!userId, "anonymous sign-in");

  // ---- auth
  check((await call("not-a-jwt", "profile")).status === 401, "bad token -> 401");

  // ---- quest-today before seeding
  let r = await call(token, "quest-today", { query: `?lat=${TARGET.lat}&lng=${TARGET.lng}` });
  check(r.status === 200 && ["none_in_region", "active"].includes(r.json.status), "quest-today responds", r.json.status);
  check((await call(token, "quest-today")).json?.error?.code === "invalid_request", "quest-today without lat/lng -> invalid_request");

  // ---- seed today's quest in this region (replaces any existing one for the test)
  const region = BigInt("0x" + latLngToCell(TARGET.lat, TARGET.lng, 7)).toString();
  const [{ today }] = await sql`select (now() at time zone ${TZ})::date::text as today`;
  const [existing] = await sql`select id from daily_quests where region_h3 = ${region} and quest_date = ${today}`;
  if (existing) {
    questId = existing.id;
  } else {
    [{ id: questId }] = await sql`
      insert into daily_quests (region_h3, quest_date, category, target, hint, place_name)
      values (${region}, ${today}, 'bench', st_setsrid(st_makepoint(${TARGET.lng}, ${TARGET.lat}), 4326)::geography,
              'A wooden bench facing the hill, just below the tower.', 'University College Hill')
      returning id`;
  }
  r = await call(token, "quest-today", { query: `?lat=${TARGET.lat}&lng=${TARGET.lng}` });
  check(r.json.status === "active" && r.json.quest?.id === questId && r.json.attempts_left === 5,
    "quest-today returns the seeded quest", `found_today=${r.json.found_today}`);

  // ---- POST profile
  const name = `smoke_${randomUUID().slice(0, 8)}`;
  check((await call(token, "profile", { method: "POST", body: { username: name } })).json.username === name, "set username");
  check((await call(token, "profile", { method: "POST", body: { username: "no spaces!" } })).json.error?.code === "invalid_username",
    "bad username -> invalid_username");

  // ---- sync: an expedition with 4 pings 10 m apart, 7 s apart, and 2 tiles
  const expId = randomUUID();
  const t0 = Date.now() - 60_000;
  const pings = [0, 1, 2, 3].map((i) => ({
    expedition_id: expId, ts: new Date(t0 + i * 7000).toISOString(),
    lat: 43.0080 + i * 0.00009, lng: -81.2722, accuracy_m: 5, speed_mps: 1.4,
  }));
  const tiles = ["8b2ab4634633fff", "8b2ab4634613fff"].map((h3) => ({ h3, cleared_at: new Date(t0).toISOString() }));
  const exp = { id: expId, started_at: new Date(t0).toISOString(), ended_at: new Date(t0 + 30_000).toISOString(), distance_m: 30, new_tiles: 2 };
  r = await call(token, "sync", { method: "POST", body: { expeditions: [exp], pings, tiles: [...tiles, { h3: "zzz", cleared_at: exp.started_at }] } });
  check(r.status === 200 && r.json.new_tiles === 2 && r.json.total_tiles === 2 && r.json.rejected.tiles === 1,
    "sync stores tiles and drops bad rows", JSON.stringify(r.json));
  r = await call(token, "sync", { method: "POST", body: { expeditions: [exp], pings, tiles } });
  check(r.json.new_tiles === 0 && r.json.total_tiles === 2, "resending the same batch is a no-op");
  const [seg] = await sql`select round(sum(segment_m)::numeric, 1)::float as m, count(*)::int as n from location_pings where user_id = ${userId}`;
  check(seg.n === 4 && Math.abs(seg.m - 30) < 1.5, "pings stored once with segment distances", `${seg.n} pings, ${seg.m} m`);
  r = await call(token, "sync", { method: "POST", body: { tiles: Array.from({ length: 5001 }, () => tiles[0]) } });
  check(r.status === 413 && r.json.error?.code === "batch_too_large", "over-limit batch -> 413 batch_too_large");

  // ---- verify-quest error paths (no attempt used)
  const tinyJpeg = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==";
  const tinyPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==";
  const verify = (where, extra = {}) => call(token, "verify-quest", { method: "POST", body: {
    quest_id: questId, lat: where.lat, lng: where.lng, accuracy_m: 5, captured_at: new Date().toISOString(),
    photo_jpeg_base64: tinyJpeg, sticker_png_base64: tinyPng, ...extra } });
  r = await verify(FAR);
  check(r.status === 422 && r.json.error?.code === "too_far" && r.json.error.details?.radius_m === 40,
    "verify far away -> too_far", `${r.json.error?.details?.distance_m} m`);
  r = await verify(TARGET, { quest_id: randomUUID() });
  check(r.status === 404 && r.json.error?.code === "quest_not_found", "unknown quest -> quest_not_found");
  r = await verify(TARGET, { lat: 999 });
  check(r.status === 400 && r.json.error?.details?.fields?.includes("lat"), "bad lat -> invalid_request");

  // ---- verify-quest with Gemini (a 1x1 test image: expect a rejection, or 502 if Gemini is overloaded)
  const started = Date.now();
  r = await verify(TARGET);
  const secs = ((Date.now() - started) / 1000).toFixed(1);
  if (r.status === 200) {
    check(r.json.verified === false && r.json.attempts_left === 4 && r.json.completion === null,
      "Gemini rejects a blank image and uses one attempt", `${secs}s, reason: ${r.json.reason}`);
  } else {
    check(r.status === 502 && r.json.error?.code === "verifier_unavailable",
      "Gemini unavailable -> 502 verifier_unavailable (no attempt used)", `${secs}s`);
  }

  // ---- simulate a verified completion directly, then check profile + already_completed
  await sql`insert into quest_attempts (user_id, quest_id, verified, confidence, reason) values (${userId}, ${questId}, true, 0.95, 'test')`;
  await sql`insert into quest_completions (quest_id, user_id, sticker_url, confidence) values (${questId}, ${userId}, 'https://example.invalid/s.png', 0.95)`;
  r = await verify(TARGET);
  check(r.status === 409 && r.json.error?.code === "already_completed", "second verify -> already_completed");
  r = await call(token, "quest-today", { query: `?lat=${TARGET.lat}&lng=${TARGET.lng}` });
  check(r.json.completed_by_me === true && r.json.found_today >= 1, "quest-today shows completed + found_today");

  // ---- profile
  r = await call(token, "profile", { query: "?include=tiles" });
  const p = r.json;
  check(r.status === 200 && p.username === name, "profile returns username");
  check(p.stats.tiles_cleared === 2 && p.stats.quests_completed === 1 && p.stats.current_streak === 1,
    "profile stats", JSON.stringify(p.stats));
  check(p.stickers.length === 1 && p.stickers[0].category === "bench" && p.stickers[0].date === today, "profile stickers");
  check(p.weekly_activity.length === 8 && p.weekly_activity.at(-1).new_tiles === 2, "weekly_activity: 8 weeks, this week's tiles");
  check(p.expeditions.length === 1 && p.expeditions[0].duration_s === 30, "profile expeditions");
  check(p.routes.length === 1 && p.routes[0].points.length >= 2, "route built from pings");
  check(p.tiles?.length === 2 && p.tiles.includes("8b2ab4634633fff"), "include=tiles returns hex ids");
} catch (e) {
  failures++;
  console.error("ERROR", e);
} finally {
  if (userId) await sql`delete from auth.users where id = ${userId}`;
  // Only delete the quest if this run created it and nobody else completed it.
  if (questId) await sql`delete from daily_quests q where id = ${questId} and hint like 'A wooden bench facing%'
                         and not exists (select 1 from quest_completions c where c.quest_id = q.id)`;
  await sql.end();
  console.log(`\n${failures ? `${failures} FAILED` : "All checks passed"}`);
  process.exitCode = failures ? 1 : 0;
}
