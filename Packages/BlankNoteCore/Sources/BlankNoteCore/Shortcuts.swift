import Foundation
import Observation

/// A key plus modifiers, like ⌥⌘F.
public struct KeyCombo: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// A lowercase character (`n`, `7`, `[`) or one of `specialKeys`' names.
    public var key: String
    public var modifiers: Modifiers
    /// The Mac's virtual key code. Global hotkeys need it: the system matches them by key
    /// position, not by character.
    public var keyCode: UInt16?

    public init(_ key: String, _ modifiers: Modifiers, keyCode: UInt16? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.keyCode = keyCode ?? Self.usKeyCodes[key]
    }

    /// Named keys and how they're drawn.
    public static let specialKeys: [String: String] = [
        "return": "↩", "delete": "⌫", "forwardDelete": "⌦", "escape": "⎋", "tab": "⇥", "space": "Space",
        "up": "↑", "down": "↓", "left": "←", "right": "→", "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟",
    ]

    /// How the shortcut is written in menus: ⌃⌥⇧⌘ then the key.
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.specialKeys[key] ?? key.uppercased())
    }

    /// Two combos are the same shortcut if they'd be pressed the same way; the key code is
    /// bookkeeping.
    public func sameKeys(as other: KeyCombo) -> Bool {
        key == other.key && modifiers == other.modifiers
    }

    /// Virtual key codes on a US keyboard, for combos built from a character (the defaults).
    static let usKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "forwardDelete": 117, "home": 115, "end": 119, "pageUp": 116, "pageDown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}

/// Everything that can have a keyboard shortcut, with its default.
public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    // Anywhere on the Mac, even when BlankNote is in the background.
    case globalToggleApp, globalNewNote, globalSearch
    // Notes
    case newNote, newFolder, searchNotes, syncNow, togglePin, deleteNote, nextNote, previousNote, copyMarkdown, showInFinder
    // Profiles
    case nextProfile, previousProfile
    // View
    case biggerText, smallerText, actualSize, toggleTheme
    // Format
    case bold, italic, strikethrough, inlineCode, link
    case heading, checklist, bulletList, numberedList, quote, codeBlock, indent, outdent

    public enum Group: String, CaseIterable, Sendable {
        case global = "Anywhere on Your Mac"
        case notes = "Notes"
        case profiles = "Profiles"
        case view = "View"
        case format = "Format"
    }

    public var group: Group {
        switch self {
        case .globalToggleApp, .globalNewNote, .globalSearch: .global
        case .newNote, .newFolder, .searchNotes, .syncNow, .togglePin, .deleteNote, .nextNote, .previousNote, .copyMarkdown, .showInFinder: .notes
        case .nextProfile, .previousProfile: .profiles
        case .biggerText, .smallerText, .actualSize, .toggleTheme: .view
        default: .format
        }
    }

    public var isGlobal: Bool { group == .global }

    /// Global hotkeys and Show in Finder only exist on the Mac.
    public var isMacOnly: Bool { isGlobal || self == .showInFinder }

    public var title: String {
        switch self {
        case .globalToggleApp: "Show or Hide BlankNote"
        case .globalNewNote: "New Note"
        case .globalSearch: "Search Notes"
        case .newNote: "New Note"
        case .newFolder: "New Folder"
        case .searchNotes: "Search All Notes"
        case .syncNow: "Sync Now"
        case .togglePin: "Pin or Unpin Note"
        case .deleteNote: "Delete Note"
        case .nextNote: "Next Note"
        case .previousNote: "Previous Note"
        case .copyMarkdown: "Copy Markdown"
        case .showInFinder: "Show in Finder"
        case .nextProfile: "Next Profile"
        case .previousProfile: "Previous Profile"
        case .biggerText: "Bigger Text"
        case .smallerText: "Smaller Text"
        case .actualSize: "Default Text Size"
        case .toggleTheme: "Switch Light/Dark"
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .inlineCode: "Inline Code"
        case .link: "Link"
        case .heading: "Heading"
        case .checklist: "Checklist"
        case .bulletList: "Bulleted List"
        case .numberedList: "Numbered List"
        case .quote: "Quote"
        case .codeBlock: "Code Block"
        case .indent: "Indent"
        case .outdent: "Outdent"
        }
    }

    public var formatAction: FormatAction? {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .strikethrough: .strikethrough
        case .inlineCode: .inlineCode
        case .link: .link
        case .heading: .heading
        case .checklist: .checklist
        case .bulletList: .bulletList
        case .numberedList: .numberedList
        case .quote: .quote
        case .codeBlock: .codeBlock
        case .indent: .indent
        case .outdent: .outdent
        default: nil
        }
    }

    public var defaultCombo: KeyCombo? {
        let cmd: KeyCombo.Modifiers = .command
        let shiftCmd: KeyCombo.Modifiers = [.shift, .command]
        let optCmd: KeyCombo.Modifiers = [.option, .command]
        let hyper: KeyCombo.Modifiers = [.control, .option, .command]
        return switch self {
        case .globalToggleApp: KeyCombo("b", hyper)
        case .globalNewNote: KeyCombo("n", hyper)
        case .globalSearch: KeyCombo("f", hyper)
        case .newNote: KeyCombo("n", cmd)
        case .newFolder: KeyCombo("n", shiftCmd)
        case .searchNotes: KeyCombo("f", optCmd)
        case .syncNow: KeyCombo("r", cmd)
        case .togglePin: KeyCombo("p", shiftCmd)
        case .deleteNote: KeyCombo("delete", optCmd)
        case .nextNote: KeyCombo("down", optCmd)
        case .previousNote: KeyCombo("up", optCmd)
        case .copyMarkdown: KeyCombo("c", shiftCmd)
        case .showInFinder: KeyCombo("r", shiftCmd)
        case .nextProfile: KeyCombo("]", [.control, .command])
        case .previousProfile: KeyCombo("[", [.control, .command])
        case .biggerText: KeyCombo("=", cmd)
        case .smallerText: KeyCombo("-", cmd)
        case .actualSize: KeyCombo("0", cmd)
        case .toggleTheme: KeyCombo("d", shiftCmd)
        case .bold: KeyCombo("b", cmd)
        case .italic: KeyCombo("i", cmd)
        case .strikethrough: KeyCombo("x", shiftCmd)
        case .inlineCode: KeyCombo("e", cmd)
        case .link: KeyCombo("k", cmd)
        case .heading: KeyCombo("h", shiftCmd)
        case .checklist: KeyCombo("l", shiftCmd)
        case .bulletList: KeyCombo("7", shiftCmd)
        case .numberedList: KeyCombo("9", shiftCmd)
        case .quote: KeyCombo("'", cmd)
        case .codeBlock: KeyCombo("m", shiftCmd)
        case .indent: KeyCombo("]", cmd)
        case .outdent: KeyCombo("[", cmd)
        }
    }
}

