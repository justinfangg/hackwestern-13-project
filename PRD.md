# PRD: Fog of War IRL

> Working title. Hack Western 13 project. Native iOS app (SwiftUI).
> Status: Draft v0.2 (2026-11-21). Scope locked to core features. Progress last updated 2026-11-21 (see §0).

---

## 0. Progress

Legend: ✅ done · 🟡 started / done but needs work · ⬜ not started.
Only work that's been pushed to GitHub is counted.

### Overall

| Area | Owner | Status | Where |
|---|---|---|---|
| PRD, team split, tech stack | All | ✅ | `main` |
| Xcode app project (iOS 17+, iPhone portrait, permissions, background location) | Justin | ✅ | `main`: `FogOfWar/` |
| FogKit package: location, simulator, expeditions, quest capture, networking (§13 Justin checklist) | Justin | ✅ mostly; API alignment pending | `main`: `Packages/FogKit/` |
| Temporary dev test screen (map, joystick, quest, expedition, recap/share) | Justin | ✅ | `main`: `FogOfWar/FogOfWar/Dev/` |
| API contract + mock responses | Vishaal | ✅ (open decisions still to settle) | `main`: `docs/api.md`, `docs/mocks/` |
| Tiger Data schema, migrations, local Docker DB, schema tests (21/21 pass) | Vishaal | ✅ locally; not yet applied to Tiger Cloud | `main`: `db/`, `scripts/db/`, `docs/backend.md` |
| Edge Functions, Supabase + Tiger Cloud setup, prompt tuning, quest + demo seeding | Justin (taken over from Vishaal) | ⬜ | |
| Pitch | Vishaal | ⬜ | |
| Fog renderer + H3 `ExplorationStore` | Ayman | ⬜ (branch `feature/ayman-map-fog` exists, no commits yet) | |
| Design system, screens, `AuthService` | Jonathan | ⬜ nothing pushed yet | |

