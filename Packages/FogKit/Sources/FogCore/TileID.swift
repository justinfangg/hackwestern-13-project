import Foundation

/// Identifier of one map tile (an H3 cell index at resolution 11, or a packed square-grid
/// cell if we fall back from H3). Owned by the exploration layer (Ayman); defined here so
/// sync and expeditions can carry tile IDs without depending on the H3 package.
///
/// Encoded in JSON as a lowercase hex string (H3's canonical string form, e.g. "8b2ab2d9a54afff").
/// Never send it as a JSON number: H3 indexes exceed 2^53 and lose precision in JavaScript.
public struct TileID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) { self.rawValue = rawValue }

    public init?(hex: String) {
        guard let v = UInt64(hex, radix: 16) else { return nil }
        rawValue = v
    }

    public var hex: String { String(rawValue, radix: 16) }
    public var description: String { hex }

    public static func < (a: TileID, b: TileID) -> Bool { a.rawValue < b.rawValue }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = TileID(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tile hex \(s)"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}
