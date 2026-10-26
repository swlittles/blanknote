import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings changed from menu commands. Views read the same keys with `@AppStorage`, so they
/// update along with these.
@MainActor
enum AppSettings {
    static let fontSizeKey = "editorFontSize"
    static let fontSizes: ClosedRange<Double> = 12...26

    static var fontSize: Double {
        UserDefaults.standard.object(forKey: fontSizeKey) as? Double ?? EditorDefaults.fontSize
    }

    /// Steps the editor's text size by `delta` points, or back to the default when `nil`.
    /// Returns the new size.
    @discardableResult
    static func changeFontSize(by delta: Double?) -> Double {
        let size = delta.map { min(max(fontSize + $0, fontSizes.lowerBound), fontSizes.upperBound) } ?? EditorDefaults.fontSize
        UserDefaults.standard.set(size, forKey: fontSizeKey)
        return size
    }

    static var theme: Appearance {
        UserDefaults.standard.string(forKey: Appearance.storageKey).flatMap(Appearance.init(rawValue:)) ?? Appearance.defaultValue
    }

    /// Switches to the opposite of what's on screen (when following the system, the opposite of
    /// the system's current look). Returns the new theme.
    @discardableResult
    static func toggleTheme() -> Appearance {
        let showingDark: Bool
        switch theme {
        case .dark: showingDark = true
        case .light: showingDark = false
        case .system:
            #if os(macOS)
            showingDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            #else
            showingDark = UITraitCollection.current.userInterfaceStyle == .dark
            #endif
        }
        let next: Appearance = showingDark ? .light : .dark
        UserDefaults.standard.set(next.rawValue, forKey: Appearance.storageKey)
        return next
    }
}
