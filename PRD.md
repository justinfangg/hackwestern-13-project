# PRD: Fog of War IRL

> Working title. Hack Western 13 project. Native iOS app (SwiftUI).
> Status: Draft v0.2 (2026-11-21). Scope locked to core features. Progress last updated 2026-11-22 (see §0).

---

## 0. Progress

Last updated 2026-11-22. Legend: ✅ done · 🟡 started / needs work · ⬜ not started.
Only work pushed to `main` is counted.

### Overall

| Area | Owner | Status | Where |
|---|---|---|---|
| PRD, team split, tech stack | All | ✅ | `PRD.md` |
| Xcode app project (iOS 17+, iPhone portrait, permissions, background location) | Justin | ✅ | `FogOfWar/` |
| FogKit: location pipeline, Simulator Mode, expeditions, quest capture, camera, sticker cutout, networking, sync, anonymous sign-in, fog restore. 64 tests | Justin | ✅ (not yet tested on a real iPhone) | `Packages/FogKit/` |
| API contract v0.2 + mocks, decisions D1–D12 settled | Vishaal → Justin | ✅ | `docs/api.md`, `docs/mocks/` |
| Supabase project: schema with row-level security, `stickers` + `quest-photos` buckets, anonymous sign-in, `GEMINI_API_KEY` secret. Originally `fog-of-war` (ref `febubbwoyptplfnsdqkv`, us-east-1); **the app now points at a rebuilt project, `SideQuest` (ref `qsxakuynoyxsyxhkxvuo`)** with Jonathan's own Gemini key (see "Changed since the original plan") | Justin → Jonathan | ✅ base setup; 🟡 `SideQuest` is missing the territory migration and `leaderboard` function | `supabase/` |
| Edge Functions `sync`, `quest-today`, `verify-quest`, `profile` (GET + POST), deployed. Smoke test 24/24 | Justin | ✅ | `supabase/functions/`, `scripts/functions/smoke.mjs` |
| Daily quests from real OpenStreetMap objects on campus (Nov 7–27 seeded) | Justin | ✅ | `scripts/db/seed-quests.mjs` |
| Demo-account seed (expeditions on real footpaths, stickers, 4-day streak, missed days) | Justin | ✅ script ready; ⬜ not yet run for the demo phone | `scripts/db/seed-demo.mjs` |
| App connected to the live backend | Justin | ✅ | `FogOfWar/FogOfWar/Config/SupabaseConfig.swift` |
| Photo verification with Gemini | Justin | 🟡 code done; **blocked**: the key is throttled (timeouts, 503s, empty 404s) | `supabase/functions/_shared/gemini.ts` |
| H3 fog map: `ExplorationStore` (SwiftData), `TileMath`, `FogRenderer`, quest marker, `PathTraceMapView` | Ayman | ✅ (performance with thousands of tiles untested on a phone) | `FogOfWar/FogOfWar/Exploration/`, `Map/` |
| Map page, cloud fog visuals, active-quest card, quest sheet, quest camera screen | Jonathan | ✅ | `FogOfWar/FogOfWar/UI/` |
| **Tab-bar navigation** (Figma 55:3722): Social / Map / Leaderboard pages that slide left and right, each rounded to the iPhone's screen corners. Replaces the old map-over-profile split | Jonathan | ✅ | `UI/MainView.swift`, `UI/MainTabBar.swift` |
| Map chrome from the new design: city name at the top, profile button top right (opens Profile as a sheet), locate button bottom right, wider Quests sheet with an **Explore** button | Jonathan | ✅ UI; ⬜ Explore does nothing yet | `UI/MapPage.swift`, `UI/QuestSheet.swift` |
| **Social activity feed** (first tab): Instagram-style scrolling feed, one post per finished session from every player (author, area, time ago, infographic, caption); pull to refresh, loads older posts on scroll. `feed` Edge Function, `FeedModel`, template `SessionInfographic` | Justin (feed) · Jonathan (infographic design) | ✅ feed + template (smoke 35/35 locally, 69 FogKit tests); ⬜ `feed` not deployed yet; 🟡 infographic is a placeholder design for Jonathan to replace | `supabase/functions/feed/`, `Social/` |
| Profile page: name, distance, city coverage, sticker board. Now opened from the profile button on the map | Jonathan | 🟡 uses placeholder stickers and a hard-coded fallback name | `FogOfWar/FogOfWar/Profile/` |
| Onboarding (username + permission screens) | Jonathan | ⬜ | |
| Designed expedition recap card | Jonathan | ⬜ (the app still uses Justin's plain `RecapSheet` from `Dev/`) | |
| **Territory leaderboard** (% / time / distance explored per campus, park, neighbourhood): areas from OSM, `leaderboard` function, `LeaderboardModel`, Leaderboard page (now the third tab; the Profile trophy button still opens it full screen) | Justin | ✅ deployed on the original project (smoke 31/31, 67 FogKit tests); ⬜ not yet on `SideQuest`, so the tab shows "Couldn't load the leaderboard" | `supabase/functions/leaderboard/`, `FogOfWar/FogOfWar/Leaderboard/` |
| Pitch | Vishaal | ⬜ | |

**What works today:** open `FogOfWar/FogOfWar.xcodeproj` and run on the iPhone Simulator against the **live Supabase backend**. You get anonymous sign-in, today's real campus quest, Jonathan's map UI with Ayman's H3 fog clearing as you drive the joystick, expeditions with a recap, and tiles, GPS fixes and expeditions syncing to the cloud. Photo verification reaches the server but returns "verifier busy" until Gemini is fixed.

**Changed since the original plan:**
- Vishaal handed all remaining technical work to Justin and is on the pitch full-time (§13, §15).
- **Supabase only:** Tiger Data was dropped. Data lives in Supabase Postgres; plain tables and views replace the Timescale features, and the Tiger prize track is no longer targeted (§15).
- Photo verification uses **Gemini** (hackathon credits) instead of Claude.
- Completing a quest no longer clears extra fog (Q-9 removed; §15).
- Justin's code lives in a local Swift package (`Packages/FogKit`). Ayman's store implements FogKit's `ExplorationClearing` protocol. See `Packages/FogKit/README.md`.
- No Apple Developer account: sign-in is Supabase anonymous auth (§15).
- **Territory leaderboards are back in scope** (2026-11-22): per-area rankings by % explored, time and distance (§15, docs/api.md §7).
- **Tab-bar navigation** (2026-11-22, Figma 55:3722): the drag-to-split between map and profile is gone. A bottom tab bar switches between three full-screen pages, **Social | Map | Leaderboard**, which slide left and right (0.3 s, no bounce). Profile is no longer a page: it opens as a sheet from the avatar button at the top right of the map (§9, §15).
- **Map chrome moved** to match the design: city name pill at the top, locate button bottom right (always visible, hidden while the quest sheet is open or the camera is up), a wider Quests sheet sitting above the tab bar. The sheet has an **Explore** button for a future free-roam mode; it has no action yet.
- **Supabase rebuilt on a new project:** Jonathan recreated the backend as project `SideQuest` (ref `qsxakuynoyxsyxhkxvuo`) with his own Gemini key, and `SupabaseConfig.swift` points at it. Setup was: link the CLI, `supabase db push --remote`, create the two buckets, `supabase secrets set GEMINI_API_KEY=…`, deploy the functions, `npm run db:seed-quests`, and **turn on anonymous sign-ins in the dashboard**. With that switch off, every request is rejected and the map shows no quest.

### Left to do for the demo

**Backend on `SideQuest`**

0. **Finish the rebuild:** run `supabase db push --remote` to apply `20261122000001_territory.sql`, then deploy the `leaderboard` and `feed` functions (`supabase functions deploy leaderboard feed`) and run `npm run db:seed-areas`. Until then the Leaderboard and Social tabs can't load. Check that `GEMINI_API_KEY` is set and the model name in `GEMINI_MODEL` is valid for that key. Or point the app back at the original project in `SupabaseConfig.swift` (Justin).

**Jonathan (UI)**
1. **Real stickers in Profile:** replace the placeholder `BoardSticker`s with `services.profile.stickers` (`imageURL`, or `localImageURL` right after capture), and show `missedDays` as greyed-out silhouettes.
2. **Remove the `"Jonathan Zhou"` fallback** in `ProfilePage` (`services.profile.username ?? "Jonathan Zhou"`).
3. **Onboarding:** username screen calling `services.profile.setUsername(_:)` (errors `invalid_username` / `username_taken`), plus location and camera permission screens (`LocationPermissions`).
4. **Designed expedition recap card** to replace `RecapSheet` (export with `ShareImage.render`). Then delete `Dev/`.
5. **Place `PathTraceMapView`** (Ayman's) in Profile, using `services.profile.routeSegments`.
6. **Streak and weekly chart** in Profile, if they're in the design (`services.profile.stats.currentStreak`, `weeklyActivity`).
6a. **Session infographic design** in `Social/SessionInfographic.swift` (the feed is built; replace the template's body, keep `init(post:)` and the square shape; the header comment lists the data available), and the **Explore** button's free-roam mode.
6b. **Real display-corner radius:** the tab pages are rounded with UIKit's private `_displayCornerRadius` (fallback 55 pt). Fine for the hackathon; replace with a fixed value before any App Store build.

**Justin**

7. **Gemini:** get a reliable key or model from the organizers or Google sponsor, then retest. The model is switchable without code changes via the `GEMINI_MODEL` secret. Fallback for the stage: Debug menu → On-device verifier.
8. **Test on a real iPhone:** walking GPS, background location with the screen locked, camera, Vision sticker cutout (doesn't run in the Simulator).
9. **Seed the demo phone:** Debug menu → copy **Your user ID** → `npm run db:seed-demo -- --user <id> --username <name> --apply` → Debug menu → **Restore fog from server** (steps in `docs/backend.md`).
10. **Stage-demo quest** at the venue, for the object Vishaal brings (D11). Insert it before seeding that day.
11. **Real Auto-Walk route:** replace the placeholder `Packages/FogKit/Sources/FogLocation/Resources/demo-route.gpx` (draw it in gpx.studio, or record it while device testing).
12. **Prompt tuning** with real photos (objects, photos of screens, wrong objects) once Gemini works.

**Vishaal (pitch)**

13. Slides, 3-minute script (demo script in §13), Devpost write-up, backup demo video, rehearsals; pick the on-stage quest object (D11).

### Nice to have
- Re-fetch the quest at midnight (`resets_at`), on app foreground and when entering a new region (Justin).
- Fog performance on a real phone with thousands of tiles (Ayman).
- App icon and real sticker art instead of the emoji placeholders (Jonathan).

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

**Cut from the hackathon** (moved to §14, Future Ideas). *Update 2026-11-22: territory leaderboards were added back (see §0).* Neighbourhood % and leaderboards, Mayor titles, loot crates, badges and titles, guilds and shared maps, satellite map toggle.

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
| P-5 | Weekly activity chart (km and new tiles per week), served from the `daily_activity` view | P1 |

### 8.5 Demo / Simulator Mode

| ID | Requirement | Priority |
|---|---|---|
| D-1 | Hidden debug toggle (e.g. triple-tap the logo) enables Simulator Mode | P0 |
| D-2 | On-screen joystick moves a virtual location at walking speed (~1.4 m/s, with a 5x boost) | P0 |
| D-3 | "Auto-Walk" plays back a bundled GPX route along real streets | P0 |
| D-4 | Simulated fixes go through the same pipeline as real GPS (one `LocationProvider` protocol) | P0 |
| D-5 | Quest geofence can be satisfied in Simulator Mode; the camera step uses a real photo of a prop on stage | P0 |
| D-6 | "Reset fog" button to restore a clean demo state | P0 |

### 8.6 Navigation & Map Chrome

| ID | Requirement | Priority |
|---|---|---|
| N-1 | Bottom tab bar with three tabs: Social, Map (default), Leaderboard. The selected tab has a white pill behind a green icon; the pill slides between tabs | P0 |
| N-2 | Switching tabs slides the pages left or right (about 0.3 s, no bounce). Each page is a full-screen card with the iPhone display's corner radius | P0 |
| N-3 | The tab bar hides while a quest is active, and accepting a quest returns to the Map tab | P0 |
| N-4 | Map top bar: current city name centered, profile button at the top right that opens Profile as a sheet | P0 |
| N-5 | Locate button at the bottom right of the map, above the Quests sheet, recenters on the player and resumes following. Hidden while the quest sheet is expanded or the camera is open | P0 |
| N-6 | Quests sheet is wide, sits above the tab bar, and has an Explore button on its right for free-roam exploration | P1 (button only; no behavior yet) |
| N-7 | Social page (first tab): activity feed of everyone's finished sessions, newest first, each post an infographic of the session's metrics (and its sticker if a quest was found) | P1 |

## 9. Information Architecture / Screens

Three tabs in a bottom tab bar (Figma 55:3722). Switching slides the pages left or right; each page is a full-screen card with the iPhone's own corner radius. The tab bar hides while a quest is active, and starting a quest always returns to the Map tab.

```
Tab bar:  Social  |  Map (default)  |  Leaderboard
├── Social
│   └── Activity feed: one post per finished session (author, area, time ago, session infographic, caption)
├── Map
│   ├── Fog map + user avatar + quest marker
│   ├── Top: city name (centered), profile button (top right → opens Profile sheet)
│   ├── Bottom right: locate button (recenter on the player)
│   ├── Quests sheet (wide, above the tab bar): hint → Accept → Camera (unlocks at 40 m)
│   │   → Verifying… → Sticker reveal; "Explore" button on its right (free-roam mode, not built)
│   ├── Active-quest card while on a quest (tab bar hidden)
│   └── Expedition recap card → Share
└── Leaderboard
    └── Territory rankings by % / time / distance per area

Profile (sheet from the map's top-right button; its trophy button also opens the Leaderboard full screen)
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
| Backend | **Supabase**: Postgres + PostGIS, Auth, Storage, Edge Functions | One service for data, sign-in, images and server code. PostGIS for the quest geofence. (TimescaleDB isn't available on Supabase Postgres 17, so stats use plain views.) |
| Auth | **Supabase anonymous sign-in** + username | No Apple Developer account on the team, so Sign in with Apple isn't available. Anonymous sign-in still issues a real user id and JWT, so the backend is unchanged |
| AI verification | **Gemini** vision model called from a Supabase Edge Function (a Flash model for speed; a Pro model if accuracy is lacking) | Hackathon provides Gemini credits; API key stays server-side; structured JSON output |
| Sticker extraction | **On-device** `VNGenerateForegroundInstanceMaskRequest` (Apple's "lift subject" API) | Free, instant, offline, no server round-trip |
| Quest object source | OpenStreetMap via Overpass API (pre-fetched) | Has benches, street lamps, trees, hydrants, artwork with exact coordinates |
| Share cards | SwiftUI `ImageRenderer` + `ShareLink` | Native, no extra deps |

Leaflet, Mapbox GL JS and Turf.js from the brainstorm are web-only and don't apply to a native SwiftUI app. H3 cell boundaries remove the need for Turf-style polygon union/difference.

#### Backend architecture

```
iOS app
  │  Supabase Auth (anonymous sign-in) → JWT
  │
  └── Supabase Edge Functions (every call carries the JWT)
         │  verify JWT → user_id
         │  uploads stickers + quest photos to Supabase Storage (verify-quest)
         ▼
      Supabase Postgres + PostGIS
         ├── tables: profiles, cleared_tiles, expeditions, daily_quests, quest_completions,
         │           location_pings, quest_attempts
         └── views:  daily_activity, quest_finds_daily
```

The app **never reads or writes tables directly**: every table has row-level security on with no policies, so the anon key and user JWTs can't touch them through Supabase's REST API. Edge Functions are the only database client; each one takes `user_id` from the verified JWT, never from the request body.

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
   FogRenderer.invalidate   SyncQueue → `sync` Edge Function → Postgres
                            (new tiles + accepted fixes as location_pings,
                             batched every 30 s / on End)
```

- Offline-first: SwiftData is the source of truth on device. Sync is upsert-only (cleared tiles never un-clear, so there are no conflicts).
- Batching keeps the number of Edge Function calls (and database connections) low; see §14.

### 10.4 Daily Quest Generation

1. **Region** = H3 res 7 cell containing the user.
2. On the first request per region per day, the `quest-today` Edge Function:
   - Picks today's object category with a seeded RNG: `seed = hash(regionCell, YYYY-MM-DD)`.
   - Queries a pre-fetched OSM table in Postgres (populated via Overpass) for features of that category within the region:
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
   │  checks: user within 40 m of quest target (server-side, PostGIS ST_DWithin)
   │          quest is today's quest for that region
   │          attempts < 5
   ▼
Vision model prompt: "Does this photo show a real, physical <bench> photographed
in person (not a screen or printout)? Respond JSON:
{verified: boolean, confidence: 0–1, reason: string}"
   │
   ▼
verified && confidence ≥ 0.7 → store sticker PNG in Supabase Storage,
                               insert `quest_completions`
   │
   ▼
Client plays sticker reveal animation
```

- If the subject mask fails (busy scene), fall back to a circular crop of the centre.
- Target latency: < 4 s end to end.

### 10.6 Data Model (Supabase Postgres)

```sql
profiles(id uuid pk → auth.users,  -- = Supabase Auth user id
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

-- Every accepted GPS fix; primary key (user_id, ts) makes sync retries no-ops
location_pings(user_id uuid, expedition_id uuid, ts timestamptz,
               location geography(Point), accuracy_m float, speed_mps float,
               segment_m float, segment_s float)

-- One row per vision-model call (5/day limit, "found today")
quest_attempts(id, user_id, quest_id, ts, verified bool, confidence, reason)

-- Views (Toronto calendar days)
daily_activity(user_id, day, distance_m, active_minutes, pings)     -- P-3, P-5
quest_finds_daily(quest_id, day, finds, attempts)                   -- Q-11
```

Full definitions: `supabase/migrations/`.

Streak is computed from `quest_completions`. The "N found today" count is shown as a count only, never names or locations.

Access control: row-level security on every table with no policies, and API privileges revoked, so only Edge Functions (which bypass RLS) can read or write. They filter every query by the JWT's `user_id`. Every new table must do the same.

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
F-6, F-7 (fog animation and soft edges) · Q-10 (sticker animation) · E-5 (story-format card) · Q-11 (found-today count) · P-5 (weekly activity chart) · then remaining P1s

### Team split

Vishaal wrote the API contract and the database schema, then handed all remaining technical work to Justin so he can focus on the pitch full-time. Justin now owns both sides of the API (app networking and the backend), which removes the main integration risk.

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
- [x] `APIClient` for the four Edge Functions, matching `docs/api.md` v0.2 (contract-tested against `docs/mocks`)
- [x] `SyncQueue` (cleared tiles + location pings + expedition records, batched per the contract's limits) (F-3 sync). Sticker upload is server-side (D3)
- [x] `QuestService` and `ProfileModel` (quest status, stats, streak, stickers, missed days, weekly activity, username) feeding Jonathan's views (Q-11, Q-13, P-3, P-5)
- [x] *(extra)* Xcode app project with FogKit linked, permissions, temporary dev test screen

**Backend (taken over from Vishaal):**
- [x] API contract in `docs/api.md` with mocks *(Vishaal)*. Open decisions D1–D12 still to settle; remove the quest reveal
- [x] Database schema and schema tests *(Vishaal, written for Tiger Data)*
- [x] Move the schema to Supabase Postgres: plain tables + views, row-level security, tests on Supabase's Postgres image *(Justin)*
- [x] Supabase project: anonymous sign-in, push migrations, public `stickers` + private `quest-photos` buckets, `GEMINI_API_KEY` secret
- [x] Edge Functions `sync`, `quest-today`, `profile` (GET + POST), each taking `user_id` from the verified JWT (§10.1)
- [x] `verify-quest` Edge Function: checks, geofence, attempt limit, Gemini vision call, Storage upload on success (Q-7, §10.5). *Gemini itself is unreliable right now*
- [ ] Prompt tuning with a folder of test photos (real objects, photos of screens, wrong objects)
- [x] Seed `daily_quests` for the campus area from OpenStreetMap (Q-1, Q-2, Q-3)
- [x] Demo-account seed script (past expeditions on real paths, stickers, streak, missed days); run it for the demo phone's user id
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
Technical work so far (merged to `main`): API contract + mocks (`docs/api.md`) and the database schema + tests (now in `supabase/migrations/` and `scripts/db/`). Everything else technical is now Justin's.

- [x] **Handover:** no cloud services had been created yet; Justin sets them up
- [ ] Pick the demo-day quest object to bring on stage (D11, e.g. a potted plant as a `tree`)
- [ ] Slides and 3-minute script (follow the demo script in §13)
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
| 0–3 | Xcode project, Supabase project, H3 package compiling, module skeleton on `main`; API contract (Vishaal, done) and `Theme` + mockups (Jonathan) |
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
| Database | **Supabase Postgres only** (changed 2026-11-21; briefly planned Tiger Data for the prize track) | One service instead of two. TimescaleDB isn't available on Supabase Postgres 17, so hypertables/continuous aggregates became plain tables and views, which are fine at hackathon scale. The Tiger prize track is no longer targeted |
| Technical ownership | Vishaal hands all remaining technical work (Edge Functions, cloud setup, prompt, seeding) to Justin and focuses on the pitch | Lets Vishaal focus on the pitch; one person owning both sides of the API removes the biggest integration risk. Vishaal's contract and schema were high quality and are kept as-is |
| AI verification provider | Gemini instead of Claude | Hack Western provides Gemini credits |
| Territory leaderboards | Added back to scope: per-area rankings (campus, parks, Downtown) by % explored, time explored and distance explored. Areas from OpenStreetMap; Downtown is a hand-drawn approximation (OSM has no London neighbourhood polygons). Only usernames and totals are shown | Requested by the team; gives the demo a social/competitive angle. Paths and positions stay private |
| Navigation | Bottom tab bar with Social, Map and Leaderboard pages that slide horizontally; Profile opens as a sheet from the map's avatar button (2026-11-22, replaces the map/profile drag split) | Matches the new Figma design (55:3722); gives Social and Leaderboard their own place and removes the split-drag gesture, which fought with map panning |
| Backend project | The app can point at any Supabase project built from `supabase/migrations`; Jonathan's own `SideQuest` project (with his own Gemini key) is current as of 2026-11-22 | The shared key was throttled; the migrations and functions rebuild a working backend in a few commands. Anonymous sign-ins must be switched on in the dashboard or nothing loads |
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