/// Why a combo can't be used for an action.
public enum ShortcutProblem: Equatable, Sendable {
    /// Needs ⌘, ⌥ or ⌃ (global hotkeys need two of them), or it would fire while typing.
    case needsModifier
    /// Taken by the system or by text editing (⌘Q, ⌘C, ⌘Z…).
    case reserved
}

/// The user's keyboard shortcuts: the defaults plus their changes, saved in UserDefaults.
@MainActor @Observable
public final class ShortcutStore {
    /// Changes from the defaults. A `nil` value means the user removed the shortcut.
    public private(set) var overrides: [ShortcutAction: KeyCombo?] = [:]
    /// While a shortcut is being recorded, menus and hotkeys stand down so they don't fire.
    public var isRecording = false

    @ObservationIgnored private let defaults: UserDefaults
    public static let defaultsKey = "keyboardShortcuts.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public func combo(for action: ShortcutAction) -> KeyCombo? {
        if let override = overrides[action] { return override }
        return action.defaultCombo
    }

    /// The shortcut menus and hotkeys should use right now: none while recording.
    public func activeCombo(for action: ShortcutAction) -> KeyCombo? {
        isRecording ? nil : combo(for: action)
    }

    /// Every action's current shortcut (none while recording), as a plain value. Menus take this
    /// rather than the store: SwiftUI rebuilds menus when their inputs change, but doesn't track
    /// observable objects read inside them.
    public var activeBindings: [ShortcutAction: KeyCombo] {
        guard !isRecording else { return [:] }
        var bindings: [ShortcutAction: KeyCombo] = [:]
        for action in ShortcutAction.allCases {
            if let combo = combo(for: action) { bindings[action] = combo }
        }
        return bindings
    }

    public func isCustomized(_ action: ShortcutAction) -> Bool {
        overrides[action] != nil
    }

    /// The action already using these keys, if any.
    public func action(using combo: KeyCombo, except action: ShortcutAction? = nil) -> ShortcutAction? {
        ShortcutAction.allCases.first { other in
            other != action && self.combo(for: other)?.sameKeys(as: combo) == true
        }
    }

    public func problem(with combo: KeyCombo, for action: ShortcutAction) -> ShortcutProblem? {
        let strong = combo.modifiers.intersection([.command, .option, .control])
        if action.isGlobal ? strong.rawValue.nonzeroBitCount < 2 : strong.isEmpty { return .needsModifier }
        if Self.reserved.contains(where: { $0.sameKeys(as: combo) }) { return .reserved }
        return nil
    }

    /// Gives `action` this shortcut (`nil` removes it). Any other action using the same keys
    /// loses its shortcut; that action is returned so the UI can say so.
    @discardableResult
    public func set(_ combo: KeyCombo?, for action: ShortcutAction) -> ShortcutAction? {
        var displaced: ShortcutAction?
        if let combo, let other = self.action(using: combo, except: action) {
            overrides[other] = .some(nil)
            displaced = other
        }
        let isDefault = switch (combo, action.defaultCombo) {
        case (nil, nil): true
        case (let combo?, let fallback?): combo.sameKeys(as: fallback)
        default: false
        }
        overrides[action] = isDefault ? nil : .some(combo)
        save()
        return displaced
    }

    public func reset(_ action: ShortcutAction) {
        // Taking the default back from whoever has it now.
        if let combo = action.defaultCombo, let other = self.action(using: combo, except: action) {
            overrides[other] = .some(nil)
        }
        overrides[action] = nil
        save()
    }

    public func resetAll() {
        overrides = [:]
        save()
    }

    /// System and text-editing shortcuts that must keep working.
    static let reserved: [KeyCombo] = {
        let cmd: KeyCombo.Modifiers = .command
        var combos = ["q", "w", "h", "m", ",", "c", "v", "x", "a", "z", "`", "tab", "space"].map { KeyCombo($0, cmd) }
        combos += [KeyCombo("z", [.shift, .command]), KeyCombo("h", [.option, .command]), KeyCombo("escape", [.option, .command]),
                   KeyCombo("space", [.control, .command]), KeyCombo("f", [.control, .command]), KeyCombo("q", [.control, .command])]
        return combos
    }()

    // MARK: Persistence

    private struct Stored: Codable {
        var combo: KeyCombo?
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return }
        var overrides: [ShortcutAction: KeyCombo?] = [:]
        for (name, value) in stored {
            if let action = ShortcutAction(rawValue: name) { overrides[action] = .some(value.combo) }
        }
        self.overrides = overrides
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, Stored(combo: $0.value)) })
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.defaultsKey)
    }
}
