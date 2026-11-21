import SwiftUI

/// Values taken from the "sidequest" Figma frame (node 16:1122).
enum SideQuestDesign {
    static let canvas = Color(red: 0x15 / 255, green: 0x15 / 255, blue: 0x15 / 255)
    static let profileSurface = Color(red: 0xF9 / 255, green: 0xF9 / 255, blue: 0xF9 / 255)
    static let splitHandle = Color(red: 0x41 / 255, green: 0x41 / 255, blue: 0x41 / 255)
    static let sheetGrabber = Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF4 / 255)
    static let primaryText = Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0A / 255)
    static let pillText = Color(red: 0xF9 / 255, green: 0xF9 / 255, blue: 0xF9 / 255)
    static let questActive = Color(red: 0xFF / 255, green: 0xBD / 255, blue: 0x3A / 255)
    static let questCompleted = Color(red: 0x7B / 255, green: 0xCC / 255, blue: 0x49 / 255)
    static let mapBottomFade = Color(red: 0xEB / 255, green: 0xEB / 255, blue: 0xEB / 255)

    /// Map container corner radius and the gap that holds the drag handle.
    static let containerCornerRadius: CGFloat = 58
    static let splitGap: CGFloat = 21

    /// PT Sans ships with iOS; scales with Dynamic Type relative to `.title3`.
    static func ptSans(_ size: CGFloat, relativeTo style: Font.TextStyle = .title3) -> Font {
        .custom("PTSans-Regular", size: size, relativeTo: style)
    }
}
