import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// The MapKit bridge for Fog of War. It consumes location and quest values supplied by
/// other modules; it intentionally does not start Core Location or fetch quest data itself.
struct FogMapView: UIViewRepresentable {
    static let westernUniversity = CLLocationCoordinate2D(latitude: 43.009, longitude: -81.273)

    let clearedCells: Set<H3CellID>
    let latestChange: ExplorationChange?
    let tileMath: TileMath
    var userCoordinate: CLLocationCoordinate2D?
    /// When false, `userCoordinate` is still used for recentering / follow, but no
    /// player annotation is drawn (profile path-trace).
    var showsUserAnnotation: Bool = true
    var questMarkers: [QuestMarkerData] = []
    /// Optional route polylines (active expedition or profile path tracing). Each
    /// inner array is one continuous segment — never join across gaps.
    var routeSegments: [[CLLocationCoordinate2D]] = []
    /// Route stroke; the active quest passes its own beacon color.
    var routeColor: UIColor = UIColor(red: 1, green: 0xBD / 255, blue: 0x3A / 255, alpha: 1)
    /// Keeps MapKit's legal label clear of chrome drawn over the map.
    var mapChromeInsets: UIEdgeInsets = .zero
    var recenterToken: Int
    /// Zooms to a spot (e.g. a quest's target) and stops following the player.
    /// Applied once per new `MapFocus.id`.
    var focus: MapFocus?
    var onMapTap: (CLLocationCoordinate2D) -> Void
    var onFollowingChanged: (Bool) -> Void
    var onQuestSelected: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> FogMapContainerView {
        let container = FogMapContainerView()
        context.coordinator.install(on: container)
        return container
    }

    func updateUIView(_ container: FogMapContainerView, context: Context) {
        context.coordinator.update(from: self, on: container.mapView)
    }

