import Foundation
import FogCore

/// A source of raw location fixes: real GPS or the simulator (PRD D-4).
/// Consumers should not use providers directly; subscribe to `LocationService`,
/// which filters, interpolates and fans out to multiple listeners.
@MainActor
public protocol LocationProvider: AnyObject {
    /// Called for every raw fix. Set by `LocationService`.
    var onFix: ((LocationFix) -> Void)? { get set }
    func start()
    func stop()
    /// Keep updating while the app is in the background (PRD E-4). No-op for the simulator.
    func setBackgroundUpdates(_ enabled: Bool)
}
