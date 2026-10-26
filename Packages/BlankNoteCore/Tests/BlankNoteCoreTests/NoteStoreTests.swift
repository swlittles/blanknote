import Foundation
import Testing
@testable import BlankNoteCore

@MainActor
struct NoteStoreTests {
    private let root: URL
    private let indexURL: URL

    init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("blanknote-\(UUID().uuidString)")
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

    @Test func onlyTrulyEmptyNotesAreDiscarded() async throws {
        let store = await makeStore()
        let editor = EditorModel(store: store)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "---\ntags: [todo]\n---\n".write(to: root.appendingPathComponent("Template.md"), atomically: true, encoding: .utf8)
        await store.reconcile()
        editor.open("Template.md")
        editor.open(nil)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Template.md").path), "front matter isn't nothing")

        let empty = try store.createNote(in: "")
        editor.open(empty)
        editor.close()
        #expect(store.summary(for: empty) == nil)
    }

    @Test func editsToANoteDeletedElsewhereAreKept() async throws {
        let store = await makeStore()
        let editor = EditorModel(store: store)
        editor.saveDelay = .seconds(60)
        let path = try store.createNote(in: "", body: "Draft\nfirst")
        editor.open(path)
        editor.update(text: "Draft\nfirst\nsecond")
        // Another app deletes the file before the autosave.
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        await store.reconcile()
        editor.flush()
        #expect(try contents(editor.path ?? "") == "Draft\nfirst\nsecond")
        #expect(store.notices.map(\.kind) == [.savedAsNewNote(title: "Draft")])
    }

    @Test func editsFollowANoteMovedByAnotherWindow() async throws {
        let store = await makeStore()
        let editor = EditorModel(store: store)
        editor.saveDelay = .seconds(60)
        var followed: String?
        editor.onPathChange = { followed = $0 }
        let path = try store.createNote(in: "", body: "Plan\nv1")
        editor.open(path)
        editor.update(text: "Plan\nv2")
        try store.createFolder(named: "Work")
        let moved = try store.moveNote(path, to: "Work")
        editor.flush()
        #expect(followed == moved)
        #expect(try contents(moved) == "Plan\nv2")
        #expect(!store.fileExists(path))
    }

    @Test func outsideEditsWhileTypingAreKeptAsACopy() async throws {
        let store = await makeStore()
        let editor = EditorModel(store: store)
        editor.saveDelay = .seconds(60)
        let path = try store.createNote(in: "", body: "Notes\nmine")
        editor.open(path)
        // Pinning (front matter only) isn't a conflict.
        try store.setPinned(true, for: path)
        editor.update(text: "Notes\nmine, edited")
        editor.flush()
        #expect(store.notices.isEmpty)
        #expect(try contents(path) == "---\npinned: true\n---\nNotes\nmine, edited")

        // Another app changes the text while there are unsaved edits here.
        editor.update(text: "Notes\nmine, edited again")
        try "---\npinned: true\n---\nNotes\ntheirs".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        editor.flush()
        #expect(try contents(path) == "---\npinned: true\n---\nNotes\nmine, edited again")
        #expect(try contents("Notes (conflicted copy).md") == "---\npinned: true\n---\nNotes\ntheirs")
        #expect(store.notices.map(\.kind) == [.keptBothVersions(title: "Notes")])
    }

    @Test func pastedFrontMatterIsNotDuplicated() async throws {
        let store = await makeStore()
        let path = try store.createNote(in: "")
        let body = "---\nauthor: me\n---\nHello\nworld"
        let saved = try store.saveNote(path, body: body)
        #expect(saved == "Hello.md")
        #expect(try store.saveNote(saved, body: body) == saved)
        #expect(try contents(saved) == body)
    }

    @Test func otherEncodingsAndLinksSurviveSaving() async throws {
        let store = await makeStore()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Windows Latin 1, from another editor.
        try Data([0x43, 0x61, 0x66, 0xE9, 0x0A, 0x72, 0xE9, 0x73, 0x75, 0x6D, 0xE9]).write(to: root.appendingPathComponent("Cafe.md"))
        // A note linked in from elsewhere, with an old creation date.
        let outside = root.deletingLastPathComponent().appendingPathComponent("Linked target.md")
        try "Linked\nv1".write(to: outside, atomically: true, encoding: .utf8)
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked.md"), withDestinationURL: outside)
        await store.reconcile()

        #expect(store.summary(for: "Cafe.md")?.title == "Café")
        let trashed = try store.trashNote("Cafe.md")
        #expect(try store.readNote(trashed).body == "Café\nrésumé")

        #expect(try store.saveNote("Linked.md", body: "Linked\nv2") == "Linked.md")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "Linked\nv2")
        #expect((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Linked.md").path)[.type] as? FileAttributeType) == .typeSymbolicLink)
        #expect((try FileManager.default.attributesOfItem(atPath: outside.path)[.creationDate] as? Date) == created)
    }

    @Test func deletingAFolderKeepsFilesThatAreNotNotes() async throws {
        let store = await makeStore()
        let folder = try store.createFolder(named: "Work")
        let note = try store.createNote(in: folder, body: "Plan")
        try "pixels".write(to: root.appendingPathComponent("Work/pic.png"), atomically: true, encoding: .utf8)
        let trashed = try store.deleteFolder(folder)
        #expect(trashed.count == 1 && store.summary(for: note) == nil)
        #expect(!store.folders.contains(folder))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".trash/Work (deleted folder)/pic.png").path))

        // An empty folder is simply removed.
        let empty = try store.createFolder(named: "Empty")
        try store.deleteFolder(empty)
        #expect(!store.fileExists(empty))
    }

    @Test func reservedFolderNamesAreAvoided() async throws {
        let store = await makeStore()
        #expect(try store.createFolder(named: "attachments") == "attachments 2")
        let folder = try store.createFolder(named: "Pictures")
        #expect(try await store.renameFolder(folder, to: "attachments") == "attachments 3")
        await store.reconcile()
        #expect(store.folders.allSatisfy { $0 != "attachments" })
    }

    @Test func renamingAFolderUpdatesWhereDeletedNotesGoBack() async throws {
        let store = await makeStore()
        let folder = try store.createFolder(named: "Old")
        let trashed = try store.trashNote(try store.createNote(in: folder, body: "Gone"))
        let renamed = try await store.renameFolder(folder, to: "New")
        #expect(store.currentFolder(for: folder) == renamed)
        #expect(try store.restoreNote(trashed) == "New/Gone.md")
    }

    @Test func changesDuringAScanAreKept() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for number in 0..<400 {
            try "Note \(number)\n\(String(repeating: "text ", count: 200))".write(to: root.appendingPathComponent("Note \(number).md"), atomically: true, encoding: .utf8)
        }
        let store = await makeStore()
        try FileManager.default.removeItem(at: indexURL)
        let scan = Task { await store.reconcile(full: true) }
        await Task.yield()
        let note = try store.createNote(in: "", body: "Made during the scan")
        let folder = try store.createFolder(named: "Also during")
        await scan.value
        #expect(store.summary(for: note) != nil)
        #expect(store.folders.contains(folder))
        #expect(store.notes.count == 401)
    }

    @Test func aDamagedIndexIsRebuilt() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Kept\nnote".write(to: root.appendingPathComponent("Kept.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4096).write(to: indexURL)
        let store = await makeStore()
        #expect(store.notes.map(\.path) == ["Kept.md"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await store.search("note") == ["Kept.md"])
    }
}
