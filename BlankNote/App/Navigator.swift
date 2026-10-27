import Foundation
import BlankNoteCore
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings on iPhone and iPad, shown as a sheet, optionally opened at a page.
enum SettingsRoute: String, Identifiable, Hashable {
    case general, profiles
    var id: String { rawValue }
}

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
    /// This window's in-app notifications.
    let toasts = Toaster()

    var sidebar: SidebarItem? = .all
    var selection: String? {
        didSet {
            guard selection != oldValue, selection != editor.path else { return }
            editor.open(selection)
        }
    }
    var searchText = ""
    private(set) var searchResults: [String]?
    /// Bumped when the notes change during a search, so the results are looked up again.
    private(set) var searchRefresh = 0
    /// iPhone (or a narrow iPad window): after deleting a note, go back to the list rather than
    /// opening the next one.
    var isCompact = false
    /// Set to show the "New Folder" prompt (from the menu or toolbar); the value is the parent.
    var newFolderParent: String?
    /// Bumped to put the cursor in the search field.
    private(set) var searchRequest = 0
    var showNewProfile = false
    /// Shows Settings (iPhone and iPad).
    var settingsRoute: SettingsRoute?

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

    /// The note in the editor.
    var openNote: NoteSummary? { editor.path.flatMap(store.summary(for:)) }

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

    func newNote(body: String = "") {
        var folder = ""
        if case .folder(let path)? = sidebar { folder = path }
        // A new note isn't in Recently Deleted, and has no tags yet: show it where it'll appear.
        switch sidebar {
        case .trash?, .tag?: sidebar = .all
        default: break
        }
        searchText = ""
        searchResults = nil
        do {
            let path = try store.createNote(in: folder, body: body)
            editor.open(path, focus: true)
            selection = path
        } catch {
            store.report(error)
        }
    }

    /// Saves the note if it's open, and returns its path afterwards: saving renames the file
    /// when the title changed.
    private func savedPath(_ path: String) -> String {
        // Every window saves its open note, in case it's this one (or the one this moves over).
        saveAllWindows()
        let path = store.summary(for: path) == nil ? store.currentPath(for: path) ?? path : path
        guard editor.path == path else { return path }
        editor.flush()
        return editor.path ?? path
    }

    private func saveAllWindows() {
        NotificationCenter.default.post(name: .blankNoteSaveEditors, object: nil)
    }

    func togglePin(_ path: String) {
        let path = savedPath(path)
        guard let note = store.summary(for: path) else { return }
        do {
            try store.setPinned(!note.pinned, for: path)
            toasts.show(note.pinned ? "Unpinned “\(note.displayTitle)”" : "Pinned “\(note.displayTitle)”",
                        systemImage: note.pinned ? "pin.slash" : "pin.fill")
        } catch {
            store.report(error)
        }
    }

    /// Moves a note to Recently Deleted (with Undo), or deletes it for good if it's already there.
    func delete(_ path: String) {
        let path = savedPath(path)
        guard let note = store.summary(for: path) else { return }
        let next = isCompact ? nil : neighbor(of: path)
        do {
            if note.isTrashed {
                try store.deleteNotePermanently(path)
                toasts.show("Deleted “\(note.displayTitle)”", systemImage: "trash")
            } else {
                let trashed = try store.trashNote(path)
                toasts.show("Moved “\(note.displayTitle)” to Recently Deleted", systemImage: "trash", actionTitle: "Undo") { [weak self] in
                    self?.restore(trashed, select: true)
                }
            }
            if selection == path || editor.path == path { selection = next }
        } catch {
            store.report(error)
        }
    }

    func restore(_ path: String, select: Bool = false) {
        do {
            let folder = (try? store.readNote(path))?.frontMatter.value("trashed-from") ?? ""
            let restored = try store.restoreNote(path)
            if select {
                if sidebar == .trash { sidebar = .all }
                // On iPhone, stay in the list where the note reappears instead of opening it.
                if !isCompact { selection = restored }
            } else {
                if selection == path { selection = nil }
                let title = store.summary(for: restored)?.displayTitle ?? ""
                toasts.show("Restored “\(title)” to \(Self.folderName(folder))", systemImage: "arrow.uturn.backward", style: .success)
            }
        } catch {
            store.report(error)
        }
    }

    func emptyTrash() {
        saveAllWindows()
        if let path = editor.path, store.summary(for: path)?.isTrashed == true { selection = nil }
        let count = store.notes.count(where: \.isTrashed)
        do {
            try store.emptyTrash()
            toasts.show(count == 1 ? "Deleted 1 note" : "Deleted \(count) notes", systemImage: "trash")
        } catch {
            store.report(error)
        }
    }

    func move(_ paths: [String], to folder: String, announce: Bool = true) {
        var moved: [(from: String, to: String)] = []
        for path in paths {
            let isOpen = editor.path == path
            let path = savedPath(path)
            guard store.summary(for: path) != nil else { continue }
            do {
                let newPath = try store.moveNote(path, to: folder)
                guard newPath != path else { continue }
                moved.append((path, newPath))
                if isOpen {
                    editor.follow(movedTo: newPath)
                    selection = newPath
                }
            } catch {
                store.report(error)
            }
        }
        guard !moved.isEmpty, announce else { return }
        let what = moved.count == 1 ? "“\(store.summary(for: moved[0].to)?.displayTitle ?? "")”" : "\(moved.count) notes"
        toasts.show("Moved \(what) to \(Self.folderName(folder))", systemImage: "folder", actionTitle: "Undo") { [weak self] in
            guard let self else { return }
            for item in moved {
                self.move([item.to], to: (item.from as NSString).deletingLastPathComponent, announce: false)
            }
        }
    }

    static func folderName(_ folder: String) -> String {
        folder.isEmpty ? "Notes" : "“\((folder as NSString).lastPathComponent)”"
    }

    // MARK: Commands for the open note

    func togglePinOpenNote() {
        if let path = editor.path { togglePin(path) }
    }

    func deleteOpenNote() {
        if let path = editor.path ?? selection { delete(path) }
    }

    func copyOpenNote() {
        guard editor.path != nil else { return }
        editor.flush()
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(editor.text, forType: .string)
        #else
        UIPasteboard.general.string = editor.text
        #endif
        toasts.show("Copied as Markdown", systemImage: "doc.on.doc", style: .success)
    }

    /// The open note's file, after saving it.
    func savedOpenNoteURL() -> URL? {
        editor.flush()
        guard let path = editor.path, let root = store.rootURL else { return nil }
        return root.appendingPathComponent(path)
    }

    #if os(macOS)
    func showOpenNoteInFinder() {
        editor.flush()
        guard let path = editor.path, let root = store.rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(path)])
    }
    #endif

    /// Opens the next (`1`) or previous (`-1`) note in the list.
    func selectAdjacent(_ step: Int) {
        let notes = visibleNotes
        guard !notes.isEmpty else { return }
        guard let current = selection, let index = notes.firstIndex(where: { $0.path == current }) else {
            selection = (step > 0 ? notes.first : notes.last)?.path
            return
        }
        let target = index + step
        guard notes.indices.contains(target) else { return }
        selection = notes[target].path
    }

    /// Puts the cursor in the search field, optionally with a search typed in.
    func requestSearch(_ text: String? = nil) {
        if sidebar == nil { sidebar = .all }
        if isCompact { selection = nil }
        if let text { searchText = text }
        searchRequest += 1
    }

    /// Carries out a request from a global hotkey, Siri, Spotlight or Shortcuts.
    func handle(_ action: AppAction) {
        switch action {
        case .newNote(let text):
            newNote(body: text ?? "")
        case .search(let text):
            requestSearch(text)
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
        saveAllWindows()
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
        saveAllWindows()
        if let open = editor.path, open.hasPrefix(path + "/") { selection = nil }
        if case .folder(let current)? = sidebar, current == path || current.hasPrefix(path + "/") { sidebar = .all }
        do {
            let trashed = try store.deleteFolder(path)
            let name = (path as NSString).lastPathComponent
            let detail = switch trashed.count {
            case 0: ""
            case 1: ". Its note is in Recently Deleted"
            default: ". Its \(trashed.count) notes are in Recently Deleted"
            }
            toasts.show("Deleted “\(name)”\(detail)", systemImage: "folder.badge.minus", actionTitle: "Undo") { [weak self] in
                self?.undoDeleteFolder(path, trashed: trashed)
            }
        } catch {
            store.report(error)
        }
    }

    private func undoDeleteFolder(_ path: String, trashed: [String]) {
        do {
            if trashed.isEmpty {
                try store.createFolder(named: (path as NSString).lastPathComponent, in: (path as NSString).deletingLastPathComponent)
            }
            for note in trashed { try store.restoreNote(note) }
            sidebar = .folder(path)
        } catch {
            store.report(error)
        }
    }

    /// Keeps the selection valid after the notes changed: follows a note or folder another window
    /// moved or renamed, and lets go of one that's gone.
    /// Switches the open note between text mode and Markdown editing.
    func toggleMarkdownEditing() {
        guard editor.path != nil, !editor.isReadOnly else { return }
        let on = !editor.showsMarkdown
        do {
            try editor.setShowsMarkdown(on)
            toasts.show(on ? "Editing as Markdown" : "Editing as text", systemImage: on ? "number" : "textformat")
        } catch {
            toasts.show("Couldn't change how this note is edited: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill", style: .error)
        }
    }

    /// Sync Now (menu, ⌘R, the Mac toolbar, pull to refresh on iPhone and iPad).
    func syncNow() async {
        let status = await store.syncNow()
        let (message, icon): (String, String) = switch status {
        case let s where s.location == .local:
            ("Notes are stored on this device, not in iCloud", "icloud.slash")
        case let s where s.uploading > 0 && s.downloading > 0:
            ("Synced. iCloud is still uploading \(Self.notes(s.uploading)) and downloading \(Self.notes(s.downloading)).", "icloud.and.arrow.up")
        case let s where s.uploading > 0:
            ("Synced. iCloud is still uploading \(Self.notes(s.uploading)) from this device.", "icloud.and.arrow.up")
        case let s where s.downloading > 0:
            ("Synced. iCloud is still downloading \(Self.notes(s.downloading)).", "icloud.and.arrow.down")
        default:
            ("Up to date with iCloud", "checkmark.icloud")
        }
        toasts.show(message, systemImage: icon)
    }

    private static func notes(_ count: Int) -> String { count == 1 ? "1 note" : "\(count) notes" }

    /// The search index caught up (notes are listed before they're indexed): look up an open search again.
    func indexChanged() {
        if searchResults != nil { searchRefresh += 1 }
    }

    func notesChanged() {
        if let open = editor.path, store.summary(for: open) == nil {
            if let moved = store.currentPath(for: open), !NoteStore.isTrashed(moved), store.summary(for: moved) != nil {
                editor.follow(movedTo: moved)
                if selection == open { selection = moved }
            } else if selection == open {
                selection = nil
            }
        }
        if case .folder(let folder)? = sidebar, !store.folders.contains(folder) {
            if let renamed = store.currentFolder(for: folder), store.folders.contains(renamed) {
                sidebar = .folder(renamed)
            } else {
                sidebar = .all
            }
        }
        if let results = searchResults {
            searchResults = results.map { store.summary(for: $0) == nil ? store.currentPath(for: $0) ?? $0 : $0 }
            searchRefresh += 1
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
        #if os(iOS)
        if let route = LaunchOptions.settingsRoute { settingsRoute = route }
        #endif
        if LaunchOptions.showNewProfile { showNewProfile = true }
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
