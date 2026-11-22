// GET feed[?before=<iso>&limit=<n>]   : finished sessions from everyone, newest first (docs/api.md §8)
// One post per ended expedition. There's no friends list yet, so every player's sessions show
// (hackathon scope). Each post carries the session's metrics, the territory it started in, and
// the sticker if a quest was found during it. Never routes or exact positions.
import { handle, invalid, iso, json } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { ensureProfile, sql } from "../_shared/db.ts";

const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 50;
/** Sessions shorter than this are noise (opened the app, walked to the fridge). */
const MIN_DISTANCE_M = 50;

Deno.serve(handle(["GET"], async (req) => {
  const userId = await requireUser(req);
  await ensureProfile(userId);

  const params = new URL(req.url).searchParams;
  const limitParam = params.get("limit");
  const limit = limitParam == null ? DEFAULT_LIMIT : Number(limitParam);
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_LIMIT) throw invalid(["limit"], `limit must be 1–${MAX_LIMIT}.`);
  const beforeParam = params.get("before");
  const before = beforeParam == null ? null : new Date(beforeParam);
  if (before && Number.isNaN(before.getTime())) throw invalid(["before"]);

  const rows = await sql`
    select e.id, e.user_id, e.started_at, e.ended_at, e.distance_m, e.new_tiles,
           extract(epoch from (e.ended_at - e.started_at))::int as duration_s,
           coalesce(pr.username, 'Explorer ' || upper(left(e.user_id::text, 4))) as name,
           area.name as area_name, area.kind as area_kind,
           find.sticker_url, find.category, find.place_name
    from expeditions e
    left join profiles pr on pr.id = e.user_id
    -- Territory the session started in (smallest area that covers the first fix).
    left join lateral (
      select a.name, a.kind
      from location_pings p join areas a on extensions.st_covers(a.boundary, p.location)
      where p.expedition_id = e.id
      order by p.ts, extensions.st_area(a.boundary)
      limit 1
    ) area on true
    -- Quest found during the session (or within 10 min of ending it: photo taken after "End").
    left join lateral (
      select qc.sticker_url, q.category, q.place_name
      from quest_completions qc join daily_quests q on q.id = qc.quest_id
      where qc.user_id = e.user_id
        and qc.completed_at between e.started_at and e.ended_at + interval '10 minutes'
      order by qc.completed_at
      limit 1
    ) find on true
    where e.ended_at is not null
      and e.distance_m >= ${MIN_DISTANCE_M}
      ${before ? sql`and e.ended_at < ${before}` : sql``}
    order by e.ended_at desc
    limit ${limit}`;

  const posts = rows.map((r) => ({
    id: r.id,
    author: { id: r.user_id, name: r.name, is_me: r.user_id === userId },
    started_at: iso(r.started_at),
    ended_at: iso(r.ended_at),
    duration_s: r.duration_s,
    distance_m: Math.round(r.distance_m * 10) / 10,
    new_tiles: r.new_tiles,
    area: r.area_name == null ? null : { name: r.area_name, kind: r.area_kind },
    sticker: r.sticker_url == null ? null : { url: r.sticker_url, category: r.category, place_name: r.place_name },
  }));

  return json({
    posts,
    // Pass as ?before= to load the next page; null when this was the last one. Keeps milliseconds
    // so sessions ending in the same second as the last post aren't skipped.
    next_before: rows.length === limit ? new Date(rows[rows.length - 1].ended_at).toISOString() : null,
  });
}));
