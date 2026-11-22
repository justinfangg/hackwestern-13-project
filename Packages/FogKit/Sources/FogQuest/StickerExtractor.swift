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

/// The photo's subject lifted out but left where it sits in the frame, so the
/// app can peel it off the photo in place (the quest result animation).
public struct SubjectCutout: @unchecked Sendable {
    /// Same size as the photo it came from: the subject's pixels, transparent elsewhere.
    public let image: CGImage
    /// The subject's bounding box in `image`, as fractions of its size (origin top-left).
    public let bounds: CGRect

    public init(image: CGImage, bounds: CGRect) {
        self.image = image
        self.bounds = bounds
    }
}

extension VisionStickerExtractor {
    /// Lifts the subject out of `image` without cropping. A photo that is already
    /// transparent around its subject (a pre-cut sticker) is used as is; when Vision
    /// finds nothing (always in the Simulator) the centre circle stands in.
    public static func cutoutInPlace(from image: CGImage) async -> SubjectCutout {
        await Task.detached(priority: .userInitiated) {
            if hasTransparentBackground(image), let bounds = opaqueBounds(of: image) {
                return SubjectCutout(image: image, bounds: bounds)
            }
            if let lifted = try? liftSubjectInPlace(image), let bounds = opaqueBounds(of: lifted) {
                return SubjectCutout(image: lifted, bounds: bounds)
            }
            return circleInPlace(image)
        }.value
    }

    static func liftSubjectInPlace(_ image: CGImage) throws -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }

        var instances = observation.allInstances
        if let centre = centreInstance(of: observation), centre != 0 { instances = IndexSet(integer: centre) }

        let buffer = try observation.generateMaskedImage(ofInstances: instances, from: handler,
                                                         croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    /// True when the image's corners are see-through (it's already a cut-out).
    public static func hasTransparentBackground(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        guard let alpha = alphaGrid(of: image, side: 32) else { return false }
        let n = alpha.side
        let corners = [alpha.values[0], alpha.values[n - 1], alpha.values[(n - 1) * n], alpha.values[n * n - 1]]
        return corners.allSatisfy { $0 < 16 }
    }

    /// Bounding box of the pixels that are clearly visible, as fractions (origin top-left).
    public static func opaqueBounds(of image: CGImage, threshold: UInt8 = 40) -> CGRect? {
        guard let alpha = alphaGrid(of: image, side: 128) else { return nil }
        let n = alpha.side
        var minX = n, minY = n, maxX = -1, maxY = -1
        for y in 0 ..< n {
            for x in 0 ..< n where alpha.values[y * n + x] > threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let unit = 1 / Double(n)
        return CGRect(x: Double(minX) * unit, y: Double(minY) * unit,
                      width: Double(maxX - minX + 1) * unit, height: Double(maxY - minY + 1) * unit)
    }

    /// The image's alpha resampled onto a `side` × `side` grid, rows top to bottom.
    private static func alphaGrid(of image: CGImage, side: Int) -> (values: [UInt8], side: Int)? {
        var values = [UInt8](repeating: 0, count: side * side)
        let drawn = values.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        // Bitmap contexts store rows top to bottom in memory, so row 0 is the image's top.
        return drawn ? (values, side) : nil
    }

    /// Fallback: the centre circle of the photo, left in place.
    static func circleInPlace(_ image: CGImage, fraction: Double = 0.7) -> SubjectCutout {
        let w = image.width, h = image.height
        let side = Double(min(w, h)) * fraction
        let rect = CGRect(x: (Double(w) - side) / 2, y: (Double(h) - side) / 2, width: side, height: side)
        let bounds = CGRect(x: rect.minX / Double(w), y: rect.minY / Double(h),
                            width: side / Double(w), height: side / Double(h))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return SubjectCutout(image: image, bounds: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return SubjectCutout(image: ctx.makeImage() ?? image, bounds: bounds)
    }
}
