import Foundation
import CoreLocation
import FogCore

/// Real GPS via `CLLocationUpdate.liveUpdates` (iOS 17+).
///
/// App setup needed (Info.plist, in the Xcode project):
/// - `NSLocationWhenInUseUsageDescription`
/// - `NSLocationAlwaysAndWhenInUseUsageDescription`
/// - Background Modes → Location updates (`UIBackgroundModes: location`) for PRD E-4
@MainActor
public final class RealLocationProvider: LocationProvider {
    public var onFix: ((LocationFix) -> Void)?

    private var task: Task<Void, Never>?
    #if os(iOS)
    private var backgroundSession: CLBackgroundActivitySession?
    #endif

    public init() {}

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                    if Task.isCancelled { break }
                    guard let location = update.location else { continue }
                    self?.onFix?(LocationFix(location, source: .gps))
                }
            } catch {
                // Stream ended (e.g. permission revoked). LocationService keeps the last fix.
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func setBackgroundUpdates(_ enabled: Bool) {
        #if os(iOS)
        if enabled {
            if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        } else {
            backgroundSession?.invalidate()
            backgroundSession = nil
        }
        #endif
    }
}

/// Location permission state and requests, for Jonathan's onboarding screens (PRD §9).
/// Ask for When In Use at onboarding; ask to upgrade to Always when the first expedition starts.
@MainActor
public final class LocationPermissions: NSObject, CLLocationManagerDelegate {
    public enum Status: Equatable, Sendable { case notDetermined, denied, whenInUse, always }

    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<Status, Never>] = []

    public override init() {
        super.init()
        manager.delegate = self
    }

    public var status: Status { Self.map(manager.authorizationStatus) }

    /// Shows the system prompt if needed and returns the resulting status.
    public func requestWhenInUse() async -> Status {
        guard status == .notDetermined else { return status }
        return await waitForAnswer { $0.requestWhenInUseAuthorization() }
    }

    /// Upgrade When In Use → Always (iOS shows this prompt at most once).
    public func requestAlways() async -> Status {
        #if os(iOS)
        guard status == .whenInUse || status == .notDetermined else { return status }
        return await waitForAnswer { $0.requestAlwaysAuthorization() }
        #else
        return status
        #endif
    }

    /// If the user keeps the current choice, iOS may not call the delegate at all,
    /// so give up waiting after a timeout and report the current status.
    private func waitForAnswer(timeout: Duration = .seconds(30),
                               _ ask: (CLLocationManager) -> Void) async -> Status {
        await withCheckedContinuation { c in
            waiters.append(c)
            ask(manager)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeAll()
            }
        }
    }

    private func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        let s = status
        pending.forEach { $0.resume(returning: s) }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = Self.map(manager.authorizationStatus)
        guard s != .notDetermined else { return }
        Task { @MainActor in self.resumeAll() }
    }

    nonisolated private static func map(_ s: CLAuthorizationStatus) -> Status {
        switch s {
        case .notDetermined: return .notDetermined
        case .authorizedAlways: return .always
        #if os(iOS)
        case .authorizedWhenInUse: return .whenInUse
        #endif
        default: return .denied
        }
    }
}
