import Foundation
import AVFoundation
import CoreGraphics

/// In-app camera for quest photos (PRD Q-6: no photo-library uploads).
///
/// Info.plist: `NSCameraUsageDescription`.
/// Show the live feed with `CameraPreview(session: controller.session)` (iOS), then call
/// `try await controller.capturePhoto()` and pass the result to `QuestCaptureModel.capture(_:)`.
public final class CameraController: NSObject, @unchecked Sendable {
    public enum CameraError: Error { case denied, unavailable, captureFailed }

    public let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "fogkit.camera")
    private var configured = false
    private var pending: CheckedContinuation<CGImage, Error>?

    public override init() { super.init() }

    /// Asks for permission if needed, configures the back camera and starts the feed.
    public func start() async throws {
        guard await Self.requestAccess() else { throw CameraError.denied }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    c.resume()
                } catch { c.resume(throwing: error) }
            }
        }
    }

    public func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// Takes a photo and returns it upright.
    public func capturePhoto() async throws -> CGImage {
        try await withCheckedThrowingContinuation { c in
            queue.async {
                guard self.pending == nil, self.session.isRunning else {
                    c.resume(throwing: CameraError.unavailable)
                    return
                }
                self.pending = c
                let settings = AVCapturePhotoSettings()
                #if os(iOS)
                if let connection = self.output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90 // portrait
                }
                #endif
                self.output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output) else { throw CameraError.unavailable }
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        configured = true
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                            error: Error?) {
        queue.async {
            let c = self.pending
            self.pending = nil
            if let data = photo.fileDataRepresentation(), error == nil,
               let image = ImageEncoding.uprightImage(from: data) {
                c?.resume(returning: image)
            } else {
                c?.resume(throwing: error ?? CameraError.captureFailed)
            }
        }
    }
}

#if os(iOS)
import SwiftUI
import UIKit

/// Plain live camera feed. Jonathan styles everything around it.
public struct CameraPreview: UIViewRepresentable {
    public let session: AVCaptureSession
    public init(session: AVCaptureSession) { self.session = session }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) {}

    public final class PreviewView: UIView {
        public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
#endif
