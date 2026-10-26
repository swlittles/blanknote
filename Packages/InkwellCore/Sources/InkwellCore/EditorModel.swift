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
    /// Set when the editor should take keyboard focus (a new note); the editor clears it with
    /// `takeFocusRequest()` once it has focused, however many times its view is recreated meanwhile.
    public private(set) var wantsFocus = false
    public private(set) var isDirty = false

    /// Called when saving renamed the file, with the new path.
    @ObservationIgnored public var onPathChange: ((String) -> Void)?
    @ObservationIgnored public var saveDelay: Duration = .milliseconds(700)
    @ObservationIgnored private var knownModified: Date?
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
        if let previous = path, !NoteStore.isTrashed(previous), store.summary(for: previous) != nil,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? store.deleteNotePermanently(previous)
        }
        path = newPath
        load()
        wantsFocus = focus
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
        guard file.body != text else { return false }
        text = file.body
        revision += 1
        return true
    }

    private func load() {
        saveTask?.cancel()
        isDirty = false
        if let path, let file = try? store.readNote(path) {
            text = file.body
            knownModified = store.summary(for: path)?.modified
        } else {
            text = ""
            knownModified = nil
        }
        revision += 1
    }

    private func save(notify: Bool = true) {
        // A note that was moved or deleted under us must not be recreated at its old path.
        guard let path, isDirty, !isReadOnly, store.summary(for: path) != nil else {
            isDirty = false
            return
        }
        do {
            let newPath = try store.saveNote(path, body: text)
            isDirty = false
            knownModified = store.summary(for: newPath)?.modified
            if newPath != path {
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
