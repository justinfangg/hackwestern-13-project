// POST verify-quest: geofence + Gemini check; on success store photo + sticker and record the completion
// (docs/api.md §4). Checks run in the contract's order; only a vision call uses up an attempt.
import { ApiError, handle, invalid, iso, isLat, isLng, isNum, json, readJson, UUID_RE } from "../_shared/http.ts";
import { admin, requireUser } from "../_shared/auth.ts";
import { currentStreak, ensureProfile, sql } from "../_shared/db.ts";
import { verifyPhoto, VerifierUnavailable } from "../_shared/gemini.ts";
import { describeError, logger, type Logger } from "../_shared/log.ts";

const MAX_BODY = 6_000_000;
const MAX_ATTEMPTS = 5;
const RADIUS_M = 40;
const MIN_CONFIDENCE = 0.7;
const QUIET_HOURS = Deno.env.get("QUIET_HOURS_ENABLED") === "true";

const decode = (b64: string): Uint8Array | null => {
  try {
    return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
};

Deno.serve(handle(["POST"], async (req) => {
  const log = logger("verify-quest");
  log.info("request.start", { content_length: req.headers.get("content-length") ?? undefined });
  try {
    const res = await verify(req, log);
    log.info("request.done", { status: res.status, total_ms: log.elapsed() });
    return res;
  } catch (e) {
    if (e instanceof ApiError) {
      const level = e.status >= 500 ? "error" : "info";
      log[level]("request.rejected", { status: e.status, code: e.code, message: e.message, details: e.details, total_ms: log.elapsed() });
    } else {
      log.error("request.crashed", { total_ms: log.elapsed(), ...describeError(e) });
    }
    throw e;
  }
}));

async function verify(req: Request, log: Logger): Promise<Response> {
  const userId = await requireUser(req);
  const body = await readJson(req, MAX_BODY);
  log.info("request.parsed", {
    user: userId.slice(0, 8),
    quest_id: body.quest_id,
    lat: body.lat,
    lng: body.lng,
    accuracy_m: body.accuracy_m,
    photo_kb: typeof body.photo_jpeg_base64 === "string" ? Math.round(body.photo_jpeg_base64.length * 0.75 / 1024) : null,
    sticker_kb: typeof body.sticker_png_base64 === "string" ? Math.round(body.sticker_png_base64.length * 0.75 / 1024) : null,
  });

  const bad: string[] = [];
  if (typeof body.quest_id !== "string" || !UUID_RE.test(body.quest_id)) bad.push("quest_id");
  if (!isLat(body.lat)) bad.push("lat");
  if (!isLng(body.lng)) bad.push("lng");
  if (body.accuracy_m != null && !isNum(body.accuracy_m)) bad.push("accuracy_m");
  const photo = typeof body.photo_jpeg_base64 === "string" ? decode(body.photo_jpeg_base64) : null;
  const sticker = typeof body.sticker_png_base64 === "string" ? decode(body.sticker_png_base64) : null;
  if (!photo?.length) bad.push("photo_jpeg_base64");
  if (!sticker?.length) bad.push("sticker_png_base64");
  if (bad.length) throw invalid(bad);
  await ensureProfile(userId);
  log.info("profile.ready");

  const questId = (body.quest_id as string).toLowerCase();
  const lat = body.lat as number, lng = body.lng as number;
  const accuracy = isNum(body.accuracy_m) ? Math.max(0, body.accuracy_m) : 0;

  // 1. quest_not_found
  const [quest] = await sql`
    select id, category, hint, quest_date::text as quest_date,
           st_distance(target, st_setsrid(st_makepoint(${lng}, ${lat}), 4326)::geography) as distance_m
    from daily_quests where id = ${questId}`;
  if (!quest) throw new ApiError(404, "quest_not_found", "That quest doesn't exist.");
  log.info("quest.loaded", {
    category: quest.category,
    quest_date: quest.quest_date,
    distance_m: Math.round(quest.distance_m * 10) / 10,
  });

  // 2. not_todays_quest (or quiet hours)
  const [{ today, hour }] = await sql`
    select (now() at time zone 'America/Toronto')::date::text as today,
           extract(hour from now() at time zone 'America/Toronto')::int as hour`;
  if (quest.quest_date !== today || (QUIET_HOURS && (hour >= 23 || hour < 5))) {
    throw new ApiError(422, "not_todays_quest", "That isn't today's quest. Refresh to get the new one.");
  }

  // 3. already_completed, 4. no_attempts_left
  const [state] = await sql`
    select exists (select 1 from quest_completions where quest_id = ${questId} and user_id = ${userId}) as completed,
           (select count(*)::int from quest_attempts where quest_id = ${questId} and user_id = ${userId}) as attempts`;
  log.info("quest.state", { today, hour, completed: state.completed, attempts_used: state.attempts });
  if (state.completed) throw new ApiError(409, "already_completed", "You already completed this quest.");
  if (state.attempts >= MAX_ATTEMPTS) throw new ApiError(429, "no_attempts_left", "You've used all 5 attempts today.");

  // 5. too_far: 40 m plus up to 20 m of GPS accuracy (D6)
  const allowed = RADIUS_M + Math.min(accuracy, 20);
  if (quest.distance_m > allowed) {
    throw new ApiError(422, "too_far",
      `You need to be within ${RADIUS_M} m of the quest. You're ${Math.round(quest.distance_m)} m away.`,
      { distance_m: Math.round(quest.distance_m * 10) / 10, radius_m: RADIUS_M });
  }

  log.info("geofence.ok", { distance_m: Math.round(quest.distance_m * 10) / 10, allowed_m: allowed, accuracy_m: accuracy });

  // 6. vision model (doesn't use an attempt if it fails)
  let verdict;
  const geminiStart = performance.now();
  try {
    verdict = await verifyPhoto(body.photo_jpeg_base64 as string, quest.category, quest.hint, log);
  } catch (e) {
    if (e instanceof VerifierUnavailable) {
      log.error("verifier.unavailable", { reason: e.message, gemini_ms: Math.round(performance.now() - geminiStart) });
      throw new ApiError(502, "verifier_unavailable", "The verifier is busy. Try again in a moment.");
    }
    throw e;
  }
  const verified = verdict.isMatch && verdict.confidence >= MIN_CONFIDENCE;
  log.info("verifier.result", {
    verified,
    is_match: verdict.isMatch,
    confidence: verdict.confidence,
    min_confidence: MIN_CONFIDENCE,
    gemini_ms: Math.round(performance.now() - geminiStart),
  });

  // On success, upload first (so a recorded completion always has its sticker), then record.
  let completion: { id: string; sticker_url: string; completed_at: string | null } | null = null;
  const completionId = crypto.randomUUID();
  let stickerUrl: string | null = null, photoPath: string | null = null;
  if (verified) {
    const stickerPath = `${userId}/${completionId}.png`;
    photoPath = `${userId}/${completionId}.jpg`;
    const [s, p] = await Promise.all([
      admin.storage.from("stickers").upload(stickerPath, sticker!, { contentType: "image/png", upsert: true }),
      admin.storage.from("quest-photos").upload(photoPath, photo!, { contentType: "image/jpeg", upsert: true }),
    ]);
    if (s.error || p.error) {
      log.error("storage.failed", { sticker_error: s.error?.message, photo_error: p.error?.message });
      throw new Error(`storage upload failed: ${s.error?.message ?? p.error?.message}`);
    }
    log.info("storage.uploaded", { sticker_path: stickerPath, photo_path: photoPath });
    stickerUrl = admin.storage.from("stickers").getPublicUrl(stickerPath).data.publicUrl;
  }

  try {
    await sql.begin(async (tx) => {
      await tx`
        insert into quest_attempts (user_id, quest_id, verified, confidence, reason)
        values (${userId}, ${questId}, ${verified}, ${verdict.confidence}, ${verdict.reason})`;
      if (verified) {
        const [c] = await tx`
          insert into quest_completions (id, quest_id, user_id, photo_url, sticker_url, confidence)
          values (${completionId}, ${questId}, ${userId}, ${photoPath}, ${stickerUrl}, ${verdict.confidence})
          returning id, sticker_url, completed_at`;
        completion = { id: c.id, sticker_url: c.sticker_url, completed_at: iso(c.completed_at) };
      }
    });
  } catch (e) {
    // A double submit that raced past the check above.
    log.warn("db.write_failed", { code: (e as { code?: string }).code, ...describeError(e) });
    if ((e as { code?: string }).code === "23505") {
      throw new ApiError(409, "already_completed", "You already completed this quest.");
    }
    throw e;
  }

  log.info("db.recorded", { verified, completion_id: completion?.id ?? null });

  return json({
    verified,
    confidence: verdict.confidence,
    reason: verdict.reason,
    attempts_left: Math.max(0, MAX_ATTEMPTS - state.attempts - 1),
    completion,
    streak: verified ? await currentStreak(userId) : null,
  });
}

