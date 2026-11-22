#!/usr/bin/env node
// Seeds a lived-in "demo account" for the stage demo: two weeks of history for ONE existing user.
//
//   npm run db:seed-demo -- --user <uuid> [--username demo_explorer] [--apply]
//
// Find the user id in the app (Debug menu → "Your user ID") or in the Supabase dashboard
// (Authentication → Users). The user must already exist (open the app once on the demo phone).
//
// Generates, deterministically from the user id:
//   - daily quests for the past 14 days (same generator as seed-quests, on conflict do nothing)
//   - 6 completed quests with sticker PNGs (supabase/seed/stickers), ending yesterday → 4-day streak
//   - 6 past expeditions along real campus footpaths (supabase/seed/osm-western-paths.json), with
//     GPS pings every ~8 m, cleared H3 res 11 tiles, route lines, distances and durations
// Uploads the stickers to Storage (needs SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY in .env), writes
// the SQL to supabase/seed/.demo.sql, and with --apply runs it on the linked cloud project.
// Re-running is safe: every insert is ON CONFLICT DO NOTHING with ids derived from the user id.
// To see the fog on the demo phone afterwards: Debug menu → Reset fog, then relaunch (D8 restore).
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gridDisk, latLngToCell } from "h3-js";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
if (existsSync(join(root, ".env"))) process.loadEnvFile(join(root, ".env"));
const args = Object.fromEntries(process.argv.slice(2).flatMap((a, i, all) =>
  a.startsWith("--") ? [[a.slice(2), all[i + 1]?.startsWith("--") || all[i + 1] === undefined ? true : all[i + 1]]] : []));
const USER = String(args.user ?? "").toLowerCase();
if (!/^[0-9a-f-]{36}$/.test(USER)) {
  console.error("Usage: npm run db:seed-demo -- --user <uuid> [--username name] [--apply]");
  process.exit(1);
}
const USERNAME = typeof args.username === "string" ? args.username : null;
const UC_HILL = { lat: 43.0087, lon: -81.2731 };
const REGION = latLngToCell(UC_HILL.lat, UC_HILL.lon, 7);

