import Foundation
import SwiftData

/// Sparse on-device persistence for one explored H3 cell.
@Model
public final class ExploredCellRecord {
    /// Canonical lowercase hexadecimal H3 identifier.
    @Attribute(.unique)
    public var cellHex: String

    public var firstClearedAt: Date

    public init(cellID: H3CellID, firstClearedAt: Date = .now) {
        self.cellHex = cellID.hexString
        self.firstClearedAt = firstClearedAt
    }

    public var cellID: H3CellID? {
        H3CellID(hexString: cellHex)
    }
}
