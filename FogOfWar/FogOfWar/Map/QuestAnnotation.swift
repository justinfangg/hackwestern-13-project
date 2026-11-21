import MapKit
import QuartzCore
import UIKit

/// Map-only adapter for Vishaal's eventual shared `Quest` model. Keeping this
/// DTO free of backend fields lets the map compile and demo independently.
struct QuestMarkerData: Identifiable, Equatable {
    let id: String
    var coordinate: CLLocationCoordinate2D
    var title: String
    var subtitle: String?
    var systemImageName: String

    init(
        id: String,
        coordinate: CLLocationCoordinate2D,
        title: String,
        subtitle: String? = nil,
        systemImageName: String = "flag.fill"
    ) {
        self.id = id
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
    }

    static func == (lhs: QuestMarkerData, rhs: QuestMarkerData) -> Bool {
        lhs.id == rhs.id
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.systemImageName == rhs.systemImageName
    }
}

/// Point annotation deliberately rendered by MapKit's annotation layer, which
/// remains above an `.aboveLabels` fog overlay.
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
        NotificationCenter.default.post(
            name: .MKAnnotationCalloutInfoDidChange,
            object: self
        )
    }
}

/// A compact, game-like quest beacon. Required display priority, maximum z
/// priority, no collision occlusion, and no clustering keep the quest visible
/// over fog and ordinary MapKit labels at every supported zoom.
final class QuestAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "QuestAnnotationView"

    private let haloLayer = CAShapeLayer()
    private let pointerLayer = CAShapeLayer()
    private let markerBody = UIView()
    private let iconView = UIImageView()

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

    override func prepareForReuse() {
        super.prepareForReuse()
        haloLayer.removeAllAnimations()
        iconView.image = nil
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        updateContent()
        installPulseAnimationIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let haloFrame = CGRect(x: 5, y: 1, width: 54, height: 54)
        haloLayer.frame = haloFrame
        haloLayer.path = UIBezierPath(ovalIn: haloLayer.bounds).cgPath

        markerBody.frame = CGRect(x: 11, y: 7, width: 42, height: 42)
        markerBody.layer.cornerRadius = markerBody.bounds.width / 2
        iconView.frame = markerBody.bounds.insetBy(dx: 9, dy: 9)

        let pointerPath = UIBezierPath()
        pointerPath.move(to: CGPoint(x: 25, y: 43))
        pointerPath.addLine(to: CGPoint(x: 32, y: 62))
        pointerPath.addLine(to: CGPoint(x: 39, y: 43))
        pointerPath.close()
        pointerLayer.path = pointerPath.cgPath
    }

    /// Refreshes SF Symbol/title state after an in-place annotation update.
    func refresh() {
        updateContent()
    }

    private func configure() {
        frame = CGRect(x: 0, y: 0, width: 64, height: 66)
        centerOffset = CGPoint(x: 0, y: -31)
        backgroundColor = .clear
        canShowCallout = true
        displayPriority = .required
        zPriority = .max
        selectedZPriority = .max
        collisionMode = .none
        clusteringIdentifier = nil

        haloLayer.fillColor = FogAppearance.default.questMarkerColor
            .withAlphaComponent(0.16)
            .cgColor
        haloLayer.strokeColor = FogAppearance.default.questMarkerColor
            .withAlphaComponent(0.5)
            .cgColor
        haloLayer.lineWidth = 1.2
        layer.addSublayer(haloLayer)

        pointerLayer.fillColor = FogAppearance.default.questMarkerColor.cgColor
        pointerLayer.shadowColor = UIColor.black.cgColor
        pointerLayer.shadowOpacity = 0.34
        pointerLayer.shadowRadius = 4
        pointerLayer.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(pointerLayer)

        markerBody.backgroundColor = FogAppearance.default.questMarkerColor
        markerBody.layer.borderColor = UIColor.white.withAlphaComponent(0.82).cgColor
        markerBody.layer.borderWidth = 2
        markerBody.layer.shadowColor = UIColor.black.cgColor
        markerBody.layer.shadowOpacity = 0.38
        markerBody.layer.shadowRadius = 8
        markerBody.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(markerBody)

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = UIColor(
            red: 24.0 / 255.0,
            green: 28.0 / 255.0,
            blue: 35.0 / 255.0,
            alpha: 1
        )
        markerBody.addSubview(iconView)

        isAccessibilityElement = true
        accessibilityTraits = [.button]
        updateContent()
        installPulseAnimationIfNeeded()
    }

    private func updateContent() {
        guard let questAnnotation = annotation as? QuestAnnotation else {
            iconView.image = UIImage(systemName: "flag.fill")
            accessibilityLabel = "Quest"
            return
        }

        let configuration = UIImage.SymbolConfiguration(pointSize: 19, weight: .bold)
        iconView.image = UIImage(
            systemName: questAnnotation.markerData.systemImageName,
            withConfiguration: configuration
        ) ?? UIImage(systemName: "flag.fill", withConfiguration: configuration)

        accessibilityLabel = questAnnotation.markerData.title
        accessibilityValue = questAnnotation.markerData.subtitle
    }

    private func installPulseAnimationIfNeeded() {
        haloLayer.removeAnimation(forKey: "quest-pulse")
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.82
        scale.toValue = 1.18

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.78
        opacity.toValue = 0.16

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 1.55
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.autoreverses = true
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        haloLayer.add(group, forKey: "quest-pulse")
    }
}
