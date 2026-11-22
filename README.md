# Fog of War IRL

**Your city is an unexplored map. Walk to clear the fog.**

Fog of War IRL is a native iOS app built at **Hack Western 13**. Every street starts hidden under animated clouds that clear wherever you walk, run or bike. Each day brings a few **side quests**: find a real object nearby (a bench, a street lamp, a particular tree), photograph it, and AI checks that it's real. The object is cut out of your photo and kept as a **holographic sticker**. Every session is shared to a friends feed and counts toward a campus leaderboard.

---

## Features

- **Fog of war map.** The map is divided into H3 hexagonal tiles (resolution 11, about 25 m per side). Tiles you pass through clear for good, with a cloud-dispersal animation. Your progress is stored on the device and backed up to the cloud.
- **Daily side quests.** Real objects from OpenStreetMap, two per area per day, the same for everyone nearby. Tap a quest to see its hint and zoom the map to it, accept it, and the camera unlocks within 40 m of the target.
- **AI photo verification.** Google Gemini checks the photo shows the right object and isn't a photo of a screen. The on-device Vision framework cuts the object out as a sticker.
- **Explore mode.** A free run with no target that records time, distance, route and newly cleared tiles.
- **Activity feed.** One post per finished session, with distance, time, the route's shape and the sticker if a quest was found. Routes are shared as shapes only, never on a map.
- **Leaderboard.** Western University's campus, ranked by % explored, time or distance, for today, this week or this month.
- **Profile.** Sticker board with holographic stickers that react to tilt, per-sticker stats, distance travelled and how much of your city you've uncovered.
- **Demo mode.** On-screen joystick and route playback, so the whole app works in the Simulator or on stage without GPS.

## Tech stack

