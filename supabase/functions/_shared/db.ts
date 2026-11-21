// Database access. Edge Functions connect directly to Supabase Postgres (SUPABASE_DB_URL is provided
// automatically) and bypass row-level security, so EVERY query must filter by the verified user id.
import postgres from "npm:postgres@3.4.5";

export const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  prepare: false, // required behind Supabase's transaction-mode pooler
  max: 3,
  idle_timeout: 20,
  connection: { search_path: "public,extensions" }, // PostGIS lives in `extensions`
});

export const TZ = "America/Toronto";

/** Creates the caller's profiles row on first contact (docs/api.md §1). */
export async function ensureProfile(userId: string): Promise<void> {
  await sql`insert into profiles (id) values (${userId}) on conflict (id) do nothing`;
}

/** Today's calendar date in Toronto ("YYYY-MM-DD"). */
export async function torontoToday(): Promise<string> {
  const [{ d }] = await sql`select (now() at time zone ${TZ})::date::text as d`;
  return d;
}

/**
 * Current streak: consecutive Toronto days with a completion, ending today or yesterday
 * (today doesn't break the streak until midnight passes). `dates` are "YYYY-MM-DD", any order.
 */
export function streakFrom(dates: string[], today: string): number {
  const days = new Set(dates);
  const shift = (d: string, n: number) => {
    const t = new Date(d + "T00:00:00Z");
    t.setUTCDate(t.getUTCDate() + n);
    return t.toISOString().slice(0, 10);
  };
  let day = days.has(today) ? today : shift(today, -1);
  let streak = 0;
  while (days.has(day)) {
    streak++;
    day = shift(day, -1);
  }
  return streak;
}

export async function currentStreak(userId: string): Promise<number> {
  const rows = await sql`
    select distinct q.quest_date::text as d
    from quest_completions c join daily_quests q on q.id = c.quest_id
    where c.user_id = ${userId}`;
  return streakFrom(rows.map((r) => r.d), await torontoToday());
}
