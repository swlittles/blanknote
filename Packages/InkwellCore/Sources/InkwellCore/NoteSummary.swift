import Foundation

/// What the note list and sidebar need to know about a note, without its full text.
public struct NoteSummary: Identifiable, Hashable, Sendable {
    /// Path relative to the notes folder, e.g. `Work/API design.md`. This is the note's identity.
    public var path: String
    public var title: String
    public var preview: String
    public var tags: [String]
    public var pinned: Bool
    public var created: Date
    public var modified: Date

    public init(path: String, title: String, preview: String, tags: [String], pinned: Bool, created: Date, modified: Date) {
        self.path = path
        self.title = title
        self.preview = preview
        self.tags = tags
        self.pinned = pinned
        self.created = created
        self.modified = modified
    }

    public init(path: String, file: NoteFile, created: Date, modified: Date) {
        var tags = file.frontMatter.list("tags")
        var seen = Set(tags.map { $0.lowercased() })
        for tag in NoteText.inlineTags(in: file.body) where seen.insert(tag.lowercased()).inserted {
            tags.append(tag)
        }
        self.init(
            path: path,
            title: NoteText.title(of: file.body),
            preview: NoteText.preview(of: file.body),
            tags: tags,
            pinned: file.frontMatter.bool("pinned"),
            created: created,
            modified: modified
        )
    }

    public var id: String { path }

    /// The folder holding the note, relative to the notes folder; `""` for the top level.
    public var folder: String { (path as NSString).deletingLastPathComponent }

    public var isTrashed: Bool { path.hasPrefix(NoteFileSystem.trashFolder + "/") }

    public var displayTitle: String { title.isEmpty ? "New Note" : title }
}
