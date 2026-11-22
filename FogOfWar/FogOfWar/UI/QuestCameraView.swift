import SwiftUI
import UIKit
import FogKit

/// Camera face of the active-quest card (Figma node 16:390): live feed filling
/// the card, the quest category pill, a close button and the shutter.
struct QuestCameraView: View {
    let label: String
    let camera: CameraController
    let onClose: () -> Void
    let onPhoto: (CGImage) -> Void
    /// Debug bypass: when set, the shutter works regardless of camera state and submits this image.
    var debugPhoto: (() -> CGImage?)? = nil
    /// Demo mode: the viewfinder shows this photo instead of the camera, and the shutter captures it.
    var demoPhoto: CGImage? = nil

    @State private var status: Status = .starting
    @State private var isCapturing = false
    @State private var shutterCount = 0
    @State private var flash = false

    private enum Status { case starting, live, denied, unavailable }

    var body: some View {
        ZStack {
            feed
            // Figma's faint top/bottom washes over the photo.
            VStack(spacing: 0) {
                LinearGradient(colors: [Color(white: 217 / 255, opacity: 0.06), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 134)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, Color(white: 217 / 255, opacity: 0.06)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 134)
            }
            .allowsHitTesting(false)

            Color.white
                .opacity(flash ? 0.8 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) { categoryPill }
        .overlay(alignment: .topTrailing) { closeButton }
        .overlay(alignment: .bottom) { shutter }
        .sensoryFeedback(.impact(weight: .medium), trigger: shutterCount)
        .task { if demoPhoto == nil { await startCamera() } }
        .onDisappear { camera.stop() }
    }

    // MARK: Feed

    @ViewBuilder
    private var feed: some View {
        if let demoPhoto {
            // Demo mode: a still "viewfinder" of the sample photo.
            GeometryReader { proxy in
                Image(decorative: demoPhoto, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .accessibilityLabel("Camera viewfinder (demo photo)")
        } else {
            liveFeed
        }
    }

    @ViewBuilder
    private var liveFeed: some View {
        switch status {
        case .live:
            CameraPreview(session: camera.session)
                .accessibilityLabel("Camera viewfinder")
        case .starting:
            SideQuestDesign.canvas
        case .denied:
            message(
                "Camera access is off",
                detail: "Allow camera access to photograph quest targets.",
                action: ("Open Settings", openSettings)
            )
        case .unavailable:
            #if targetEnvironment(simulator)
            message("No camera in the Simulator", detail: "The shutter submits a test photo.", action: nil)
            #else
            message("Camera unavailable", detail: "Try closing and reopening the camera.", action: nil)
            #endif
        }
    }

    private func message(_ title: String, detail: String, action: (String, () -> Void)?) -> some View {
        ZStack {
            SideQuestDesign.canvas
            VStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let action {
                    Button(action.0, action: action.1)
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 40)
        }
    }

    // MARK: Chrome

    /// White pill with the quest category (Figma: 87 × 46, PT Sans 22).
    private var categoryPill: some View {
        Text(label)
            .font(SideQuestDesign.ptSans(22))
            .tracking(-0.66)
            .foregroundStyle(Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255))
            .lineLimit(1)
            .padding(.horizontal, 25)
            .frame(minWidth: 87, minHeight: 46)
            .background(.white, in: .capsule)
            .padding(.leading, 26)
            .padding(.top, 20)
            .accessibilityLabel("Quest: \(label)")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image("CameraClose")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close camera")
        // Puts the 17.7 pt glyph where Figma has it (35 pt down, 34 pt in).
        .padding(.top, 22)
        .padding(.trailing, 21)
    }

    /// 63 pt white disc inside a 73 pt ring, 33 pt above the card's bottom.
    private var shutter: some View {
        Button(action: takePhoto) {
            ZStack {
                Circle()
                    .strokeBorder(Color(red: 1, green: 0xFC / 255, blue: 0xFC / 255), lineWidth: 3)
                    .frame(width: 73, height: 73)
                Circle()
                    .fill(.white)
                    .frame(width: 63, height: 63)
                    .scaleEffect(isCapturing ? 0.86 : 1)
            }
            .contentShape(Circle())
        }
        .buttonStyle(ShutterButtonStyle())
        .disabled(isCapturing || (debugPhoto == nil && demoPhoto == nil && (status == .starting || status == .denied)))
        .accessibilityLabel("Take photo")
        .padding(.bottom, 33)
    }

    // MARK: Actions

    private func startCamera() async {
        do {
            try await camera.start()
            withAnimation(.easeOut(duration: 0.25)) { status = .live }
        } catch CameraController.CameraError.denied {
            status = .denied
        } catch {
            status = .unavailable
        }
    }

    private func takePhoto() {
        shutterCount += 1
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        withAnimation(.easeIn(duration: 0.3).delay(0.08)) { flash = false }

        if let image = debugPhoto?() {
            onPhoto(image)
            return
        }

        if let demoPhoto {
            onPhoto(demoPhoto)
            return
        }

        if status != .live {
            #if targetEnvironment(simulator)
            // No camera in the Simulator: submit a generated test image.
            onPhoto(DevHarnessView.testImage())
            #endif
            return
        }

        isCapturing = true
        Task {
            defer { isCapturing = false }
            if let photo = try? await camera.capturePhoto() {
                onPhoto(photo)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.35), value: configuration.isPressed)
    }
}
