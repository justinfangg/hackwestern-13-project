import Foundation
import FogKit

/// Sticker artwork on disk for the memory board. A sticker collected on this device already has
/// its PNG (`localImageURL`); one only the server knows about (another install, or a find made
/// before an update) is downloaded once from `imageURL` into Caches and reused after that.
@MainActor
enum StickerImageCache {
    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StickerImages", isDirectory: true)
    }

    private static func cachedFile(for sticker: Sticker) -> URL {
        directory.appendingPathComponent("\(sticker.id.uuidString.lowercased()).png")
    }

    /// The artwork file if it's on disk now, without downloading.
    static func file(for sticker: Sticker) -> URL? {
        if let local = sticker.localImageURL, FileManager.default.fileExists(atPath: local.path) { return local }
        let cached = cachedFile(for: sticker)
        return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
    }

    /// Downloads every sticker that has no artwork on disk yet. Returns true if any arrived.
    static func download(missingFrom stickers: [Sticker]) async -> Bool {
        let missing = stickers.filter { file(for: $0) == nil && $0.imageURL != nil }
        guard !missing.isEmpty else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var arrived = false
        for sticker in missing {
            guard let remote = sticker.imageURL,
                  let (data, response) = try? await URLSession.shared.data(from: remote),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 300,
                  !data.isEmpty,
                  (try? data.write(to: cachedFile(for: sticker), options: .atomic)) != nil else { continue }
            arrived = true
        }
        return arrived
    }
}
