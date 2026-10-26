import Foundation
import Testing
@testable import BlankNoteCore

@MainActor
struct ProfileStoreTests {
    private let container: URL
    private let defaults: UserDefaults

    init() {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "profiles-\(UUID().uuidString)")!
    }

    private func makeStore() async -> ProfileStore {
        let store = ProfileStore(container: container, defaults: defaults)
        await store.start()
        return store
    }

    private func write(_ text: String, to path: String) throws {
        let url = container.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: container.appendingPathComponent(path).path)
    }

    @Test func firstLaunchMovesExistingNotesIntoPersonal() async throws {
        // The layout from before profiles: notes and folders straight in the container.
        try write("Groceries", to: "Groceries.md")
        try write("Plan", to: "Work/Plan.md")
        try write("Old", to: ".trash/Old.md")
        let store = await makeStore()

        #expect(store.profiles.map(\.name) == ["Personal"])
        #expect(store.active?.name == "Personal")
        #expect(store.active?.theme == .claude)
        #expect(exists("Personal/Groceries.md"))
        #expect(exists("Personal/Work/Plan.md"))
        #expect(exists("Personal/.trash/Old.md"))
        #expect(exists("Personal/\(ProfileStore.metadataFile)"))
        #expect(!exists("Groceries.md"))

        // Nothing moves again on the next launch, and Personal's folders aren't profiles.
        let reopened = await makeStore()
        #expect(reopened.profiles.map(\.name) == ["Personal"])
        #expect(reopened.profiles.first?.id == store.profiles.first?.id)
    }

    @Test func aNoteFolderNamedPersonalDoesNotCollide() async throws {
        try write("Diary", to: "Personal/Diary.md")
        let store = await makeStore()
        #expect(store.profiles.first?.folderName == "Personal 2")
        #expect(exists("Personal 2/Personal/Diary.md"))
    }

    @Test func createRenameRecolorReorderDelete() async throws {
        let store = await makeStore()
        let acme = try store.create(name: "  Acme Corp ", theme: ProfileTheme(accent: 0x3B7FC4))
        #expect(acme.name == "Acme Corp")
        #expect(acme.folderName == "Acme Corp")
        let second = try store.create(name: "acme corp", theme: .claude)
        #expect(second.folderName == "acme corp 2", "folder names are unique ignoring case")
        #expect(store.profiles.map(\.name) == ["Personal", "Acme Corp", "acme corp"])

        try store.rename(second.id, to: "Company2")
        #expect(exists("Company2/\(ProfileStore.metadataFile)"))
        #expect(!exists("acme corp 2"))
        try store.rename(acme.id, to: "ACME Corp")
        #expect(store.profiles.first { $0.id == acme.id }?.folderName == "ACME Corp", "case-only renames rename the folder")

        try store.setTheme(ProfileTheme(accent: 0x4F8A4B, tintsBackground: false), for: acme.id)
        try store.reorder([second.id, acme.id])
        #expect(store.profiles.map(\.name) == ["Company2", "ACME Corp", "Personal"])

        store.activate(second.id)
        #expect(store.neighbor(1)?.name == "ACME Corp")
        #expect(store.neighbor(-1)?.name == "Personal", "wraps around")

        // A fresh store reads everything back from the files, active profile included.
        let reopened = await makeStore()
        #expect(reopened.profiles.map(\.name) == ["Company2", "ACME Corp", "Personal"])
        #expect(reopened.profiles[1].theme == ProfileTheme(accent: 0x4F8A4B, tintsBackground: false))
        #expect(reopened.active?.name == "Company2")

        // Deleting keeps the notes in a hidden folder and moves to another profile.
        try write("Secret", to: "Company2/Secret.md")
        try reopened.delete(second.id)
        #expect(reopened.profiles.map(\.name) == ["ACME Corp", "Personal"])
        #expect(reopened.active?.name == "ACME Corp")
        let deleted = try FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent(ProfileStore.deletedFolder).path)
        #expect(deleted.count == 1 && deleted[0].hasPrefix("Company2 "))
        try reopened.delete(acme.id)
        #expect(throws: ProfileStore.ProfileError.self) { try reopened.delete(reopened.profiles[0].id) }
    }

    @Test func foldersAddedOutsideTheAppBecomeProfiles() async throws {
        let store = await makeStore()
        try FileManager.default.createDirectory(at: container.appendingPathComponent("Side Project"), withIntermediateDirectories: true)
        store.refresh()
        let side = try #require(store.profiles.first { $0.name == "Side Project" })
        #expect(side.theme != .claude, "a new profile gets a theme no other profile uses")
        #expect(exists("Side Project/\(ProfileStore.metadataFile)"))
    }

    @Test func profilesNotYetDownloadedStillShow() async throws {
        let store = await makeStore()
        try write("", to: "Laptop/.\(ProfileStore.metadataFile).icloud")
        store.refresh()
        #expect(store.profiles.contains { $0.name == "Laptop" })
        #expect(ProfileStore.placeholderID(for: "Laptop") == ProfileStore.placeholderID(for: "Laptop"))
    }

    @Test func unreadableOrPendingSettingsAreNotOverwritten() async throws {
        let store = await makeStore()
        try write(#"{"accent":"coral","name":"Work"}"#, to: "Work/\(ProfileStore.metadataFile)")
        try write("", to: "Laptop/.\(ProfileStore.metadataFile).icloud")
        store.refresh()
        #expect(store.profiles.map(\.name).sorted() == ["Laptop", "Personal", "Work"])
        try store.reorder(store.profiles.map(\.id).reversed())
        #expect(try String(contentsOf: container.appendingPathComponent("Work/\(ProfileStore.metadataFile)"), encoding: .utf8).contains("coral"))
        #expect(!exists("Laptop/\(ProfileStore.metadataFile)"))
        let laptop = try #require(store.profiles.first { $0.name == "Laptop" })
        #expect(throws: ProfileStore.ProfileError.self) { try store.setTheme(ProfileTheme(accent: 0x3B7FC4), for: laptop.id) }
    }

    @Test func anInterruptedFirstMoveIsFinishedNextTime() async throws {
        try write("Groceries", to: "Groceries.md")
        try write("Plan", to: "Work/Plan.md")
        // As if the app stopped after making the profile but before moving anything.
        try write("Personal", to: ProfileStore.migrationMarker)
        try write(##"{"id":"\##(UUID().uuidString)","name":"Personal","theme":{"accent":"#D97757"},"order":0,"created":"2026-01-01T00:00:00Z"}"##,
                  to: "Personal/\(ProfileStore.metadataFile)")
        let store = await makeStore()
        #expect(store.profiles.map(\.name) == ["Personal"], "Work is a note folder, not a profile")
        #expect(exists("Personal/Groceries.md"))
        #expect(exists("Personal/Work/Plan.md"))
        #expect(!exists(ProfileStore.migrationMarker))
    }

    @Test func notesInAProfileStayInIt() async throws {
        let profiles = await makeStore()
        let work = try profiles.create(name: "Work", theme: .claude)
        let personalNotes = NoteStore(options: .init(root: profiles.folderURL(for: profiles.profiles[0]),
                                                     indexURL: container.appendingPathComponent("p.sqlite"), useICloud: false, watchForChanges: false))
        let workNotes = NoteStore(options: .init(root: profiles.folderURL(for: work),
                                                 indexURL: container.appendingPathComponent("w.sqlite"), useICloud: false, watchForChanges: false))
        await personalNotes.start()
        await workNotes.start()
        try workNotes.createNote(in: "", body: "Quarterly plan #q4")
        await personalNotes.reconcile()
        #expect(personalNotes.notes.isEmpty)
        #expect(workNotes.notes.map(\.title) == ["Quarterly plan #q4"])
        #expect(workNotes.tagCounts.map(\.tag) == ["q4"])
    }
}

