// GET quest-today?lat=&lng= : today's quest for the H3 res 7 region containing lat,lng (docs/api.md §3).
import { handle, invalid, iso, isLat, isLng, json } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { ensureProfile, sql, TZ } from "../_shared/db.ts";
import { hexToDb, regionOf } from "../_shared/h3.ts";

const MAX_ATTEMPTS = 5;
// D5: quiet hours (23:00–05:00 Toronto) are off during the hackathon.
const QUIET_HOURS = Deno.env.get("QUIET_HOURS_ENABLED") === "true";

Deno.serve(handle(["GET"], async (req) => {
  const userId = await requireUser(req);
  const params = new URL(req.url).searchParams;
  const lat = Number(params.get("lat")), lng = Number(params.get("lng"));
  const bad = [!params.has("lat") || !isLat(lat) ? "lat" : null, !params.has("lng") || !isLng(lng) ? "lng" : null]
    .filter((f): f is string => f !== null);
  if (bad.length) throw invalid(bad, "lat and lng are required query parameters.");
  await ensureProfile(userId);

  const region = regionOf(lat, lng);
  const [clock] = await sql`
    select (now() at time zone ${TZ})::date::text                                      as today,
           extract(hour from now() at time zone ${TZ})::int                            as hour,
           (date_trunc('day', now() at time zone ${TZ}) + interval '1 day') at time zone ${TZ} as resets_at,
           (date_trunc('day', now() at time zone ${TZ})
              + case when extract(hour from now() at time zone ${TZ}) >= 23 then interval '1 day 5 hours'
                     else interval '5 hours' end) at time zone ${TZ}                   as available_at`;

  const base = { date: clock.today, region_h3: region, resets_at: iso(clock.resets_at) };
  const none = (status: string, availableAt: string | null = null) =>
    json({ ...base, status, available_at: availableAt, quest: null, found_today: 0, completed_by_me: false, attempts_left: 0 });

  if (QUIET_HOURS && (clock.hour >= 23 || clock.hour < 5)) return none("quiet_hours", iso(clock.available_at));

  const [quest] = await sql`
    select id, category, hint, place_name,
           st_y(target::geometry) as lat, st_x(target::geometry) as lng
    from daily_quests where region_h3 = ${hexToDb(region)} and quest_date = ${clock.today}`;
  if (!quest) return none("none_in_region");

  const [stats] = await sql`
    select (select coalesce(sum(finds), 0)::int from quest_finds_daily
              where quest_id = ${quest.id} and day = ${clock.today})                             as found_today,
           exists (select 1 from quest_completions where quest_id = ${quest.id} and user_id = ${userId}) as completed,
           (select count(*)::int from quest_attempts where quest_id = ${quest.id} and user_id = ${userId}) as attempts`;

  return json({
    ...base,
    status: "active",
    available_at: null,
    quest: {
      id: quest.id,
      category: quest.category,
      hint: quest.hint,
      place_name: quest.place_name,
      target: { lat: quest.lat, lng: quest.lng },
      geofence_radius_m: 40,
    },
    found_today: stats.found_today,
    completed_by_me: stats.completed,
    attempts_left: Math.max(0, MAX_ATTEMPTS - stats.attempts),
  });
}));

