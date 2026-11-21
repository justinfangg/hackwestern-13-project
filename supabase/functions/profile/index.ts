// GET profile[?include=tiles]: everything the Profile tab needs (docs/api.md §5).
// POST profile: set or change the username (docs/api.md §6).
import { ApiError, handle, iso, json, readJson } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { currentStreak, ensureProfile, sql, TZ } from "../_shared/db.ts";
import { dbToHex } from "../_shared/h3.ts";

const USERNAME_RE = /^[A-Za-z0-9_]{3,20}$/;

Deno.serve(handle(["GET", "POST"], async (req) => {
  const userId = await requireUser(req);
  await ensureProfile(userId);
  return req.method === "POST" ? setUsername(req, userId) : getProfile(req, userId);
}));

async function setUsername(req: Request, userId: string): Promise<Response> {
  const body = await readJson(req, 10_000);
  const username = typeof body.username === "string" ? body.username.trim() : "";
  if (!USERNAME_RE.test(username)) {
    throw new ApiError(400, "invalid_username", "Usernames are 3–20 letters, numbers or underscores.");
  }
  try {
    const [p] = await sql`
      update profiles set username = ${username} where id = ${userId}
      returning id, username, created_at`;
    return json({ user_id: p.id, username: p.username, created_at: iso(p.created_at) });
  } catch (e) {
    if ((e as { code?: string }).code === "23505") throw new ApiError(409, "username_taken", "That username is taken.");
    throw e;
  }
}

async function getProfile(req: Request, userId: string): Promise<Response> {
  const includeTiles = new URL(req.url).searchParams.get("include") === "tiles";

  const [profile] = await sql`select id, username, created_at from profiles where id = ${userId}`;
  const [stats] = await sql`
    select (select count(*)::int from cleared_tiles where user_id = ${userId})                        as tiles_cleared,
           (select coalesce(sum(distance_m), 0)::float8 from daily_activity where user_id = ${userId}) as distance_m,
           (select count(*)::int from quest_completions where user_id = ${userId})                    as quests_completed`;

  const stickers = await sql`
    select c.id as completion_id, q.id as quest_id, q.quest_date::text as date, q.category,
           st_y(q.target::geometry) as lat, st_x(q.target::geometry) as lng, q.place_name, q.hint,
           c.sticker_url, c.completed_at
    from quest_completions c join daily_quests q on q.id = c.quest_id
    where c.user_id = ${userId} order by c.completed_at desc`;

  // Days from signup to yesterday with no completion, newest first, at most 30. Category = that day's
  // quest in the user's home region (the region of their latest completion), or null (D9).
  const missed = await sql`
    with home as (
      select q.region_h3 from quest_completions c join daily_quests q on q.id = c.quest_id
      where c.user_id = ${userId} order by c.completed_at desc limit 1
    ), days as (
      select d::date as day from generate_series(
        (select (created_at at time zone ${TZ})::date from profiles where id = ${userId}),
        (now() at time zone ${TZ})::date - 1, interval '1 day') d
    )
    select days.day::text as date,
           (select q.category from daily_quests q, home where q.region_h3 = home.region_h3 and q.quest_date = days.day) as category
    from days
    where not exists (select 1 from quest_completions c join daily_quests q on q.id = c.quest_id
                      where c.user_id = ${userId} and q.quest_date = days.day)
    order by days.day desc limit 30`;

  // Last 8 Monday-start Toronto weeks, oldest first, zeros included.
  const weekly = await sql`
    with weeks as (
      select generate_series(date_trunc('week', (now() at time zone ${TZ})::date) - interval '7 weeks',
                             date_trunc('week', (now() at time zone ${TZ})::date), interval '1 week')::date as week_start
    )
    select w.week_start::text as week_start,
           coalesce((select sum(distance_m) from daily_activity a
                     where a.user_id = ${userId} and a.day >= w.week_start and a.day < w.week_start + 7), 0)::float8 as distance_m,
           (select count(*) from cleared_tiles t
            where t.user_id = ${userId}
              and (t.first_cleared_at at time zone ${TZ})::date >= w.week_start
              and (t.first_cleared_at at time zone ${TZ})::date < w.week_start + 7)::int as new_tiles
    from weeks w order by w.week_start`;

  const expeditions = await sql`
    select id, started_at, ended_at, extract(epoch from ended_at - started_at)::int as duration_s, distance_m, new_tiles,
           case when path is not null
                then st_asgeojson(st_simplify(path::geometry, 0.00005))::json -> 'coordinates' end as points
    from expeditions where user_id = ${userId} and ended_at is not null
    order by started_at desc limit 50`;

  const body: Record<string, unknown> = {
    user_id: profile.id,
    username: profile.username,
    created_at: iso(profile.created_at),
    stats: { ...stats, current_streak: await currentStreak(userId) },
    stickers: stickers.map((s) => ({
      completion_id: s.completion_id, quest_id: s.quest_id, date: s.date, category: s.category,
      place: { lat: s.lat, lng: s.lng }, place_name: s.place_name, hint: s.hint,
      sticker_url: s.sticker_url, completed_at: iso(s.completed_at),
    })),
    missed_days: missed.map((m) => ({ date: m.date, category: m.category })),
    weekly_activity: weekly,
    expeditions: expeditions.map((e) => ({
      id: e.id, started_at: iso(e.started_at), ended_at: iso(e.ended_at), duration_s: e.duration_s,
      distance_m: e.distance_m, new_tiles: e.new_tiles,
    })),
    routes: expeditions.filter((e) => Array.isArray(e.points)).map((e) => ({
      expedition_id: e.id,
      points: (e.points as [number, number][]).map(([lng, lat]) => ({ lat, lng })),
    })),
  };
  if (includeTiles) {
    const tiles = await sql`select h3::text as h3 from cleared_tiles where user_id = ${userId}`;
    body.tiles = tiles.map((t) => dbToHex(t.h3));
  }
  return json(body);
}
