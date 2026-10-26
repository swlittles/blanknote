import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

/// Claude Code's colours: the coral accent on warm off-white (light) or warm charcoal (dark).
/// Every colour is dynamic, so text already in the editor follows light/dark changes.
enum Palette {
    static let accent = PlatformColor.dynamic(light: 0xD97757, dark: 0xD97757)
    /// The accent where it colours text (links, tags, code), deepened in light mode for contrast.
    static let accentText = PlatformColor.dynamic(light: 0xB9552F, dark: 0xE89276)
    static let background = PlatformColor.dynamic(light: 0xFAF9F5, dark: 0x262624)
    static let sidebar = PlatformColor.dynamic(light: 0xF0EEE6, dark: 0x1F1E1D)
    static let text = PlatformColor.dynamic(light: 0x141413, dark: 0xF0EEE6)
    static let secondaryText = PlatformColor.dynamic(light: 0x5E5D59, dark: 0xB4B1A7)
    /// Markdown syntax characters and comments.
    static let tertiaryText = PlatformColor.dynamic(light: 0xA8A69E, dark: 0x76746D)
    /// List rows on iPhone and iPad, a step lighter (or darker) than the background.
    static let card = PlatformColor.dynamic(light: 0xFFFFFF, dark: 0x2E2E2B)
    static let selectedRow = PlatformColor.dynamic(light: 0xF6DED4, dark: 0x4A3329)
    static let codeBackground = PlatformColor.dynamic(light: 0xF0EEE6, dark: 0x30302E)
    static let green = PlatformColor.dynamic(light: 0x5F7743, dark: 0xA3B784)
    static let blue = PlatformColor.dynamic(light: 0x3F6F9E, dark: 0x8DB4DC)
    static let tagBackground = PlatformColor.dynamic(light: 0xD97757, dark: 0xD97757, alpha: 0.14)
    static let selection = PlatformColor.dynamic(light: 0xD97757, dark: 0xD97757, alpha: 0.28)

    static var accentColor: Color { Color(accent) }
    static var backgroundColor: Color { Color(background) }
    static var sidebarColor: Color { Color(sidebar) }
}

extension Color {
    init(_ color: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}

extension PlatformColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        #if os(macOS)
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
        #else
        self.init(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }

    static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> PlatformColor {
        #if os(macOS)
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark, alpha: alpha) : NSColor(hex: light, alpha: alpha)
        }
        #else
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: alpha) : UIColor(hex: light, alpha: alpha)
        }
        #endif
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
