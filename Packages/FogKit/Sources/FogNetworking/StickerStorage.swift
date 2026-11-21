import Foundation
import FogCore

/// Uploads a sticker PNG and returns its public URL (PRD Q-8).
public protocol StickerUploading: Sendable {
    func upload(png: Data, questID: UUID) async throws -> URL
}

/// Supabase Storage via its REST API (no SDK needed in FogKit).
/// Bucket setup (Vishaal): public bucket named `stickers`; storage policy allowing an
/// authenticated user to insert/update objects under the folder named after their user id.
public final class SupabaseStickerStorage: StickerUploading {
    private let config: BackendConfig
    private let auth: AuthTokenProviding
    private let session: URLSession

    public init(config: BackendConfig, auth: AuthTokenProviding, session: URLSession = .shared) {
        self.config = config
        self.auth = auth
        self.session = session
    }

    public func upload(png: Data, questID: UUID) async throws -> URL {
        guard let userID = await auth.currentUserID else { throw APIError.notSignedIn }
        let path = "\(userID.uuidString.lowercased())/\(questID.uuidString.lowercased()).png"
        let base = config.projectURL.appendingPathComponent("storage/v1/object")

        var request = URLRequest(url: base.appendingPathComponent("\(config.stickerBucket)/\(path)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")

        let (data, response) = try await session.upload(for: request, from: png)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return base.appendingPathComponent("public/\(config.stickerBucket)/\(path)")
    }
}

/// Keeps stickers local only; used with `MockFogAPI` and in tests.
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
