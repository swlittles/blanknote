import Foundation
import Testing
@testable import InkwellCore

@MainActor
struct NoteStoreTests {
    private let root: URL
    private let indexURL: URL

    init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-\(UUID().uuidString)")
        root = base.appendingPathComponent("Notes")
        indexURL = base.appendingPathComponent("index.sqlite")
    }

    private func makeStore() async -> NoteStore {
        let store = NoteStore(options: .init(root: root, indexURL: indexURL, useICloud: false, watchForChanges: false))
        await store.start()
        return store
    }

    private func contents(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func createSaveRenameAndReload() async throws {
        let store = await makeStore()
        let path = try store.createNote(in: "")
        #expect(path == "Untitled.md")

        let renamed = try store.saveNote(path, body: "# Shopping list\n- milk")
        #expect(renamed == "Shopping list.md")
        #expect(try contents(renamed) == "# Shopping list\n- milk")
        #expect(store.summary(for: path) == nil)
        #expect(store.summary(for: renamed)?.title == "Shopping list")

        // A second note with the same title gets a number, and keeps it.
        let other = try store.createNote(in: "", body: "Shopping list")
        #expect(other == "Shopping list 2.md")
        #expect(try store.saveNote(other, body: "Shopping list\nmore") == other)

        // Case-only title changes rename the file too.
        #expect(try store.saveNote(renamed, body: "# shopping List") == "shopping List.md")

        // A fresh store finds the same notes and can search them.
        let reopened = await makeStore()
        #expect(Set(reopened.notes.map(\.path)) == ["shopping List.md", "Shopping list 2.md"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await reopened.search("more") == ["Shopping list 2.md"])
    }

    @Test func pinningWritesFrontMatterAndKeepsBody() async throws {
        let store = await makeStore()
        let path = try store.createNote(in: "", body: "Pinned note\ntext")
        try store.setPinned(true, for: path)
        #expect(try contents(path) == "---\npinned: true\n---\nPinned note\ntext")
        #expect(store.summary(for: path)?.pinned == true)
        _ = try store.saveNote(path, body: "Pinned note\nedited")
        #expect(try contents(path) == "---\npinned: true\n---\nPinned note\nedited")
        try store.setPinned(false, for: path)
        #expect(try contents(path) == "Pinned note\nedited")
    }

    @Test func trashAndRestore() async throws {
        let store = await makeStore()
        try store.createFolder(named: "Work")
        let path = try store.createNote(in: "Work", body: "Plan")
        let trashed = try store.trashNote(path)
        #expect(trashed == ".trash/Plan.md")
        #expect(store.summary(for: trashed)?.isTrashed == true)

        // Trashed notes keep their file name when edited.
        #expect(try store.saveNote(trashed, body: "Different title") == trashed)

        let restored = try store.restoreNote(trashed)
        #expect(restored == "Work/Plan.md")
        #expect(try contents(restored) == "Different title")

        try store.trashNote(restored)
        try store.emptyTrash()
        #expect(store.notes.isEmpty)
    }

    @Test func foldersMoveRenameDelete() async throws {
        let store = await makeStore()
        let work = try store.createFolder(named: "Work")
        #expect(try store.createFolder(named: "Work") == "Work 2")
        let sub = try store.createFolder(named: "API", in: work)
        let note = try store.createNote(in: "", body: "Design")
        let moved = try store.moveNote(note, to: sub)
        #expect(moved == "Work/API/Design.md")

        let renamed = try await store.renameFolder(work, to: "Job")
        #expect(renamed == "Job")
        #expect(store.summary(for: "Job/API/Design.md") != nil)
        #expect(store.folders.contains("Job/API"))
        #expect(!store.folders.contains("Work"))

        try store.deleteFolder("Job")
        #expect(store.summary(for: ".trash/Design.md") != nil)
        #expect(!store.folders.contains("Job/API"))
    }

    @Test func reconcilePicksUpOutsideChanges() async throws {
        let store = await makeStore()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Ideas"), withIntermediateDirectories: true)
        try "From VS Code\n#ext".write(to: root.appendingPathComponent("Ideas/outside.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.appendingPathComponent("Ideas/readme.txt"), atomically: true, encoding: .utf8)
        await store.reconcile()
        #expect(store.notes.map(\.path) == ["Ideas/outside.md"])
        #expect(store.folders == ["Ideas"])
        #expect(store.tagCounts.map(\.tag) == ["ext"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("Ideas/outside.md"))
        await store.reconcile()
        #expect(store.notes.isEmpty)
    }

    @Test func editorAutosavesFollowsRenamesAndDiscardsEmptyNotes() async throws {
        let store = await makeStore()
        let editor = EditorModel(store: store)
        editor.saveDelay = .milliseconds(10)
        var followed: String?
        editor.onPathChange = { followed = $0 }

        let first = try store.createNote(in: "")
        editor.open(first)
        editor.update(text: "Meeting notes\n- agenda")
        try await Task.sleep(for: .milliseconds(150))
        #expect(followed == "Meeting notes.md")
        #expect(editor.path == "Meeting notes.md")
        #expect(!editor.isDirty)

        // Leaving a note saves it, but a rename on the way out isn't reported: reporting it would
        // re-select the note being left.
        followed = nil
        editor.update(text: "Retitled\n- agenda")
        editor.open(nil)
        #expect(followed == nil)
        #expect(store.summary(for: "Retitled.md") != nil)
        editor.open("Retitled.md")
        editor.update(text: "Meeting notes\n- agenda")
        editor.flush()
        #expect(followed == "Meeting notes.md")

        // An empty note is thrown away when you move on.
        let empty = try store.createNote(in: "")
        editor.open(empty)
        editor.open("Meeting notes.md")
        #expect(store.summary(for: empty) == nil)

        // Outside edits reload when there are no unsaved changes.
        try "Meeting notes\nchanged elsewhere".write(to: root.appendingPathComponent("Meeting notes.md"), atomically: true, encoding: .utf8)
        await store.reconcile()
        let revision = editor.revision
        editor.reloadIfChangedOnDisk()
        #expect(editor.text == "Meeting notes\nchanged elsewhere")
        #expect(editor.revision == revision + 1)
    }
}
