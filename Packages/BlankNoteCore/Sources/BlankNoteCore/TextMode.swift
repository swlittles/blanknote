import Foundation

/// Text mode, the editor's default: notes are still Markdown underneath, but the syntax (`**`, `#`,
/// `[](url)`, code fences, list bullets and checkboxes) is hidden or drawn as formatting, so writing
/// feels like a plain notes app. These helpers keep editing sensible around the hidden characters:
/// the cursor never stops inside them, and deleting removes what you can see.
public enum TextMode {
    /// Characters the editor hides in text mode (or draws over, for bullets and checkboxes), in the
    /// lines touching `range`.
    public static func hiddenRanges(in text: String, around range: NSRange) -> [NSRange] {
        let ns = text as NSString
        let limit = lines(around: range, in: ns)
        var ranges = MarkdownHighlighter.spans(in: text, limit: limit).compactMap { span -> NSRange? in
            switch span.style {
            case .marker, .fence: span.range
            default: nil
            }
        }
        var location = limit.location
        while location < NSMaxRange(limit) {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if let prefix = listPrefix(lineStart: line.location, in: ns) { ranges.append(prefix) }
            location = max(NSMaxRange(line), location + 1)
        }
        return merged(ranges)
    }

    /// Where the cursor should go if it landed at `location` (coming from `previous`): never inside
    /// hidden syntax, and never before a line's hidden prefix (a heading's `#`, a list bullet), where
    /// typing would break it. Moving left from the start of such a line goes to the end of the line above.
    public static func caret(_ location: Int, from previous: Int, in text: String) -> Int {
        let ns = text as NSString
        guard location <= ns.length else { return location }
        for run in hiddenRanges(in: text, around: NSRange(location: location, length: 0)) {
            let lineStart = ns.lineRange(for: NSRange(location: run.location, length: 0)).location
            let startsLine = run.location == lineStart
            let inside = run.location < location && location < NSMaxRange(run)
            let beforePrefix = startsLine && location == run.location && NSMaxRange(run) > run.location
            guard inside || beforePrefix else { continue }
            if startsLine {
                // Left arrow from the line's first visible character: on to the line above.
                if previous == NSMaxRange(run), location < previous, lineStart > 0 { return lineStart - 1 }
                return NSMaxRange(run)
            }
            return location >= previous ? NSMaxRange(run) : run.location
        }
        return location
    }

    /// Adjusts an edit typed in text mode, or returns nil to let it through as it is:
    /// - Delete at the start of a list item removes its bullet (and checkbox), leaving plain text.
    /// - Deleting a hidden character deletes the visible one next to it instead.
    /// - A selection's hidden syntax at either end is kept when only part of its span is replaced, so
    ///   typing over part of a bold word stays bold; a span emptied completely loses its syntax too.
    public static func edit(replacing range: NSRange, with replacement: String, selection: NSRange, in text: String) -> TextEdit? {
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return nil }
        let hidden = hiddenRanges(in: text, around: range)
        func isHidden(_ index: Int) -> Bool { hidden.contains { NSLocationInRange(index, $0) } }

        if replacement.isEmpty, selection.length == 0, range.length > 0 {
            let backspace = NSMaxRange(range) == selection.location
            if backspace, let prefix = listPrefix(lineStart: ns.lineRange(for: NSRange(location: selection.location, length: 0)).location, in: ns),
               selection.location == NSMaxRange(prefix) {
                return TextEdit(range: prefix, replacement: "", selection: NSRange(location: prefix.location, length: 0))
            }
            guard (range.location..<NSMaxRange(range)).allSatisfy(isHidden) else { return nil }
            var index = backspace ? range.location - 1 : NSMaxRange(range)
            while index >= 0, index < ns.length, isHidden(index) { index += backspace ? -1 : 1 }
            guard index >= 0, index < ns.length else {
                return TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
            }
            let character = ns.rangeOfComposedCharacterSequence(at: index)
            return TextEdit(range: character, replacement: "", selection: NSRange(location: character.location, length: 0))
        }

        guard range.length > 0 else { return nil }
        // Syntax whose other half is outside the edit stays (after the new text), so its span keeps
        // its formatting instead of leaving half a marker behind.
        let pairs = markerPairs(in: text, around: range)
        var target = range
        var kept: [NSRange] = []
        for (open, close) in pairs {
            let openIn = NSIntersectionRange(open, range).length > 0, closeIn = NSIntersectionRange(close, range).length > 0
            guard openIn != closeIn else { continue }
            let marker = openIn ? open : close
            kept.append(marker)
            target = NSUnionRange(target, marker)
        }
        if !kept.isEmpty {
            let markers = kept.sorted { $0.location < $1.location }.map { ns.substring(with: $0) }.joined()
            let end = target.location + (replacement as NSString).length
            return TextEdit(range: target, replacement: replacement + markers, selection: NSRange(location: end, length: 0))
        }
        // Deleting everything between a pair of markers removes the pair as well.
        if replacement.isEmpty, let pair = pairs.first(where: { NSMaxRange($0.0) == range.location && $0.1.location == NSMaxRange(range) }) {
            return TextEdit(range: NSUnionRange(pair.0, pair.1), replacement: "", selection: NSRange(location: pair.0.location, length: 0))
        }
        return nil
    }

    // MARK: Helpers

    /// A bullet line's hidden prefix, from the line start to its text: `- `, `  * `, `- [ ] `.
    /// Numbered items keep their number, so they have none.
    static func listPrefix(lineStart: Int, in text: NSString) -> NSRange? {
        let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
        let content = NSRange(location: line.location, length: MarkdownHighlighter.withoutNewline(line, in: text).length)
        guard let match = bulletPrefix.firstMatch(in: text as String, range: content) else { return nil }
        return match.range
    }

    private static let bulletPrefix = MarkdownPatterns.regex(#"^[ \t]*[-*+][ \t]+(?:\[[ xX]\][ \t]+)?"#, [.anchorsMatchLines])

    private static func lines(around range: NSRange, in text: NSString) -> NSRange {
        let start = min(range.location, text.length)
        return text.lineRange(for: NSRange(location: start, length: min(range.length, text.length - start)))
    }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// The opening and closing syntax of each inline span (`**bold**`, `` `code` ``, `[link](url)`) in
    /// the lines touching `range`.
    static func markerPairs(in text: String, around range: NSRange) -> [(NSRange, NSRange)] {
        let spans = MarkdownHighlighter.spans(in: text, limit: lines(around: range, in: text as NSString))
        let markers = spans.filter { $0.style == .marker }.map(\.range)
        var pairs: [(NSRange, NSRange)] = []
        for span in spans {
            switch span.style {
            case .bold, .italic, .strikethrough, .inlineCode:
                if let open = markers.first(where: { $0.location == span.range.location && $0.length < span.range.length }),
                   let close = markers.first(where: { NSMaxRange($0) == NSMaxRange(span.range) && $0 != open }) {
                    pairs.append((open, close))
                }
            case .link:
                if let open = markers.first(where: { NSMaxRange($0) == span.range.location }),
                   let close = markers.first(where: { $0.location == NSMaxRange(span.range) }) {
                    pairs.append((open, close))
                }
            default:
                break
            }
        }
        return pairs
    }
}
