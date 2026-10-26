import Foundation

/// The welcome note created on first launch, and the demo notes used for screenshots.
enum SampleNotes {
    static let welcome = """
        # Welcome to Inkwell

        Every note is a plain **Markdown** file, so your notes stay yours: open them in any editor, `grep` them, or keep them in git.

        ## The basics
        - The first line of a note is its title
        - Tag anything, anywhere: #inkwell #ideas
        - Links work too: https://commonmark.org

        ## Checklists
        - [x] Open Inkwell
        - [ ] Tap a box to tick it off
        - [ ] Press Return to keep a list going, twice to end it

        ## Code
        ```swift
        let greeting = "Hello, notes"
        print(greeting) // prints once
        ```

        > Format from the keyboard: ⌘B bold, ⌘I italic, ⌘⇧L checklist, ⌘] indent.
        """

    static func write(to root: URL) {
        let now = Date()
        let notes: [(path: String, age: TimeInterval, text: String)] = [
            ("Welcome to Inkwell.md", 60, welcome),
            ("Work/API design.md", 3600 * 2, """
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
            ("Work/Standup.md", 3600 * 26, """
                Standup
                **Yesterday:** shipped the importer, fixed the *flaky* test
                **Today:** review [the sync PR](https://github.com) and pair on search
                ~~Blocked on design~~ unblocked #work
                """),
            ("Personal/Groceries.md", 3600 * 50, """
                Groceries
                - [ ] Oat milk
                - [x] Coffee beans
                - [ ] Lemons
                - [ ] Parmesan
                """),
            ("Personal/Trip ideas.md", 3600 * 24 * 9, """
                # Trip ideas
                > Somewhere with mountains and good bread.

                - Lisbon in spring #travel
                - Kyoto, but not in peak season
                - Drive the coast road
                """),
            ("Snippets/zsh.md", 3600 * 24 * 40, """
                # zsh
                ```bash
                # find big files
                du -sh * | sort -h | tail -20
                git log --oneline --graph --all
                ```
                #snippets
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
