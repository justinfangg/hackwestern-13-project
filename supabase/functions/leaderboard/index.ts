// GET leaderboard?lat=&lng=                     : territory areas, nearest first, with the caller's stats
// GET leaderboard?area=<id>&metric=<metric>     : top 50 for one area + the caller's rank (docs/api.md §7)
// Metrics: percent (share of the area's tiles cleared), time (seconds of movement inside the area),
// distance (metres moved inside the area). Only usernames and totals are returned: never paths or positions.
import { ApiError, handle, invalid, isLat, isLng, json } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { ensureProfile, sql } from "../_shared/db.ts";

const METRICS = ["percent", "time", "distance"] as const;
type Metric = (typeof METRICS)[number];
const TOP = 50;

Deno.serve(handle(["GET"], async (req) => {
  const userId = await requireUser(req);
  await ensureProfile(userId);
  const params = new URL(req.url).searchParams;
  const areaId = params.get("area");
  return areaId ? ranking(userId, areaId, params.get("metric") ?? "percent") : areas(userId, params);
}));

async function areas(userId: string, params: URLSearchParams): Promise<Response> {
  const hasPoint = params.has("lat") || params.has("lng");
  const lat = Number(params.get("lat")), lng = Number(params.get("lng"));
  if (hasPoint && (!isLat(lat) || !isLng(lng))) throw invalid(["lat", "lng"].filter((f) => !params.has(f) || !(f === "lat" ? isLat(lat) : isLng(lng))));

  const rows = await sql`
    with mine_tiles as (
      select at.area_id, count(*)::int as tiles
      from cleared_tiles ct join area_tiles at on at.h3 = ct.h3
      where ct.user_id = ${userId} group by at.area_id
    ), mine_moves as (
      select a.id as area_id, sum(p.segment_s)::float8 as time_s, sum(p.segment_m)::float8 as distance_m
      from location_pings p join areas a on extensions.st_covers(a.boundary, p.location)
      where p.user_id = ${userId} group by a.id
    )
    select a.id, a.name, a.kind, a.total_tiles,
           coalesce(t.tiles, 0) as my_tiles, coalesce(m.time_s, 0) as my_time_s, coalesce(m.distance_m, 0) as my_distance_m,
           ${hasPoint ? sql`extensions.st_distance(a.boundary, extensions.st_setsrid(extensions.st_makepoint(${lng}, ${lat}), 4326)::extensions.geography)` : sql`null::float8`} as distance_from_me_m
    from areas a
    left join mine_tiles t on t.area_id = a.id
    left join mine_moves m on m.area_id = a.id
    order by ${hasPoint ? sql`distance_from_me_m` : sql`a.kind`}, a.name`;

  return json({
    areas: rows.map((r) => ({
      id: r.id, name: r.name, kind: r.kind, total_tiles: r.total_tiles,
      distance_from_me_m: r.distance_from_me_m == null ? null : Math.round(r.distance_from_me_m),
      mine: {
        percent: round(100 * r.my_tiles / r.total_tiles, 2),
        time_s: Math.round(r.my_time_s),
        distance_m: round(r.my_distance_m, 1),
      },
    })),
  });
}

async function ranking(userId: string, areaId: string, metricParam: string): Promise<Response> {
  if (!(METRICS as readonly string[]).includes(metricParam)) throw invalid(["metric"], "metric must be percent, time or distance.");
  const metric = metricParam as Metric;
  const [area] = await sql`select id, name, kind, total_tiles from areas where id = ${areaId}`;
  if (!area) throw new ApiError(404, "area_not_found", "That area doesn't exist.");

  const scores = metric === "percent"
    ? sql`select ct.user_id, (100.0 * count(*) / ${area.total_tiles})::float8 as value
          from cleared_tiles ct join area_tiles at on at.h3 = ct.h3 and at.area_id = ${areaId}
          group by ct.user_id`
    : sql`select p.user_id, sum(${metric === "time" ? sql`p.segment_s` : sql`p.segment_m`})::float8 as value
          from location_pings p join areas a on a.id = ${areaId} and extensions.st_covers(a.boundary, p.location)
          group by p.user_id`;

  const rows = await sql`
    with scores as (${scores}), ranked as (
      select s.user_id, s.value, rank() over (order by s.value desc)::int as rank,
             coalesce(pr.username, 'Explorer ' || upper(left(s.user_id::text, 4))) as name
      from scores s left join profiles pr on pr.id = s.user_id
      where s.value > 0
    )
    select *, (select count(*)::int from ranked) as total from ranked
    where rank <= ${TOP} or user_id = ${userId}
    order by rank, name`;

  const entry = (r: Record<string, unknown>) => ({
    rank: r.rank, name: r.name, value: round(r.value as number, metric === "percent" ? 2 : 1), is_me: r.user_id === userId,
  });
  const top = rows.filter((r) => (r.rank as number) <= TOP);
  const me = rows.find((r) => r.user_id === userId);
  return json({
    area: { id: area.id, name: area.name, kind: area.kind, total_tiles: area.total_tiles },
    metric,
    total_players: rows[0]?.total ?? 0,
    entries: top.map(entry),
    me: me ? entry(me) : null,
  });
}

const round = (v: number, places: number) => Math.round(v * 10 ** places) / 10 ** places;
