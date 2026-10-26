import BlankNoteCore
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

/// The app's colours. Surfaces and the accent come from the active profile's theme (Claude Code's
/// coral on warm neutrals by default); text colours are the same in every profile. Every colour is
/// dynamic, resolving for light or dark mode, and for the current theme, when it's drawn.
enum Palette {
    static let accent = themed(\.accent)
    /// The accent where it colours text (links, tags, code), with enough contrast to read.
    static let accentText = themed(\.accentText)
    static let background = themed(\.background)
    static let sidebar = themed(\.sidebar)
    /// List rows on iPhone and iPad, a step lighter (or darker) than the background.
    static let card = themed(\.card)
    /// iOS draws a selected row's text white, so this is a solid, dark-enough accent.
    static let selectedRow = themed(\.selectedRow)
    static let codeBackground = themed(\.codeBackground)
    static let tagBackground = themed(\.accent, alpha: 0.14)
    static let selection = themed(\.accent, alpha: 0.28)

    static let text = PlatformColor.dynamic(light: 0x141413, dark: 0xF0EEE6)
    static let secondaryText = PlatformColor.dynamic(light: 0x5E5D59, dark: 0xB4B1A7)
    /// Markdown syntax characters and comments.
    static let tertiaryText = PlatformColor.dynamic(light: 0xA8A69E, dark: 0x76746D)
    static let green = PlatformColor.dynamic(light: 0x5F7743, dark: 0xA3B784)
    static let blue = PlatformColor.dynamic(light: 0x3F6F9E, dark: 0x8DB4DC)
    static let danger = PlatformColor.dynamic(light: 0xC2413A, dark: 0xE5695F)

    static var accentColor: Color { Color(accent) }
    static var backgroundColor: Color { Color(background) }
    static var sidebarColor: Color { Color(sidebar) }

    private static func themed(_ role: KeyPath<ThemeColors, ThemeColors.Pair>, alpha: CGFloat = 1) -> PlatformColor {
        PlatformColor.dynamic { isDark in
            let pair = ThemeState.colors[keyPath: role]
            return PlatformColor(hex: isDark ? pair.dark : pair.light, alpha: alpha)
        }
    }
}

/// The active profile's theme. Changing it redraws every window in the new colours.
@MainActor @Observable
final class ThemeState {
    static let shared = ThemeState()

    /// Read by `Palette`'s colours when they're drawn, which can happen outside SwiftUI.
    nonisolated(unsafe) static private(set) var colors = ThemeColors(.claude)

    private(set) var theme = ProfileTheme.claude
    /// Bumped on every change. Views that draw with `Palette` depend on it so they redraw.
    private(set) var revision = 0

    func apply(_ theme: ProfileTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        Self.colors = ThemeColors(theme)
        revision += 1
    }
}

/// Applies the theme's tint to its content and redraws it when the theme changes, without
/// recreating it (so a sheet or settings page stays where it is).
struct ThemeTinted<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let _ = ThemeState.shared.revision
        content.tint(Palette.accentColor)
    }
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
        dynamic { isDark in PlatformColor(hex: isDark ? dark : light, alpha: alpha) }
    }

    /// A colour worked out each time it's drawn, from whether the appearance is dark.
    static func dynamic(_ provider: @escaping (_ isDark: Bool) -> PlatformColor) -> PlatformColor {
        #if os(macOS)
        NSColor(name: nil) { appearance in provider(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) }
        #else
        UIColor { traits in provider(traits.userInterfaceStyle == .dark) }
        #endif
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    /// The settings key. It must not match a launch flag (`-theme`): a launch argument with a
    /// setting's own name overrides that setting for the whole run, so the picker would do nothing.
    /// (Not "appearance" either: values saved under that old key shouldn't override the new default.)
    static let storageKey = "colorTheme"
    static let defaultValue = Appearance.dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Applies the theme to every window of the app, Settings included.
    ///
    /// Done through AppKit/UIKit rather than SwiftUI's `preferredColorScheme`, which on the Mac
    /// doesn't go back to following the system once it has been set to light or dark.
    @MainActor
    func apply() {
        #if os(macOS)
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        #else
        let style: UIUserInterfaceStyle = switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
        #endif
    }
}
