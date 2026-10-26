import Foundation
import Testing
@testable import InkwellCore

@MainActor
struct ShortcutTests {
    private func makeStore() -> (ShortcutStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "shortcuts-\(UUID().uuidString)")!
        return (ShortcutStore(defaults: defaults), defaults)
    }

    @Test func defaultsAreUniqueAndValid() {
        let (store, _) = makeStore()
        var seen: [KeyCombo] = []
        for action in ShortcutAction.allCases {
            let combo = try! #require(action.defaultCombo, "\(action) has a default")
            #expect(!seen.contains { $0.sameKeys(as: combo) }, "\(action)'s default \(combo.displayString) is used twice")
            #expect(store.problem(with: combo, for: action) == nil, "\(action)'s default \(combo.displayString)")
            #expect(combo.keyCode != nil, "\(action) can be registered as a hotkey")
            seen.append(combo)
        }
    }

    @Test func displayStrings() {
        #expect(KeyCombo("n", [.command, .option, .control]).displayString == "⌃⌥⌘N")
        #expect(KeyCombo("down", [.option, .command]).displayString == "⌥⌘↓")
        #expect(KeyCombo("[", .command).displayString == "⌘[")
        #expect(KeyCombo("7", [.shift, .command]).displayString == "⇧⌘7")
    }

    @Test func rulesForNewShortcuts() {
        let (store, _) = makeStore()
        #expect(store.problem(with: KeyCombo("j", []), for: .bold) == .needsModifier)
        #expect(store.problem(with: KeyCombo("j", .shift), for: .bold) == .needsModifier)
        #expect(store.problem(with: KeyCombo("j", .option), for: .bold) == nil)
        #expect(store.problem(with: KeyCombo("c", .command), for: .bold) == .reserved)
        #expect(store.problem(with: KeyCombo("z", [.shift, .command]), for: .bold) == .reserved)
        // Global hotkeys apply in every app, so they need two of ⌘ ⌥ ⌃.
        #expect(store.problem(with: KeyCombo("j", .command), for: .globalNewNote) == .needsModifier)
        #expect(store.problem(with: KeyCombo("j", [.control, .option]), for: .globalNewNote) == nil)
    }

    @Test func assigningTakesTheKeysFromTheirOldAction() {
        let (store, _) = makeStore()
        let displaced = store.set(KeyCombo("b", .command), for: .italic)
        #expect(displaced == .bold)
        #expect(store.combo(for: .italic)?.displayString == "⌘B")
        #expect(store.combo(for: .bold) == nil)
        #expect(store.isCustomized(.bold))

        // Resetting italic gives back ⌘I; resetting bold takes ⌘B back from italic.
        store.reset(.bold)
        #expect(store.combo(for: .bold)?.displayString == "⌘B")
        #expect(store.combo(for: .italic) == nil)
        store.reset(.italic)
        #expect(store.combo(for: .italic)?.displayString == "⌘I")
        #expect(store.overrides.isEmpty)
    }

    @Test func settingTheDefaultAgainIsNotACustomization() {
        let (store, _) = makeStore()
        store.set(KeyCombo("j", .option), for: .link)
        #expect(store.isCustomized(.link))
        store.set(KeyCombo("k", .command), for: .link)
        #expect(!store.isCustomized(.link))
    }

    @Test func changesAreSavedAndRecordingSilencesShortcuts() {
        let (store, defaults) = makeStore()
        store.set(KeyCombo("j", [.control, .option]), for: .globalNewNote)
        store.set(nil, for: .deleteNote)
        let reloaded = ShortcutStore(defaults: defaults)
        #expect(reloaded.combo(for: .globalNewNote)?.displayString == "⌃⌥J")
        #expect(reloaded.combo(for: .globalNewNote)?.keyCode == 38)
        #expect(reloaded.combo(for: .deleteNote) == nil)
        #expect(reloaded.combo(for: .newNote)?.displayString == "⌘N")

        reloaded.isRecording = true
        #expect(reloaded.activeCombo(for: .newNote) == nil)
        reloaded.resetAll()
        #expect(ShortcutStore(defaults: defaults).overrides.isEmpty)
    }
}
