// GET leaderboard?lat=&lng=&metric=&period=    : city leaderboard for day / week / month (docs/api.md §7, current app)
// GET leaderboard?lat=&lng=                     : territory areas, nearest first, with the caller's stats (older builds)
// GET leaderboard?area=<id>&metric=<metric>     : top 50 for one area, all time + the caller's rank (older builds)
// Metrics: percent (share of the area's tiles cleared), time (seconds of movement inside the area),
// distance (metres moved inside the area). Only usernames and totals are returned: never paths or positions.
import { ApiError, handle, invalid, iso, isLat, isLng, json } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { ensureProfile, sql, TZ } from "../_shared/db.ts";

const METRICS = ["percent", "time", "distance"] as const;
type Metric = (typeof METRICS)[number];
const TOP = 50;
const PERIODS = ["day", "week", "month"] as const;
type Period = (typeof PERIODS)[number];
/** The one area the app's leaderboard ranks (2026-11-22: Western's campus; was the whole city).
 *  Any `areas` id works; override with the LEADERBOARD_AREA secret. */
const LEADERBOARD_AREA = Deno.env.get("LEADERBOARD_AREA") ?? "western-campus";
/** You see the board when you're within this distance of that area. */
const CITY_SEARCH_M = 30_000;

Deno.serve(handle(["GET"], async (req) => {
  const userId = await requireUser(req);
  await ensureProfile(userId);
  const params = new URL(req.url).searchParams;
  if (params.has("period")) return cityBoard(userId, params);
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
    where a.kind <> 'city'
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
  const [area] = await sql`select id, name, kind, total_tiles, cell_res from areas where id = ${areaId}`;
  if (!area) throw new ApiError(404, "area_not_found", "That area doesn't exist.");

  const scores = metric === "percent"
    ? sql`select ct.user_id, (100.0 * count(*) / ${area.total_tiles})::float8 as value
          from cleared_tiles ct join area_tiles at
            on at.area_id = ${areaId} and at.h3 = public.h3_parent(ct.h3, ${area.cell_res})
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

// ---------------------------------------------------------------- city leaderboard (current app)

/** The leaderboard area (Western's campus) when you're within 30 km of it, ranked over today / this week / this month. */
async function cityBoard(userId: string, params: URLSearchParams): Promise<Response> {
  const lat = Number(params.get("lat")), lng = Number(params.get("lng"));
  const metric = params.get("metric") ?? "percent", period = params.get("period") ?? "week";
  const bad = [
    !params.has("lat") || !isLat(lat) ? "lat" : null,
    !params.has("lng") || !isLng(lng) ? "lng" : null,
    (METRICS as readonly string[]).includes(metric) ? null : "metric",
    (PERIODS as readonly string[]).includes(period) ? null : "period",
  ].filter((f): f is string => f !== null);
  if (bad.length) throw invalid(bad, "lat and lng are required; metric is percent, time or distance; period is day, week or month.");

  const here = sql`extensions.st_setsrid(extensions.st_makepoint(${lng}, ${lat}), 4326)::extensions.geography`;
  const [city] = await sql`
    select id, name, kind, total_tiles, cell_res
    from areas
    where id = ${LEADERBOARD_AREA} and extensions.st_dwithin(boundary, ${here}, ${CITY_SEARCH_M})`;
  // Calendar periods in Toronto time; weeks start on Monday.
  const [{ since }] = await sql`
    select date_trunc(${period}, now() at time zone ${TZ}) at time zone ${TZ} as since`;
  const base = { metric, period, period_start: iso(since) };
  if (!city) {
    return json({ ...base, area: null, total_players: 0, entries: [], me: null, mine: { percent: 0, time_s: 0, distance_m: 0 } });
  }

  // Tiles first cleared in the period inside the city, and movement in the period inside it.
  const tiles = sql`
    select ct.user_id, count(*)::int as tiles
    from cleared_tiles ct
    join area_tiles at on at.area_id = ${city.id} and at.h3 = public.h3_parent(ct.h3, ${city.cell_res})
    where ct.first_cleared_at >= ${since}
    group by ct.user_id`;
  const moves = sql`
    select p.user_id, sum(p.segment_s)::float8 as time_s, sum(p.segment_m)::float8 as distance_m
    from location_pings p join areas a on a.id = ${city.id} and extensions.st_covers(a.boundary, p.location)
    where p.ts >= ${since}
    group by p.user_id`;
  const valueOf = metric === "percent" ? sql`100.0 * coalesce(t.tiles, 0) / ${city.total_tiles}`
    : metric === "time" ? sql`coalesce(m.time_s, 0)` : sql`coalesce(m.distance_m, 0)`;

  const rows = await sql`
    with t as (${tiles}), m as (${moves}),
    scores as (
      select coalesce(t.user_id, m.user_id) as user_id, (${valueOf})::float8 as value,
             100.0 * coalesce(t.tiles, 0) / ${city.total_tiles} as percent,
             coalesce(m.time_s, 0) as time_s, coalesce(m.distance_m, 0) as distance_m
      from t full join m on m.user_id = t.user_id
    ), ranked as (
      select s.*, rank() over (order by s.value desc)::int as rank,
             coalesce(pr.username, 'Explorer ' || upper(left(s.user_id::text, 4))) as name
      from scores s left join profiles pr on pr.id = s.user_id
      where s.value > 0
    )
    select r.*, (select count(*)::int from ranked) as total,
           (select row_to_json(x) from (select percent, time_s, distance_m from scores where user_id = ${userId}) x) as mine
    from ranked r
    where r.rank <= ${TOP} or r.user_id = ${userId}
    order by r.rank, r.name`;

  // `mine` is needed even when you have no score in this metric (or no rows at all).
  const [mineRow] = rows.length ? [rows[0].mine] : (await sql`
    with t as (${tiles}), m as (${moves})
    select (select 100.0 * tiles / ${city.total_tiles} from t where user_id = ${userId}) as percent,
           (select time_s from m where user_id = ${userId}) as time_s,
           (select distance_m from m where user_id = ${userId}) as distance_m`);
  const mine = {
    percent: round(Number(mineRow?.percent ?? 0), 3),
    time_s: Math.round(Number(mineRow?.time_s ?? 0)),
    distance_m: round(Number(mineRow?.distance_m ?? 0), 1),
  };

  const entry = (r: Record<string, unknown>) => ({
    rank: r.rank, name: r.name, value: round(r.value as number, metric === "percent" ? 3 : 1), is_me: r.user_id === userId,
  });
  const me = rows.find((r) => r.user_id === userId);
  return json({
    ...base,
    area: { id: city.id, name: city.name, kind: city.kind, total_tiles: city.total_tiles },
    total_players: rows[0]?.total ?? 0,
    entries: rows.filter((r) => (r.rank as number) <= TOP).map(entry),
    me: me ? entry(me) : null,
    mine,
  });
}

const round = (v: number, places: number) => Math.round(v * 10 ** places) / 10 ** places;
