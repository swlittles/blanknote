import Foundation

/// Reads the facts the app shows about a note (title, preview, tags) out of its Markdown body.
public enum NoteText {
    /// The note's title: its first non-blank line, without heading markers or inline formatting.
    public static func title(of body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let title = stripInline(stripHeading(trimmed))
            return String(title.prefix(120)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// A one-line preview of the text after the title.
    public static func preview(of body: String, maxLength: Int = 160) -> String {
        var parts: [String] = []
        var length = 0
        var foundTitle = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if !foundTitle {
                foundTitle = true
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || isRule(trimmed) { continue }
            let text = stripInline(stripLinePrefix(trimmed))
            guard !text.isEmpty else { continue }
            parts.append(text)
            length += text.count + 1
            if length >= maxLength { break }
        }
        return String(parts.joined(separator: " ").prefix(maxLength))
    }

    /// `#tags` written in the body, outside code. Case-insensitively unique, in order of appearance.
    public static func inlineTags(in body: String) -> [String] {
        var tags: [String] = []
        var seen = Set<String>()
        var inFence = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, line.contains("#") else { continue }
            let text = String(line) as NSString
            let codeRanges = MarkdownPatterns.inlineCode.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map(\.range)
            for match in MarkdownPatterns.tag.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                let tag = text.substring(with: match.range(at: 1))
                if seen.insert(tag.lowercased()).inserted { tags.append(tag) }
            }
        }
        return tags
    }

    /// A safe file name (without extension) for a note with this title.
    public static func fileName(for title: String) -> String {
        // Only C0/C1 control characters: `.controlCharacters` also covers format characters such
        // as the zero-width joiner inside emoji, and Persian's zero-width non-joiner.
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
            .union(CharacterSet(charactersIn: "\u{0}"..."\u{1F}")).union(CharacterSet(charactersIn: "\u{7F}"..."\u{9F}"))
        var name = title.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : name
    }

    static func stripHeading(_ line: String) -> String {
        guard line.hasPrefix("#") else { return line }
        let hashes = line.prefix(while: { $0 == "#" })
        let rest = line.dropFirst(hashes.count)
        guard hashes.count <= 6, rest.isEmpty || rest.first == " " || rest.first == "\t" else { return line }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func stripLinePrefix(_ line: String) -> String {
        let text = stripHeading(line) as NSString
        guard let match = MarkdownPatterns.linePrefix.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else {
            return text as String
        }
        return text.substring(from: match.range.length)
    }

    static func stripInline(_ text: String) -> String {
        var result = text
        // [text](url) → text, then drop the emphasis markers themselves.
        result = MarkdownPatterns.link.stringByReplacingMatches(
            in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "$2")
        for marker in ["**", "__", "~~", "`"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }
}

/// Regular expressions shared by the parser, the highlighter and the editing commands, so that what
/// the editor colours as a tag is exactly what the sidebar lists as one.
enum MarkdownPatterns {
    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants, so a failure here is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// `#tag`, `#tag/subtag`. Not `#123`, `C#`, `url/#anchor`, or `&#38;`.
    static let tag = regex(#"(?<![\p{L}\p{N}_#/&;])#((?=[\p{N}_\-/]*\p{L})[\p{L}\p{N}_][\p{L}\p{N}_\-/]*[\p{L}\p{N}_])"#)
    static let inlineCode = regex(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    /// `[text](url)` and `![alt](url)`. Group 1: optional `!`, 2: text, 3: url.
    static let link = regex(#"(!?)\[([^\]\n]*)\]\(([^)\s]+)(?:\s+"[^"\n]*")?\)"#)
    static let wikiLink = regex(#"\[\[([^\]\n]+)\]\]"#)
    static let autolink = regex(#"\b(?:https?://|www\.)[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#, .caseInsensitive)
    static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    static let italicStar = regex(#"(?<![\*\\])\*(?=[^\s\*])(.+?)(?<=[^\s\*\\])\*(?!\*)"#)
    static let italicUnderscore = regex(#"(?<![\w_\\])_(?=[^\s_])(.+?)(?<=[^\s_\\])_(?![\w_])"#)
    static let strikethrough = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    /// Heading, quote, list or task markers at the start of a line.
    static let linePrefix = regex(#"^[ \t]*(?:>[ \t]?|[-*+][ \t]+(?:\[[ xX]\][ \t]+)?|\d{1,9}[.)][ \t]+)"#)
}
