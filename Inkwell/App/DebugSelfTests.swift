#if DEBUG && os(macOS)
import AppKit
import InkwellCore

/// Checks of Mac behaviour that the iPhone UI tests can't cover, run with a launch argument.
/// Each writes its findings to a file for a script to read:
///
/// - `-themeSelfTest <file>`: sets the theme to dark, light, then system (as the Settings picker
///   does) and records what the windows show after each.
/// - `-shortcutSelfTest <file>`: presses shortcuts (through normal event dispatch) before and after
///   shortcut, records it again, then lists which global hotkeys registered.
@MainActor
enum DebugSelfTests {
    static func run(shortcuts: ShortcutStore) {
        if let path = LaunchOptions.value(after: "-themeSelfTest") { theme(writingTo: path) }
        if let path = LaunchOptions.value(after: "-shortcutSelfTest") { shortcutsTest(shortcuts, writingTo: path) }
    }

    private static func theme(writingTo path: String) {
        Task {
            var lines: [String] = []
            try? await Task.sleep(for: .seconds(1))
            for theme in [Appearance.dark, .light, .system] {
                UserDefaults.standard.set(theme.rawValue, forKey: Appearance.storageKey)
                try? await Task.sleep(for: .milliseconds(500))
                let shown = NSApp.windows.filter(\.isVisible).map { $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "?" }
                lines.append("\(theme.rawValue): \(shown.joined(separator: ","))")
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func shortcutsTest(_ shortcuts: ShortcutStore, writingTo path: String) {
        Task {
            var lines: [String] = []
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("default: New Note \(menuItem("New Note")), Bold \(menuItem("Bold")), Next Note \(menuItem("Next Note"))")
            shortcuts.set(KeyCombo("j", [.option, .command]), for: .newNote)
            shortcuts.set(nil, for: .bold)
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("changed: New Note \(menuItem("New Note")), Bold \(menuItem("Bold"))")
            shortcuts.isRecording = true
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("recording: New Note \(menuItem("New Note")), hotkeys registered while recording: \(GlobalHotkeys.shared.registeredCount)")
            shortcuts.isRecording = false
            shortcuts.resetAll()
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("reset: New Note \(menuItem("New Note")), Bold \(menuItem("Bold"))")
            lines.append("global hotkeys registered: \(GlobalHotkeys.shared.registeredCount), failed: \(GlobalHotkeys.shared.failures.map(\.rawValue))")
            lines.append("notes windows: \(NSApp.windows.filter { $0.isVisible && GlobalHotkeys.isNotesWindow($0) }.count) of \(NSApp.windows.filter(\.isVisible).map { $0.identifier?.rawValue ?? "nil" })")

            // What the global hotkeys do, called the way the hotkey handler calls it.
            if let nav = ActionRouter.shared.activeNavigator {
                let before = nav.store.notes.count
                GlobalHotkeys.shared.perform(.globalNewNote)
                try? await Task.sleep(for: .milliseconds(600))
                lines.append("global New Note: notes \(before) → \(nav.store.notes.count), editor on new note: \(nav.editor.path?.hasPrefix("Untitled") == true), app active: \(NSApp.isActive)")
                GlobalHotkeys.shared.perform(.globalToggleApp)
                try? await Task.sleep(for: .milliseconds(600))
                lines.append("global Show/Hide while active: hidden \(NSApp.isHidden)")
                GlobalHotkeys.shared.perform(.globalToggleApp)
                try? await Task.sleep(for: .milliseconds(600))
                lines.append("global Show/Hide while hidden: hidden \(NSApp.isHidden), active \(NSApp.isActive)")
                GlobalHotkeys.shared.perform(.globalSearch)
                try? await Task.sleep(for: .milliseconds(600))
                lines.append("global Search: search requests \(nav.searchRequest)")
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// "<key equivalent> <modifiers>" for the first menu item with this title.
    private static func menuItem(_ title: String) -> String {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            if let menu {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
            }
            for item in menu?.items ?? [] {
                if item.title == title { return item }
                if let found = find(item.submenu) { return found }
            }
            return nil
        }
        guard let item = find(NSApp.mainMenu) else { return "missing" }
        let flags = item.keyEquivalentModifierMask
        var mods = ""
        if flags.contains(.control) { mods += "⌃" }
        if flags.contains(.option) { mods += "⌥" }
        if flags.contains(.shift) { mods += "⇧" }
        if flags.contains(.command) { mods += "⌘" }
        return item.keyEquivalent.isEmpty ? "none" : mods + item.keyEquivalent.uppercased()
    }
}
#endif
