import Foundation
import FogKit

/// A stable, type-safe H3 cell identifier.
///
/// H3 indexes are unsigned 64-bit integers. They are encoded as canonical,
/// lowercase hexadecimal strings at persistence and synchronization boundaries.
///
/// Marked `nonisolated` so the type stays usable from MapKit's off-main
/// overlay draw calls under the app's default MainActor isolation.
nonisolated public struct H3CellID: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt64) {
        self.init(rawValue: rawValue)
    }

    public init?(_ hexString: String) {
        self.init(hexString: hexString)
    }

    public init?(hexString: String) {
        var candidate = hexString.trimmingCharacters(in: .whitespacesAndNewlines)

        if candidate.hasPrefix("0x") || candidate.hasPrefix("0X") {
            candidate.removeFirst(2)
        }

        guard
            !candidate.isEmpty,
            candidate.count <= 16,
            candidate.allSatisfy(\Character.isHexDigit),
            let value = UInt64(candidate, radix: 16)
        else {
            return nil
        }

        self.init(rawValue: value)
    }

    /// The canonical form used by SwiftData and backend synchronization.
    public var hexString: String {
        String(rawValue, radix: 16, uppercase: false)
    }

    public static func < (lhs: H3CellID, rhs: H3CellID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension H3CellID: Identifiable {
    public var id: UInt64 { rawValue }
}

extension H3CellID: CustomStringConvertible {
    public var description: String { hexString }
}

extension H3CellID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encodedID = try container.decode(String.self)

        guard let cellID = H3CellID(hexString: encodedID) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an H3 index encoded as a hexadecimal string."
            )
        }

        self = cellID
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

extension H3CellID {
    init(_ tileID: TileID) {
        self.init(rawValue: tileID.rawValue)
    }

    var tileID: TileID {
        TileID(rawValue)
    }
}
