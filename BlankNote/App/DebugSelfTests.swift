#if DEBUG && os(macOS)
import AppKit
import BlankNoteCore

/// Checks of Mac behaviour that the iPhone UI tests can't cover, run with a launch argument.
/// Each writes its findings to a file for a script to read:
///
/// - `-themeSelfTest <file>`: sets the theme to dark, light, then system (as the Settings picker
///   does) and records what the windows show after each.
/// - `-shortcutSelfTest <file>`: presses shortcuts (through normal event dispatch) before and after
///   shortcut, records it again, then lists which global hotkeys registered.
/// - `-typingSelfTest <file>`: types at the end of the open note's title, pausing after each letter
///   for the autosave (which renames the file), and records where the cursor and the text went.
@MainActor
enum DebugSelfTests {
    static func run(shortcuts: ShortcutStore) {
        if let path = LaunchOptions.value(after: "-themeSelfTest") { theme(writingTo: path) }
        if let path = LaunchOptions.value(after: "-shortcutSelfTest") { shortcutsTest(shortcuts, writingTo: path) }
        if let path = LaunchOptions.value(after: "-typingSelfTest") { typing(writingTo: path) }
    }

    private static func typing(writingTo path: String) {
        Task {
            var lines: [String] = []
            try? await Task.sleep(for: .seconds(1.5))
            func editor(_ view: NSView?) -> InkTextView? {
                guard let view else { return nil }
                if let text = view as? InkTextView { return text }
                return view.subviews.lazy.compactMap(editor).first
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && editor($0.contentView) != nil }),
                  let view = editor(window.contentView) else {
                try? "no editor".write(toFile: path, atomically: true, encoding: .utf8)
                return
            }
            window.makeFirstResponder(view)
            let titleEnd = (view.string as NSString).lineRange(for: NSRange(location: 0, length: 0)).length - 1
            view.setSelectedRange(NSRange(location: titleEnd, length: 0))
            for letter in ["s", "!", "x"] {
                view.insertText(letter, replacementRange: view.selectedRange())
                try? await Task.sleep(for: .seconds(1.2))
                lines.append("title: cursor \(view.selectedRange().location), focused \(window.firstResponder === view), \(view.string.components(separatedBy: "\n")[0])")
            }
            // Partway through the third line ("Lisbon in spring" in the demo notes).
            let lineStarts = view.string.utf16.indices.filter { view.string.utf16[$0] == 10 }.map { view.string.utf16.distance(from: view.string.utf16.startIndex, to: $0) + 1 }
            let middle = lineStarts.count > 2 ? lineStarts[2] + 5 : 0
            view.setSelectedRange(NSRange(location: middle, length: 0))
            view.insertText("Q", replacementRange: view.selectedRange())
            lines.append("mid-line: typed at \(middle), cursor now \(view.selectedRange().location)")
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
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
