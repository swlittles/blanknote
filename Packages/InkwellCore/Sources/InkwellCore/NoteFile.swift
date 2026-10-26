import Foundation

/// The optional YAML block at the top of a note file.
///
/// Inkwell only reads and writes a few simple keys (`tags`, `pinned`, `trashed-from`, `trashed`),
/// but it keeps every other line exactly as it found it, so front matter written by other tools
/// (Obsidian, Jekyll, Hugo…) survives a round trip.
public struct FrontMatter: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// Empty for blank lines and comments, which are kept as entries of their own so that
        /// changing a neighbouring key leaves them alone.
        public var key: String
        /// The entry's raw lines: `key: value` followed by any indented or `- item` lines.
        public var lines: [String]
    }

    public var entries: [Entry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// The text after `key:` on the entry's first line, without quotes.
    public func value(_ key: String) -> String? {
        guard let entry = entries.first(where: { $0.key == key }), let first = entry.lines.first,
              let colon = first.firstIndex(of: ":") else { return nil }
        return Self.unquote(first[first.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// A list value, written either inline (`tags: [a, b]` or `tags: a, b`) or as a block of `- item` lines.
    public func list(_ key: String) -> [String] {
        guard let entry = entries.first(where: { $0.key == key }) else { return [] }
        let inline = value(key) ?? ""
        if !inline.isEmpty {
            var text = Substring(inline)
            if text.hasPrefix("["), text.hasSuffix("]") { text = text.dropFirst().dropLast() }
            return text.split(separator: ",")
                .map { Self.unquote($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        }
        return entry.lines.dropFirst().compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") else { return nil }
            let item = Self.unquote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            return item.isEmpty ? nil : item
        }
    }

    public func bool(_ key: String) -> Bool {
        switch value(key)?.lowercased() {
        case "true", "yes", "on": true
        default: false
        }
    }

    /// Sets `key: value`, replacing the entry in place. `nil` removes the entry.
    public mutating func set(_ key: String, _ value: String?) {
        guard let value else {
            entries.removeAll { $0.key == key }
            return
        }
        let line = "\(key): \(value)"
        if !key.isEmpty, let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].lines = [line]
        } else {
            entries.append(Entry(key: key, lines: [line]))
        }
    }

    public mutating func setList(_ key: String, _ values: [String]) {
        set(key, values.isEmpty ? nil : "[" + values.map(Self.quoteIfNeeded).joined(separator: ", ") + "]")
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" else {
            return text
        }
        let inner = String(text.dropFirst().dropLast())
        // Undo `quoteIfNeeded`'s escaping (YAML's double-quoted style); single quotes double up.
        return first == "\""
            ? inner.replacingOccurrences(of: "\\\\", with: "\u{0}").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\u{0}", with: "\\")
            : inner.replacingOccurrences(of: "''", with: "'")
    }

    static func quoteIfNeeded(_ text: String) -> String {
        let special = CharacterSet(charactersIn: ":,[]{}#&*!|>'\"%@`")
        if text.rangeOfCharacter(from: special) != nil || text != text.trimmingCharacters(in: .whitespaces) {
            return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return text
    }
}

/// A note file: optional front matter plus the Markdown body the user edits.
public struct NoteFile: Equatable, Sendable {
    public var frontMatter: FrontMatter
    public var body: String

    public init(frontMatter: FrontMatter = FrontMatter(), body: String) {
        self.frontMatter = frontMatter
        self.body = body
    }

    public init(contents raw: String) {
        let contents = raw.contains("\r\n") ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        guard contents.hasPrefix("---\n") else {
            self.init(body: contents)
            return
        }
        let lines = contents.components(separatedBy: "\n")
        guard let close = lines.indices.dropFirst().first(where: {
            let line = lines[$0].trimmingCharacters(in: .whitespaces)
            return line == "---" || line == "..."
        }) else {
            self.init(body: contents)
            return
        }

        var frontMatter = FrontMatter()
        for line in lines[1..<close] {
            let startsEntry = !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t")
                && !line.hasPrefix("-") && !line.hasPrefix("#")
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") {
                // Blank lines and comments stand alone, so replacing the entry above keeps them.
                frontMatter.entries.append(.init(key: "", lines: [line]))
            } else if startsEntry {
                // A top-level line without a colon means this isn't front matter after all,
                // just a note that starts with a horizontal rule.
                guard let colon = line.firstIndex(of: ":") else {
                    self.init(body: contents)
                    return
                }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                frontMatter.entries.append(.init(key: key, lines: [line]))
            } else if frontMatter.entries.isEmpty {
                frontMatter.entries.append(.init(key: "", lines: [line]))
            } else {
                frontMatter.entries[frontMatter.entries.count - 1].lines.append(line)
            }
        }
        self.init(frontMatter: frontMatter, body: lines[(close + 1)...].joined(separator: "\n"))
    }

    /// The file's text: front matter (when there is any) followed by the body.
    public var contents: String {
        guard !frontMatter.isEmpty else { return body }
        let header = frontMatter.entries.flatMap(\.lines).joined(separator: "\n")
        return "---\n" + header + "\n---\n" + body
    }
}
