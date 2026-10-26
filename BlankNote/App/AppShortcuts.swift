import AppIntents

/// App Shortcuts: how you start BlankNote from outside the app on iPhone and iPad (Siri, Spotlight,
/// the Action Button, Back Tap, the Shortcuts app), and on the Mac from Shortcuts and Spotlight.

struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Opens BlankNote with a new note, optionally starting with some text.")
    static let openAppWhenRun = true

    @Parameter(title: "Text", description: "What the note starts with.")
    var text: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        ActionRouter.shared.post(.newNote(text: text))
        return .result()
    }
}

struct SearchNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Notes"
    static let description = IntentDescription("Opens BlankNote's search, optionally with a search already typed.")
    static let openAppWhenRun = true

    @Parameter(title: "Search For")
    var query: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        ActionRouter.shared.post(.search(query))
        return .result()
    }
}

struct BlankNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: ["New note in \(.applicationName)", "Start an \(.applicationName) note", "Create a note in \(.applicationName)"],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: SearchNotesIntent(),
            phrases: ["Search \(.applicationName)", "Search my \(.applicationName) notes"],
            shortTitle: "Search Notes",
            systemImageName: "magnifyingglass"
        )
    }
}
