import SwiftUI
import FogKit

/// The profile container under the map (Figma 42:2159): who you are, how much
/// of your city you've uncovered, how far you've walked on quests, and the
/// memory board of collected stickers.
struct ProfilePage: View {
    /// Height the profile gets when it's fully open; the board fills what's left.
    let contentHeight: CGFloat

    @Environment(FogServices.self) private var services
    @Environment(ExplorationStore.self) private var explorationStore
    @State private var coverage = CityCoverage()
    @State private var percentExplored: Double?
    @State private var selectedSticker: BoardSticker?

    // Figma offsets from the top of the profile container.
    private static let horizontalMargin: CGFloat = 28
    private static let headerTop: CGFloat = 30
    private static let statsTop: CGFloat = 99
    private static let boardTop: CGFloat = 198
    private static let bottomMargin: CGFloat = 30
    private static let minimumBoardHeight: CGFloat = 280

    init(contentHeight: CGFloat) {
        self.contentHeight = contentHeight
        #if DEBUG
        _selectedSticker = State(initialValue: HolographicStickerDebugFixture.current?.boardSticker)
        #endif
    }

    var body: some View {
        profileContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: SideQuestDesign.containerCornerRadius, style: .continuous)
                .fill(SideQuestDesign.profileSurface)
        }
        .task(id: coordinateKey) {
            guard let coordinate = playerCoordinate else { return }
            await coverage.locate(near: coordinate.clCoordinate)
        }
        .task(id: CoverageInputs(city: coverage.city, cleared: explorationStore.clearedCells.count)) {
            percentExplored = await coverage.percentExplored(by: explorationStore.clearedCells)
        }
        .task { await services.profile.refresh() }
        .fullScreenCover(item: $selectedSticker) { selectedSticker in
            let detail = detailData(for: selectedSticker)
            HolographicStickerDetailView(
                sticker: selectedSticker,
                collectedSticker: detail.collectedSticker,
                expedition: detail.expedition,
                isSample: detail.isSample,
                onDismiss: { self.selectedSticker = nil }
            )
            .preferredColorScheme(.light)
        }
    }

    private var profileContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, Self.headerTop)
                .frame(height: Self.statsTop, alignment: .top)

            stats
                .frame(height: Self.boardTop - Self.statsTop, alignment: .top)

            StickerBoard(
                label: Date.now.formatted(.dateTime.month(.abbreviated).year()),
                onSelect: { selectedSticker = $0 }
            )
                .frame(height: boardHeight)
        }
        .padding(.horizontal, Self.horizontalMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var boardHeight: CGFloat {
        max(contentHeight - Self.boardTop - Self.bottomMargin, Self.minimumBoardHeight)
    }

    private func detailData(for boardSticker: BoardSticker) -> (
        collectedSticker: Sticker?,
        expedition: ExpeditionSummary?,
        isSample: Bool
    ) {
        #if DEBUG
        if let fixture = HolographicStickerDebugFixture.current {
            return (fixture.collectedSticker, fixture.expedition, true)
        }
        #endif

        let collectedSticker = matchingSticker(for: boardSticker)
        return (
            collectedSticker,
            collectedSticker.flatMap { matchingExpedition(for: $0) },
            false
        )
    }

    /// Board demo stickers intentionally have non-UUID ids, so they cannot be
    /// associated with route data by accident. Once a board item carries a
    /// real completion or quest UUID, prefer an exact persisted relationship;
    /// timestamp containment is accepted only when it identifies one summary.
    private func matchingSticker(for boardSticker: BoardSticker) -> Sticker? {
        guard let identifier = UUID(uuidString: boardSticker.id) else { return nil }
        return services.profile.stickers.first(where: {
            $0.id == identifier || $0.questID == identifier
        })
    }

    private func matchingExpedition(for collectedSticker: Sticker) -> ExpeditionSummary? {
        let expeditions = services.profile.expeditions
        if let exact = expeditions.first(where: { $0.sticker?.id == collectedSticker.id }) {
            return exact
        }
        if let exactQuest = expeditions.first(where: { $0.sticker?.questID == collectedSticker.questID }) {
            return exactQuest
        }

        let containing = expeditions.filter {
            $0.startedAt <= collectedSticker.collectedAt && collectedSticker.collectedAt <= $0.endedAt
        }
        return containing.count == 1 ? containing[0] : nil
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text(services.profile.username ?? "Jonathan Zhou")
                    .font(SideQuestDesign.calSans(22))
                    .tracking(-0.22)
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // Friends aren't in the backend yet; the design's count stands in.
                Text("6 friends")
                    .font(SideQuestDesign.ptSans(17, relativeTo: .body))
                    .tracking(-0.51)
                    .foregroundStyle(.black)
            }
            .padding(.leading, 5)
            .padding(.top, 3)

            Spacer(minLength: 12)

            Image("ProfileAvatar")
                .resizable()
                .frame(width: 50, height: 50)
                .accessibilityLabel("Profile picture")
        }
    }

    // MARK: Stats

    private var stats: some View {
        HStack(spacing: 18) {
            ProfileStatCard(
                value: Self.percentText(displayedPercent),
                label: cityName ?? "Your city",
                color: SideQuestDesign.cityCard,
                accessibilityText: "Explored \(Self.percentText(displayedPercent)) of \(cityName ?? "your city")",
                labelTrailing: 11,
                labelTop: 9
            ) {
                Image("ProfileCityGlyph")
                    .frame(width: 102, height: 102)
                    .offset(x: -41, y: -6)
            }

            ProfileStatCard(
                value: Self.distanceText(totalDistanceMeters),
                label: "Traveled",
                color: SideQuestDesign.travelCard,
                accessibilityText: "Traveled \(Self.distanceText(totalDistanceMeters)) on quests",
                labelTrailing: 10,
                labelTop: 8
            ) {
                Image("ProfileTravelGlyph")
                    .frame(width: 69.3332, height: 80.008)
                    .offset(x: -8.67, y: -1.67)
            }
        }
    }

    /// Lifetime quest distance plus the quest in progress (or the debug menu's value).
    private var totalDistanceMeters: Double {
        services.debug.distanceMeters(
            real: services.profile.stats.distanceM + (services.expeditions.active?.distanceMeters ?? 0)
        )
    }

    /// Real coverage, unless the debug menu sets one.
    private var displayedPercent: Double? {
        services.debug.cityExploredPercent(real: percentExplored).map { min($0, 100) }
    }

    private var cityName: String? {
        services.debug.cityName(real: coverage.city?.name)
    }

    private var playerCoordinate: Coordinate? {
        services.location.currentCoordinate ?? services.location.displayCoordinate
    }

    /// Changes only when the player moves ~1 km, so the city lookup isn't re-run on every fix.
    private var coordinateKey: String? {
        playerCoordinate.map { String(format: "%.2f,%.2f", $0.latitude, $0.longitude) }
    }

    private struct CoverageInputs: Equatable {
        var city: CityCoverage.City?
        var cleared: Int
    }

    static func percentText(_ percent: Double?) -> String {
        guard let percent, percent > 0 else { return "0%" }
        if percent >= 1 { return "\(Int(percent.rounded()))%" }
        if percent < 0.1 { return "<0.1%" }
        return percent.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    static func distanceText(_ meters: Double) -> String {
        let km = max(meters, 0) / 1000
        if km >= 10 { return "\(Int(km.rounded()).formatted())km" }
        return km.formatted(.number.precision(.fractionLength(km == 0 ? 0 : 1))) + "km"
    }
}

/// A summary card (Figma "Location Summary" / "Travel Summary"): a faint
/// glyph bleeding off the leading edge, the label top-right, the value bottom-left.
private struct ProfileStatCard<Glyph: View>: View {
    let value: String
    let label: String
    let color: Color
    let accessibilityText: String
    let labelTrailing: CGFloat
    let labelTop: CGFloat
    @ViewBuilder let glyph: Glyph

    var body: some View {
        color
            .frame(maxWidth: .infinity)
            .frame(height: 75)
            // Overlays so the glyph (taller than the card) can't size the card.
            .overlay(alignment: .topLeading) { glyph }
            .overlay(alignment: .topTrailing) {
                Text(label)
                    .font(SideQuestDesign.ptSans(fixed: 17))
                    .tracking(-0.51)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.leading, 60)
                    .padding(.trailing, labelTrailing)
                    .padding(.top, labelTop)
            }
            .overlay(alignment: .bottomLeading) {
                Text(value)
                    .font(SideQuestDesign.calSans(38, relativeTo: nil))
                    .tracking(-0.38)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.leading, 15)
                    .padding(.trailing, 10)
                    .padding(.bottom, 6)
            }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
