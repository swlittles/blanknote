import InkwellCore
import SwiftUI

struct SettingsView: View {
    let store: NoteStore
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("editorFontSize") private var fontSize = EditorDefaults.fontSize
    @State private var rebuilding = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: $fontSize, in: 12...26, step: 1) {
                    LabeledContent("Text Size", value: "\(Int(fontSize)) pt")
                }
            }
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
