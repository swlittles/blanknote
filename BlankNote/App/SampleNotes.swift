import Foundation

/// The welcome note created on first launch, and the demo notes used for screenshots.
enum SampleNotes {
    static let welcome = """
        # Welcome to BlankNote

        Every note is a plain **Markdown** file, so your notes stay yours: open them in any editor, `grep` them, or keep them in git.

        ## The basics
        - The first line of a note is its title
        - Tag anything, anywhere: #blanknote #ideas
        - Links work too: https://commonmark.org

        ## Checklists
        - [x] Open BlankNote
        - [ ] Tap a box to tick it off
        - [ ] Press Return to keep a list going, twice to end it

        ## Code
        ```swift
        let greeting = "Hello, notes"
        print(greeting) // prints once
        ```

        > Format from the keyboard: ⌘B bold, ⌘I italic, ⌘⇧L checklist, ⌘] indent.
        """

    /// Three sample profiles with notes: Personal (Claude), Acme Corp (Ocean) and Side Project (Forest).
    static func write(to root: URL) {
        let now = Date()
        let profiles: [(folder: String, order: Int, accent: String, tints: Bool)] = [
            ("Personal", 0, "#D97757", false),
            ("Acme Corp", 1, "#3B7FC4", true),
            ("Side Project", 2, "#4F8A4B", true),
        ]
        for profile in profiles {
            let json = """
                {
                  "created" : "2026-10-01T09:00:00Z",
                  "id" : "\(UUID().uuidString)",
                  "name" : "\(profile.folder)",
                  "order" : \(profile.order),
                  "theme" : { "accent" : "\(profile.accent)", "tintsBackground" : \(profile.tints) }
                }
                """
            let url = root.appendingPathComponent(profile.folder).appendingPathComponent(".blanknote-profile.json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? json.write(to: url, atomically: true, encoding: .utf8)
        }

        let notes: [(path: String, age: TimeInterval, text: String)] = [
            ("Personal/Welcome to BlankNote.md", 60, welcome),
            ("Personal/Groceries.md", 3600 * 50, """
                Groceries
                - [ ] Oat milk
                - [x] Coffee beans
                - [ ] Lemons
                - [ ] Parmesan
                """),
            ("Personal/Travel/Trip ideas.md", 3600 * 24 * 9, """
                # Trip ideas
                > Somewhere with mountains and good bread.

                - Lisbon in spring #travel
                - Kyoto, but not in peak season
                - Drive the coast road
                """),
            ("Personal/Snippets/zsh.md", 3600 * 24 * 40, """
                # zsh
                ```bash
                # find big files
                du -sh * | sort -h | tail -20
                git log --oneline --graph --all
                ```
                #snippets
                """),
            ("Acme Corp/Engineering/API design.md", 3600 * 2, """
                ---
                pinned: true
                ---
                # API design
                Notes for the v2 sync endpoint. #work #api

                ## Endpoints
                1. `GET /notes?since=<cursor>` returns changes
                2. `PUT /notes/:id` with an `If-Match` header

                ## Open questions
                - [ ] Do we paginate deletes?
                - [x] Cursor format: opaque base64
                - [ ] Rate limits per device or per account?

                ```ts
                export async function pull(cursor: string) {
                  const res = await fetch(`/notes?since=${cursor}`)
                  return res.json() // { notes, next }
                }
                ```
                """),
            ("Acme Corp/Standup.md", 3600 * 26, """
                Standup
                **Yesterday:** shipped the importer, fixed the *flaky* test
                **Today:** review [the sync PR](https://github.com) and pair on search
                ~~Blocked on design~~ unblocked #work
                """),
            ("Acme Corp/Q4 planning.md", 3600 * 24 * 3, """
                # Q4 planning
                - [ ] Hire two backend engineers #hiring
                - [ ] Ship offline mode
                - [x] Retire the v1 API
                """),
            ("Side Project/Launch checklist.md", 3600 * 5, """
                # Launch checklist
                - [x] Landing page
                - [ ] Pricing #launch
                - [ ] App Store screenshots
                """),
            ("Side Project/Ideas.md", 3600 * 24 * 12, """
                Ideas
                A tiny CLI that turns notes into a static site. #ideas
                """),
        ]
        for note in notes {
            let url = root.appendingPathComponent(note.path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? note.text.write(to: url, atomically: true, encoding: .utf8)
            let date = now.addingTimeInterval(-note.age)
            try? FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
        }
    }
}