| Layer | Technology |
|---|---|
| iOS app | Swift, SwiftUI, MapKit, Core Location, AVFoundation, Vision, SwiftData, Metal (one blur shader) |
| Shared app logic | `FogKit`, a local Swift package (location pipeline, expeditions, sync, quests, networking), tested with Swift Testing |
| Map tiles | [Uber H3](https://h3geo.org) (resolution 11) via SwiftyH3 on the device and `h3-js` on the server |
| Backend | [Supabase](https://supabase.com): Postgres + PostGIS, Auth (anonymous sign-in), Storage, Edge Functions (Deno, TypeScript) |
| AI | Google Gemini (photo verification) |
| Map data | OpenStreetMap (quest objects, footpaths, campus, park and city boundaries) |

## Architecture

```
┌──────────────────────── iPhone ────────────────────────┐
│  SwiftUI app (FogOfWar/)                               │
│   Map · Social · Leaderboard tabs, Profile sheet       │
│        │                                               │
│  FogKit (Packages/FogKit)                              │
│   Location → path interpolation → tile clearing ──► SwiftData (tiles)
│   Expeditions · Quest capture · Sync queue (offline-first)
└────────┬───────────────────────────────────────────────┘
         │ HTTPS + JWT (Supabase anonymous session)
┌────────▼──────────── Supabase ─────────────────────────┐
│  Edge Functions: sync · quest-today · verify-quest     │
│                  profile · feed · leaderboard          │
│        │                         │                     │
│  Postgres + PostGIS        Storage (stickers,          │
│  (row-level security,       quest photos)              │
│   no direct client access)        │                    │
└───────────────────────────────────┼────────────────────┘
                                    └──► Google Gemini (verification)
```

The app only talks to the Edge Functions. Row-level security blocks the public API key from reading tables or Storage directly. The full API contract, with example requests and responses, is in [`docs/api.md`](docs/api.md).

## Repository layout

```
FogOfWar/               Xcode project: SwiftUI screens, map rendering, fog, profile, social, leaderboard
Packages/FogKit/        Swift package with the app's core logic and its tests
supabase/
  migrations/           Database schema (applied in order by the Supabase CLI)
  functions/            Edge Functions (one folder each, shared code in _shared/)
  seed/                 OpenStreetMap snapshots and generated seed SQL
scripts/                Node tools: schema test, function smoke test, seeding (quests, areas, demo account)
docs/                   API contract, backend guide, mock responses
PRD.md                  Product requirements, progress and decisions log
```

## Getting started

### Run the iOS app

Requirements: macOS with **Xcode 26** (iOS 26 SDK). The app targets **iOS 17+**, iPhone, portrait.

1. Open `FogOfWar/FogOfWar.xcodeproj`.
2. Pick an iPhone Simulator (e.g. iPhone 17) and press **⌘R**.

The app connects to the backend in `FogOfWar/FogOfWar/Config/SupabaseConfig.swift`, which holds the project URL and the public (publishable) key. In the Simulator it starts in **Simulator Mode**: drag the joystick on the left of the map to walk. The **debug button** (top left of the map, debug builds only) has the simulator controls, a mock backend, fog reset and restore, and an on-device verifier fallback.

> Sticker cutout uses Vision features that only run on a real device. Background location and the camera also need a real iPhone.

### Run the backend locally

Requirements: Node 22+, Docker Desktop, and the [Supabase CLI](https://supabase.com/docs/guides/cli).

```sh
npm install
supabase start                 # local Postgres, Auth, Storage; applies supabase/migrations
npm run db:test                # schema checks
echo 'GEMINI_API_KEY=<your key>' > supabase/functions/.env   # gitignored; needed for photo verification
npm run functions:serve        # serve the Edge Functions locally
npm run functions:smoke        # end-to-end checks against the local functions
```

See [`docs/backend.md`](docs/backend.md) for the full guide: deploying, secrets, seeding quests and the demo account, and restoring a device's fog from the server.

### Configuration

| Setting | Where | Purpose |
|---|---|---|
| Project URL + publishable key | `FogOfWar/FogOfWar/Config/SupabaseConfig.swift` | Which Supabase project the app uses (safe to commit) |
| `GEMINI_API_KEY` | Supabase secret / `supabase/functions/.env` | Photo verification. **Never commit it** |
| `GEMINI_MODEL` | Supabase secret (optional) | Switch the Gemini model without a code change |
| `LEADERBOARD_AREA` | Supabase secret (optional) | Area the leaderboard ranks (default `western-campus`, or e.g. `london`) |
| `QUIET_HOURS_ENABLED` | Supabase secret (optional) | Hide quests 23:00–05:00 Toronto time (off by default) |

Anonymous sign-ins must be **enabled** in the Supabase dashboard (Authentication → Sign In / Providers). Without that, every request is rejected.

## Testing

| What | Command |
|---|---|
| FogKit unit and contract tests (76) | `cd Packages/FogKit && swift test` |
| Database schema checks | `npm run db:test` |
| Edge Function smoke test (41 checks, local stack) | `npm run functions:smoke` |
| App build | Xcode **⌘B**, or `xcodebuild -project FogOfWar/FogOfWar.xcodeproj -scheme FogOfWar -destination 'platform=iOS Simulator,name=iPhone 17' build` |

## Privacy

- Sign-in is anonymous; a username is optional.
- Your location history is private. Other players never see where you are or where you walked. The feed shows only a route's **shape**, scaled to a square with no coordinates or scale, and the leaderboard shows only usernames and totals.
- Quest photos are stored privately and used only for verification and to make your sticker.

## Team

Built in 36 hours at Hack Western 13 by:

- **Justin**: FogKit (location, expeditions, sync, quests), backend, Edge Functions, social feed, leaderboard
- **Jonathan**: product design and SwiftUI front end (map, quest flow, profile, holographic stickers)
- **Ayman**: H3 fog engine, map rendering and route tracing
- **Vishaal**: API contract and schema design, pitch

## Acknowledgements

- Map data © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors, available under the Open Database License (ODbL).
- [H3](https://h3geo.org) by Uber; [SwiftyH3](https://github.com/pawelmajcher/SwiftyH3) and [h3-js](https://github.com/uber/h3-js).
- Fonts: [Cal Sans](https://github.com/calcom/font) and [PT Sans](https://fonts.google.com/specimen/PT+Sans), both under the SIL Open Font License.
- Apple MapKit, Supabase and Google Gemini.
