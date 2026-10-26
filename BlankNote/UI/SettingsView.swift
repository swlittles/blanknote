import BlankNoteCore
import SwiftUI

struct SettingsView: View {
    let store: NoteStore
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.defaultValue
    @AppStorage("editorFontSize") private var fontSize = EditorDefaults.fontSize
    @State private var rebuilding = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("themePicker")
                Stepper(value: $fontSize, in: AppSettings.fontSizes, step: 1) {
                    LabeledContent("Text Size", value: "\(Int(fontSize)) pt")
                }
            }
            #if os(iOS)
            Section {
                NavigationLink(value: SettingsRoute.profiles) {
                    Label("Profiles", systemImage: "person.2")
                }
                .accessibilityIdentifier("profilesSettings")
            }
            Section {
                NavigationLink("Keyboard Shortcuts") { ShortcutsSettingsView() }
                    .accessibilityIdentifier("keyboardShortcuts")
            } footer: {
                Text("For a hardware keyboard. To start BlankNote from anywhere, use Siri, Spotlight, the Action Button or Back Tap with the “New Note” and “Search Notes” shortcuts.")
            }
            #endif
            Section {
                LabeledContent("Location", value: store.location == .iCloud ? "iCloud Drive" : "On This Device")
                if let root = store.rootURL {
                    LabeledContent("Folder") {
                        Text(root.path(percentEncoded: false))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                    #if os(macOS)
                    Button("Show Notes Folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    }
                    #endif
                }
                Button(rebuilding ? "Rebuilding…" : "Rebuild Search Index") {
                    rebuilding = true
                    Task {
                        await store.reconcile(full: true)
                        rebuilding = false
                    }
                }
                .disabled(rebuilding)
            } header: {
                Text("Storage")
            } footer: {
                Text("Notes are plain Markdown files. \(store.notes.count(where: { !$0.isTrashed })) notes.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(macOS)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}
