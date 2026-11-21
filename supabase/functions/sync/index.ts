// POST sync: upload cleared tiles, accepted GPS fixes and expedition records (docs/api.md §2).
// Idempotent: resending a batch changes nothing. Bad rows are dropped and counted, not failed.
import { ApiError, handle, iso, isLat, isLng, isNum, json, readJson, UUID_RE } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { ensureProfile, sql } from "../_shared/db.ts";
import { hexToDb, isTile } from "../_shared/h3.ts";

const LIMITS = { tiles: 5000, pings: 2000, expeditions: 50 };
const MAX_BODY = 2_000_000;
const GAP_S = 5 * 60; // a gap over 5 min isn't counted as movement
const FUTURE_MS = 5 * 60 * 1000;

const asArray = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const asDate = (v: unknown): Date | null => {
  if (typeof v !== "string") return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) || d.getTime() > Date.now() + FUTURE_MS ? null : d;
};
const R = 6_371_008.8;
const haversine = (a: { lat: number; lng: number }, b: { lat: number; lng: number }) => {
  const rad = Math.PI / 180, dLat = (b.lat - a.lat) * rad, dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
};

Deno.serve(handle(["POST"], async (req) => {
  const userId = await requireUser(req);
  const body = await readJson(req, MAX_BODY);
  const rawExpeditions = asArray(body.expeditions), rawPings = asArray(body.pings), rawTiles = asArray(body.tiles);
  if (rawTiles.length > LIMITS.tiles || rawPings.length > LIMITS.pings || rawExpeditions.length > LIMITS.expeditions) {
    throw new ApiError(413, "batch_too_large",
      "A batch may contain at most 5000 tiles, 2000 pings and 50 expeditions.",
      { max_tiles: LIMITS.tiles, max_pings: LIMITS.pings, max_expeditions: LIMITS.expeditions });
  }
  await ensureProfile(userId);
  const rejected = { tiles: 0, pings: 0, expeditions: 0 };

  // ---- validate expeditions
  const expeditions = rawExpeditions.flatMap((e: any) => {
    const started = asDate(e?.started_at), ended = e?.ended_at == null ? null : asDate(e.ended_at);
    const ok = typeof e?.id === "string" && UUID_RE.test(e.id) && started && (e.ended_at == null || ended) &&
      (!ended || ended >= started) && isNum(e.distance_m) && e.distance_m >= 0 &&
      Number.isInteger(e.new_tiles) && e.new_tiles >= 0;
    if (!ok) { rejected.expeditions++; return []; }
    return [{ id: e.id.toLowerCase(), started_at: started!, ended_at: ended, distance_m: e.distance_m, new_tiles: e.new_tiles }];
  });

  // ---- validate pings (sorted by time)
  const pings = rawPings.flatMap((p: any) => {
    const ts = asDate(p?.ts);
    const expOk = p?.expedition_id == null || (typeof p.expedition_id === "string" && UUID_RE.test(p.expedition_id));
    if (!ts || !isLat(p?.lat) || !isLng(p?.lng) || !expOk) { rejected.pings++; return []; }
    return [{
      ts, lat: p.lat as number, lng: p.lng as number,
      expedition_id: p.expedition_id ? String(p.expedition_id).toLowerCase() : null,
      accuracy_m: isNum(p.accuracy_m) ? p.accuracy_m : null,
      speed_mps: isNum(p.speed_mps) && p.speed_mps >= 0 ? p.speed_mps : null,
    }];
  }).sort((a, b) => a.ts.getTime() - b.ts.getTime());

  // ---- validate tiles
  const tiles = rawTiles.flatMap((t: any) => {
    const at = asDate(t?.cleared_at);
    if (!isTile(t?.h3) || !at) { rejected.tiles++; return []; }
    return [{ h3: hexToDb(t.h3), cleared_at: at }];
  });

  const result = await sql.begin(async (tx) => {
    // Expeditions: upsert by id, only for this user. ended_at never goes back to null.
    for (const e of expeditions) {
      const rows = await tx`
        insert into expeditions (id, user_id, started_at, ended_at, distance_m, new_tiles)
        values (${e.id}, ${userId}, ${e.started_at}, ${e.ended_at}, ${e.distance_m}, ${e.new_tiles})
        on conflict (id) do update set
          ended_at = coalesce(expeditions.ended_at, excluded.ended_at),
          distance_m = excluded.distance_m,
          new_tiles = excluded.new_tiles
        where expeditions.user_id = ${userId}
        returning id`;
      if (!rows.length) rejected.expeditions++; // id belongs to someone else
    }

    // Pings: segment_m / segment_s from this user's previous fix, including the last one already stored.
    if (pings.length) {
      const owned = new Set((await tx`
        select id::text from expeditions
        where user_id = ${userId} and id = any(${[...new Set(pings.map((p) => p.expedition_id).filter(Boolean))]}::uuid[])`)
        .map((r) => r.id));
      const [prevRow] = await tx`
        select ts, st_y(location::geometry) as lat, st_x(location::geometry) as lng from location_pings
        where user_id = ${userId} and ts < ${pings[0].ts} order by ts desc limit 1`;
      let prev = prevRow ? { ts: new Date(prevRow.ts), lat: prevRow.lat, lng: prevRow.lng } : null;
      const segM: number[] = [], segS: number[] = [];
      for (const p of pings) {
        const dt = prev ? (p.ts.getTime() - prev.ts.getTime()) / 1000 : Infinity;
        const near = dt > 0 && dt <= GAP_S;
        segM.push(near ? haversine(prev!, p) : 0);
        segS.push(near ? dt : 0);
        prev = { ts: p.ts, lat: p.lat, lng: p.lng };
      }
      await tx`
        insert into location_pings (user_id, expedition_id, ts, location, accuracy_m, speed_mps, segment_m, segment_s)
        select ${userId}, u.exp, u.ts, st_setsrid(st_makepoint(u.lng, u.lat), 4326)::geography,
               u.acc, u.speed, u.seg_m, u.seg_s
        from unnest(${pings.map((p) => (p.expedition_id && owned.has(p.expedition_id) ? p.expedition_id : null))}::uuid[],
                    ${pings.map((p) => p.ts.toISOString())}::timestamptz[],
                    ${pings.map((p) => p.lat)}::float8[], ${pings.map((p) => p.lng)}::float8[],
                    ${pings.map((p) => p.accuracy_m)}::float8[], ${pings.map((p) => p.speed_mps)}::float8[],
                    ${segM}::float8[], ${segS}::float8[])
             as u(exp, ts, lat, lng, acc, speed, seg_m, seg_s)
        on conflict (user_id, ts) do nothing`;
    }

    // Tiles: upsert; the earliest cleared_at wins. Count rows that are new for this user.
    let newTiles = 0;
    if (tiles.length) {
      const rows = await tx`
        insert into cleared_tiles (user_id, h3, first_cleared_at)
        select ${userId}, u.h3, u.at
        from unnest(${tiles.map((t) => t.h3)}::bigint[], ${tiles.map((t) => t.cleared_at.toISOString())}::timestamptz[]) as u(h3, at)
        on conflict (user_id, h3) do update
          set first_cleared_at = least(cleared_tiles.first_cleared_at, excluded.first_cleared_at)
        returning (xmax = 0) as inserted`;
      newTiles = rows.filter((r) => r.inserted).length;
    }

    // Ended expeditions: build the route line from their pings (once).
    const ended = expeditions.filter((e) => e.ended_at).map((e) => e.id);
    if (ended.length) {
      await tx`
        update expeditions e set path = r.line
        from (select expedition_id, st_makeline(location::geometry order by ts)::geography as line
              from location_pings
              where user_id = ${userId} and expedition_id = any(${ended}::uuid[])
              group by expedition_id having count(*) >= 2) r
        where e.id = r.expedition_id and e.user_id = ${userId}`;
    }

    const [{ total }] = await tx`select count(*)::int as total from cleared_tiles where user_id = ${userId}`;
    return { newTiles, total };
  });

  return json({ new_tiles: result.newTiles, total_tiles: result.total, rejected, server_time: iso(new Date()) });
}));
