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
    /// The sticker whose stats are showing (kept while it flies back to the board).
    @State private var focus: StickerFocus?
    /// Drives the board ⇄ stats transition.
    @State private var isFocused = false
    /// Top-left of this page in global coordinates, to place the flying sticker.
    @State private var pageOrigin: CGPoint = .zero
    /// Bumped when sticker artwork finishes downloading, so the board picks it up.
    @State private var stickerArtworkVersion = 0

    // Figma offsets from the top of the profile container.
    private static let horizontalMargin: CGFloat = 28
    private static let headerTop: CGFloat = 30
    private static let statsTop: CGFloat = 99
    private static let boardTop: CGFloat = 198
    private static let bottomMargin: CGFloat = 30
    private static let minimumBoardHeight: CGFloat = 280

    /// Board ⇄ stats: the sticker flies while the pages cross-fade through a blur.
    private static let focusAnimation: Animation = .spring(duration: 0.55, bounce: 0.16)
    private static let fadeBlur: CGFloat = 14

    /// A sticker just collected: the board drops it into place when the page opens.
    var placingStickerID: String? = nil
    var onStickerPlaced: () -> Void = {}

    init(contentHeight: CGFloat, placingStickerID: String? = nil, onStickerPlaced: @escaping () -> Void = {}) {
        self.contentHeight = contentHeight
        self.placingStickerID = placingStickerID
        self.onStickerPlaced = onStickerPlaced
        #if DEBUG
        if let fixture = HolographicStickerDebugFixture.current {
            _focus = State(initialValue: StickerFocus(
                sticker: fixture.boardSticker,
                source: nil,
                expedition: fixture.expedition,
                date: fixture.collectedSticker.collectedAt
            ))
            _isFocused = State(initialValue: true)
        }
        #endif
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                profileContent
                    .opacity(isFocused ? 0 : 1)
                    .blur(radius: isFocused ? Self.fadeBlur : 0)
                    .allowsHitTesting(focus == nil)
                    .accessibilityHidden(focus != nil)

                if let focus {
                    stickerStats(focus, width: proxy.size.width)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { pageOrigin = $0 }
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
        // Stickers the server returned that this device has no artwork for yet.
        .task(id: services.profile.stickers.map(\.id)) {
            if await StickerImageCache.download(missingFrom: services.profile.stickers) { stickerArtworkVersion &+= 1 }
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
                stickers: boardStickers,
                label: Date.now.formatted(.dateTime.month(.abbreviated).year()),
                hiddenStickerID: focus?.sticker.id,
                placingStickerID: placingStickerID,
                onPlaced: onStickerPlaced,
                onSelect: { openStats(for: $0, from: $1) }
            )
                .frame(height: boardHeight)
        }
        .padding(.horizontal, Self.horizontalMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The four Figma demo stickers, then the player's own, oldest first: every find the server
    /// returns (artwork downloaded from Supabase Storage once, then cached) plus ones collected on
    /// this device that the server doesn't have yet. Debug-bypass stickers only exist in debug builds.
    private var boardStickers: [BoardSticker] {
        _ = stickerArtworkVersion // re-read once downloads land
        let collected = services.profile.stickers.reversed().enumerated().compactMap { index, sticker in
            StickerImageCache.file(for: sticker).flatMap { BoardSticker.collected(sticker, imageFile: $0, index: index) }
        }
        return BoardSticker.demo + collected
    }

    private var boardHeight: CGFloat {
        max(contentHeight - Self.boardTop - Self.bottomMargin, Self.minimumBoardHeight)
    }

    // MARK: Sticker stats

    struct StickerFocus {
        let sticker: BoardSticker
        /// Where the sticker sat on the board, in this page's coordinates
        /// (`nil` when opened without one; it fades in place instead).
        let source: StickerPlacement?
        let expedition: ExpeditionSummary?
        /// Shown at the bottom of the stats page.
        let date: Date?
    }

    /// The stats page plus the sticker flying between the board and its spot at the top.
    @ViewBuilder
    private func stickerStats(_ focus: StickerFocus, width: CGFloat) -> some View {
        let rest = StickerStatsLayout.heroPlacement(for: focus.sticker, width: width)

        StickerStatsView(
            sticker: focus.sticker,
            expedition: focus.expedition,
            date: focus.date,
            onDismiss: closeStats
        )
            .opacity(isFocused ? 1 : 0)
            .blur(radius: isFocused ? 0 : Self.fadeBlur)
            .allowsHitTesting(isFocused)
            .onAppear {
                guard !isFocused else { return }
                withAnimation(Self.focusAnimation) { isFocused = true }
            }

        StickerHeroView(
            sticker: focus.sticker,
            placement: isFocused ? rest : (focus.source ?? rest),
            restScale: rest.scale,
            movement: heroMovement(for: focus.sticker, rest: rest, width: width)
        )
        .opacity(focus.source == nil && !isFocused ? 0 : 1)
        .allowsHitTesting(isFocused)
    }

    /// How far the sticker can be dragged around its spot without hitting the stats.
    private func heroMovement(for sticker: BoardSticker, rest: StickerPlacement, width: CGFloat) -> CGSize {
        CGSize(
            width: max(0, min(48, (width - sticker.size.width * rest.scale) / 2 - 16)),
            height: 14
        )
    }

    private func openStats(for sticker: BoardSticker, from globalPlacement: StickerPlacement) {
        guard focus == nil else { return }
        let source = StickerPlacement(
            center: CGPoint(
                x: globalPlacement.center.x - pageOrigin.x,
                y: globalPlacement.center.y - pageOrigin.y
            ),
            scale: globalPlacement.scale
        )
        // Shown at the board position first; `onAppear` then animates it up.
        isFocused = false
        focus = StickerFocus(
            sticker: sticker,
            source: source,
            expedition: expedition(for: sticker),
            date: date(for: sticker)
        )
    }

    private func closeStats() {
        guard focus != nil, isFocused else { return }
        withAnimation(Self.focusAnimation, completionCriteria: .removed) {
            isFocused = false
        } completion: {
            focus = nil
        }
    }

    /// When the sticker was collected. The demo stickers have no record, so
    /// they show today's date as a stand-in.
    private func date(for boardSticker: BoardSticker) -> Date? {
        if let collected = matchingSticker(for: boardSticker) { return collected.collectedAt }
        return boardSticker.id.hasPrefix("demo.") ? .now : nil
    }

    private func expedition(for boardSticker: BoardSticker) -> ExpeditionSummary? {
        matchingSticker(for: boardSticker).flatMap { matchingExpedition(for: $0) }
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
    let labelTop: CGFloat
    @ViewBuilder let glyph: Glyph

    var body: some View {
        color
            .frame(maxWidth: .infinity)
            .frame(height: 75)
            // Overlays so the glyph (taller than the card) can't size the card.
            .overlay(alignment: .topLeading) { glyph }
            // Label and value both sit on the leading edge.
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(SideQuestDesign.ptSans(fixed: 17))
                    .tracking(-0.51)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.leading, 15)
                    .padding(.trailing, 10)
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
