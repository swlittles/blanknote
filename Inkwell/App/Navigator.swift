import Foundation
import InkwellCore
import Observation

enum SidebarItem: Hashable {
    case all
    case folder(String)
    case tag(String)
    case trash
}

/// One window's state: what the sidebar and note list show, which note is open, and the actions
/// that change them. Each window (Mac, iPad) has its own; they share one `NoteStore`.
@MainActor @Observable
final class Navigator {
    let store: NoteStore
    let editor: EditorModel

    var sidebar: SidebarItem? = .all
    var selection: String? {
        didSet {
            guard selection != oldValue, selection != editor.path else { return }
            editor.open(selection)
        }
    }
    var searchText = ""
    private(set) var searchResults: [String]?
    /// iPhone (or a narrow iPad window): after deleting a note, go back to the list rather than
    /// opening the next one.
    var isCompact = false
    /// Set to show the "New Folder" prompt (from the menu or toolbar); the value is the parent.
    var newFolderParent: String?

    init(store: NoteStore) {
        self.store = store
        editor = EditorModel(store: store)
        editor.onPathChange = { [weak self] path in self?.selection = path }
    }

    // MARK: What's shown

    var title: String {
        if searchResults != nil { return "Search" }
        switch sidebar ?? .all {
        case .all: return "All Notes"
        case .folder(let path): return (path as NSString).lastPathComponent
        case .tag(let tag): return "#\(tag)"
        case .trash: return "Recently Deleted"
        }
    }

    var isShowingTrash: Bool { sidebar == .trash && searchResults == nil }

    var visibleNotes: [NoteSummary] {
        if let searchResults {
            var byPath: [String: NoteSummary] = [:]
            for note in store.notes where !note.isTrashed { byPath[note.path] = note }
            return searchResults.compactMap { byPath[$0] }
        }
        let notes: [NoteSummary]
        switch sidebar ?? .all {
        case .all:
            notes = store.notes.filter { !$0.isTrashed }
        case .folder(let folder):
            notes = store.notes.filter { $0.folder == folder }
        case .tag(let tag):
            let tag = tag.lowercased()
            notes = store.notes.filter { note in
                !note.isTrashed && note.tags.contains { $0.lowercased() == tag || $0.lowercased().hasPrefix(tag + "/") }
            }
        case .trash:
            notes = store.notes.filter(\.isTrashed)
        }
        return notes.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned, !isShowingTrash { return lhs.pinned }
            return lhs.modified > rhs.modified
        }
    }

    func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let results = await store.search(query)
        guard !Task.isCancelled else { return }
        searchResults = results
    }

    // MARK: Notes

    func newNote() {
        var folder = ""
        if case .folder(let path)? = sidebar { folder = path }
        if sidebar == .trash { sidebar = .all }
        searchText = ""
        searchResults = nil
        do {
            let path = try store.createNote(in: folder)
            editor.open(path, focus: true)
            selection = path
        } catch {
            store.report(error)
        }
    }

    func togglePin(_ path: String) {
        guard let note = store.summary(for: path) else { return }
        if editor.path == path { editor.flush() }
        do { try store.setPinned(!note.pinned, for: path) } catch { store.report(error) }
    }

    /// Moves a note to Recently Deleted, or deletes it for good if it's already there.
    func delete(_ path: String) {
        let next = isCompact ? nil : neighbor(of: path)
        if editor.path == path { editor.flush() }
        do {
            if store.summary(for: path)?.isTrashed == true {
                try store.deleteNotePermanently(path)
            } else {
                try store.trashNote(path)
            }
            if selection == path || editor.path == path { selection = next }
        } catch {
            store.report(error)
        }
    }

    func restore(_ path: String) {
        do {
            try store.restoreNote(path)
            if selection == path { selection = nil }
        } catch {
            store.report(error)
        }
    }

    func emptyTrash() {
        if let path = editor.path, store.summary(for: path)?.isTrashed == true { selection = nil }
        do { try store.emptyTrash() } catch { store.report(error) }
    }

    func move(_ paths: [String], to folder: String) {
        for path in paths {
            guard store.summary(for: path) != nil else { continue }
            let isOpen = editor.path == path
            if isOpen { editor.flush() }
            do {
                let newPath = try store.moveNote(path, to: folder)
                if isOpen {
                    editor.follow(movedTo: newPath)
                    selection = newPath
                }
            } catch {
                store.report(error)
            }
        }
    }

    private func neighbor(of path: String) -> String? {
        let notes = visibleNotes
        guard let index = notes.firstIndex(where: { $0.path == path }) else { return nil }
        if index + 1 < notes.count { return notes[index + 1].path }
        return index > 0 ? notes[index - 1].path : nil
    }

    // MARK: Folders

    func createFolder(named name: String, in parent: String) {
        do {
            sidebar = .folder(try store.createFolder(named: name, in: parent))
        } catch {
            store.report(error)
        }
    }

    func renameFolder(_ path: String, to name: String) async {
        editor.flush()
        do {
            let newPath = try await store.renameFolder(path, to: name)
            func moved(_ item: String) -> String? {
                item == path || item.hasPrefix(path + "/") ? newPath + item.dropFirst(path.count) : nil
            }
            if case .folder(let current)? = sidebar, let updated = moved(current) { sidebar = .folder(updated) }
            if let open = editor.path, let updated = moved(open) {
                editor.follow(movedTo: updated)
                selection = updated
            }
        } catch {
            store.report(error)
        }
    }

    func deleteFolder(_ path: String) {
        editor.flush()
        if let open = editor.path, open.hasPrefix(path + "/") { selection = nil }
        if case .folder(let current)? = sidebar, current == path || current.hasPrefix(path + "/") { sidebar = .all }
        do { try store.deleteFolder(path) } catch { store.report(error) }
    }

    /// Keeps the selection valid after the notes changed on disk.
    func notesChanged() {
        if let selection, store.summary(for: selection) == nil, editor.path == selection {
            self.selection = nil
        }
        if case .folder(let folder)? = sidebar, !store.folders.contains(folder) {
            sidebar = .all
        }
    }

    // MARK: Launch options

    func applyLaunchOptions() {
        if let sidebar = LaunchOptions.sidebar { self.sidebar = sidebar }
        if let title = LaunchOptions.openTitle,
           let note = store.notes.first(where: { $0.title == title }) {
            selection = note.path
        }
        if let query = LaunchOptions.search { searchText = query }
    }
}

/// A folder in the sidebar's tree.
struct FolderNode: Identifiable, Hashable {
    let path: String
    let name: String
    /// `nil` for folders without subfolders, so `OutlineGroup` shows no disclosure arrow.
    var children: [FolderNode]?

    var id: String { path }

    static func tree(_ folders: [String]) -> [FolderNode] {
        var childrenByParent: [String: [String]] = [:]
        for folder in folders {
            childrenByParent[(folder as NSString).deletingLastPathComponent, default: []].append(folder)
        }
        func nodes(in parent: String) -> [FolderNode]? {
            guard let paths = childrenByParent[parent] else { return nil }
            return paths
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { FolderNode(path: $0, name: ($0 as NSString).lastPathComponent, children: nodes(in: $0)) }
        }
        return nodes(in: "") ?? []
    }
}
