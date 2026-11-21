import Foundation
import FogCore

/// Saves a sticker PNG somewhere and returns its URL.
/// The server uploads stickers to Supabase Storage itself (docs/api.md D3), so the app only keeps a
/// local copy for instant display in the sticker book.
public protocol StickerUploading: Sendable {
    func upload(png: Data, questID: UUID) async throws -> URL
}

/// Local sticker cache in Application Support/FogOfWar/stickers.
public final class LocalStickerStorage: StickerUploading {
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FogOfWar/stickers", isDirectory: true)
    }

    public func upload(png: Data, questID: UUID) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(questID.uuidString.lowercased()).png")
        try png.write(to: url, options: .atomic)
        return url
    }
}
