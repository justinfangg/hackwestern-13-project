import SwiftUI
import FogLocation

/// On-screen joystick for Simulator Mode (PRD D-2). Drag the knob; release to stop.
/// Deliberately plain: it's a demo tool, overlaid on the map only when the simulator is on.
public struct JoystickView: View {
    private let simulator: SimulatedLocationProvider
    private let radius: CGFloat
    @State private var knob: CGSize = .zero

    public init(simulator: SimulatedLocationProvider, radius: CGFloat = 60) {
        self.simulator = simulator
        self.radius = radius
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.25))
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 2))
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: radius * 0.8, height: radius * 0.8)
                .offset(knob)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var v = value.translation
                    let length = (v.width * v.width + v.height * v.height).squareRoot()
                    if length > radius { v = CGSize(width: v.width / length * radius, height: v.height / length * radius) }
                    knob = v
                    // Screen y grows downward; north is up.
                    simulator.setJoystick(x: Double(v.width / radius), y: Double(-v.height / radius))
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.2)) { knob = .zero }
                    simulator.setJoystick(x: 0, y: 0)
                }
        )
        .accessibilityLabel("Simulator joystick")
    }
}
