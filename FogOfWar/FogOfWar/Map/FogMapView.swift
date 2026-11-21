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
    var questMarker: QuestMarkerData?
    /// Optional route polylines (active expedition or profile path tracing). Each
    /// inner array is one continuous segment — never join across gaps.
    var routeSegments: [[CLLocationCoordinate2D]] = []
    var recenterToken: Int
    var onMapTap: (CLLocationCoordinate2D) -> Void
    var onFollowingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        context.coordinator.install(on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.update(from: self, on: mapView)
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.invalidate(mapView: mapView)
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
        private var isFollowingUser = true
        private var questAnnotation: QuestAnnotation?
        private var playerAnnotation: PlayerAnnotation?
        private var routeOverlays: [MKPolyline] = []
        private var renderedRouteSegments: [[CLLocationCoordinate2D]] = []
        private weak var mapView: MKMapView?

        init(parent: FogMapView) {
            self.parent = parent
            self.lastRecenterToken = parent.recenterToken
            super.init()
        }

        func install(on mapView: MKMapView) {
            self.mapView = mapView
            mapView.delegate = self
            mapView.accessibilityLabel = "Exploration map"
            mapView.accessibilityHint = "Pan and pinch to explore. Uncleared places are covered by fog."

            let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            configuration.pointOfInterestFilter = .includingAll
            mapView.preferredConfiguration = configuration
            mapView.isPitchEnabled = false
            mapView.isRotateEnabled = false
            mapView.showsCompass = true
            mapView.showsScale = true

            mapView.register(
                QuestAnnotationView.self,
                forAnnotationViewWithReuseIdentifier: QuestAnnotationView.reuseIdentifier
            )
            mapView.register(
                MKMarkerAnnotationView.self,
                forAnnotationViewWithReuseIdentifier: PlayerAnnotation.reuseIdentifier
            )

            let initialCenter = parent.userCoordinate ?? Self.westernUniversity
            mapView.setRegion(
                MKCoordinateRegion(
                    center: initialCenter,
                    latitudinalMeters: 1_000,
                    // A square region makes MapKit expand the vertical span to
                    // more than 2 km on a portrait iPhone. This ratio keeps the
                    // initial visible height near the PRD's requested 1 km and
                    // preserves the PRD's roughly one-kilometre initial view.
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

            if newParent.recenterToken != lastRecenterToken {
                lastRecenterToken = newParent.recenterToken
                setFollowing(true)
                mapView.setCenter(newParent.userCoordinate ?? Self.westernUniversity, animated: true)
            } else if
                let coordinate = newParent.userCoordinate,
                !coordinatesEqual(coordinate, lastUserCoordinate),
                isFollowingUser
            {
                mapView.setCenter(coordinate, animated: true)
            }

            lastUserCoordinate = newParent.userCoordinate
        }

        func invalidate(mapView: MKMapView) {
            fogRenderer?.atmosphericMotionEnabled = false
            fogRenderer?.visibleMapRectProvider = nil
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
                renderedCells = []
                lastRenderedChangeID = parent.latestChange?.id
                return
            }

            let addedCells = desiredCells.subtracting(renderedCells)
            let removedCells = renderedCells.subtracting(desiredCells)
            let change = parent.latestChange

            if
                removedCells.isEmpty,
                !addedCells.isEmpty,
                let change,
                change.id != lastRenderedChangeID,
                change.newlyClearedCells.isSuperset(of: addedCells),
                let origin = change.origin
            {
                let geometries = addedCells.compactMap { try? parent.tileMath.geometry(for: $0) }
                fogRenderer.reveal(
                    geometries,
                    origin: origin,
                    radiusMeters: change.radiusMeters ?? 0,
                    style: .normal
                )
            } else {
                let geometries = desiredCells.compactMap { try? parent.tileMath.geometry(for: $0) }
                fogRenderer.setClearedGeometries(geometries)
            }

            renderedCells = desiredCells
            lastRenderedChangeID = change?.id
        }

        private func updateAnnotations(on mapView: MKMapView) {
            if let markerData = parent.questMarker {
                if let questAnnotation, questAnnotation.markerData.id == markerData.id {
                    questAnnotation.update(with: markerData)
                    (mapView.view(for: questAnnotation) as? QuestAnnotationView)?.refresh()
                } else {
                    if let questAnnotation {
                        mapView.removeAnnotation(questAnnotation)
                    }
                    let annotation = QuestAnnotation(data: markerData)
                    questAnnotation = annotation
                    mapView.addAnnotation(annotation)
                }
            } else if let questAnnotation {
                mapView.removeAnnotation(questAnnotation)
                self.questAnnotation = nil
            }

            if parent.showsUserAnnotation, let coordinate = parent.userCoordinate {
                if let playerAnnotation {
                    playerAnnotation.coordinate = coordinate
                } else {
                    let annotation = PlayerAnnotation(coordinate: coordinate)
                    playerAnnotation = annotation
                    mapView.addAnnotation(annotation)
                }
            } else if let playerAnnotation {
                mapView.removeAnnotation(playerAnnotation)
                self.playerAnnotation = nil
            }
        }

        private func updateRouteOverlays(on mapView: MKMapView) {
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
                mapView.addOverlays(polylines, level: .aboveRoads)
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
                renderer.strokeColor = UIColor(red: 1.0, green: 0.55, blue: 0.18, alpha: 0.92)
                renderer.lineWidth = 4
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
            renderer.atmosphericMotionEnabled = !UIAccessibility.isReduceMotionEnabled
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

            if annotation is PlayerAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: PlayerAnnotation.reuseIdentifier,
                    for: annotation
                ) as? MKMarkerAnnotationView
                view?.annotation = annotation
                view?.markerTintColor = UIColor(red: 0.10, green: 0.82, blue: 0.76, alpha: 1)
                view?.glyphTintColor = .white
                view?.glyphImage = UIImage(systemName: "figure.walk")
                view?.displayPriority = .required
                view?.zPriority = .max
                view?.collisionMode = .circle
                view?.clusteringIdentifier = nil
                return view
            }

            return nil
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

private final class PlayerAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "PlayerAnnotationView"

    @objc dynamic var coordinate: CLLocationCoordinate2D
    let title: String? = "Explorer"

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
}
