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

    // Profile page (Figma 42:2159).
    static let cityCard = Color(red: 0x43 / 255, green: 0x7B / 255, blue: 0x3F / 255)
    static let travelCard = Color(red: 0x27 / 255, green: 0x57 / 255, blue: 0x6B / 255)
    static let boardBorder = Color(red: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE6 / 255)
    static let boardDot = Color(red: 0xE8 / 255, green: 0xE8 / 255, blue: 0xE8 / 255)
    static let boardLabelText = Color(red: 0x46 / 255, green: 0x46 / 255, blue: 0x46 / 255)

    // Tab bar + map chrome (Figma 55:3722).
    /// Selected tab icon, the Explore button and the locate pin.
    static let accentGreen = Color(red: 0x43 / 255, green: 0x7B / 255, blue: 0x3F / 255)
    /// Unselected tab icons (Figma "Control Icon" stroke, trophy fill).
    static let tabInactive = Color(red: 0x9E / 255, green: 0xA1 / 255, blue: 0x9E / 255)
    /// Fill of the social tab's stacked cards.
    static let tabIconFill = Color(red: 0xEF / 255, green: 0xEF / 255, blue: 0xEF / 255)

    /// Corner radius of the device's display, so full-screen pages can be
    /// rounded to match the hardware (55 pt on current iPhones). UIKit only
    /// exposes it through a private key; falls back to 55 if that ever fails.
    @MainActor
    static var screenCornerRadius: CGFloat {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
        if let radius = screen?.value(forKey: "_displayCornerRadius") as? CGFloat, radius > 0 {
            return radius
        }
        return 55
    }

    /// PT Sans (bundled in Fonts/); scales with Dynamic Type relative to `.title3`.
    static func ptSans(_ size: CGFloat, relativeTo style: Font.TextStyle = .title3) -> Font {
        .custom("PTSans-Regular", size: size, relativeTo: style)
    }

    /// Fixed-size PT Sans for text inside fixed-size chrome (cards, pills).
    static func ptSans(fixed size: CGFloat) -> Font {
        .custom("PTSans-Regular", fixedSize: size)
    }

    /// Figma's display face, Cal Sans (bundled in Fonts/). Falls back to a bold
    /// system face if the font ever fails to load.
    static func calSans(_ size: CGFloat, relativeTo style: Font.TextStyle? = .title2) -> Font {
        let name = "CalSans-Regular"
        guard UIFont(name: name, size: size) != nil else {
            return .system(size: size, weight: .bold)
        }
        if let style { return .custom(name, size: size, relativeTo: style) }
        return .custom(name, fixedSize: size)
    }
}
