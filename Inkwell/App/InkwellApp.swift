import InkwellCore
import SwiftUI

@main
struct InkwellApp: App {
    @State private var store = NoteStore(options: LaunchOptions.storeOptions)
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .preferredColorScheme(appearance.colorScheme)
                .tint(Palette.accentColor)
        }
        .commands { InkwellCommands() }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif

        #if os(macOS)
        Settings {
            SettingsView(store: store)
                .preferredColorScheme(appearance.colorScheme)
                .tint(Palette.accentColor)
        }
        #endif
    }
}

extension FocusedValues {
    @Entry var navigator: Navigator?
}

struct InkwellCommands: Commands {
    @FocusedValue(\.navigator) private var navigator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { navigator?.newNote() }
                .keyboardShortcut("n")
                .disabled(navigator == nil)
            Button("New Folder") { navigator?.newFolderParent = "" }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(navigator == nil)
        }
        CommandMenu("Format") {
            format("Bold", .bold, "b")
            format("Italic", .italic, "i")
            format("Strikethrough", .strikethrough, "x", [.command, .shift])
            format("Inline Code", .inlineCode, "`")
            format("Link", .link, "k")
            Divider()
            format("Heading", .heading, "h", [.command, .shift])
            format("Checklist", .checklist, "l", [.command, .shift])
            format("Bulleted List", .bulletList, "7", [.command, .shift])
            format("Numbered List", .numberedList, "9", [.command, .shift])
            format("Quote", .quote, "'")
            format("Code Block", .codeBlock, "m", [.command, .shift])
            Divider()
            format("Indent", .indent, "]")
            format("Outdent", .outdent, "[")
        }
    }

    private func format(_ title: String, _ action: FormatAction, _ key: KeyEquivalent, _ modifiers: EventModifiers = .command) -> some View {
        Button(title) { FormatCommand.send(action) }
            .keyboardShortcut(key, modifiers: modifiers)
    }
}
