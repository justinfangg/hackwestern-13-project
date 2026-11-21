import MapKit
import SwiftUI
import UIKit

/// Map-only adapter for the shared `Quest` model. Keeping this DTO free of
/// backend fields lets the map compile and demo independently.
struct QuestMarkerData: Identifiable, Equatable {
    enum Status: Equatable {
        /// Yellow/orange beacon: quest still to find.
        case active
        /// Green beacon: collected today.
        case completed
    }

    let id: String
    var coordinate: CLLocationCoordinate2D
    /// Short label for the map pill, e.g. "Tree".
    var title: String
    var subtitle: String?
    var participantCount: Int
    var status: Status
    /// Whether the name/participants pill is drawn next to the beacon.
    var showsLabel: Bool

    init(
        id: String,
        coordinate: CLLocationCoordinate2D,
        title: String,
        subtitle: String? = nil,
        participantCount: Int = 0,
        status: Status = .active,
        showsLabel: Bool = true
    ) {
        self.id = id
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        self.participantCount = participantCount
        self.status = status
        self.showsLabel = showsLabel
    }

    static func == (lhs: QuestMarkerData, rhs: QuestMarkerData) -> Bool {
        lhs.id == rhs.id
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.participantCount == rhs.participantCount
            && lhs.status == rhs.status
            && lhs.showsLabel == rhs.showsLabel
    }
}

/// Point annotation rendered by MapKit's annotation layer, which stays above
/// the `.aboveLabels` cloud overlay.
final class QuestAnnotation: NSObject, MKAnnotation {
    private(set) var markerData: QuestMarkerData

    @objc dynamic private(set) var coordinate: CLLocationCoordinate2D
    @objc dynamic private(set) var title: String?
    @objc dynamic private(set) var subtitle: String?

    init(data: QuestMarkerData) {
        markerData = data
        coordinate = data.coordinate
        title = data.title
        subtitle = data.subtitle
        super.init()
    }

    func update(with data: QuestMarkerData) {
        markerData = data
        coordinate = data.coordinate
        title = data.title
        subtitle = data.subtitle
    }
}

/// The Figma quest goal: a glowing beacon (orange when active, green once
/// collected) with a pill showing the quest name and how many explorers are on it.
final class QuestAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "QuestAnnotationView"

    /// Figma pin frame and the beacon dot's center inside it.
    private static let pinSize = CGSize(width: 92.8642, height: 95.0936)
    private static let dotCenter = CGPoint(x: 46.2881, y: 46.2881)
    /// Gap between the pill's bottom edge and the beacon's center (Figma: ~17-18 pt).
    private static let pillLift: CGFloat = 17.5

    private let pinView = UIImageView()
    private let pillHost = UIHostingController(rootView: QuestMarkerPill(title: "", participantCount: 0, status: .active))

    override var annotation: MKAnnotation? {
        didSet { updateContent() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        updateContent()
    }

    /// Refreshes the pill after an in-place annotation update.
    func refresh() {
        updateContent()
    }

    private func configure() {
        frame = CGRect(origin: .zero, size: Self.pinSize)
        // Put the beacon dot (not the frame center) on the coordinate.
        centerOffset = CGPoint(
            x: Self.pinSize.width / 2 - Self.dotCenter.x,
            y: Self.pinSize.height / 2 - Self.dotCenter.y
        )
        backgroundColor = .clear
        canShowCallout = false
        displayPriority = .required
        zPriority = .defaultUnselected
        collisionMode = .none
        clusteringIdentifier = nil

        pinView.frame = bounds
        pinView.contentMode = .scaleToFill
        addSubview(pinView)

        pillHost.view.backgroundColor = .clear
        pillHost.view.isUserInteractionEnabled = false
        pillHost.sizingOptions = .intrinsicContentSize
        addSubview(pillHost.view)

        isAccessibilityElement = true
        accessibilityTraits = [.button]
        updateContent()
    }

    private func updateContent() {
        guard let data = (annotation as? QuestAnnotation)?.markerData else { return }

        pinView.image = UIImage(named: data.status == .completed ? "QuestPinCompleted" : "QuestPinActive")
        pillHost.rootView = QuestMarkerPill(
            title: data.title,
            participantCount: data.participantCount,
            status: data.status
        )

        let pillSize = pillHost.sizeThatFits(in: CGSize(width: 240, height: 60))
        // Figma: the active pill hangs up-left of its beacon, the completed one up-right.
        let originX = data.status == .completed
            ? Self.dotCenter.x + 7
            : Self.dotCenter.x - pillSize.width
        pillHost.view.frame = CGRect(
            x: originX,
            y: Self.dotCenter.y - Self.pillLift - pillSize.height,
            width: pillSize.width,
            height: pillSize.height
        )
        let pillAlpha: CGFloat = data.showsLabel ? 1 : 0
        if pillHost.view.alpha != pillAlpha {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState]) {
                self.pillHost.view.alpha = pillAlpha
                self.pillHost.view.transform = data.showsLabel ? .identity : CGAffineTransform(scaleX: 0.85, y: 0.85)
            }
        }

        accessibilityLabel = "\(data.title) quest"
        accessibilityValue = data.participantCount == 1
            ? "1 explorer"
            : "\(data.participantCount) explorers"
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event)
            || (pillHost.view.alpha > 0 && pillHost.view.frame.contains(point))
    }
}

