#if DEBUG
import CoreLocation
import SwiftUI

/// Temporary Ayman-owned harness. It deliberately avoids Justin's simulator/location pipeline.
struct MapDebugHUD: View {
    let discoveredCount: Int
    let lastTappedCoordinate: CLLocationCoordinate2D
    let onAreaReveal: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hexagon.fill")
                    .foregroundStyle(Color(red: 0.29, green: 0.94, blue: 0.85))
                Text("\(discoveredCount) discovered")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
            }

            Label("Tap map · reveal 30 m", systemImage: "hand.tap.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))

            Text(coordinateLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.45))

            HStack(spacing: 8) {
                Button(action: onAreaReveal) {
                    Label("Area reveal", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(DebugMapButtonStyle(tint: Color(red: 0.16, green: 0.74, blue: 0.70)))
                .accessibilityHint("Debug only: reveals a 150 meter radius around the last tapped point")

                Button(role: .destructive, action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(DebugMapButtonStyle(tint: Color(red: 0.70, green: 0.22, blue: 0.28)))
                .accessibilityLabel("Reset exploration")
            }
        }
        .foregroundStyle(.white)
        .padding(13)
        .background(Color(red: 0.025, green: 0.045, blue: 0.085).opacity(0.91), in: RoundedRectangle(cornerRadius: 17))
        .overlay {
            RoundedRectangle(cornerRadius: 17)
                .stroke(Color(red: 0.28, green: 0.90, blue: 0.82).opacity(0.24), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.34), radius: 14, y: 6)
    }

    private var coordinateLabel: String {
        String(
            format: "%.5f, %.5f",
            lastTappedCoordinate.latitude,
            lastTappedCoordinate.longitude
        )
    }
}

private struct DebugMapButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(tint.opacity(configuration.isPressed ? 0.48 : 0.30), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(tint.opacity(0.72), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif
