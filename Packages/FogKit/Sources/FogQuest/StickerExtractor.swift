import Foundation
import CoreGraphics
import CoreImage
import Vision

/// Turns a quest photo into a sticker with a transparent background (PRD Q-8).
public protocol StickerExtracting: Sendable {
    func extractSticker(from image: CGImage) async -> CGImage
}

/// On-device subject lifting with Vision (`VNGenerateForegroundInstanceMaskRequest`, iOS 17+).
/// Picks the object at the centre of the photo (where the user aimed); falls back to a
/// circular crop if Vision finds nothing. Note: Vision masks need the Neural Engine, so in the
/// iOS Simulator this always uses the fallback. Test on a real phone.
public struct VisionStickerExtractor: StickerExtracting {
    public init() {}

    public func extractSticker(from image: CGImage) async -> CGImage {
        await Task.detached(priority: .userInitiated) {
            (try? Self.liftSubject(image)) ?? Self.circularCrop(image)
        }.value
    }

    static func liftSubject(_ image: CGImage) throws -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }

        var instances = observation.allInstances
        if let centre = centreInstance(of: observation), centre != 0 { instances = IndexSet(integer: centre) }

        let buffer = try observation.generateMaskedImage(ofInstances: instances, from: handler,
                                                         croppedToInstancesExtent: true)
        let ci = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    /// Label of the instance under the centre pixel of the mask (0 = background).
    static func centreInstance(of observation: VNInstanceMaskObservation) -> Int? {
        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        let pixel = base.advanced(by: (h / 2) * row + (w / 2)).assumingMemoryBound(to: UInt8.self)
        return Int(pixel.pointee)
    }

    /// Fallback sticker: centre of the photo clipped to a circle.
    public static func circularCrop(_ image: CGImage, fraction: Double = 0.8) -> CGImage {
        let side = Int(Double(min(image.width, image.height)) * fraction)
        let originX = (image.width - side) / 2, originY = (image.height - side) / 2
        guard side > 0,
              let square = image.cropping(to: CGRect(x: originX, y: originY, width: side, height: side)),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.draw(square, in: rect)
        return ctx.makeImage() ?? image
    }
}
