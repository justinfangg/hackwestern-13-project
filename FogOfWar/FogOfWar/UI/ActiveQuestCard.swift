import SwiftUI
import FogKit

/// Dark card shown while a quest is in progress (Figma node 16:383): elapsed
/// time, quest name, distance left, who else is on it, and the abandon /
/// capture buttons.
///
/// The same container doubles as the camera (Figma node 16:390): opening it
/// springs the card taller and blur-swaps the summary for the live feed.
struct ActiveQuestCard: View {
    let quest: Quest
    let startedAt: Date
    let captureState: QuestCaptureModel.State
    let distanceToTarget: Double?
    /// Explorers on this quest (real count, or the debug override).
    let participantCount: Int
    @Binding var isCameraOpen: Bool
    let camera: CameraController
    let cameraHeight: CGFloat
    let onAbandon: () -> Void
    let onCapture: () -> Void
    let onPhoto: (CGImage) -> Void
    /// Debug bypass: capture is always enabled and the shutter submits this image.
    var debugPhoto: (() -> CGImage?)? = nil
    /// Demo mode: the camera shows (and captures) this photo.
    var demoPhoto: CGImage? = nil
    /// A photo being checked (or its answer): replaces the camera face.
    var resultFace: AnyView? = nil
    /// Height of the card while `resultFace` shows (it grows once the answer is in).
    var resultHeight: CGFloat = 0

    @State private var confirmAbandon = false

    static let height: CGFloat = 168
    /// Figma camera card: 388 × 542.
    static let cameraHeight: CGFloat = 542
    static let cornerRadius: CGFloat = 53
    /// Spring for the card growing into (and shrinking out of) the camera.
    static let cameraTransition: Animation = .spring(duration: 0.36, bounce: 0.14)

    var body: some View {
        // Each face keeps its own fixed height and is pinned to the bottom, so
        // the growing card reveals the camera instead of re-laying it out.
        ZStack(alignment: .bottom) {
            if let resultFace {
                resultFace
                    .frame(height: cardHeight)
                    .transition(.blurReplace)
            } else if isCameraOpen {
                QuestCameraView(
                    label: quest.category.capitalized,
                    camera: camera,
                    onClose: {
                        withAnimation(Self.cameraTransition) { isCameraOpen = false }
                    },
                    onPhoto: onPhoto,
                    debugPhoto: debugPhoto,
                    demoPhoto: demoPhoto
                )
                .frame(height: cameraHeight)
                .transition(.blurReplace)
            } else {
                summary
                    .frame(height: Self.height)
                    .transition(.blurReplace)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight, alignment: .bottom)
        .background(SideQuestDesign.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .confirmationDialog("Abandon this quest?", isPresented: $confirmAbandon, titleVisibility: .visible) {
            Button("Abandon Quest", role: .destructive, action: onAbandon)
        } message: {
            Text("Your route so far is still saved.")
        }
    }

    private var cardHeight: CGFloat {
        if resultFace != nil { return resultHeight }
        return isCameraOpen ? cameraHeight : Self.height
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                // Live, self-updating elapsed time since the quest was accepted.
                Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
                    .font(SideQuestDesign.calSans(65, relativeTo: nil))
                    .tracking(-0.65)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 16)
                    .accessibilityLabel("Time on quest")

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 0) {
                    Text(quest.title)
                    Text(statusLine)
                        .contentTransition(.numericText())
                }
                .font(SideQuestDesign.ptSans(20))
                .tracking(-0.6)
                .lineLimit(1)
                .padding(.bottom, 26)
            }
            .padding(.leading, 32)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 0) {
                ParticipantStack(count: participantCount)
                    .padding(.top, 30)
                Spacer(minLength: 0)
                HStack(spacing: 8.4) {
                    Button(action: { confirmAbandon = true }) {
                        Image("QuestCancelButton")
                    }
                    .accessibilityLabel("Abandon quest")

                    Button(action: onCapture) {
                        Image("QuestCaptureButton")
                    }
                    .disabled(!canCapture)
                    .opacity(canCapture ? 1 : 0.45)
                    .accessibilityLabel("Capture")
                    .accessibilityHint(canCapture ? "Take a photo of the quest target" : "Get within 40 metres to unlock")
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.bottom, 21.4)
            }
            .padding(.trailing, 27)
        }
        .foregroundStyle(SideQuestDesign.pillText)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: canCapture)
    }

    /// In range, or retrying after a failed photo.
    private var canCapture: Bool {
        if debugPhoto != nil { return captureState != .verifying }
        switch captureState {
        case .ready, .rejected, .tooFar, .error: return true
        default: return false
        }
    }

    private var statusLine: String {
        switch captureState {
        case .ready: return "You're here!"
        case .verifying: return "Verifying…"
        case .success, .alreadyCompleted: return "Quest complete"
        case .rejected(_, let left): return "Not quite: \(left) tries left"
        case .tooFar: return "Get a little closer"
        case .outOfAttempts: return "Out of attempts today"
        default:
            guard let distanceToTarget else { return "Locating…" }
            let distance = Measurement(value: distanceToTarget, unit: UnitLength.meters)
                .formatted(.measurement(width: .narrow, usage: .road))
            return "\(distance) left"
        }
    }
}

/// Overlapping avatar bubbles plus a "+N" overflow count.
/// The avatars are the Figma placeholders until profile photos exist.
private struct ParticipantStack: View {
    let count: Int

    private static let placeholders: [(image: String, background: Color)] = [
        ("ParticipantAvatar3", Color(red: 0xFF / 255, green: 0xBF / 255, blue: 0xB8 / 255)),
        ("ParticipantAvatar2", Color(red: 0xFF / 255, green: 0xE5 / 255, blue: 0xB8 / 255)),
        ("ParticipantAvatar1", Color(red: 0xED / 255, green: 0xBB / 255, blue: 0xD6 / 255))
    ]

    var body: some View {
        let shown = min(count, Self.placeholders.count)
        if shown > 0 {
            HStack(spacing: 4) {
                HStack(spacing: -13) {
                    ForEach(0 ..< shown, id: \.self) { index in
                        let avatar = Self.placeholders[index]
                        Image(avatar.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 30, height: 30)
                            .background(avatar.background)
                            .clipShape(.circle)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .zIndex(Double(shown - index))
                    }
                }
                if count > shown {
                    Text("+\(count - shown)")
                        .font(SideQuestDesign.ptSans(20))
                        .tracking(-0.6)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(count == 1 ? "1 explorer on this quest" : "\(count) explorers on this quest")
        }
    }
}

/// Subtle press feedback for image-only buttons.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}
