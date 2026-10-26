import InkwellCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension KeyCombo {
    /// The shortcut for SwiftUI menus and buttons.
    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "return": equivalent = .return
        case "delete": equivalent = .delete
        case "forwardDelete": equivalent = .deleteForward
        case "escape": equivalent = .escape
        case "tab": equivalent = .tab
        case "space": equivalent = .space
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "home": equivalent = .home
        case "end": equivalent = .end
        case "pageUp": equivalent = .pageUp
        case "pageDown": equivalent = .pageDown
        default:
            guard key.count == 1, let character = key.first else { return nil }
            equivalent = KeyEquivalent(character)
        }
        var modifiers: EventModifiers = []
        if self.modifiers.contains(.command) { modifiers.insert(.command) }
        if self.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if self.modifiers.contains(.option) { modifiers.insert(.option) }
        if self.modifiers.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    #if os(iOS)
    /// A combo from a hardware-keyboard press, for the shortcut recorder. `nil` for a modifier key
    /// pressed on its own.
    init?(uiKey key: UIKey) {
        let special: [UIKeyboardHIDUsage: String] = [
            .keyboardReturnOrEnter: "return", .keyboardDeleteOrBackspace: "delete", .keyboardDeleteForward: "forwardDelete",
            .keyboardEscape: "escape", .keyboardTab: "tab", .keyboardSpacebar: "space",
            .keyboardUpArrow: "up", .keyboardDownArrow: "down", .keyboardLeftArrow: "left", .keyboardRightArrow: "right",
            .keyboardHome: "home", .keyboardEnd: "end", .keyboardPageUp: "pageUp", .keyboardPageDown: "pageDown",
        ]
        let name = special[key.keyCode] ?? key.charactersIgnoringModifiers.lowercased()
        guard !name.isEmpty else { return nil }
        var modifiers: Modifiers = []
        if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
        if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
        self.init(name, modifiers)
    }
    #endif

    #if os(macOS)
    /// A combo from a key-down event, keeping its key code for global hotkeys.
    init?(event: NSEvent) {
        let special: [UInt16: String] = [
            36: "return", 51: "delete", 117: "forwardDelete", 53: "escape", 48: "tab", 49: "space",
            126: "up", 125: "down", 123: "left", 124: "right", 115: "home", 119: "end", 116: "pageUp", 121: "pageDown",
        ]
        let key: String
        if let name = special[event.keyCode] {
            key = name
        } else if let characters = event.characters(byApplyingModifiers: []), !characters.isEmpty {
            // Without modifiers, so ⇧⌘7 records as "7", not "&".
            key = characters.lowercased()
        } else {
            return nil
        }
        var modifiers: Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self.init(key, modifiers, keyCode: event.keyCode)
    }
    #endif
}