// ---- helpers
const det = (label) => { // deterministic UUID (v4-shaped) from the user id + a label
  const h = createHash("sha256").update(`${USER}:${label}`).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
const rng = (seed) => { let a = seed >>> 0; return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; };
const R = 6_371_008.8;
const dist = (a, b) => {
  const rad = Math.PI / 180, dLat = (b.lat - a.lat) * rad, dLon = (b.lon - a.lon) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
};
const today = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Toronto" }).format(new Date());
const daysAgo = (n) => { const t = new Date(today + "T12:00:00Z"); t.setUTCDate(t.getUTCDate() - n); return t.toISOString().slice(0, 10); };
const local = (date, h, m = 0) => new Date(`${date}T${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:00-05:00`); // EST
const s = (v) => (v == null ? "null" : `'${String(v).replaceAll("'", "''")}'`);
const point = (p) => `extensions.st_setsrid(extensions.st_makepoint(${p.lon}, ${p.lat}), 4326)::extensions.geography`;

// ---- 1. quests for the past 14 days (reuses the quest generator)
const questSql = execFileSync("node", [join(root, "scripts/db/seed-quests.mjs"), "--start", daysAgo(14), "--days", "15"], { encoding: "utf8" });
const categoryByDate = {};
for (const m of questSql.matchAll(/\((\d+), '(\d{4}-\d{2}-\d{2})', '([a-z_]+)'/g)) {
  if (BigInt(m[1]).toString(16) === REGION) categoryByDate[m[2]] = m[3];
}

// ---- 2. walking routes on the campus path network
const paths = JSON.parse(readFileSync(join(root, "supabase/seed/osm-western-paths.json"), "utf8"));
const key = (p) => `${p[0]},${p[1]}`;
const graph = new Map();
for (const w of paths.ways) {
  for (let i = 1; i < w.geometry.length; i++) {
    const [a, b] = [key(w.geometry[i - 1]), key(w.geometry[i])];
    if (!graph.has(a)) graph.set(a, new Set());
    if (!graph.has(b)) graph.set(b, new Set());
    graph.get(a).add(b);
    graph.get(b).add(a);
  }
}
const toPt = (k) => { const [lat, lon] = k.split(",").map(Number); return { lat, lon }; };
const nearUC = [...graph.keys()].filter((k) => graph.get(k).size >= 3 && dist(toPt(k), UC_HILL) < 450);

function walk(seed, targetMeters) {
  const rand = rng(seed);
  let current = nearUC[Math.floor(rand() * nearUC.length)], previous = null;
  const route = [toPt(current)];
  let length = 0;
  for (let steps = 0; length < targetMeters && steps < 5000; steps++) {
    const options = [...graph.get(current)].filter((n) => n !== previous);
    const next = (options.length ? options : [...graph.get(current)])[Math.floor(rand() * (options.length || graph.get(current).size))];
    length += dist(toPt(current), toPt(next));
    previous = current;
    current = next;
    route.push(toPt(current));
  }
  // Densify to a fix every ~8 m, like FixFilter + PathInterpolator output.
  const out = [route[0]];
  for (let i = 1; i < route.length; i++) {
    const a = route[i - 1], b = route[i], d = dist(a, b), n = Math.max(1, Math.round(d / 8));
    for (let j = 1; j <= n; j++) out.push({ lat: a.lat + (b.lat - a.lat) * (j / n), lon: a.lon + (b.lon - a.lon) * (j / n) });
  }
  return out;
}

// ---- 3. expeditions, pings, tiles
const EXPEDITIONS = [[1, 1300], [2, 900], [3, 1500], [5, 800], [8, 1100], [12, 1250]]; // [days ago, metres]
const tileFirst = new Map(); // hex -> Date
const expRows = [], pingRows = [];
for (const [i, [ago, meters]] of EXPEDITIONS.entries()) {
  const id = det(`expedition-${i}`);
  const date = daysAgo(ago);
  const points = walk(parseInt(id.slice(0, 8), 16), meters);
  const start = local(date, 16, 10 * i);
  let t = start.getTime(), distance = 0, newTiles = 0;
  points.forEach((p, k) => {
    const segM = k === 0 ? 0 : dist(points[k - 1], p);
    const segS = k === 0 ? 0 : segM / 1.4;
    t += segS * 1000;
    distance += segM;
    const ts = new Date(Math.round(t));
    pingRows.push(`(${s(USER)}, ${s(id)}, ${s(ts.toISOString())}, ${point(p)}, 5, 1.4, ${segM.toFixed(2)}, ${segS.toFixed(2)})`);
    for (const cell of gridDisk(latLngToCell(p.lat, p.lon, 11), 1)) {
      if (!tileFirst.has(cell)) { tileFirst.set(cell, ts); newTiles++; }
    }
  });
  expRows.push({ id, started: start.toISOString(), ended: new Date(Math.round(t)).toISOString(), distance, newTiles });
}

// ---- 4. completions (+ attempts) and stickers
const COMPLETED = [1, 2, 3, 4, 7, 9];         // days ago: 4-day streak ending yesterday
const FAILED_FIRST = new Set([2, 7]);         // a rejected attempt before the success
const completions = COMPLETED.map((ago) => {
  const date = daysAgo(ago);
  const category = categoryByDate[date];
  if (!category) throw new Error(`No UC Hill quest generated for ${date}`);
  return { ago, date, category, id: det(`completion-${date}`), at: local(date, 15, 20 + ago).toISOString() };
});

const url = process.env.SUPABASE_URL, secret = process.env.SUPABASE_SERVICE_ROLE_KEY;
const stickerUrl = (c) => `${url}/storage/v1/object/public/stickers/${USER}/${c.id}.png`;

// ---- SQL
const sql = `-- Demo account seed for ${USER} (generated ${new Date().toISOString()})
${questSql}
insert into public.profiles (id) values (${s(USER)}) on conflict (id) do nothing;
-- Backdate the account so the past two weeks count as "missed days" where nothing was found (Q-13).
update public.profiles set created_at = least(created_at, ${s(local(daysAgo(14), 9).toISOString())}) where id = ${s(USER)};
${USERNAME ? `update public.profiles set username = ${s(USERNAME)} where id = ${s(USER)}
  and not exists (select 1 from public.profiles where lower(username) = lower(${s(USERNAME)}) and id <> ${s(USER)});` : ""}

insert into public.expeditions (id, user_id, started_at, ended_at, distance_m, new_tiles) values
${expRows.map((e) => `  (${s(e.id)}, ${s(USER)}, ${s(e.started)}, ${s(e.ended)}, ${e.distance.toFixed(1)}, ${e.newTiles})`).join(",\n")}
on conflict (id) do nothing;

insert into public.location_pings (user_id, expedition_id, ts, location, accuracy_m, speed_mps, segment_m, segment_s) values
${pingRows.map((r) => `  ${r}`).join(",\n")}
on conflict (user_id, ts) do nothing;

insert into public.cleared_tiles (user_id, h3, first_cleared_at) values
${[...tileFirst].map(([hex, ts]) => `  (${s(USER)}, ${BigInt("0x" + hex)}, ${s(ts.toISOString())})`).join(",\n")}
on conflict (user_id, h3) do nothing;

update public.expeditions e set path = r.line
from (select expedition_id, extensions.st_makeline(location::extensions.geometry order by ts)::extensions.geography as line
      from public.location_pings where user_id = ${s(USER)} and expedition_id is not null
      group by expedition_id having count(*) >= 2) r
where e.id = r.expedition_id and e.user_id = ${s(USER)} and e.path is null;

${completions.map((c) => `with q as (select id from public.daily_quests where region_h3 = ${BigInt("0x" + REGION)} and quest_date = '${c.date}'),
ins as (
  insert into public.quest_completions (id, quest_id, user_id, sticker_url, confidence, completed_at)
  select ${s(c.id)}, q.id, ${s(USER)}, ${s(stickerUrl(c))}, 0.93, ${s(c.at)} from q
  on conflict (quest_id, user_id) do nothing
  returning quest_id
)
insert into public.quest_attempts (user_id, quest_id, ts, verified, confidence, reason)
select ${s(USER)}, quest_id, ts, verified, conf, reason from ins, (values
  ${FAILED_FIRST.has(c.ago) ? `(timestamptz '${new Date(Date.parse(c.at) - 120_000).toISOString()}', false, 0.34, 'This looks like a photo of a screen. Point the camera at the real ${c.category.replaceAll("_", " ")}.'),\n  ` : ""}(timestamptz '${c.at}', true, 0.93, 'Found it!')
) as a(ts, verified, conf, reason);`).join("\n\n")}
`;
const sqlPath = join(root, "supabase/seed/.demo.sql");
writeFileSync(sqlPath, sql);

const km = (expRows.reduce((a, e) => a + e.distance, 0) / 1000).toFixed(1);
console.log(`Demo seed for ${USER}: ${expRows.length} expeditions (${km} km), ${pingRows.length} pings, ` +
  `${tileFirst.size} tiles, ${completions.length} completions (${completions.map((c) => c.category).join(", ")}).`);
console.log(`SQL written to ${sqlPath}`);

// ---- upload stickers (server-side key; never shipped in the app)
if (!url || !secret) {
  console.error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing in .env: stickers not uploaded.");
  process.exit(1);
}
for (const c of completions) {
  const png = readFileSync(join(root, `supabase/seed/stickers/${c.category}.png`));
  const res = await fetch(`${url}/storage/v1/object/stickers/${USER}/${c.id}.png`, {
    method: "POST",
    headers: { apikey: secret, Authorization: `Bearer ${secret}`, "Content-Type": "image/png", "x-upsert": "true" },
    body: png,
  });
  if (!res.ok) throw new Error(`Sticker upload failed (${res.status}): ${await res.text()}`);
}
console.log(`Uploaded ${completions.length} stickers.`);

if (args.apply) {
  execFileSync("supabase", ["db", "query", "--remote", "--yes", "-f", sqlPath], { cwd: root, stdio: ["ignore", "ignore", "inherit"] });
  console.log("Applied to the linked project.");
} else {
  console.log("Review the SQL, then re-run with --apply (or: supabase db query --remote -f supabase/seed/.demo.sql).");
}
