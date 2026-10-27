import Foundation
import Observation

/// The note open in a window's editor: loads it, autosaves edits shortly after typing pauses,
/// follows renames, and reloads it when the file changes on disk.
@MainActor @Observable
public final class EditorModel {
    public let store: NoteStore
    public private(set) var path: String?
    /// The text as last typed. Not observed: views redraw on `revision`, not on every keystroke.
    @ObservationIgnored public private(set) var text = ""
    /// Changes whenever `text` is replaced by something other than typing in the editor
    /// (another note opened, the file changed on disk), so the text view knows to reload.
    public private(set) var revision = 0
    /// True when the latest `revision` reloaded the same note (changed on disk), so the text view
    /// should keep the cursor and scroll position rather than start at the top.
    @ObservationIgnored public private(set) var revisionIsReload = false
    /// The cursor and how far the note is scrolled, kept up to date by the text view, so a view
    /// made afresh for the same note (the window redrawn in a new theme) picks up where it was.
    @ObservationIgnored public var selection = NSRange(location: 0, length: 0)
    @ObservationIgnored public var scrollOffset: Double = 0
    /// Set when the editor should take keyboard focus (a new note); the editor clears it with
    /// `takeFocusRequest()` once it has focused, however many times its view is recreated meanwhile.
    public private(set) var wantsFocus = false
    public private(set) var isDirty = false
    /// The open note is edited as Markdown, with its syntax showing, instead of in text mode.
    public private(set) var showsMarkdown = false

    /// Called when saving renamed the file, with the new path.
    @ObservationIgnored public var onPathChange: ((String) -> Void)?
    @ObservationIgnored public var saveDelay: Duration = .milliseconds(700)
    @ObservationIgnored private var knownModified: Date?
    /// The note's text as last read from or written to disk, to notice edits made elsewhere.
    @ObservationIgnored private var knownBody: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init(store: NoteStore) {
        self.store = store
    }

    /// Notes in Recently Deleted can be read but not edited.
    public var isReadOnly: Bool {
        guard let path else { return true }
        return NoteStore.isTrashed(path)
    }

    /// Opens another note, saving the current one first. A note left empty is discarded, the way
    /// Apple Notes does it.
    public func open(_ newPath: String?, focus: Bool = false) {
        if newPath == path {
            if focus { wantsFocus = true }
            return
        }
        // Saving may rename the file; don't report that, since we're leaving the note anyway.
        saveTask?.cancel()
        if isDirty { save(notify: false) }
        discardIfEmpty()
        path = newPath
        load()
        wantsFocus = focus
    }

    /// Saves and closes the note (the window is closing or showing another profile), discarding it
    /// if it was left empty.
    public func close() {
        open(nil)
    }

    /// Deletes the open note if the file is truly empty: no text, and no front matter (a pinned
    /// or tagged note, or a template, is kept).
    private func discardIfEmpty() {
        guard let path, !NoteStore.isTrashed(path), store.summary(for: path) != nil,
              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let file = try? store.readNote(path), file.frontMatter.isEmpty,
              file.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? store.deleteNotePermanently(path)
    }

    /// Switches the open note between text mode and Markdown editing, saving the choice in its file.
    public func setShowsMarkdown(_ on: Bool) throws {
        guard let path, !isReadOnly, on != showsMarkdown else { return }
        flush()
        try store.setMarkdownEditing(on, for: self.path ?? path)
        showsMarkdown = on
    }

    /// Returns true (once) if the editor should take focus now.
    public func takeFocusRequest() -> Bool {
        guard wantsFocus else { return false }
        wantsFocus = false
        return true
    }

    /// Called by the text view on every edit.
    public func update(text newText: String) {
        guard newText != text, !isReadOnly else { return }
        text = newText
        isDirty = true
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Saves now if there are unsaved edits.
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        if isDirty { save() }
    }

    /// Reloads the note if its file changed on disk (an edit from another device or app) and
    /// there are no unsaved edits here. Returns true if the text changed.
    @discardableResult
    public func reloadIfChangedOnDisk() -> Bool {
        guard let path, !isDirty, let summary = store.summary(for: path), summary.modified != knownModified,
              let file = try? store.readNote(path) else { return false }
        knownModified = summary.modified
        knownBody = file.body
        showsMarkdown = NoteStore.editsAsMarkdown(file)
        guard file.body != text else { return false }
        text = file.body
        revisionIsReload = true
        revision += 1
        return true
    }

    private func load() {
        saveTask?.cancel()
        isDirty = false
        showsMarkdown = false
        if let path, let file = try? store.readNote(path) {
            text = file.body
            showsMarkdown = NoteStore.editsAsMarkdown(file)
            knownBody = file.body
            knownModified = store.summary(for: path)?.modified
        } else {
            text = ""
            knownBody = nil
            knownModified = nil
        }
        revisionIsReload = false
        selection = NSRange(location: 0, length: 0)
        scrollOffset = 0
        revision += 1
    }

    private func save(notify: Bool = true) {
        guard var path, isDirty, !isReadOnly else {
            isDirty = false
            return
        }
        do {
            let newPath: String
            if store.summary(for: path) == nil, !store.fileExists(path) {
                if let moved = store.currentPath(for: path), !NoteStore.isTrashed(moved), store.fileExists(moved) {
                    // Another window moved or renamed it: save it there.
                    path = moved
                    newPath = try store.saveNote(moved, body: text, base: knownBody)
                } else {
                    // Deleted (or moved away) elsewhere while there were unsaved edits: keep them
                    // as a new note rather than lose them.
                    let folder = (path as NSString).deletingLastPathComponent
                    newPath = try store.createNote(in: store.folders.contains(folder) ? folder : "", body: text)
                    let title = NoteText.title(of: text)
                    store.post(.savedAsNewNote(title: title.isEmpty ? "Untitled" : title))
                }
            } else {
                newPath = try store.saveNote(path, body: text, base: knownBody)
            }
            isDirty = false
            knownBody = text
            knownModified = store.summary(for: newPath)?.modified
            if newPath != self.path {
                self.path = newPath
                if notify { onPathChange?(newPath) }
            }
        } catch {
            store.report(error)
        }
    }

    /// Points the editor at the note's new path after it was moved without reloading the text.
    public func follow(movedTo newPath: String) {
        guard path != newPath else { return }
        path = newPath
        knownModified = store.summary(for: newPath)?.modified
    }
}