**What works today:** run `FogOfWar/FogOfWar.xcodeproj` on the iPhone Simulator. The joystick moves you, tiles clear (shown as blue dots until Ayman's fog lands), expeditions track distance, tiles and time, the quest unlocks within 40 m, a photo "verifies" against the mock backend and becomes a sticker, and the recap card can be shared. Everything uses `MockFogAPI` and `GridExplorer` stand-ins.

**Changed since the original plan:**
- Vishaal hands over all remaining technical work to Justin and focuses on the pitch full-time (§13, §15).
- Completing a quest no longer clears extra fog (Q-9 removed; §15).
- Justin's code lives in a local Swift package (`Packages/FogKit`) that the app imports, not in app folders. Ayman implements the `ExplorationClearing` protocol instead of subscribing to location himself. See `Packages/FogKit/README.md`.

### Justin: what's next (in order)

1. **Get access from Vishaal:** has he created the Tiger Cloud service or Supabase project? If so, get access or the connection details (into `.env` only, never committed). If not, create them yourself (step 6).
2. **Settle the open decisions in `docs/api.md`** (D1–D12; Justin now decides). Recommended: accept all as proposed. **Remove the quest reveal** from the contract and mocks (`reveal_radius_m` in `quest-today`, the `reveal` object in `verify-quest`).
3. **Align `FogNetworking` with `docs/api.md`.** My provisional shapes in `APIModels.swift` differ in several places:
   - coordinates are `{ "lat", "lng" }`, not `{ "latitude", "longitude" }`
   - `sync`: pings use `ts` (with milliseconds) / `lat` / `lng` / `accuracy_m` / `speed_mps`; tiles use `h3`; expeditions have no route segments (the server builds routes from pings) and must be sent with any batch containing their pings; limits are 5000 tiles / 2000 pings / 50 expeditions
   - `quest-today`: new wrapper (`status`, `found_today`, `completed_by_me`, `attempts_left`, `resets_at`); the quest has `place_name`, `geofence_radius_m`, no `title`
   - `verify-quest`: request sends `lat`, `lng`, `accuracy_m`, `photo_jpeg_base64` **and** `sticker_png_base64` (≤ 512 px); response has `attempts_left`, `completion.sticker_url`, `streak`; the client must **not** re-check confidence. Drop `StickerStorage` (D3: the server uploads)
   - error envelope: map `too_far`, `already_completed`, `no_attempts_left`, `not_todays_quest` and `verifier_unavailable` (retry, doesn't use an attempt) to `QuestCaptureModel` states; on any 401, refresh the token and retry once
   - `profile`: new sticker shape, `missed_days`, `expeditions`, `routes`; add `POST profile` (username) for Jonathan's onboarding
   - use the files in `docs/mocks/` as test fixtures, and make `MockFogAPI` return them
4. **Write the Edge Functions** in `supabase/functions/` (TypeScript; install the CLI with `brew install supabase/tap/supabase`), test locally against the Docker database: `quest-today` → `sync` → `profile` (GET + POST) → `verify-quest`.
5. **Write and tune the `verify-quest` prompt** (Claude vision) with a folder of test photos: real objects, photos of screens, wrong objects.
6. **Cloud setup:** Tiger Cloud service (`npm run db:migrate:tiger`), Supabase project (anonymous sign-in, public `stickers` + private `quest-photos` buckets, secrets: Tiger URL, Anthropic key), deploy the functions, put the project URL + anon key in `FogOfWarApp.swift`.
7. **Seed data:** hand-pick campus quest targets into `daily_quests`; seed the demo account (past expeditions, stickers, a streak).
8. **Restore fog after reinstall** (D8): when local tiles are empty, call `GET profile?include=tiles` and hand the tiles to Ayman's store.
9. **Quest refresh timing:** refetch at `resets_at`, on app foreground, and when crossing into a new region.
10. **Test on a real iPhone:** walking GPS, background location with the screen locked, camera, Vision sticker cutout.
11. **Draw the real demo route** in gpx.studio and replace `Packages/FogKit/Sources/FogLocation/Resources/demo-route.gpx`.
12. **Integrate teammates' pieces as they land:** Ayman's `ExplorationStore` and Jonathan's `AuthService` in `FogOfWarApp.swift`, then remove `Dev/` once Jonathan's screens cover the flow.

If this is too much for one person, the easiest pieces to hand off are step 7 (seeding) and step 10 (device testing).

## 1. Summary

Fog of War IRL turns your city into an unexplored video game map. Every street starts hidden under animated fog. The fog clears for good wherever you walk, run, or bike. A **Daily Side Quest** gives each day a clear goal: find a randomly chosen real-world object (a bench, a lamppost, a particular tree) at a set location, photograph it, and have AI confirm it. The object is cut out of the photo and saved as a **sticker** in your collection. Everyone in the same area gets the same quest, so players end up meeting at the same spot.

## 2. Scope Decision

We are building **two core loops and polishing them**, not a wide feature set.

**In scope (the whole product for the hackathon):**
1. **Fog clearing:** the map is covered in fog that clears as you move.
2. **Daily Quest to sticker:** go to today's object, photograph it, AI verifies it, it becomes a sticker, and the fog around it clears.
3. **Expedition card:** a shareable Strava-style recap after each walk.
4. **Profile:** sticker book, path tracing, lifetime stats.
5. **Demo mode:** joystick and route playback so the demo works on stage without GPS.

**Cut from the hackathon** (moved to §14, Future Ideas): neighbourhood % and leaderboards, Mayor titles, loot crates, badges and titles, guilds and shared maps, satellite map toggle.

Rule for the team: if a task isn't on the in-scope list, it waits until the core is polished and the demo has been rehearsed.

## 3. Problem & Opportunity

- People walk the same routes every day and never see most of their own neighbourhood.
- Fitness trackers (Strava, Apple Fitness) reward distance and speed, not curiosity, and they don't help you meet anyone.
- Location games (Pokémon GO) are built around a fictional layer and don't reward knowing the real map.

**Opportunity:** combine the pull of exploring a game map with real places, plus one shared daily goal that brings local players together.

## 4. Goals & Non-Goals

### Goals
1. Make exploring your own city feel like uncovering a game map.
2. Give a clear daily reason to go outside (the Daily Quest) on top of open-ended fog clearing.
3. Encourage local socializing by sending nearby players to the same place each day.
4. Produce shareable output (expedition cards, stickers) that spreads the app by word of mouth.
5. **Hackathon:** a stable, polished live demo that does not need real GPS movement on stage.

### Non-Goals (for the hackathon)
- Everything in the cut list in §2.
- Android or web clients.
- Turn-by-turn navigation.
- Full anti-cheat (GPS spoofing detection beyond basic checks).
- Monetization, chat, or messaging.

## 5. Target Users

| Persona | Description | What they want |
|---|---|---|
| **The Wanderer** | Student or young professional, walks a lot, curious | A reason to try new streets; something to show for it |
| **The Collector** | Likes completing sets | A growing sticker book and a quest streak to protect |
| **The Runner/Cyclist** | Already uses Strava | New routes; a map that shows where they've been |
| **The Newcomer** | Just moved to a city or campus | Learn the area; meet people nearby |

## 6. Core Concepts & Glossary

| Term | Definition |
|---|---|
| **Tile / Cell** | Smallest unit of the map grid. Uber H3 hexagon at resolution 11 (~25 m edge, ~2,150 m²). |
| **Fog** | Dark animated layer covering every tile the user has not cleared. |
| **Vision radius** | Distance around the user's GPS position within which tiles clear. Fixed at 30 m. |
| **Expedition** | One tracked session from Start to End. |
| **Expedition Card** | Strava-style shareable recap image of an expedition. |
| **Daily Quest** | One object-at-a-location challenge per region per day. |
| **Region** | Area that shares a Daily Quest. H3 resolution 7 cell (~5 km², about 1–2 km across), so the quest is always walkable. |
| **Sticker** | Object cut out of a verified quest photo and saved to the user's collection. |
| **Streak** | Number of consecutive days the user has completed the Daily Quest. |

## 7. User Stories

### Exploration
- As a user, I see my city covered in fog, with only the places I've been visible.
- As a user, when I walk, fog around me clears in real time and stays cleared for good.
- As a user, I can start and end an expedition and see a recap card afterward.

### Daily Quest
- As a user, I see today's quest object and its location on the map.
- As a user, when I'm close to the quest location, I can open the in-app camera and photograph the object.
- As a user, the app tells me within a few seconds whether the photo was verified.
- As a user, once verified, I see the object "peel off" into a sticker in my collection.
- As a user, I can see how many others completed today's quest in my area.

### Profile
- As a user, my profile shows my sticker book, the paths I've walked, my stats, and my quest streak.
- As a user, I can share an expedition card or a sticker to Instagram/Messages.

### Demo
- As a presenter, I can turn on Simulator Mode and drive my avatar with an on-screen joystick or play back a pre-recorded route, so fog clears live on stage.

## 8. Feature Requirements

Priority: **P0** = must ship · **P1** = polish, done once all P0s work end to end

### 8.1 Fog Map

| ID | Requirement | Priority |
|---|---|---|
| F-1 | Full-screen map with all uncleared tiles covered by fog | P0 |
| F-2 | Tiles within the vision radius (30 m) of each accepted GPS fix are marked cleared | P0 |
| F-3 | Cleared tiles persist locally and sync to the backend | P0 |
| F-4 | Fill in gaps between GPS fixes (interpolate the line between consecutive points) so fast movement doesn't leave holes | P0 |
| F-5 | Map recenters on the user; supports pan/zoom; fog rendering stays at 60 fps with 10k+ cleared tiles | P0 |
| F-6 | Fog reveals with a smooth animation (fade/dissolve) as tiles clear | P1 |
| F-7 | Fog has an animated, drifting cloud texture (not flat black), with soft edges around cleared areas | P1 |
| F-8 | Reject bad fixes: horizontal accuracy > 50 m, or implied speed > 15 m/s (prevents car-driving and GPS jumps from clearing fog) | P1 |

### 8.2 Expeditions & Expedition Card

| ID | Requirement | Priority |
|---|---|---|
| E-1 | Start / End expedition button; tracks path, distance, duration, new tiles cleared | P0 |
| E-2 | On End, show a recap card: route polyline over a mini fog map, distance, time, new tiles cleared, quest sticker if completed during the walk | P0 |
| E-3 | Share card as an image (SwiftUI `ImageRenderer` + `ShareLink`) | P0 |
| E-4 | Background location while an expedition is active (screen locked) | P1 |
| E-5 | Card is designed to look good on an Instagram story (9:16) | P1 |

### 8.3 Daily Quest

| ID | Requirement | Priority |
|---|---|---|
| Q-1 | One quest per Region per day, the same for every user in that Region | P0 |
| Q-2 | A quest = object category (bench, lamppost, tree, fire hydrant, mural, statue, mailbox, etc.) + target coordinates + hint text | P0 |
| Q-3 | Quest targets come from real mapped objects (OpenStreetMap features, see §10.4) so the object actually exists at that spot | P0 |
| Q-4 | Quest marker is shown on the map. The marker is never hidden by fog; fog acts as a lure toward it | P0 |
| Q-5 | Camera unlocks only when the user is within 40 m of the target (geofence) | P0 |
| Q-6 | In-app camera only, no photo library uploads (basic anti-cheat) | P0 |
| Q-7 | Photo is sent to an AI vision model that returns `{verified: bool, confidence, reason}` for "does this photo contain a real <object>?" | P0 |
| Q-8 | On success, the object is cut out of the photo (subject lifting) into a transparent-background sticker | P0 |
| Q-9 | *Removed:* completing a quest does not clear extra fog. Fog only clears where the user has walked | n/a |
| Q-10 | Sticker animates into the collection ("peel off" effect) | P1 |
| Q-11 | Show a count of "N explorers found today's quest" for the Region | P1 |
| Q-12 | Retry allowed on a failed verification, with the model's reason shown (max 5 attempts/day) | P1 |
| Q-13 | Quest resets at local midnight; missed days show as greyed-out silhouettes in the sticker book | P1 |

### 8.4 Profile

| ID | Requirement | Priority |
|---|---|---|
| P-1 | Sticker book grid with tap-to-view detail (date, place, mini map) | P0 |
| P-2 | Path-tracing map: every route the user has walked, drawn over their cleared area, Strava-heatmap style | P0 |
| P-3 | Lifetime stats: tiles cleared, km travelled, quests completed, current streak | P0 |
| P-4 | Expedition history list | P1 |
| P-5 | Weekly activity chart (km and new tiles per week), served from Tiger Data continuous aggregates | P1 |

### 8.5 Demo / Simulator Mode

| ID | Requirement | Priority |
|---|---|---|
| D-1 | Hidden debug toggle (e.g. triple-tap the logo) enables Simulator Mode | P0 |
| D-2 | On-screen joystick moves a virtual location at walking speed (~1.4 m/s, with a 5x boost) | P0 |
| D-3 | "Auto-Walk" plays back a bundled GPX route along real streets | P0 |
| D-4 | Simulated fixes go through the same pipeline as real GPS (one `LocationProvider` protocol) | P0 |
| D-5 | Quest geofence can be satisfied in Simulator Mode; the camera step uses a real photo of a prop on stage | P0 |
| D-6 | "Reset fog" button to restore a clean demo state | P0 |

## 9. Information Architecture / Screens

Two tabs only. Fewer screens means more time to polish each one.

```
TabView
├── Map (default)
│   ├── Fog map + user avatar + quest marker
│   ├── Top: quest card ("🪑 Find the bench • 420 m • 8 found today")
│   ├── Bottom: Start/End Expedition button
│   ├── Quest sheet: hint → Camera (unlocks at 40 m) → Verifying… → Sticker reveal
│   └── Expedition recap card → Share
└── Profile
    ├── Avatar, lifetime stats, streak
    ├── Sticker book grid
    ├── Path-tracing map
    └── Expedition history
```

Onboarding (P0, minimal): pick a username (creates a Supabase anonymous account in the background), then location permission explainer ("When In Use" first, then ask for "Always" when the user starts their first expedition), then camera permission prompted at first quest.

## 10. Technical Architecture

### 10.1 Stack

| Layer | Choice | Why |
|---|---|---|
| Client | **SwiftUI, iOS 17+** | Required; iOS 17 unlocks the SwiftUI `Map` APIs, `VNGenerateForegroundInstanceMaskRequest`, and `@Observable` |
| Map | **MapKit** (`UIViewRepresentable` `MKMapView` for the custom overlay) | Free, no API key or quota, native performance |
| Fog rendering | Custom `MKOverlay` + `MKOverlayRenderer` (see §10.2) | Fast with thousands of cells; full control of the look |
| Grid | **Uber H3** via Swift package (e.g. `SwiftyH3`), resolution 11 | Hex cells have uniform neighbour distance; IDs are compact `UInt64`s; `gridDisk` gives the vision radius for free |
| Location | Core Location (`CLLocationUpdate.liveUpdates()`) | Native async stream; background support |
| Database | **Tiger Data** (Tiger Cloud: Postgres + TimescaleDB + PostGIS) | Hackathon prize track. GPS breadcrumbs are time-series data, so they go in a hypertable; continuous aggregates power stats; PostGIS for the quest geofence |
| Backend services | **Supabase**, for Auth, Storage and Edge Functions only (no Supabase database) | Sign-in, sticker image hosting, and server code without running our own server; `supabase-swift` SDK |
| Auth | **Supabase anonymous sign-in** + username | No Apple Developer account on the team, so Sign in with Apple isn't available. Anonymous sign-in still issues a real user id and JWT, so the backend is unchanged |
| AI verification | Vision LLM called from a Supabase Edge Function (**Claude Haiku 5.5** for speed and cost; **Claude Sonnet 5.5** if accuracy is lacking) | API key stays server-side; structured JSON output |
| Sticker extraction | **On-device** `VNGenerateForegroundInstanceMaskRequest` (Apple's "lift subject" API) | Free, instant, offline, no server round-trip |
| Quest object source | OpenStreetMap via Overpass API (pre-fetched) | Has benches, street lamps, trees, hydrants, artwork with exact coordinates |
| Share cards | SwiftUI `ImageRenderer` + `ShareLink` | Native, no extra deps |

Leaflet, Mapbox GL JS and Turf.js from the brainstorm are web-only and don't apply to a native SwiftUI app. H3 cell boundaries remove the need for Turf-style polygon union/difference.

#### Backend architecture

```
iOS app
  │  Supabase Auth (anonymous sign-in) → JWT
  │
  ├── Supabase Storage ← sticker PNGs and quest photos (uploaded directly by the app)
  │
  └── Supabase Edge Functions (every call carries the JWT)
         │  verify JWT → user_id
         │  Postgres connection string kept in Edge Function secrets
         ▼
      Tiger Data (Tiger Cloud service)
         ├── regular tables: profiles, cleared_tiles, expeditions, daily_quests, quest_completions
         ├── hypertable:     location_pings
         └── continuous aggregates: daily_activity, quest_finds_daily
```

The app **never connects to Tiger Data directly**; the database credentials live only in Edge Function secrets. Because Supabase's auto-generated table API and row-level security only work with Supabase's own database, every Edge Function must take `user_id` from the verified JWT, never from the request body.

#### API (Supabase Edge Functions)

| Function | Method | Does |
|---|---|---|
| `sync` | POST | Upserts a batch of cleared tiles + location pings; inserts/updates expeditions |
| `quest-today` | GET `?lat&lng` | Returns today's quest for the user's region + "N found today" |
| `verify-quest` | POST | Geofence check, vision model call, records completion (§10.5) |
| `profile` | GET | Stats, streak, sticker list, weekly activity, path-trace data |

### 10.2 Fog Rendering

Avoid: one world-sized `MKPolygon` with every cleared hex as an interior hole. It gets slow past a few hundred holes.

**Approach:**
1. A single `FogOverlay: MKOverlay` with `boundingMapRect = .world`.
2. `FogRenderer: MKOverlayRenderer` overrides `draw(_:zoomScale:in:)`:
   - Fill the tile rect with the fog colour/texture.
   - Look up cleared H3 cells that intersect the rect (in-memory `Set<H3Index>` plus a res 7 parent-cell bucket for fast lookup).
   - For each cell, build its hex path and fill with `CGBlendMode.clear` to punch a transparent hole. Add a soft blurred edge for a "cloud edge" look.
3. When new cells clear, call `setNeedsDisplay(mapRect)` only for the affected rect.
4. Animated drifting clouds (P1): a SwiftUI `Canvas`/`TimelineView` or Metal shader layer above the map, masked by the fog alpha. Ship static fog first, then add animation.
5. At low zoom, draw from coarser parent cells to keep frame time down.

### 10.3 Location → Tile Clearing Pipeline

```
LocationProvider (protocol)
 ├── RealLocationProvider (CLLocationUpdate.liveUpdates)
 └── SimulatedLocationProvider (joystick / GPX playback)
          │
          ▼
   FixFilter (accuracy ≤ 50 m, speed ≤ 15 m/s, dedupe)
          │
          ▼
   Interpolator (points every 10 m between previous & current fix)
          │
          ▼
   For each point: h3 = latLngToCell(point, res 11)
                   newly = gridDisk(h3, k=1)  // ≈ 30 m radius at res 11
                   minus already-cleared set
          │
          ▼
   ExplorationStore (in-memory Set + SwiftData persistence)
          │                     │
          ▼                     ▼
   FogRenderer.invalidate   SyncQueue → `sync` Edge Function → Tiger Data
                            (new tiles + accepted fixes as location_pings,
                             batched every 30 s / on End)
```

- Offline-first: SwiftData is the source of truth on device. Sync is upsert-only (cleared tiles never un-clear, so there are no conflicts).
- Batching keeps the number of Edge Function calls (and database connections) low; see §14.

### 10.4 Daily Quest Generation

1. **Region** = H3 res 7 cell containing the user.
2. On the first request per region per day, the `quest-today` Edge Function:
   - Picks today's object category with a seeded RNG: `seed = hash(regionCell, YYYY-MM-DD)`.
   - Queries a pre-fetched OSM table in Tiger Data (populated via Overpass) for features of that category within the region:
     - bench → `amenity=bench`
     - lamppost → `highway=street_lamp`
     - tree → `natural=tree`
     - hydrant → `emergency=fire_hydrant`
     - mural/statue → `tourism=artwork`
     - mailbox → `amenity=post_box`
   - Filters to publicly accessible spots (parks, sidewalks, near footways; not private land).
   - Picks one with the seeded RNG and stores it in `daily_quests`.
3. **For the hackathon:** seed `daily_quests` by hand for the Western campus area so the demo is deterministic. Automated generation is P1.

### 10.5 AI Verification Flow

```
In-app camera capture
   │
   ├─(on device)─ VNGenerateForegroundInstanceMaskRequest → sticker PNG (transparent bg)
   │
   ▼
Upload photo (JPEG, ≤ 1024 px) + GPS + timestamp → Edge Function `verify-quest`
   │  checks: user within 40 m of quest target (server-side, PostGIS ST_DWithin in Tiger Data)
   │          quest is today's quest for that region
   │          attempts < 5
   ▼
Vision model prompt: "Does this photo show a real, physical <bench> photographed
in person (not a screen or printout)? Respond JSON:
{verified: boolean, confidence: 0–1, reason: string}"
   │
   ▼
verified && confidence ≥ 0.7 → store sticker PNG in Supabase Storage,
                               insert `quest_completions` in Tiger Data
   │
   ▼
Client plays sticker reveal animation
```

- If the subject mask fails (busy scene), fall back to a circular crop of the centre.
- Target latency: < 4 s end to end.

### 10.6 Data Model (Tiger Data)

```sql
profiles(id uuid pk,             -- = Supabase Auth user id
         username text, avatar_url text, created_at)

cleared_tiles(user_id uuid, h3 bigint, first_cleared_at timestamptz,
              primary key (user_id, h3))

expeditions(id uuid pk, user_id, started_at, ended_at, distance_m float,
            new_tiles int, path geography(LineString))

daily_quests(id uuid pk, region_h3 bigint, quest_date date, category text,
             target geography(Point), hint text, osm_id bigint,
             unique (region_h3, quest_date))

quest_completions(id uuid pk, quest_id, user_id, photo_url text, sticker_url text,
                  confidence float, completed_at, unique (quest_id, user_id))

-- Time-series: every accepted GPS fix
location_pings(user_id uuid, expedition_id uuid, ts timestamptz,
               location geography(Point), accuracy_m float, speed_mps float)
SELECT create_hypertable('location_pings', by_range('ts'));
```

**Timescale features we use** (the Tiger Data prize story):

| Feature | Used for |
|---|---|
| `location_pings` hypertable | Source of truth for path tracing (P-2) and expedition routes; scales to millions of fixes |
| `daily_activity` continuous aggregate (`time_bucket('1 day', ts)` per user: distance, active minutes, ping count) | Lifetime stats (P-3) and the weekly activity chart (P-5) without scanning raw pings |
| `quest_finds_daily` continuous aggregate (completions per quest per day) | "N found today" count (Q-11) |
| Compression policy on `location_pings` older than 7 days | Keeps storage small; mention in the pitch |

Streak is computed from `quest_completions`. The "N found today" count is shown as a count only, never names or locations.

Access control: no row-level security (that's a Supabase-database feature). Edge Functions are the only database client and filter every query by the JWT's `user_id`.

### 10.7 Client Module Layout

```
FogOfWar/
├── App/              FogOfWarApp.swift, RootTabView.swift
├── Location/         LocationProvider.swift, RealLocationProvider.swift,
│                     SimulatedLocationProvider.swift, FixFilter.swift
├── Exploration/      ExplorationStore.swift (H3 set, SwiftData), TileMath.swift
├── Map/              FogMapView.swift (UIViewRepresentable), FogOverlay.swift,
│                     FogRenderer.swift, QuestAnnotation.swift
├── Quest/            QuestService.swift, QuestCameraView.swift,
│                     StickerExtractor.swift, StickerRevealView.swift
├── Expedition/       ExpeditionManager.swift, ExpeditionCardView.swift
├── Profile/          ProfileView.swift, StickerBookView.swift, PathTraceMapView.swift
├── Backend/          AuthService.swift (Supabase Auth), APIClient.swift (Edge Functions),
│                     StickerStorage.swift (Supabase Storage), SyncQueue.swift
├── Debug/            JoystickView.swift, GPXPlayer.swift, DebugMenu.swift
└── DesignSystem/     Theme.swift (colours, fonts, spacing, radii), Components/
                      (QuestCard, PrimaryButton, StickerTile, StatTile, Sheet styles)
```

### 10.8 Design System & UI Workflow

UI design is owned by **Jonathan** and built in parallel with feature logic, so no one waits on designs.

- **Logic and views are separate.** Every screen has an `@Observable` view model owned by the feature owner. Views only read view-model state and call its methods, so restyling never touches logic.
- **Feature owners ship plain screens first**: stock SwiftUI controls wired to the real view model. Jonathan then reskins them with `DesignSystem` components, or the owner swaps them in.
- **`DesignSystem/` is the only place for visual constants.** No hardcoded colours, fonts or paddings in feature views; use `Theme`.
- **Fog art direction:** the fog's look is drawn inside Ayman's renderer, so Jonathan provides colours, a mockup and edge-style references, and Ayman implements it.
- **Hour 3 deliverable from Jonathan:** first version of `Theme` + placeholder components on `main`, plus low-fi mockups of the Map tab, quest sheet, recap card and Profile so everyone builds toward the same layout.

## 11. Non-Functional Requirements

| Area | Requirement |
|---|---|
| Performance | 60 fps map pan/zoom with 10k cleared tiles; tile clearing visible < 300 ms after a fix |
| Battery | ≤ 8%/hour during an active expedition. High-accuracy GPS only while an expedition is active |
| Offline | Exploration works fully offline; quests need network for verification only |
| Privacy | Location history is private; no other user ever sees your paths or position. The only shared data is the anonymous "N found today" count. Photos are used only for verification and stickers |
| Permissions | Clear pre-permission screens for Location (When In Use → Always) and Camera; app stays usable if "Always" is denied (fog clears only while app is open) |
| Safety | Quest targets restricted to public places; "Be aware of your surroundings" on the quest screen; no quests between 23:00–05:00 local |
| Accessibility | Dynamic Type, VoiceOver labels on map controls, fog colour with enough contrast against cleared areas |

## 12. Success Metrics

**Hackathon demo**
- The full demo runs without real GPS: joystick clears fog, reach the quest, photo verifies, sticker appears, expedition card is shared.
- Verification works on a real prop on stage in < 4 s.
- No visible jank, placeholder UI, or debug text in the demo flow.

**Product (post-hackathon)**
- D1 / D7 retention; % of DAU completing the Daily Quest; average streak length.
- Average new tiles cleared per user per week (are people actually going somewhere new?).
- Quest co-presence: % of completions where another player completed within ±30 min (proxy for socializing).
- Share rate of expedition cards and stickers.

## 13. Hackathon Plan (~36 h)

### MVP (must ship)
All P0s in §8: F-1–F-5 · E-1–E-3 · Q-1–Q-9 · P-1–P-3 · D-1–D-6

### Polish (once the P0 flow works end to end)
F-6, F-7 (fog animation and soft edges) · Q-10 (sticker animation) · E-5 (story-format card) · Q-11 (found-today count) · P-5 (weekly activity chart, for the Tiger Data prize) · then remaining P1s

### Team split

Vishaal wrote the API contract and the Tiger Data schema, then handed all remaining technical work to Justin so he can focus on the pitch full-time. Justin now owns both sides of the API (app networking and the backend), which removes the main integration risk.

| Member | Area | Requirements | Modules (§10.7) |
|---|---|---|---|
| **Ayman** | Map, fog & path tracing | F-1, F-2, F-3 (local), F-5, F-6, F-7, Q-4, P-2 | `Map/`, `Exploration/`, `Profile/PathTraceMapView` |
| **Justin** | Location, expeditions, demo mode, quest capture, app networking **and backend** | F-3, F-4, F-8, E-1, E-3, E-4, D-1–D-6, Q-1, Q-2, Q-3, Q-5 (logic), Q-6, Q-7, Q-8, Q-11, Q-13 (backend), P-5 (data) | `Location/`, `Expedition/` (logic), `Debug/`, `Quest/` (camera, sticker extraction, `QuestService`), `Backend/` (except `AuthService`), `supabase/functions/`, `db/`, seeding |
| **Jonathan** | Front-end design, quest experience, Profile UI & sign-in | Design system (§10.8), quest sheet UI, sticker peel in Q-10, Q-12, Q-13 (UI), E-2, E-5, P-1, P-3, P-4, P-5 (chart UI), onboarding + sign-in (§9) | `DesignSystem/`, `Quest/` (views & animations), `Expedition/ExpeditionCardView`, `Profile/` (except path trace), `Backend/AuthService`, `App/` |
| **Vishaal** | Pitch (technical work handed to Justin) | — | Slides, script, Devpost, rehearsals |

#### Ayman: Map, fog & path tracing
- [ ] `FogMapView` (`UIViewRepresentable` around `MKMapView`), recentering, pan/zoom (F-1, F-5)
- [ ] `FogOverlay` + `FogRenderer`: fog fill, hex holes with `CGBlendMode.clear`, partial invalidation (§10.2)
- [ ] H3 integration and `TileMath`: point → cell, `gridDisk` for the 30 m vision radius (F-2)
- [ ] `ExplorationStore`: in-memory set + SwiftData persistence, `clear(cells:)` API (F-3 local)
- [ ] Low-zoom performance: coarse parent-cell drawing, 60 fps with 10k tiles (F-5)
- [ ] Quest marker annotation that stays visible above the fog (Q-4)
- [ ] Path-tracing map in Profile: all routes drawn over the cleared area, reusing the fog renderer (P-2)
- [ ] Polish: fog dissolve on clear, drifting cloud texture, soft edges (F-6, F-7)

#### Justin: Location, expeditions, demo mode, quest capture & app networking
- [x] `LocationProvider` protocol + `RealLocationProvider` (`CLLocationUpdate.liveUpdates`)
- [x] `FixFilter` (accuracy/speed/dedupe) and the 10 m interpolator (F-4, F-8)
- [x] `ExpeditionManager`: Start/End, path, distance, duration, new tiles (E-1)
- [x] Background location during an active expedition (E-4). *Untested on a real phone*
- [x] Recap-card data (`ExpeditionSummary`) + `ImageRenderer`/`ShareLink` export of Jonathan's card view (E-3)
- [x] Simulator Mode: hidden toggle, joystick (by hour 10), GPX Auto-Walk, Reset fog (D-1–D-6). *Demo route is a placeholder*
- [x] `QuestCaptureModel`: geofence gate (within 40 m → `canCapture`), state machine idle → capturing → verifying → success/failure (Q-5)
- [x] In-app camera (`AVCaptureSession`), no photo library access (Q-6). *Untested on a real phone*
- [x] `StickerExtractor` with `VNGenerateForegroundInstanceMaskRequest`, circular-crop fallback (Q-8). *Untested on a real phone*
- [x] On-device fallback (`VNClassifyImageRequest`) behind the debug toggle (§14)
- [ ] 🟡 `APIClient` for the four Edge Functions, built against Vishaal's API contract (mock responses until the functions are live). *Built against provisional shapes; needs aligning with `docs/api.md` (§0)*
- [ ] 🟡 `SyncQueue` (cleared tiles + location pings, batched) and `StickerStorage` upload (F-3 sync). *Queue works offline and batches; payload/limits need aligning; `StickerStorage` likely dropped (D3)*
- [ ] 🟡 `QuestService.today()` and `ProfileModel` (stats, streak, sticker list, weekly activity) feeding Jonathan's views (Q-11, P-3, P-5). *Working against the mock; response shapes need aligning*
- [x] *(extra)* Xcode app project with FogKit linked, permissions, temporary dev test screen

**Backend (taken over from Vishaal):**
- [x] API contract in `docs/api.md` with mocks *(Vishaal)*. Open decisions D1–D12 still to settle; remove the quest reveal
- [x] Tiger Data schema: PostGIS, `location_pings` + `quest_attempts` hypertables, continuous aggregates, columnstore policy, local Docker DB, schema tests *(Vishaal)*
- [ ] Tiger Cloud service + apply migrations (`npm run db:migrate:tiger`)
- [ ] Supabase project: anonymous sign-in, public `stickers` + private `quest-photos` buckets, Edge Function secrets
- [ ] Edge Functions `sync`, `quest-today`, `profile` (GET + POST), each taking `user_id` from the verified JWT (§10.1)
- [ ] `verify-quest` Edge Function: checks, geofence, attempt limit, Claude vision call, Storage upload on success (Q-7, §10.5)
- [ ] Prompt tuning with a folder of test photos (real objects, photos of screens, wrong objects)
- [ ] Hand-seed `daily_quests` for the campus area (OSM Overpass script optional) (Q-1, Q-2, Q-3)
- [ ] Seed the demo account (past expeditions, stickers, a streak)
- [ ] Draw the real demo route in gpx.studio for Auto-Walk

#### Jonathan: Front-end design, quest experience, Profile UI & sign-in
- [ ] Hour 3: `Theme` (colours, fonts, spacing, radii) + placeholder components on `main`; low-fi mockups of Map tab, quest sheet, recap card, Profile (§10.8)
- [ ] `DesignSystem` components: `QuestCard`, `PrimaryButton`, `StickerTile`, `StatTile`, sheet styles
- [ ] Fog art direction for Ayman: colour, texture reference, edge style
- [ ] Quest sheet UI on top of Justin's `QuestCaptureModel`: hint → camera → verifying → result; "N found today" on the quest card
- [ ] Failed-verification retry UI showing the model's reason (Q-12)
- [ ] Sticker "peel off" animation into the collection (Q-10)
- [ ] Expedition recap card design, 9:16 story layout (E-2, E-5)
- [ ] Profile tab: stats + streak (P-3), sticker book grid + detail with missed-day silhouettes (P-1, Q-13), expedition history (P-4), weekly activity chart with Swift Charts (P-5)
- [ ] `AuthService`: Supabase anonymous sign-in via `supabase-swift`, session kept in the Keychain, username saved to `profiles`
- [ ] Onboarding and permission screens (§9)
- [ ] App icon; design pass over every screen in the demo flow before feature freeze

#### Vishaal: Pitch
Technical work so far (merged to `main`): API contract + mocks (`docs/api.md`), Tiger Data schema + migrations + tests (`db/`, `scripts/db/`, `docs/backend.md`). Everything else technical is now Justin's.

- [ ] **Handover:** tell Justin whether a Tiger Cloud service or Supabase project already exists, and share access (connection strings via a private channel, never in the repo)
- [ ] Pick the demo-day quest object to bring on stage (D11, e.g. a potted plant as a `tree`)
- [ ] Slides and 3-minute script (follow the demo script in §13)
- [ ] Tiger Data prize talking points: hypertables for GPS pings, continuous aggregates for stats and "found today", columnstore compression
- [ ] Devpost write-up
- [ ] Coordinate the backup demo video and run rehearsals

#### Shared interfaces (agree in hours 0–3)
| Interface | Owner | Used by |
|---|---|---|
| API contract (`docs/api.md`) | Justin (written by Vishaal) | Justin (`APIClient`), Jonathan (error codes, username rules) |
| `LocationProvider` (async stream of `CLLocation`) | Justin | Ayman (clearing), Justin (quest geofence) |
| `ExplorationStore.clear(cells:)` / `isCleared(_:)` / `clearedCells` | Ayman | Justin (expedition tile counts, sync) |
| `Quest` model + `QuestService.today()` | Justin | Jonathan (quest sheet), Ayman (marker) |
| `QuestCaptureModel` (state, `canCapture`, `capture()`, `VerificationResult`) | Justin | Jonathan (quest sheet UI) |
| `ExpeditionSummary` (route, distance, time, new tiles, sticker) | Justin | Jonathan (recap card) |
| `ProfileModel` (stats, streak, stickers, weekly activity, routes) | Justin | Jonathan (Profile UI), Ayman (path trace) |
| `Theme` + `DesignSystem` components | Jonathan | Everyone |
| `AuthService` (current user, JWT) | Jonathan | Justin (`APIClient`) |

Until an interface is real, each owner ships a mock version on `main` so nobody is blocked.

#### Integration rules
- **Xcode project:** create it with Xcode 16 and keep its default folder setup (folders sync automatically), so adding files doesn't edit the shared `project.pbxproj`. One person creates the full folder structure from §10.7 in hour 0.
- **Edge Functions live in the repo** under `supabase/functions/`, so backend code goes through the same PRs as the app.
- **Small PRs, merged to `main` several times a day.** No branch lives longer than about half a day.
- **`main` must always build.** Pull before starting work; fix a broken build before anything else.
- **Hour 18 is the first end-to-end run**, ugly or not: joystick → fog clears → quest → verify → sticker → recap card.
- **Simulator Mode first:** Justin ships the joystick by hour 10 so everyone can test their feature without walking outside.

### Timeline
| Hours | Milestone |
|---|---|
| 0–3 | Xcode project, Tiger Cloud service, Supabase project, H3 package compiling, module skeleton on `main`; API contract (Vishaal, done) and `Theme` + mockups (Jonathan) |
| 3–10 | Static fog over MapKit with holes from a hardcoded tile set; joystick moving a dot; camera + subject lift working standalone |
| 10–18 | End-to-end clearing (location → tiles → fog); verification Edge Function returning JSON; auth + sync |
| 18–24 | Quest geofence + sticker; Profile sticker book + path trace; expedition card + share. **Full P0 flow works end to end.** |
| 24–32 | Polish only: fog animation, reveal animations, card design, empty states, app icon. No new features. Vishaal is on the pitch full-time |
| 32–36 | Feature freeze. Record a backup demo video, rehearse the pitch (led by Vishaal), verify the seeded demo account |

### Demo script (3 min)
1. Open the app: campus under fog. "This is your city before you've explored it."
2. Joystick-walk down a street; fog dissolves live.
3. Today's quest: "Find the bench. 8 explorers found it today." Walk to the marker; the camera unlocks.
4. Photograph a real object on stage; AI verifies; the sticker peels off into the sticker book.
5. End the expedition; show the expedition card; share it.
6. Open Profile: sticker book, path tracing, streak.

## 14. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Fog rendering is slow or ugly | Start with the flat-colour `MKOverlayRenderer` approach; animation is polish-phase only |
| Indoor GPS on stage is unusable | Simulator Mode (P0) plus a recorded backup video |
| Venue Wi-Fi is flaky for AI verification | Use a phone hotspot; on-device fallback (`VNClassifyImageRequest` label match) behind the debug toggle |
| OSM objects are missing or misplaced | Hand-picked quest targets for the demo; post-hack, let users report "object not found" and reroll |
| AI accepts fake photos (photo of a screen) | Prompt asks explicitly about screens and printouts; in-app camera only; GPS geofence checked server-side |
| Tiger Data free plan is in beta, US East only, no connection pooler | Batch syncs to keep connection count low; open one connection per Edge Function call and close it; ask the Tiger sponsor for credits on a paid plan with pooling |
| No Apple Developer account: anonymous accounts are lost if the app is deleted; apps installed from Xcode with a free account expire after 7 days | Fine for the hackathon; reinstall from Xcode before the demo. Post-hackathon: let users link an email to their anonymous account (Supabase supports this) |
| H3 Swift package build issues | Fallback: square grid from quantized lat/lng (`floor(lat / Δ), floor(lng / Δ)`), ~20 m cells, behind the same `TileID` abstraction |
| Scope creep | §2 is the scope. New ideas go to §16 |

## 15. Decisions Log

| Question | Decision | Reason |
|---|---|---|
| Region size for shared quests | H3 res 7 (~5 km², 1–2 km across). Later, size by player density | The quest must be a 10–15 minute walk or people skip it |
| Quest reward | Sticker + streak. Completing a quest does **not** clear extra fog (changed 2026-11-21; was a 150 m reveal) | Fog should only show where the user has actually been |
| Seeing other players | Hackathon: anonymous "N found today" count only. No live positions ever | Community signal without stalking risk |
| Vision radius | Fixed at 30 m | A growing radius would clear streets the user never walked |
| Feature scope | Two core loops + expedition card + profile + demo mode; everything else cut | A polished core wins more than many half-working features |
| Database | Tiger Data for all data; Supabase kept only for Auth, Storage and Edge Functions (Option A) | Tiger Data prize track. GPS history is time-series data, which fits Tiger well. Keeping Supabase avoids building our own auth, file storage and API server |
| Technical ownership | Vishaal hands all remaining technical work (Edge Functions, cloud setup, prompt, seeding) to Justin and focuses on the pitch | Lets Vishaal focus on the pitch; one person owning both sides of the API removes the biggest integration risk. Vishaal's contract and schema were high quality and are kept as-is |
| Sign-in | Supabase anonymous sign-in + username; no Sign in with Apple | Nobody on the team has a paid Apple Developer account, which Sign in with Apple requires |
| Name | Keep "Fog of War IRL" for the hackathon | Says exactly what the app does in a 3-minute pitch |

## 16. Future Ideas (post-hackathon, not in scope)

- **Quest presence:** "3 explorers nearby right now" within 100 m of the quest target; recent-finds feed with first names; "found alongside 2 others" on stickers.
- **Territory:** % explored per neighbourhood/park/campus, leaderboards, Mayor titles.
- **Loot crates:** cosmetic rewards spawned in uncleared tiles nearby.
- **Badges and titles:** Night Owl, Dead-End Enthusiast, Creature of Habit, Streak Keeper.
- **Guilds:** shared group maps and combined completion.
- Satellite map style under cleared areas.
- Weekly multi-object scavenger hunts across a district.
- Apple Watch companion; Live Activity showing tiles cleared during an expedition.
- Import past routes from Apple Health / Strava to pre-clear fog.
- Seasonal sticker sets.
