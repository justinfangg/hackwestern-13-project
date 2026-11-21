// swift-tools-version:5.10
import PackageDescription

// FogKit: non-UI logic for Fog of War IRL (location, expeditions, quest capture,
// networking, demo mode). The iOS app target imports `FogKit`.
// Builds and tests on macOS too: `swift test` from this folder.
let package = Package(
    name: "FogKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FogKit", targets: ["FogKit"]),
    ],
    targets: [
        // Shared models + the protocols teammates implement (no dependencies).
        .target(name: "FogCore"),
        // GPS + simulator providers, fix filtering, interpolation, GPX.
        .target(name: "FogLocation", dependencies: ["FogCore"], resources: [.process("Resources")]),
        // Edge Function client, sync queue, sticker upload, quest + profile data.
        .target(name: "FogNetworking", dependencies: ["FogCore"]),
        // Expedition tracking, exploration pipeline, share-card export.
        .target(name: "FogExpedition", dependencies: ["FogCore", "FogLocation"]),
        // Quest geofence/state machine, camera, sticker extraction.
        .target(name: "FogQuest", dependencies: ["FogCore", "FogLocation", "FogNetworking"]),
        // Simulator Mode controls (joystick, debug menu). Unstyled, debug-only UI.
        .target(name: "FogDebug", dependencies: ["FogCore", "FogLocation"]),
        // Umbrella: re-exports everything and wires services together.
        .target(name: "FogKit", dependencies: ["FogCore", "FogLocation", "FogNetworking", "FogExpedition", "FogQuest", "FogDebug"]),
        .testTarget(name: "FogKitTests", dependencies: ["FogKit"]),
    ]
)
