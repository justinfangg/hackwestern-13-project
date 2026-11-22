#!/usr/bin/env node
// Generates daily quests from real OpenStreetMap objects (PRD §10.4) and writes them as SQL.
//
//   node scripts/db/seed-quests.mjs [--days 7] [--start YYYY-MM-DD] [--slots 2] > supabase/seed/quests.sql
//
// --slots N seeds N quests per region per day (slot 0 = the original daily quest). Each extra slot
// is inserted from three candidates in different categories; the database keeps the first one
// that doesn't repeat the category or object of an earlier slot that day, so extra quests stay
// distinct even when slot 0 came from an earlier run with different options.
//
// Input: supabase/seed/osm-western-campus.json (an Overpass snapshot of Western's main campus).
// For each H3 res 7 region that has objects, and each day, it picks one real object
// deterministically (same input → same quests), rotating categories so consecutive days differ.
// The hint names the nearest named building. Inserts use ON CONFLICT DO NOTHING, so re-running
// never overwrites a quest that already exists (or that people have already completed).
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { latLngToCell } from "h3-js";

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) =>
  a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc, []));
const DAYS = Number(args.days ?? 7);
const torontoToday = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Toronto" }).format(new Date());
const START = args.start ?? torontoToday;
const SLOTS = Math.max(1, Number(args.slots ?? 1));
const CANDIDATES = 3;

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const osm = JSON.parse(readFileSync(join(root, "supabase/seed/osm-western-campus.json"), "utf8"));

// ---- classify objects
const categoryOf = (t) =>
  t.amenity === "bench" ? "bench"
  : t.highway === "street_lamp" ? "lamppost"
  : t.natural === "tree" ? "tree"
  : t.emergency === "fire_hydrant" ? "fire_hydrant"
  : t.tourism === "artwork" ? "mural"
  : t.amenity === "post_box" ? "mailbox"
  : null;

const objects = osm.elements.flatMap((e) => {
  const category = categoryOf(e.tags);
  return category && e.lat && e.lon ? [{ ...e, category }] : [];
});
const buildings = osm.elements.filter((e) => e.tags.building && e.tags.name && e.lat && e.lon);

const R = 6_371_008.8;
const dist = (a, b) => {
  const rad = Math.PI / 180, dLat = (b.lat - a.lat) * rad, dLon = (b.lon - a.lon) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
};
const nearestBuilding = (o) => {
  let best = null;
  for (const b of buildings) {
    const d = dist(o, b);
    if (!best || d < best.d) best = { name: b.tags.name, d };
  }
  return best && best.d <= 200 ? best : null;
};

const describe = (o) => {
  const near = nearestBuilding(o);
  const where = near ? (near.d < 25 ? `right by ${near.name}` : `near ${near.name}`) : "somewhere on campus";
  const extra = {
    bench: o.tags.backrest === "no" ? "a backless bench" : "a bench",
    lamppost: "a street lamp",
    tree: o.tags.species ? `a ${o.tags.species} tree` : o.tags.leaf_type === "needleleaved" ? "an evergreen tree" : "a tree",
    fire_hydrant: "a fire hydrant",
    mural: o.tags.name ? `the artwork "${o.tags.name}"` : "a piece of public art",
    mailbox: "a Canada Post mailbox",
  }[o.category];
  return { hint: `Find ${extra} ${where}.`, placeName: near?.name ?? null };
};

// ---- deterministic picking
const hash = (s) => { let h = 2166136261; for (const c of s) h = Math.imul(h ^ c.charCodeAt(0), 16777619); return h >>> 0; };
const addDays = (d, n) => { const t = new Date(d + "T12:00:00Z"); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10); };

const byRegion = new Map();
for (const o of objects) {
  const region = latLngToCell(o.lat, o.lon, 7);
  if (!byRegion.has(region)) byRegion.set(region, []);
  byRegion.get(region).push(o);
}

const sqlStr = (s) => (s == null ? "null" : `'${String(s).replaceAll("'", "''")}'`);
const rows = [];
const extraRows = [];
const rowSql = (region, date, slot, o) => {
  const { hint, placeName } = describe(o);
  return `  (${BigInt("0x" + region)}, '${date}'::date, ${slot}::smallint, '${o.category}', ` +
    `extensions.st_setsrid(extensions.st_makepoint(${o.lon}, ${o.lat}), 4326)::extensions.geography, ${sqlStr(hint)}, ${sqlStr(placeName)}, ${o.id}::bigint)`;
};
for (const [region, list] of [...byRegion].sort()) {
  const categories = [...new Set(list.map((o) => o.category))].sort((a, b) => hash(region + a) - hash(region + b));
  const used = new Set();
  for (let day = 0; day < DAYS; day++) {
    const date = addDays(START, day);
    const category = categories[day % categories.length];
    const pool = list.filter((o) => o.category === category).sort((a, b) => a.id - b.id);
    // Start at a deterministic offset, then skip objects already used in this region.
    const start = hash(`${region}:${date}`) % pool.length;
    const o = Array.from({ length: pool.length }, (_, i) => pool[(start + i) % pool.length])
      .find((c) => !used.has(c.id)) ?? pool[start];
    used.add(o.id);
    rows.push(rowSql(region, date, 0, o));
  }
  // Extra slots, after all slot-0 picks so they never change slot 0's choices. Prefer objects no
  // other quest uses; small regions may reuse an object from another day (never the same day).
  const usedOn = new Map(); // date -> ids picked that day
  for (let slot = 1; slot < SLOTS; slot++) {
    for (let day = 0; day < DAYS; day++) {
      const date = addDays(START, day);
      if (!usedOn.has(date)) usedOn.set(date, new Set());
      const today = usedOn.get(date);
      for (let k = 0; k < Math.min(CANDIDATES, categories.length); k++) {
        const category = categories[(day + slot + k) % categories.length];
        const all = list.filter((o) => o.category === category && !today.has(o.id)).sort((a, b) => a.id - b.id);
        const fresh = all.filter((o) => !used.has(o.id));
        const pool = fresh.length ? fresh : all;
        if (pool.length === 0) continue;
        const o = pool[hash(`${region}:${date}:${slot}:${k}`) % pool.length];
        used.add(o.id);
        today.add(o.id);
        extraRows.push(rowSql(region, date, slot, o));
      }
    }
  }
}

console.log(`-- Generated by scripts/db/seed-quests.mjs on ${new Date().toISOString()}
-- ${byRegion.size} region(s) × ${DAYS} day(s) from ${START}. Objects: ${osm.source}.
insert into public.daily_quests (region_h3, quest_date, slot, category, target, hint, place_name, osm_id) values
${rows.join(",\n")}
on conflict (region_h3, quest_date, slot) do nothing;${extraRows.length ? `

-- Extra quests (slots 1–${SLOTS - 1}): candidates in preference order; the first that differs from the
-- day's earlier slots wins, the rest hit the slot's unique key and are skipped.
insert into public.daily_quests (region_h3, quest_date, slot, category, target, hint, place_name, osm_id)
select v.* from (values
${extraRows.join(",\n")}
) as v (region_h3, quest_date, slot, category, target, hint, place_name, osm_id)
where not exists (
  select 1 from public.daily_quests d
  where d.region_h3 = v.region_h3 and d.quest_date = v.quest_date and d.slot < v.slot
    and (d.category = v.category or d.osm_id = v.osm_id))
on conflict (region_h3, quest_date, slot) do nothing;` : ""}`);
