import SwiftUI
import FogKit

/// Dark card shown while a quest is in progress (Figma node 16:383): elapsed
/// time, quest name, distance left, who else is on it, and the abandon /
/// capture buttons.
struct ActiveQuestCard: View {
    let quest: Quest
    let startedAt: Date
    let captureState: QuestCaptureModel.State
    let distanceToTarget: Double?
    let onAbandon: () -> Void
    let onCapture: () -> Void

    @State private var confirmAbandon = false

    static let height: CGFloat = 168

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                // Live, self-updating elapsed time since the quest was accepted.
                Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
                    // Figma uses Cal Sans 65; it isn't bundled, so a bold system face stands in.
                    .font(.system(size: 65, weight: .bold))
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
                ParticipantStack(count: quest.foundTodayCount)
                    .padding(.top, 22)
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
        .frame(height: Self.height)
        .background(SideQuestDesign.canvas, in: RoundedRectangle(cornerRadius: 53, style: .continuous))
        .animation(.snappy, value: canCapture)
        .confirmationDialog("Abandon this quest?", isPresented: $confirmAbandon, titleVisibility: .visible) {
            Button("Abandon Quest", role: .destructive, action: onAbandon)
        } message: {
            Text("Your route so far is still saved.")
        }
    }

    /// In range, or retrying after a failed photo.
    private var canCapture: Bool {
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
