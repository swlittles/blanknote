import BlankNoteCore
import SwiftUI
import UniformTypeIdentifiers

enum EditorDefaults {
    #if os(macOS)
    static let fontSize: Double = 15
    #else
    static let fontSize: Double = 17
    #endif
}

/// The open note's file, saved first so what's shared includes the latest typing (saving may
/// also rename the file, so its path is looked up then).
struct SharedNote: Transferable {
    let nav: Navigator

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText) { note in
            guard let url = await note.nav.savedOpenNoteURL() else { throw CocoaError(.fileNoSuchFile) }
            return SentTransferredFile(url)
        }
    }
}

/// The detail column: the open note, or a placeholder.
struct EditorPane: View {
    let nav: Navigator
    @Environment(NoteStore.self) private var store
    @AppStorage("editorFontSize") private var fontSize = EditorDefaults.fontSize

    var body: some View {
        Group {
            if let path = nav.editor.path, let note = store.summary(for: path) {
                MarkdownEditor(model: nav.editor, fontSize: CGFloat(fontSize))
                    .onChange(of: note.modified) {
                        if nav.editor.reloadIfChangedOnDisk() {
                            nav.toasts.show("Updated with changes made on another device or in another app",
                                            systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if note.isTrashed { trashBanner(note) }
                    }
                    .toolbar { toolbar(for: note) }
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "square.and.pencil",
                                       description: Text("Pick a note, or press ⌘N to start a new one."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.backgroundColor)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func trashBanner(_ note: NoteSummary) -> some View {
        HStack {
            Label("In Recently Deleted", systemImage: "trash")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Restore") { nav.restore(note.path) }
                .buttonStyle(.bordered)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.sidebarColor)
    }

    @ToolbarContentBuilder
    private func toolbar(for note: NoteSummary) -> some ToolbarContent {
        if !note.isTrashed {
            ToolbarItem {
                Button {
                    nav.togglePin(note.path)
                } label: {
                    Label(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.fill" : "pin")
                }
            }
            ToolbarItem {
                ShareLink(item: SharedNote(nav: nav), preview: SharePreview(note.displayTitle)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem {
                Menu {
                    Toggle(isOn: Binding(get: { nav.editor.showsMarkdown }, set: { _ in nav.toggleMarkdownEditing() })) {
                        Label("Edit as Markdown", systemImage: "number")
                    }
                    Divider()
                    MoveMenu(nav: nav, path: note.path)
                    Button("Copy Markdown", systemImage: "doc.on.doc") { nav.copyOpenNote() }
                    #if os(macOS)
                    Button("Show in Finder", systemImage: "folder") { nav.showOpenNoteInFinder() }
                    #endif
                    Divider()
                    Button("Delete Note", systemImage: "trash", role: .destructive) { nav.delete(note.path) }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }
}
