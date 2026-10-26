import BlankNoteCore
import SwiftUI

struct NoteListView: View {
    @Bindable var nav: Navigator
    @Environment(NoteStore.self) private var store
    @State private var confirmEmptyTrash = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let notes = nav.visibleNotes
        List(selection: $nav.selection) {
            ForEach(sections(for: notes), id: \.title) { section in
                Section(section.title) {
                    ForEach(section.notes) { note in
                        NoteRow(note: note, showFolder: showsFolder, isSelected: nav.selection == note.path)
                            #if os(iOS)
                            .modifier(SwipeActions(nav: nav, note: note))
                            #endif
                            .tag(note.path)
                            .draggable(note.path)
                            .contextMenu { menu(for: note) }
                            #if os(iOS)
                            .listRowBackground(Color(nav.selection == note.path ? Palette.selectedRow : Palette.card))
                            #endif
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.plain)
        #endif
        .scrollContentBackground(.hidden)
        .background(Palette.backgroundColor)
        .navigationTitle(nav.title)
        .searchable(text: $nav.searchText, prompt: "Search all notes")
        .searchFocused($searchFocused)
        .onChange(of: nav.searchRequest) { searchFocused = true }
        .task(id: "\(nav.searchText)\u{0}\(nav.searchRefresh)") { await nav.runSearch() }
        #if os(macOS)
        .onDeleteCommand {
            if let selection = nav.selection { nav.delete(selection) }
        }
        #endif
        .overlay {
            if notes.isEmpty, store.isReady {
                emptyState
            }
        }
        .toolbar {
            if nav.isShowingTrash {
                ToolbarItem {
                    Button("Empty", systemImage: "trash.slash") { confirmEmptyTrash = true }
                        .disabled(notes.isEmpty)
                }
            } else {
                #if os(macOS)
                ToolbarItem {
                    Button { Task { await nav.syncNow() } } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Sync Now (check iCloud for changes)")
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button { nav.newNote() } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                }
            }
        }
        #if os(iOS)
        // Pull down to sync.
        .refreshable { await nav.syncNow() }
        #endif
        .confirmationDialog("Delete every note in Recently Deleted?", isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { nav.emptyTrash() }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var showsFolder: Bool {
        if nav.searchResults != nil { return true }
        switch nav.sidebar ?? .all {
        case .folder: return false
        default: return true
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if nav.searchResults != nil {
            ContentUnavailableView.search(text: nav.searchText)
        } else if nav.isShowingTrash {
            ContentUnavailableView("Nothing Deleted", systemImage: "trash", description: Text("Deleted notes stay here for 30 days."))
        } else {
            ContentUnavailableView {
                Label("No Notes", systemImage: "note.text")
            } description: {
                Text("Write something down.")
            } actions: {
                Button("New Note") { nav.newNote() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func menu(for note: NoteSummary) -> some View {
        if note.isTrashed {
            Button("Restore", systemImage: "arrow.uturn.backward") { nav.restore(note.path) }
            Button("Delete Now", systemImage: "trash", role: .destructive) { nav.delete(note.path) }
        } else {
            Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin") { nav.togglePin(note.path) }
            MoveMenu(nav: nav, path: note.path)
            #if os(macOS)
            if let root = store.rootURL {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(note.path)])
                }
            }
            #endif
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { nav.delete(note.path) }
        }
    }

    // MARK: Sections

    private struct NoteSection {
        var title: String
        var notes: [NoteSummary]
    }

    /// Pinned notes first, then by date the way Apple Notes groups them. Search results keep
    /// their relevance order in one section.
    private func sections(for notes: [NoteSummary]) -> [NoteSection] {
        if nav.searchResults != nil {
            return notes.isEmpty ? [] : [NoteSection(title: "Top Results", notes: notes)]
        }
        var sections: [NoteSection] = []
        func add(_ note: NoteSummary, to title: String) {
            if sections.last?.title == title {
                sections[sections.count - 1].notes.append(note)
            } else {
                sections.append(NoteSection(title: title, notes: [note]))
            }
        }
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        for note in notes {
            if note.pinned, !note.isTrashed {
                add(note, to: "Pinned")
                continue
            }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: note.modified), to: startOfToday).day ?? 0
            let title = switch days {
            case ..<1: "Today"
            case 1: "Yesterday"
            case 2..<7: "Previous 7 Days"
            case 7..<30: "Previous 30 Days"
            default: calendar.isDate(note.modified, equalTo: now, toGranularity: .year)
                ? note.modified.formatted(.dateTime.month(.wide))
                : note.modified.formatted(.dateTime.year())
            }
            add(note, to: title)
        }
        return sections
    }
}

struct NoteRow: View {
    let note: NoteSummary
    let showFolder: Bool
    var isSelected = false

    /// On iPhone and iPad the selected row is solid accent, so its text is white whether or not
    /// the list has focus (iOS only whitens it while it does).
    private var onAccent: Bool {
        #if os(iOS)
        isSelected
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if note.pinned, !note.isTrashed {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.accentColor))
                }
                Text(note.displayTitle)
                    .font(.headline)
                    .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(dateText)
                    .foregroundStyle(onAccent ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                Text(note.preview.isEmpty ? "No additional text" : note.preview)
                    .foregroundStyle(onAccent ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            .font(.subheadline)
            if showFolder, !note.folder.isEmpty, !note.isTrashed {
                Label((note.folder as NSString).lastPathComponent, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(onAccent ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var dateText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(note.modified) {
            return note.modified.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: note.modified, to: .now).day, days < 7 {
            return note.modified.formatted(.dateTime.weekday(.wide))
        }
        return note.modified.formatted(date: .numeric, time: .omitted)
    }
}

/// "Move to" submenu listing every folder.
struct MoveMenu: View {
    let nav: Navigator
    let path: String
    @Environment(NoteStore.self) private var store

    var body: some View {
        let current = (path as NSString).deletingLastPathComponent
        Menu("Move to", systemImage: "folder") {
            Button("Notes (top level)") { nav.move([path], to: "") }
                .disabled(current.isEmpty)
            ForEach(store.folders, id: \.self) { folder in
                Button(folder.replacingOccurrences(of: "/", with: " › ")) { nav.move([path], to: folder) }
                    .disabled(folder == current)
            }
        }
    }
}

#if os(iOS)
/// Swipe right to pin, left to delete.
private struct SwipeActions: ViewModifier {
    let nav: Navigator
    let note: NoteSummary

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) {
                if !note.isTrashed {
                    Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin") {
                        nav.togglePin(note.path)
                    }
                    .tint(Palette.accentColor)
                }
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) { nav.delete(note.path) }
            }
    }
}
#endif
