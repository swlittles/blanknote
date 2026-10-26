import Foundation
import InkwellCore
#if os(macOS)
import AppKit
#endif

/// Launch arguments for screenshots and manual testing:
///
/// - `-demo`: use a fresh folder of sample notes instead of your real ones
/// - `-open "<title>"`: open the note with this title
/// - `-sidebar all|trash|folder:<path>|tag:<tag>`
/// - `-search "<text>"`
/// - `-theme system|light|dark`: the theme to start with; Settings can still change it
enum LaunchOptions {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isDemo: Bool { arguments.contains("-demo") }

    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Saves the `-theme` argument as the theme setting, as if it had been picked in Settings.
    static func applyTheme() {
        guard let value = value(after: "-theme"), let theme = Appearance(rawValue: value) else { return }
        UserDefaults.standard.set(theme.rawValue, forKey: Appearance.storageKey)
    }

    #if DEBUG && os(macOS)
    /// `-themeSelfTest <file>`: sets the theme setting to dark, light, then system (the way the
    /// Settings picker does) and writes what the window actually shows after each to `<file>`.
    @MainActor
    static func runThemeSelfTest() {
        guard let path = value(after: "-themeSelfTest") else { return }
        Task { @MainActor in
            var lines: [String] = []
            try? await Task.sleep(for: .seconds(1))
            for theme in [Appearance.dark, .light, .system] {
                UserDefaults.standard.set(theme.rawValue, forKey: Appearance.storageKey)
                try? await Task.sleep(for: .milliseconds(500))
                let shown = NSApp.windows.filter(\.isVisible).map { $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "?" }
                lines.append("\(theme.rawValue): \(shown.joined(separator: ","))")
            }
            lines.append("system is: \(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "?")")
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    #endif

    static var openTitle: String? { value(after: "-open") }
    static var search: String? { value(after: "-search") }

    static var sidebar: SidebarItem? {
        guard let value = value(after: "-sidebar") else { return nil }
        if value == "all" { return .all }
        if value == "trash" { return .trash }
        if value.hasPrefix("folder:") { return .folder(String(value.dropFirst(7))) }
        if value.hasPrefix("tag:") { return .tag(String(value.dropFirst(4))) }
        return nil
    }

    static var storeOptions: NoteStore.Options {
        guard isDemo else { return NoteStore.Options(welcomeNote: SampleNotes.welcome) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let root = caches.appendingPathComponent("Demo Notes", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        SampleNotes.write(to: root)
        return NoteStore.Options(root: root, indexURL: caches.appendingPathComponent("Demo Index/notes.sqlite"), useICloud: false)
    }
}
