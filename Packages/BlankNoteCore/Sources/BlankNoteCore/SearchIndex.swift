import Foundation
import SQLite3

/// A per-device SQLite cache of every note's summary and text, with full-text search (FTS5).
///
/// It is never synced and can always be rebuilt from the files: at launch the store shows the
/// cached summaries straight away, then re-reads only the files whose modification date changed.
public actor SearchIndex {
    private static let schemaVersion: Int32 = 1
    private let db: OpaquePointer

    /// `rootIdentity` names the notes folder this cache describes. If it changes (say the notes
    /// moved from local storage to iCloud), the cache is emptied.
    public init(url: URL, rootIdentity: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw IndexError.open(url.path)
        }
        db = handle
        try Self.exec(db, "PRAGMA journal_mode=WAL")

        if try Self.userVersion(db) != Self.schemaVersion {
            try Self.exec(db, "DROP TABLE IF EXISTS notes; DROP TABLE IF EXISTS fts; DROP TABLE IF EXISTS meta")
            try Self.exec(db, """
                CREATE TABLE notes(path TEXT PRIMARY KEY, title TEXT, preview TEXT, tags TEXT,
                                   pinned INTEGER, created REAL, modified REAL);
                CREATE VIRTUAL TABLE fts USING fts5(path UNINDEXED, title, body,
                                                    tokenize='porter unicode61 remove_diacritics 2');
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
                PRAGMA user_version=\(Self.schemaVersion);
                """)
        }

        var storedRoot: String?
        try Self.query(db, "SELECT value FROM meta WHERE key='root'", []) { storedRoot = Self.text($0, 0) }
        if storedRoot != rootIdentity {
            try Self.exec(db, "DELETE FROM notes; DELETE FROM fts")
            try Self.run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('root', ?)", [.text(rootIdentity)])
        }
    }

    deinit {
        sqlite3_close(db)
    }

    public func allSummaries() -> [NoteSummary] {
        var notes: [NoteSummary] = []
        try? Self.query(db, "SELECT path, title, preview, tags, pinned, created, modified FROM notes", []) { row in
            let tags = Self.text(row, 3)
            notes.append(NoteSummary(
                path: Self.text(row, 0),
                title: Self.text(row, 1),
                preview: Self.text(row, 2),
                tags: tags.isEmpty ? [] : tags.components(separatedBy: "\u{1F}"),
                pinned: sqlite3_column_int(row, 4) != 0,
                created: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 5)),
                modified: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 6))
            ))
        }
        return notes
    }

    public func apply(upserts: [(summary: NoteSummary, body: String)], removals: [String]) {
        guard !upserts.isEmpty || !removals.isEmpty else { return }
        do {
            try Self.exec(db, "BEGIN")
            for path in removals {
                try Self.run(db, "DELETE FROM notes WHERE path=?", [.text(path)])
                try Self.run(db, "DELETE FROM fts WHERE path=?", [.text(path)])
            }
            for (note, body) in upserts {
                try Self.run(db, "INSERT OR REPLACE INTO notes(path, title, preview, tags, pinned, created, modified) VALUES(?,?,?,?,?,?,?)", [
                    .text(note.path), .text(note.title), .text(note.preview), .text(note.tags.joined(separator: "\u{1F}")),
                    .int(note.pinned ? 1 : 0), .real(note.created.timeIntervalSinceReferenceDate),
                    .real(note.modified.timeIntervalSinceReferenceDate),
                ])
                try Self.run(db, "DELETE FROM fts WHERE path=?", [.text(note.path)])
                try Self.run(db, "INSERT INTO fts(path, title, body) VALUES(?,?,?)", [.text(note.path), .text(note.title), .text(body)])
            }
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
        }
    }

    public func removeAll() {
        try? Self.exec(db, "DELETE FROM notes; DELETE FROM fts")
    }

    /// Paths of notes matching every word of `text` (as prefixes), best matches first.
    /// Title matches weigh much more than body matches.
    public func search(_ text: String, limit: Int = 300) -> [String] {
        guard let expression = Self.matchExpression(for: text) else { return [] }
        var paths: [String] = []
        try? Self.query(db, "SELECT path FROM fts WHERE fts MATCH ? ORDER BY bm25(fts, 0.0, 8.0, 1.0) LIMIT ?", [.text(expression), .int(Int64(limit))]) {
            paths.append(Self.text($0, 0))
        }
        return paths
    }

    static func matchExpression(for text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).compactMap { word -> String? in
            let cleaned = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            return cleaned.isEmpty ? nil : "\"" + cleaned.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    // MARK: SQLite helpers

    enum IndexError: Error {
        case open(String)
        case sql(String)
    }

    enum Value {
        case text(String)
        case int(Int64)
        case real(Double)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IndexError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func run(_ db: OpaquePointer, _ sql: String, _ values: [Value]) throws {
        try query(db, sql, values) { _ in }
    }

    private static func query(_ db: OpaquePointer, _ sql: String, _ values: [Value], row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw IndexError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return
            default: throw IndexError.sql(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func userVersion(_ db: OpaquePointer) throws -> Int32 {
        var version: Int32 = 0
        try query(db, "PRAGMA user_version", []) { version = sqlite3_column_int($0, 0) }
        return version
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }
}