struct ProfileThemeTests {
    @Test func savedAsReadableHex() throws {
        let data = try JSONEncoder().encode(ProfileTheme(accent: 0x3B7FC4))
        #expect(String(decoding: data, as: UTF8.self).contains("\"#3B7FC4\""))
        #expect(try JSONDecoder().decode(ProfileTheme.self, from: Data(##"{"accent":"#4f8a4b"}"##.utf8)) == ProfileTheme(accent: 0x4F8A4B))
        #expect(ProfileTheme.claude.presetName == "Claude")
        #expect(ProfileTheme(accent: 0x123456).presetName == nil)
    }

    @Test func claudeKeepsTheOriginalPalette() {
        let colors = ThemeColors(.claude)
        #expect(colors.accent.light == 0xD97757)
        #expect(colors.background.dark == 0x262624)
        #expect(colors.accentText.light == 0xB9552F)
    }

    @Test(arguments: ProfileTheme.presets.map(\.theme) + [ProfileTheme(accent: 0xFFF59D), ProfileTheme(accent: 0x0B1A3A), ProfileTheme(accent: 0x000000)])
    func everyThemeStaysReadable(theme: ProfileTheme) {
        let colors = ThemeColors(theme)
        // Text-coloured accents against the backgrounds they're drawn on.
        #expect(ThemeColors.contrast(colors.accentText.light, colors.background.light) >= 4.0)
        #expect(ThemeColors.contrast(colors.accentText.dark, colors.background.dark) >= 4.0)
        // White text on a selected row.
        #expect(ThemeColors.contrast(0xFFFFFF, colors.selectedRow.light) >= 3)
        #expect(ThemeColors.contrast(0xFFFFFF, colors.selectedRow.dark) >= 3)
        // The accent is visible in dark mode.
        #expect(ThemeColors.contrast(colors.accent.dark, 0x262624) >= 2.9)
    }

    @Test func tintingFollowsTheAccent() {
        let blue = ThemeColors(ProfileTheme(accent: 0x3B7FC4))
        let plain = ThemeColors(ProfileTheme(accent: 0x3B7FC4, tintsBackground: false))
        #expect(blue.sidebar.light != 0xF0EEE6)
        #expect(blue.sidebar.light & 0xFF > blue.sidebar.light >> 16 & 0xFF, "a blue profile's sidebar leans blue")
        #expect(plain.sidebar.light == 0xF0EEE6)
        #expect(plain.background.dark == 0x262624)
    }
}
