# FogKit

Non-UI logic for Fog of War IRL: location, expeditions, quest capture, networking and demo mode (Justin's areas in the PRD).
It's a local Swift package, so it builds and tests without the app and doesn't touch the shared Xcode project file.

```bash
cd Packages/FogKit
swift test        # runs on macOS, no simulator needed
```

## Adding it to the app

1. In Xcode: **File → Add Package Dependencies… → Add Local…** and pick `Packages/FogKit`. Add the `FogKit` library to the app target.
2. `import FogKit` (it re-exports every module).
3. Create one `FogServices` at launch and put it in the environment:

```swift
@main
struct FogOfWarApp: App {
    @State private var services = FogServices(
        explorer: ExplorationStore(),          // Ayman's; GridExplorer() works until it exists
        auth: authService,                     // Jonathan's; nil = mock backend
        backend: BackendConfig(projectURL: URL(string: "https://<project>.supabase.co")!,
                               anonKey: "<anon key>"))

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(services)
                .task { services.start() }
        }
    }
}
```

With `auth: nil` or `backend: nil`, everything runs against `MockFogAPI`, which returns a sample quest, accepts every photo, and fakes sync. You can build and demo the whole flow before the backend exists.

### Info.plist keys (app target)

| Key | Why |
|---|---|
| `NSLocationWhenInUseUsageDescription` | Fog clearing |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | Expeditions with the screen locked |
| `UIBackgroundModes` → `location` | Same (Signing & Capabilities → Background Modes → Location updates) |
| `NSCameraUsageDescription` | Quest photos |

## What each teammate uses

| You are | You use | Notes |
|---|---|---|
| **Ayman** | Implement `ExplorationClearing` (`FogCore/TeamInterfaces.swift`) on `ExplorationStore` | FogKit calls `clearTiles(around:)` for every interpolated GPS point. You don't need to subscribe to location yourself. Return only *newly* cleared tiles (used for expedition counts and sync). `GridExplorer` is a working square-grid version to copy from or fall back to. |
| | `services.quests.today?.target` | Quest marker position |
| | `services.profile.routeSegments` | Path-tracing map (each segment is a separate line; don't join them) |
| | `services.profile.remote?.tiles` after `refresh(includeTiles: true)` | Restore fog after a reinstall (D8) |
| | `services.location.currentCoordinate` | User dot / recentering |
| **Jonathan** | Implement `AuthTokenProviding` on `AuthService` | `accessToken(forceRefresh:)` = the Supabase session JWT; when `forceRefresh` is true, refresh the session first (FogKit calls this once after a 401) |
| | `services.questCapture` | Render `state` (`.noQuest`, `.locked`, `.ready`, `.verifying`, `.success(sticker)`, `.rejected(reason:attemptsLeft:)`, `.tooFar(distanceMeters:)`, `.alreadyCompleted`, `.outOfAttempts`, `.error`), `distanceToTarget`, `attemptsLeft`, `streak`, `canCapture`; call `capture(_:)` and `retry()` |
| | `services.quests` | `today` (`title`, `hint`, `placeName`, `foundTodayCount`), `status` (`.active` / `.quietHours` / `.noneInRegion`), `availableAt` |
| | `CameraController` + `CameraPreview` | `try await camera.start()`, show `CameraPreview(session: camera.session)`, then `await services.questCapture.capture(try await camera.capturePhoto())` |
| | `services.expeditions` | `isActive`, `active` (live distance/tiles/startedAt), `start()`, `end()`. Show the recap card when `lastSummary` becomes non-nil; `dismissSummary()` after |
| | `ShareImage.render(YourCardView(summary:))` | Returns a `SharePNG` for `ShareLink` at 1080×1920 |
| | `services.profile` | `username`, `stats`, `stickers`, `missedDays`, `weeklyActivity`, `expeditions`; call `await refresh()`. Onboarding: `try await setUsername(_:)` (errors `invalid_username`, `username_taken`) |
| | `LocationPermissions` | `requestWhenInUse()` in onboarding, `requestAlways()` when the first expedition starts |
| | `JoystickView`, `DebugMenuView`, `.debugUnlockGesture(services.debug)` | Show the joystick over the map when `services.debug.isSimulatorEnabled`; show the debug menu as a sheet when `isMenuUnlocked` |
| **Backend** | `FogNetworking/APIModels.swift` | Matches `docs/api.md` v0.2; `ContractTests` check it against every file in `docs/mocks`. The server uploads stickers (D3), so the app only keeps a local copy |

## Layout

| Module | Contents |
|---|---|
| `FogCore` | Shared models (`Coordinate`, `LocationFix`, `TileID`, `Quest`, `Sticker`, `ExpeditionSummary`), teammate protocols, `GridExplorer`, JSON helpers |
| `FogLocation` | `LocationService` (single entry point), `RealLocationProvider`, `SimulatedLocationProvider`, `FixFilter`, `PathInterpolator`, `GPXParser`, `LocationPermissions` |
| `FogExpedition` | `ExplorationPipeline` (location → fog → sync), `ExpeditionManager`, `ExpeditionHistory`, `ShareImage` |
| `FogQuest` | `QuestCaptureModel`, `CameraController`/`CameraPreview`, `VisionStickerExtractor`, `RemoteQuestVerifier`, `OnDeviceQuestVerifier` |
| `FogNetworking` | `FogAPI` (`LiveFogAPI`, `MockFogAPI`), `SyncQueue`, `QuestService`, sticker storage |
| `FogDebug` | `DebugSettings`, `JoystickView`, `DebugMenuView` |
| `FogKit` | `FogServices` (wires everything), `ProfileModel` |

## Known limits

- **iOS-only code isn't compiled yet.** This machine only has the Command Line Tools, so `swift test` builds for macOS. `#if os(iOS)` blocks (`CameraPreview`, background location session, Always permission, camera rotation) need their first build in Xcode.
- **Sticker cutout needs a real iPhone.** Vision's subject lifting doesn't run in the iOS Simulator, so stickers fall back to a circular crop there.
- **`demo-route.gpx` is a placeholder** near University College and isn't snapped to real paths. Replace it with the route drawn in gpx.studio, keeping the same filename.
