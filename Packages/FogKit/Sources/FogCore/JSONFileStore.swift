import Foundation

/// Tiny Codable-to-disk helper for offline state (pending sync, expedition history).
/// Files live in Application Support/FogOfWar/.
public struct JSONFileStore<Value: Codable>: Sendable {
    public let url: URL

    public init(filename: String, directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FogOfWar", isDirectory: true)
        url = base.appendingPathComponent(filename)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONCoding.encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            print("[FogKit] Failed to save \(url.lastPathComponent): \(error)")
        }
    }

    public func delete() { try? FileManager.default.removeItem(at: url) }
}

/// Shared JSON settings: snake_case keys and ISO-8601 dates, matching the Edge Functions.
public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }
}