/// Quest pill from Figma (node 26:2027): colored capsule, PT Sans 20 title,
/// two-person glyph and participant count.
struct QuestMarkerPill: View {
    let title: String
    let participantCount: Int
    let status: QuestMarkerData.Status

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
            HStack(spacing: 2) {
                Image("QuestParticipants")
                    .resizable()
                    .frame(width: 20, height: 16)
                Text(participantCount, format: .number)
                    .monospacedDigit()
            }
        }
        .font(SideQuestDesign.ptSans(20))
        .tracking(-0.6)
        .foregroundStyle(SideQuestDesign.pillText)
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(minWidth: 103, minHeight: 36)
        .background(
            status == .completed ? SideQuestDesign.questCompleted : SideQuestDesign.questActive,
            in: .capsule
        )
        .fixedSize()
    }
}

/// The player's position: the Figma blue dot with its heading beam.
final class UserLocationAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "UserLocationAnnotationView"

    @objc dynamic var coordinate: CLLocationCoordinate2D
    let title: String? = "You"

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
}

final class UserLocationAnnotationView: MKAnnotationView {
    /// Figma "Pin" frame and the dot's center inside it.
    private static let pinSize = CGSize(width: 92.5762, height: 94.7291)
    private static let dotCenter = CGPoint(x: 46, y: 45.9235)
    /// Bearing (degrees clockwise from north) the beam points at in the Figma asset.
    private static let assetBeamBearing: CGFloat = 163

    private let pinView = UIImageView(image: UIImage(named: "UserLocationPin"))
    private var currentHeading: CGFloat?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        frame = CGRect(origin: .zero, size: Self.pinSize)
        centerOffset = CGPoint(
            x: Self.pinSize.width / 2 - Self.dotCenter.x,
            y: Self.pinSize.height / 2 - Self.dotCenter.y
        )
        backgroundColor = .clear
        canShowCallout = false
        displayPriority = .required
        zPriority = .max
        collisionMode = .circle
        clusteringIdentifier = nil

        // Rotate the beam around the dot, not the frame center.
        pinView.frame = bounds
        pinView.layer.anchorPoint = CGPoint(
            x: Self.dotCenter.x / Self.pinSize.width,
            y: Self.dotCenter.y / Self.pinSize.height
        )
        pinView.layer.position = Self.dotCenter
        addSubview(pinView)

        isAccessibilityElement = true
        accessibilityLabel = "Your location"
    }

    /// Points the beam along `bearing` (degrees clockwise from north).
    func setHeading(_ bearing: CLLocationDirection?, animated: Bool) {
        guard let bearing else { return }
        let target = CGFloat(bearing)
        // Unwrap so the beam always takes the short way round.
        var next = target
        if let currentHeading {
            var delta = (target - currentHeading).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            next = currentHeading + delta
        }
        currentHeading = next
        let radians = (next - Self.assetBeamBearing) * .pi / 180
        let apply = { self.pinView.transform = CGAffineTransform(rotationAngle: radians) }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.45,
                delay: 0,
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: apply
            )
        } else {
            apply()
        }
    }
}
