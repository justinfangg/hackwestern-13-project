# Fog of War IRL: Backend API contract

Owner: Justin (written by Vishaal) · Client: Justin (`APIClient`) · Status: **v0.1 draft (2026-11-21)**

Four Supabase Edge Functions in front of Tiger Data. The app talks only to these functions. It never talks to Tiger Data or Supabase Storage directly.
Mock responses live in [`docs/mocks/`](mocks/), one file per response. Build against the mocks until the functions are live.
Items marked **Proposal, needs team OK** are listed again under [Open decisions](#open-decisions).

---

## 1. Conventions

### Base URL and headers
```
{SUPABASE_URL}/functions/v1/<name>        e.g. https://<ref>.supabase.co/functions/v1/sync
```
| Header | Value | Required |
|---|---|---|
| `Authorization` | `Bearer <access_token>` (from Supabase anonymous sign-in) | always |
| `apikey` | Supabase anon key | always |
| `Content-Type` | `application/json` | on POST |

The server takes `user_id` **only from the verified JWT**. No request body or query parameter ever contains a user id.
Any function call creates your `profiles` row if it doesn't exist yet (with `username: null`).

### Errors
Every error from our code has this shape. `details` is optional and specific to each code.
```json
{ "error": { "code": "too_far", "message": "You need to be within 40 m…", "details": { "distance_m": 87.2, "radius_m": 40 } } }
```
`message` is plain English and fine to show in a debug build. User-facing copy should switch on `code`.

| Status | `code` | When |
|---|---|---|
| 400 | `invalid_request` | Missing or invalid field. `details.fields` lists them |
| 400 | `invalid_username` | `POST profile` username breaks the rules (§6) |
| 401 | `unauthorized` | Missing, invalid or expired JWT. Refresh the session and retry once |
| 404 | `quest_not_found` | `verify-quest` with an unknown `quest_id` |
| 405 | `method_not_allowed` | Wrong HTTP method |
| 409 | `already_completed` | You already completed this quest |
| 409 | `username_taken` | Someone else has that username (case-insensitive) |
| 413 | `batch_too_large` / `payload_too_large` | Over the limits in §2 / §4 |
| 422 | `not_todays_quest` | `quest_id` isn't today's active quest for that location (or it's quiet hours) |
| 422 | `too_far` | Outside the geofence. `details.distance_m`, `details.radius_m` |
| 429 | `no_attempts_left` | 5 verification attempts used today |
| 500 | `internal` | Bug or database error. Safe to retry later |
| 502 | `verifier_unavailable` | Vision model failed or timed out. **Does not use up an attempt.** Retry |

> A 401 can also come from the Supabase gateway (before our code runs), with a different body. Treat **any** 401 as "refresh the token" without parsing the body.
> A photo that fails verification is **not** an error: it's a `200` with `verified: false`.

### Data formats
| Thing | Format | Example |
|---|---|---|
| H3 cell | lowercase hex **string**, no `0x` (64-bit ids don't fit in a JSON number). Swift: `String(cell, radix: 16)` / `UInt64(s, radix: 16)` | `"8b2ab4634633fff"` (res 11 tile), `"872ab4634ffffff"` (res 7 region) |
| Timestamp | ISO 8601 UTC with `Z`. **Server sends whole seconds** (works with `JSONDecoder.dateDecodingStrategy = .iso8601`). Server accepts fractional seconds | `"2026-11-21T17:16:04Z"` |
| Calendar day | `YYYY-MM-DD` in **America/Toronto**. Decode as `String`, not `Date` | `"2026-11-21"` |
| Coordinates | `{ "lat": 43.0087, "lng": -81.2731 }` (WGS 84, degrees) | |
| Distance | metres, as floats, field names end in `_m` (km is a display concern) | `"distance_m": 1671.7` |
| Duration | seconds, as integers, `_s` | `"duration_s": 1020` |
| IDs | UUID strings. **The client generates expedition ids** (`UUID().uuidString`), so retries are idempotent | |
| Images | standard base64 (not URL-safe), no `data:` prefix | |
| Quest category | `bench` · `lamppost` · `tree` · `fire_hydrant` · `mural` · `statue` · `mailbox`. The client must show unknown values with a generic icon | |

"Today", "midnight" and quiet hours (23:00–05:00) are all in **America/Toronto** (Proposal, needs team OK: D2).

---

## 2. `POST sync`

Uploads cleared tiles, accepted GPS fixes and expedition records. **Idempotent:** sending the same batch twice changes nothing, so retry freely.

**When:** every 30 s while there is something queued, plus once when an expedition is ended. Run one request at a time, oldest batch first.
**Limits per request:** ≤ 5000 tiles, ≤ 2000 pings, ≤ 50 expeditions, ≤ 2 MB body. Split bigger backlogs (e.g. after being offline) into several requests. Over the limits → `413 batch_too_large`.

Request ([mock](mocks/sync.request.json)). Every array may be empty or left out.
```json
{
  "expeditions": [{ "id": "9e4b7a1d-…", "started_at": "2026-11-21T17:05:30Z", "ended_at": "2026-11-21T17:22:30Z",
                    "distance_m": 364.4, "new_tiles": 21 }],
  "pings": [{ "expedition_id": "9e4b7a1d-…", "ts": "2026-11-21T17:22:09Z", "lat": 43.00801, "lng": -81.2722,
              "accuracy_m": 6.5, "speed_mps": 1.4 }],
  "tiles": [{ "h3": "8b2ab4634633fff", "cleared_at": "2026-11-21T17:22:09Z" }]
}
```
| Field | Rules |
|---|---|
| `expeditions[]` | Upsert by `id`. `ended_at: null` while it's running. Once `ended_at` is set it stays set. `distance_m` and `new_tiles` are the client's running totals (last write wins). **Every batch that has pings for an expedition must also include that expedition's current record.** The server builds the route line itself from the pings |
| `pings[]` | Accepted fixes only (after `FixFilter`), raw fixes rather than interpolated points. `expedition_id` may be `null` for fixes outside an expedition (these count toward distance but don't appear in `routes`). Deduped on `(user, ts)`, so **send `ts` with milliseconds** (`ISO8601DateFormatter` with `.withFractionalSeconds`). With whole seconds, two fixes in the same second collide and one is dropped |
| `tiles[]` | Res 11 cells, including Quest Reveal tiles. Upserted. The earliest `cleared_at` wins |

Bad rows (invalid H3, a lat/lng out of range, `ts` more than 5 min in the future) are **dropped and counted**, not failed, so one bad row can't jam the queue. A `200` means everything else is stored: remove the batch from the queue.

Response `200` ([mock](mocks/sync.200.json)):
```json
{ "new_tiles": 3, "total_tiles": 138, "rejected": { "tiles": 0, "pings": 0, "expeditions": 0 }, "server_time": "2026-11-21T17:22:41Z" }
```
`new_tiles` = tiles the server had never seen for you. Error example: [`sync.413.json`](mocks/sync.413.json).

---

## 3. `GET quest-today?lat=<lat>&lng=<lng>`

Today's quest for the region (H3 res 7) that contains `lat,lng`. Call it on launch, when the app comes to the foreground, when you cross into a new region, and after `resets_at`.

Response `200` ([mock](mocks/quest-today.200.json)):
```json
{
  "date": "2026-11-21",
  "region_h3": "872ab4634ffffff",
  "status": "active",
  "available_at": null,
  "resets_at": "2026-11-22T05:00:00Z",
  "quest": {
    "id": "b7e4d1c2-5a3f-4c8e-9d16-2f0a7b3c8e91",
    "category": "bench",
    "hint": "A wooden bench facing the hill, just below the tower.",
    "place_name": "University College Hill",
    "target": { "lat": 43.0087, "lng": -81.2731 },
    "geofence_radius_m": 40,
    "reveal_radius_m": 150
  },
  "found_today": 8,
  "completed_by_me": false,
  "attempts_left": 5
}
```
| Field | Meaning |
|---|---|
| `status` | `active` · `none_in_region` (no quest seeded for this region) · `quiet_hours` (23:00–05:00 Toronto) |
| `quest` | Present only when `status = active`, otherwise `null` |
| `available_at` | When `quiet_hours`: when the next quest appears (05:00 Toronto). Otherwise `null` |
| `resets_at` | Next local midnight (UTC). Refetch after it |
| `found_today` | Count of distinct users who completed this quest today. Only a count, never names |
| `place_name` | Short label for the target, or `null` |
| `attempts_left` | 5 minus today's attempts that reached the vision model. `0` when there's no quest |

"No quest" is a `200` with `quest: null`, never an error ([quiet hours](mocks/quest-today.200-quiet-hours.json), [none in region](mocks/quest-today.200-none-in-region.json)). Missing or invalid `lat`/`lng` → `400 invalid_request` ([mock](mocks/quest-today.400.json)).

---

## 4. `POST verify-quest`

Checks the geofence, asks the vision model whether the photo shows today's object and, if it passes, saves the photo and sticker and records the completion. Target: < 4 s.

Request ([mock](mocks/verify-quest.request.json)), body ≤ 6 MB:
```json
{
  "quest_id": "b7e4d1c2-5a3f-4c8e-9d16-2f0a7b3c8e91",
  "lat": 43.00885, "lng": -81.273, "accuracy_m": 7.5,
  "captured_at": "2026-11-21T17:16:01Z",
  "photo_jpeg_base64": "/9j/4AAQ…",
  "sticker_png_base64": "iVBORw0K…"
}
```
- `photo_jpeg_base64`: the in-app camera photo, JPEG, long edge ≤ 1024 px, quality ~0.7.
- `sticker_png_base64`: the on-device cut-out (`VNGenerateForegroundInstanceMaskRequest`, or the circular-crop fallback), transparent PNG, long edge ≤ 512 px.
- **Proposal, needs team OK (D3):** the server uploads both to Storage **only when verification passes**. The app never uploads to Storage, so `StickerStorage` isn't needed and anonymous users need no Storage policies.

Checks run in this order: `quest_not_found` (404) → `not_todays_quest` (422) → `already_completed` (409) → `no_attempts_left` (429) → `too_far` (422) → vision model.
Geofence: the distance from `lat,lng` to `quest.target` must be ≤ 40 m + min(`accuracy_m`, 20) (Proposal, needs team OK: D6). Only a vision call uses up an attempt. Geofence failures and `502` don't.

Response `200`, passed ([mock](mocks/verify-quest.200-verified.json)):
```json
{
  "verified": true,
  "confidence": 0.94,
  "reason": "Looks like a real wooden park bench.",
  "attempts_left": 4,
  "completion": { "id": "e2a9c7f1-…", "sticker_url": "https://<ref>.supabase.co/storage/v1/object/public/stickers/<user_id>/<completion_id>.png",
                  "completed_at": "2026-11-21T17:16:04Z" },
  "streak": 4,
  "reveal": { "center": { "lat": 43.0087, "lng": -81.2731 }, "radius_m": 150 }
}
```
Response `200`, failed ([mock](mocks/verify-quest.200-rejected.json)): `verified: false`, `completion`, `streak` and `reveal` are `null`, and `reason` is a short sentence you can show in the retry UI (Q-12).
- `verified` is the server's final answer (model says yes **and** `confidence ≥ 0.7`). Don't re-apply a threshold on the client.
- `streak` = the new current streak after this completion.
- `reveal`: clear `gridDisk` around `center` for `radius_m` locally, then send those tiles via `sync` as usual.

Error example: [`verify-quest.422-too-far.json`](mocks/verify-quest.422-too-far.json). Also possible: `already_completed`, `no_attempts_left`, `not_todays_quest`, `quest_not_found`, `payload_too_large`, `verifier_unavailable`.

---

## 5. `GET profile[?include=tiles]`

Everything the Profile tab needs, in one call.

Response `200` ([mock](mocks/profile.200.json)), abridged:
```json
{
  "user_id": "3f6c2a9e-…", "username": "vishaal", "created_at": "2026-11-14T18:55:02Z",
  "stats": { "tiles_cleared": 138, "distance_m": 1671.7, "quests_completed": 6, "current_streak": 4 },
  "stickers": [{ "completion_id": "e2a9c7f1-…", "quest_id": "b7e4d1c2-…", "date": "2026-11-21", "category": "bench",
                 "place": { "lat": 43.0087, "lng": -81.2731 }, "place_name": "University College Hill",
                 "hint": "A wooden bench facing the hill, just below the tower.",
                 "sticker_url": "https://…/stickers/<user_id>/<completion_id>.png", "completed_at": "2026-11-21T17:16:04Z" }],
  "missed_days": [{ "date": "2026-11-17", "category": "tree" }],
  "weekly_activity": [{ "week_start": "2026-11-16", "distance_m": 1220.6, "new_tiles": 100 }],
  "expeditions": [{ "id": "9e4b7a1d-…", "started_at": "2026-11-21T17:05:30Z", "ended_at": "2026-11-21T17:22:30Z",
                    "duration_s": 1020, "distance_m": 364.4, "new_tiles": 21 }],
  "routes": [{ "expedition_id": "9e4b7a1d-…", "points": [{ "lat": 43.0105, "lng": -81.2745 }, { "lat": 43.0095, "lng": -81.2738 }] }]
}
```
| Field | Meaning |
|---|---|
| `username` | `null` until `POST profile` has been called |
| `stats.current_streak` | Run of consecutive Toronto days with a completion, ending today **or yesterday** (today doesn't break the streak until midnight passes) |
| `stickers` | All completions, newest first. `place` = the quest target |
| `missed_days` | Days from the signup day to yesterday with no completion, newest first, at most 30. `category` = that day's quest in your home region (the region of your latest completion), or `null` (Proposal, needs team OK: D9). Shown as greyed silhouettes |
| `weekly_activity` | The last 8 weeks, oldest first, Monday-start Toronto weeks, weeks with no activity included as zeros. Served from Timescale continuous aggregates |
| `expeditions` | The last 50 ended expeditions, newest first |
| `routes` | One simplified polyline (~5 m tolerance) per ended expedition, for path tracing |
| `tiles` | **Only with `?include=tiles`**: every cleared res 11 cell id ([mock](mocks/profile.200-include-tiles.json)). Call it once after a fresh install or sign-in to restore the fog, then rely on local state (Proposal, needs team OK: D8) |

Error example: [`profile.401.json`](mocks/profile.401.json).

---

## 6. `POST profile`

Sets or changes your username. Call it in onboarding, right after anonymous sign-in. This is the only call that writes `profiles` (the app can't reach Tiger Data directly).

Request ([mock](mocks/profile-post.request.json)): `{ "username": "vishaal" }`
Response `200` ([mock](mocks/profile-post.200.json)): `{ "user_id": "3f6c2a9e-…", "username": "vishaal", "created_at": "2026-11-14T18:55:02Z" }`

Username rules (Proposal, needs team OK: D1):
- 3–20 characters, `^[A-Za-z0-9_]+$`; leading and trailing spaces are trimmed.
- Stored as typed. Uniqueness is **case-insensitive** (`Vishaal` blocks `vishaal`).
- Setting the username you already have → `200`.
- A rule break → `400 invalid_username`. Taken → `409 username_taken` ([mock](mocks/profile-post.409.json)).

---

## Open decisions

Each needs a yes or no from the team. The contract assumes **yes** until told otherwise.

| # | Proposal | Affects |
|---|---|---|
| D1 | `POST profile` sets the username (nothing else writes `profiles`). Rules as in §6 | Jonathan (`AuthService`, onboarding) |
| D2 | "Today", midnight reset and quiet hours use fixed **America/Toronto**, not the device timezone | everyone |
| D3 | `verify-quest` takes photo + sticker as base64 and the **server** uploads them to Storage on success. The app never touches Storage: `StickerStorage` gets dropped and anonymous users need no Storage policies | Justin |
| D4 | H3 ids as lowercase hex strings in JSON (bigint in the database) | Justin, Ayman |
| D5 | **Quiet hours (23:00–05:00) are off during the hackathon** (server flag), otherwise nobody can test quests overnight. On for the post-hack product | everyone |
| D6 | Server geofence allows 40 m + min(GPS accuracy, 20 m), so GPS jitter between the client check and the request doesn't cause `too_far`. The client still unlocks the camera at 40 m | Justin |
| D7 | All distances in metres (`_m`). The app converts to km for display | Jonathan |
| D8 | `GET profile?include=tiles` restores the fog after a reinstall. This is also how the seeded demo account shows its fog. The app calls it once when local storage is empty | Justin, Ayman |
| D9 | `missed_days[].category` comes from your home region (latest completion), or `null` | Jonathan |
| D10 | Stickers live in a **public** bucket under unguessable `<user_id>/<completion_id>.png` paths (`AsyncImage` works with no auth). Quest photos go in a **private** bucket and are never returned | everyone |
| D11 | Demo-day quest category: pick an object we can physically bring on stage (e.g. a potted `tree`). Photos of screens or printouts get rejected by design | pitch, Vishaal (V6) |
| D12 | "No quest" is a `200` with `status` + `quest: null`, not a 404 | Justin |