    static func dismantleUIView(_ container: FogMapContainerView, coordinator: Coordinator) {
        coordinator.invalidate(mapView: container.mapView)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        private var parent: FogMapView
        private let overlay = FogOverlay()
        private var fogRenderer: FogRenderer?
        private var renderedCells: Set<H3CellID> = []
        private var lastRenderedChangeID: UUID?
        private var lastUserCoordinate: CLLocationCoordinate2D?
        private var lastRecenterToken: Int
        private var lastFocusID: UUID?
        private var isFollowingUser = true
        private var questAnnotations: [String: QuestAnnotation] = [:]
        private var playerAnnotation: UserLocationAnnotation?
        private var playerHeading: CLLocationDirection?
        private var routeOverlays: [MKPolyline] = []
        private var renderedRouteSegments: [[CLLocationCoordinate2D]] = []
        private var renderedRouteColor: UIColor?
        private weak var mapView: MKMapView?
        private weak var dispersalView: CloudDispersalView?

        init(parent: FogMapView) {
            self.parent = parent
            self.lastRecenterToken = parent.recenterToken
            self.lastFocusID = parent.focus?.id
            super.init()
        }

        func install(on container: FogMapContainerView) {
            let mapView = container.mapView
            self.mapView = mapView
            dispersalView = container.dispersalView
            mapView.delegate = self
            mapView.accessibilityLabel = "Exploration map"
            mapView.accessibilityHint = "Pan and pinch to explore. Unexplored places are covered by clouds."

            let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
            configuration.pointOfInterestFilter = .includingAll
            mapView.preferredConfiguration = configuration
            mapView.isPitchEnabled = false
            mapView.isRotateEnabled = false
            mapView.showsCompass = false
            mapView.showsScale = false
            mapView.layoutMargins = parent.mapChromeInsets

            mapView.register(
                QuestAnnotationView.self,
                forAnnotationViewWithReuseIdentifier: QuestAnnotationView.reuseIdentifier
            )
            mapView.register(
                UserLocationAnnotationView.self,
                forAnnotationViewWithReuseIdentifier: UserLocationAnnotation.reuseIdentifier
            )

            let initialCenter = parent.userCoordinate ?? Self.westernUniversity
            mapView.setRegion(
                MKCoordinateRegion(
                    center: initialCenter,
                    latitudinalMeters: 1_000,
                    // A square region makes MapKit expand the vertical span to
                    // more than 2 km on a portrait iPhone. This ratio keeps the
                    // initial visible height near the PRD's requested 1 km.
                    longitudinalMeters: 460
                ),
                animated: false
            )

            let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(mapTapped(_:)))
            tapRecognizer.cancelsTouchesInView = false
            tapRecognizer.delegate = self
            mapView.addGestureRecognizer(tapRecognizer)

            mapView.addOverlay(overlay, level: .aboveLabels)
            updateAnnotations(on: mapView)
            updateRouteOverlays(on: mapView)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.renderInitialExploration()
            }
        }

        func update(from newParent: FogMapView, on mapView: MKMapView) {
            parent = newParent
            updateExploration()
            updateAnnotations(on: mapView)
            updateRouteOverlays(on: mapView)

            if mapView.layoutMargins != newParent.mapChromeInsets {
                mapView.layoutMargins = newParent.mapChromeInsets
            }

            if let focus = newParent.focus, focus.id != lastFocusID {
                lastFocusID = focus.id
                lastRecenterToken = newParent.recenterToken
                setFollowing(false)
                let center = MKMapPoint(focus.coordinate)
                let side = focus.spanMeters * MKMapPointsPerMeterAtLatitude(focus.coordinate.latitude)
                let rect = MKMapRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
                mapView.setVisibleMapRect(rect, edgePadding: focus.padding, animated: true)
            } else if newParent.recenterToken != lastRecenterToken {
                lastRecenterToken = newParent.recenterToken
                setFollowing(true)
                mapView.setCenter(newParent.userCoordinate ?? Self.westernUniversity, animated: true)
            } else if let coordinate = newParent.userCoordinate, isFollowingUser {
                // Also catches drift from the initial region being applied
                // before the map had its final size.
                let point = mapView.convert(coordinate, toPointTo: mapView)
                let center = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
                let offCenter = hypot(point.x - center.x, point.y - center.y) > 2
                if !coordinatesEqual(coordinate, lastUserCoordinate) || (offCenter && mapView.bounds.height > 0) {
                    mapView.setCenter(coordinate, animated: true)
                }
            }

            lastUserCoordinate = newParent.userCoordinate
        }

        func invalidate(mapView: MKMapView) {
            fogRenderer?.visibleMapRectProvider = nil
            dispersalView?.removeAllPuffs()
            mapView.delegate = nil
            if !routeOverlays.isEmpty {
                mapView.removeOverlays(routeOverlays)
                routeOverlays.removeAll()
                renderedRouteSegments.removeAll()
            }
            mapView.removeOverlay(overlay)
            self.mapView = nil
        }

        private func renderInitialExploration() {
            guard let fogRenderer else { return }
            let geometries = parent.clearedCells.compactMap { try? parent.tileMath.geometry(for: $0) }
            fogRenderer.setClearedGeometries(geometries)
            renderedCells = parent.clearedCells
            lastRenderedChangeID = parent.latestChange?.id
        }

        private func updateExploration() {
            guard let fogRenderer else { return }
            let desiredCells = parent.clearedCells
            guard desiredCells != renderedCells else { return }

            if desiredCells.isEmpty {
                fogRenderer.reset()
                dispersalView?.removeAllPuffs()
                renderedCells = []
                lastRenderedChangeID = parent.latestChange?.id
                return
            }

            let addedCells = desiredCells.subtracting(renderedCells)
            let removedCells = renderedCells.subtracting(desiredCells)
            let change = parent.latestChange

            // Location updates can coalesce between SwiftUI updates, so the
            // latest change may not list every added cell. Any purely additive
            // update still animates (and pushes clouds) from the newest origin.
            if
                removedCells.isEmpty,
                !addedCells.isEmpty,
                let origin = change?.origin ?? parent.userCoordinate
            {
                let geometries = addedCells.compactMap { try? parent.tileMath.geometry(for: $0) }
                let dispersed = fogRenderer.reveal(
                    geometries,
                    origin: origin,
                    radiusMeters: change?.radiusMeters ?? 0,
                    style: .normal
                )
                dispersalView?.disperse(dispersed, awayFrom: origin)
            } else {
                let geometries = desiredCells.compactMap { try? parent.tileMath.geometry(for: $0) }
                fogRenderer.setClearedGeometries(geometries)
            }

            renderedCells = desiredCells
            lastRenderedChangeID = change?.id
        }

        private func updateAnnotations(on mapView: MKMapView) {
            var stale = questAnnotations
            for marker in parent.questMarkers {
                if let existing = stale.removeValue(forKey: marker.id) {
                    if existing.markerData != marker {
                        existing.update(with: marker)
                        (mapView.view(for: existing) as? QuestAnnotationView)?.refresh()
                    }
                } else {
                    let annotation = QuestAnnotation(data: marker)
                    questAnnotations[marker.id] = annotation
                    mapView.addAnnotation(annotation)
                }
            }
            for (id, annotation) in stale {
                mapView.removeAnnotation(annotation)
                questAnnotations.removeValue(forKey: id)
            }

            if parent.showsUserAnnotation, let coordinate = parent.userCoordinate {
                if let playerAnnotation {
                    let previous = playerAnnotation.coordinate
                    if !coordinatesEqual(coordinate, previous) {
                        updateHeading(from: previous, to: coordinate)
                        UIView.animate(
                            withDuration: 0.35,
                            delay: 0,
                            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
                        ) {
                            playerAnnotation.coordinate = coordinate
                        }
                        (mapView.view(for: playerAnnotation) as? UserLocationAnnotationView)?
                            .setHeading(playerHeading, animated: true)
                    }
                } else {
                    let annotation = UserLocationAnnotation(coordinate: coordinate)
                    playerAnnotation = annotation
                    mapView.addAnnotation(annotation)
                }
            } else if let playerAnnotation {
                mapView.removeAnnotation(playerAnnotation)
                self.playerAnnotation = nil
            }
        }

        /// The location pipeline has no compass heading, so the beam follows the
        /// direction of travel once the player has moved a meaningful distance.
        private func updateHeading(from previous: CLLocationCoordinate2D, to next: CLLocationCoordinate2D) {
            let from = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            let to = CLLocation(latitude: next.latitude, longitude: next.longitude)
            guard to.distance(from: from) > 0.8 else { return }

            let lat1 = previous.latitude * .pi / 180
            let lat2 = next.latitude * .pi / 180
            let deltaLon = (next.longitude - previous.longitude) * .pi / 180
            let y = sin(deltaLon) * cos(lat2)
            let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
            let bearing = atan2(y, x) * 180 / .pi
            playerHeading = (bearing + 360).truncatingRemainder(dividingBy: 360)
        }

        private func updateRouteOverlays(on mapView: MKMapView) {
            // Recolor in place (e.g. the quest turning green once collected).
            if renderedRouteColor != parent.routeColor {
                renderedRouteColor = parent.routeColor
                for polyline in routeOverlays {
                    guard let renderer = mapView.renderer(for: polyline) as? MKPolylineRenderer else { continue }
                    renderer.strokeColor = parent.routeColor
                    renderer.setNeedsDisplay()
                }
            }

            let desired = parent.routeSegments.filter { $0.count >= 2 }
            guard !Self.routeSegmentsEqual(renderedRouteSegments, desired) else { return }

            if !routeOverlays.isEmpty {
                mapView.removeOverlays(routeOverlays)
                routeOverlays.removeAll(keepingCapacity: true)
            }

            let polylines = desired.map { MKPolyline(coordinates: $0, count: $0.count) }
            routeOverlays = polylines
            renderedRouteSegments = desired
            if !polylines.isEmpty {
                // Same level as the clouds but added later, so the walked
                // route draws on top of any cloud edge it brushes past.
                mapView.addOverlays(polylines, level: .aboveLabels)
            }
        }

        private static func routeSegmentsEqual(
            _ lhs: [[CLLocationCoordinate2D]],
            _ rhs: [[CLLocationCoordinate2D]]
        ) -> Bool {
            guard lhs.count == rhs.count else { return false }
            for (leftSegment, rightSegment) in zip(lhs, rhs) {
                guard leftSegment.count == rightSegment.count else { return false }
                for (left, right) in zip(leftSegment, rightSegment) {
                    if abs(left.latitude - right.latitude) > 0.000_001
                        || abs(left.longitude - right.longitude) > 0.000_001
                    {
                        return false
                    }
                }
            }
            return true
        }

        private func setFollowing(_ following: Bool) {
            guard isFollowingUser != following else { return }
            isFollowingUser = following
            parent.onFollowingChanged(following)
        }

        @objc
        private func mapTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let mapView = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: mapView)
            parent.onMapTap(mapView.convert(point, toCoordinateFrom: mapView))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            let isUserPan = mapView.subviews
                .flatMap { $0.gestureRecognizers ?? [] }
                .compactMap { $0 as? UIPanGestureRecognizer }
                .contains { $0.state == .began || $0.state == .changed }

            if isUserPan {
                setFollowing(false)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                // Figma route: 5 pt, round caps/joins, in the quest's color.
                renderer.strokeColor = parent.routeColor
                renderer.lineWidth = 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }

            guard overlay === self.overlay else { return MKOverlayRenderer(overlay: overlay) }

            if let fogRenderer {
                return fogRenderer
            }

            let renderer = FogRenderer(overlay: overlay)
            renderer.visibleMapRectProvider = { [weak mapView] in mapView?.visibleMapRect }
            fogRenderer = renderer
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is QuestAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: QuestAnnotationView.reuseIdentifier,
                    for: annotation
                ) as? QuestAnnotationView
                view?.annotation = annotation
                return view
            }

            if annotation is UserLocationAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: UserLocationAnnotation.reuseIdentifier,
                    for: annotation
                ) as? UserLocationAnnotationView
                view?.annotation = annotation
                view?.setHeading(playerHeading, animated: false)
                return view
            }

            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            if let quest = annotation as? QuestAnnotation {
                parent.onQuestSelected(quest.markerData.id)
            }
            mapView.deselectAnnotation(annotation, animated: false)
        }

        private func coordinatesEqual(
            _ lhs: CLLocationCoordinate2D,
            _ rhs: CLLocationCoordinate2D?
        ) -> Bool {
            guard let rhs else { return false }
            return abs(lhs.latitude - rhs.latitude) < 0.000_001
                && abs(lhs.longitude - rhs.longitude) < 0.000_001
        }

        private static var westernUniversity: CLLocationCoordinate2D {
            FogMapView.westernUniversity
        }
    }
}

/// Hosts the map with the fog-fade effect layered on top.
final class FogMapContainerView: UIView {
    let mapView = MKMapView(frame: .zero)
    let dispersalView = CloudDispersalView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        mapView.frame = bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(mapView)

        dispersalView.frame = bounds
        dispersalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dispersalView.mapView = mapView
        addSubview(dispersalView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A one-off "show this place" request for `FogMapView`. Make a new value (new
/// `id`) each time; the map zooms when it sees an id it hasn't applied yet.
struct MapFocus: Equatable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D
    /// Width of ground to show around the spot.
    var spanMeters: Double = 260
    /// Keeps the spot clear of chrome (e.g. the expanded Quests sheet).
    var padding: UIEdgeInsets = .zero

    static func == (lhs: MapFocus, rhs: MapFocus) -> Bool { lhs.id == rhs.id }
}
