import Foundation

public enum CodeBlockPosition: Int, Sendable {
    case first, middle, last
}

/// A kind of Markdown text the editor draws differently. The editor maps each to fonts and colours.
public enum MarkdownStyle: Hashable, Sendable {
    /// The note's first line when it isn't a heading.
    case title
    case heading(Int)
    /// Syntax characters (`**`, `#`, `[`, `](url)`…), drawn dimmed.
    case marker
    case bold
    case italic
    case strikethrough
    case inlineCode
    /// A whole line of a fenced code block, including the fences.
    case codeBlock(CodeBlockPosition)
    case fence
    case codeKeyword
    case codeString
    case codeComment
    case codeNumber
    case quote
    case link
    /// The `url` of `[text](url)`.
    case linkDestination
    /// A bare `https://…` link in the text.
    case url
    case tag
    case listMarker
    case taskBox(checked: Bool)
    case completedTask
    case horizontalRule
}

public struct StyledRange: Equatable, Sendable {
    public var range: NSRange
    public var style: MarkdownStyle

    public init(_ range: NSRange, _ style: MarkdownStyle) {
        self.range = range
        self.style = style
    }
}

/// Finds the Markdown structure in a note, line by line. The result is a list of ranges and
/// styles; later ranges are drawn on top of earlier ones.
public enum MarkdownHighlighter {
    /// Styles for the lines that intersect `limit` (the whole text by default). Fence state is
    /// always worked out from the top, so a partial pass styles code blocks correctly.
    public static func spans(in text: String, limit: NSRange? = nil) -> [StyledRange] {
        let ns = text as NSString
        let limit = limit ?? NSRange(location: 0, length: ns.length)
        var spans: [StyledRange] = []
        var fence: Fence?
        var seenTitle = false
        var location = 0

        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            let contentRange = Self.withoutNewline(lineRange, in: ns)
            let line = ns.substring(with: contentRange)
            let wanted = NSIntersectionRange(lineRange, limit).length > 0
                || (limit.length == 0 && limit.location >= lineRange.location && limit.location <= NSMaxRange(lineRange))
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let isFirstLine = !seenTitle && !isBlank
            if !isBlank { seenTitle = true }

            if let open = fence {
                if open.closes(line) {
                    fence = nil
                    if wanted {
                        spans.append(.init(lineRange, .codeBlock(.last)))
                        spans.append(.init(contentRange, .fence))
                    }
                } else if wanted {
                    spans.append(.init(lineRange, .codeBlock(.middle)))
                    spans += CodeTokenizer.tokens(in: line, offset: contentRange.location, language: open.language)
                }
                continue
            }
            if let open = Fence(opening: line) {
                fence = open
                if wanted {
                    spans.append(.init(lineRange, .codeBlock(.first)))
                    spans.append(.init(contentRange, .fence))
                }
                continue
            }
            guard wanted, !isBlank else { continue }
            spans += lineSpans(line, at: contentRange.location, isTitle: isFirstLine)
        }
        return spans
    }

    /// True if the line opens or closes a code fence. The editor re-styles the whole note when
    /// the number of fences changes, since that changes which lines are code.
    public static func isFenceLine(_ line: some StringProtocol) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    // MARK: Lines

    private static let heading = MarkdownPatterns.regex(#"^ {0,3}(#{1,6})(?:[ \t]+|$)"#)
    private static let quote = MarkdownPatterns.regex(#"^ {0,3}(>[ \t]?)+"#)
    private static let task = MarkdownPatterns.regex(#"^([ \t]*)([-*+])([ \t]+)(\[[ xX]\])(?=[ \t]|$)"#)
    private static let listItem = MarkdownPatterns.regex(#"^[ \t]*([-*+]|\d{1,9}[.)])(?=[ \t]|$)"#)
    private static let rule = MarkdownPatterns.regex(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)

    private static func lineSpans(_ line: String, at offset: Int, isTitle: Bool) -> [StyledRange] {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        var spans: [StyledRange] = []
        func add(_ range: NSRange, _ style: MarkdownStyle) {
            spans.append(.init(NSRange(location: range.location + offset, length: range.length), style))
        }

        if !isTitle, rule.firstMatch(in: line, range: full) != nil {
            add(full, .horizontalRule)
            return spans
        }
        if let match = heading.firstMatch(in: line, range: full) {
            add(full, .heading(match.range(at: 1).length))
            add(match.range, .marker)
        } else if isTitle {
            add(full, .title)
        }
        if let match = quote.firstMatch(in: line, range: full) {
            add(full, .quote)
            add(match.range, .marker)
        }
        if let match = task.firstMatch(in: line, range: full) {
            let box = match.range(at: 4)
            let checked = ns.substring(with: box).lowercased() == "[x]"
            add(match.range(at: 2), .listMarker)
            add(box, .taskBox(checked: checked))
            if checked, NSMaxRange(match.range) < ns.length {
                add(NSRange(location: NSMaxRange(match.range), length: ns.length - NSMaxRange(match.range)), .completedTask)
            }
        } else if let match = listItem.firstMatch(in: line, range: full) {
            add(match.range(at: 1), .listMarker)
        }
        spans += inlineSpans(line, offset: offset)
        return spans
    }

    // MARK: Inline

    private static func inlineSpans(_ line: String, offset: Int) -> [StyledRange] {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        var spans: [StyledRange] = []
        // Code and URLs are literal: nothing inside them is formatting.
        var literal: [NSRange] = []
        func add(_ range: NSRange, _ style: MarkdownStyle) {
            spans.append(.init(NSRange(location: range.location + offset, length: range.length), style))
        }
        func isFree(_ range: NSRange) -> Bool {
            !literal.contains { NSIntersectionRange($0, range).length > 0 }
        }

        for match in MarkdownPatterns.inlineCode.matches(in: line, range: full) {
            let tick = match.range(at: 1).length
            add(match.range, .inlineCode)
            add(NSRange(location: match.range.location, length: tick), .marker)
            add(NSRange(location: NSMaxRange(match.range) - tick, length: tick), .marker)
            literal.append(match.range)
        }
        for match in MarkdownPatterns.link.matches(in: line, range: full) where isFree(match.range) {
            let text = match.range(at: 2)
            add(NSRange(location: match.range.location, length: text.location - match.range.location), .marker)
            add(text, .link)
            let rest = NSRange(location: NSMaxRange(text), length: NSMaxRange(match.range) - NSMaxRange(text))
            add(rest, .marker)
            add(match.range(at: 3), .linkDestination)
            literal.append(rest)
        }
        for match in MarkdownPatterns.wikiLink.matches(in: line, range: full) where isFree(match.range) {
            add(NSRange(location: match.range.location, length: 2), .marker)
            add(match.range(at: 1), .link)
            add(NSRange(location: NSMaxRange(match.range) - 2, length: 2), .marker)
            literal.append(match.range)
        }
        for match in MarkdownPatterns.autolink.matches(in: line, range: full) where isFree(match.range) {
            add(match.range, .url)
            literal.append(match.range)
        }
        func emphasis(_ pattern: NSRegularExpression, markerLength: Int, style: MarkdownStyle) {
            for match in pattern.matches(in: line, range: full) where isFree(match.range) {
                add(match.range, style)
                add(NSRange(location: match.range.location, length: markerLength), .marker)
                add(NSRange(location: NSMaxRange(match.range) - markerLength, length: markerLength), .marker)
            }
        }
        emphasis(MarkdownPatterns.bold, markerLength: 2, style: .bold)
        emphasis(MarkdownPatterns.italicStar, markerLength: 1, style: .italic)
        emphasis(MarkdownPatterns.italicUnderscore, markerLength: 1, style: .italic)
        emphasis(MarkdownPatterns.strikethrough, markerLength: 2, style: .strikethrough)
        for match in MarkdownPatterns.tag.matches(in: line, range: full) where isFree(match.range)
            && !MarkdownPatterns.isColour((line as NSString).substring(with: match.range(at: 1))) {
            add(match.range, .tag)
        }
        return spans
    }

    // MARK: Helpers

    static func withoutNewline(_ range: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(range)
        while end > range.location, let scalar = UnicodeScalar(text.character(at: end - 1)),
              CharacterSet.newlines.contains(scalar) {
            end -= 1
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    private struct Fence {
        var character: Character
        var length: Int
        var language: String

        init?(opening line: String) {
            let trimmed = line.drop(while: { $0 == " " })
            guard line.count - trimmed.count <= 3, let first = trimmed.first, first == "`" || first == "~" else { return nil }
            let run = trimmed.prefix(while: { $0 == first })
            guard run.count >= 3 else { return nil }
            let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            if first == "`", info.contains("`") { return nil }
            character = first
            length = run.count
            language = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
        }

        func closes(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= length && trimmed.allSatisfy { $0 == character }
        }
    }
}
