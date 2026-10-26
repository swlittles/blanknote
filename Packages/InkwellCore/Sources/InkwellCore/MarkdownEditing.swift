import Foundation

/// One change to the editor's text: replace `range` with `replacement`, then select `selection`.
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

/// Formatting commands from the menu, keyboard shortcuts and the iPhone keyboard bar.
public enum FormatAction: String, CaseIterable, Sendable {
    case bold, italic, strikethrough, inlineCode, link
    case heading, checklist, bulletList, numberedList, quote, codeBlock
    case indent, outdent
}

/// The text changes behind the editor's Markdown commands. Pure functions of text and selection,
/// so the iOS and Mac editors share them and the tests can check them.
public enum MarkdownEditing {
    public struct LinePrefix: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case task(bullet: String, checked: Bool)
            case bullet(String)
            case ordered(number: Int, delimiter: String)
            case quote
        }
        public var indent: String
        public var kind: Kind
        /// Length of the whole prefix, indent included, in UTF-16 units.
        public var length: Int

        /// The prefix a new line after this one starts with.
        var continuation: String {
            switch kind {
            case .task(let bullet, _): indent + bullet + " [ ] "
            case .bullet(let bullet): indent + bullet + " "
            case .ordered(let number, let delimiter): indent + "\(number + 1)\(delimiter) "
            case .quote: indent + "> "
            }
        }
    }

    private static let prefixPattern = MarkdownPatterns.regex(
        #"^([ \t]*)(?:([-*+])[ \t]+\[([ xX])\](?:[ \t]+|$)|([-*+])(?:[ \t]+|$)|(\d{1,9})([.)])(?:[ \t]+|$)|>[ \t]?)"#)

    public static func linePrefix(of line: String) -> LinePrefix? {
        let ns = line as NSString
        guard let match = prefixPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        let indent = group(1) ?? ""
        let kind: LinePrefix.Kind
        if let bullet = group(2) {
            kind = .task(bullet: bullet, checked: group(3)?.lowercased() == "x")
        } else if let bullet = group(4) {
            kind = .bullet(bullet)
        } else if let number = group(5).flatMap(Int.init) {
            kind = .ordered(number: number, delimiter: group(6) ?? ".")
        } else {
            kind = .quote
        }
        return LinePrefix(indent: indent, kind: kind, length: match.range.length)
    }

    // MARK: Return, Tab

    /// Return inside a list continues it; Return on an empty item ends the list.
    /// `nil` means "insert a plain newline".
    public static func newline(in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let line = lineContent(in: ns, at: selection.location)
        let lineText = ns.substring(with: line)
        guard let prefix = linePrefix(of: lineText), selection.location - line.location >= prefix.length else { return nil }

        let rest = (lineText as NSString).substring(from: prefix.length)
        if rest.trimmingCharacters(in: .whitespaces).isEmpty, selection.length == 0 {
            // An empty item: outdent it if it's nested, otherwise end the list.
            if !prefix.indent.isEmpty, let edit = indent(in: text, selection: selection, outdent: true) {
                return edit
            }
            return TextEdit(range: line, replacement: "", selection: NSRange(location: line.location, length: 0))
        }
        let insertion = "\n" + prefix.continuation
        return TextEdit(range: selection, replacement: insertion,
                        selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
    }

    /// Indents or outdents every line the selection touches by one tab.
    /// With `listsOnly`, does nothing (returns `nil`) for a cursor on a line that isn't a list item,
    /// so Tab still types a tab in ordinary text.
    public static func indent(in text: String, selection: NSRange, outdent: Bool, listsOnly: Bool = false) -> TextEdit? {
        let ns = text as NSString
        let block = linesRange(in: ns, for: selection)
        let original = ns.substring(with: block)
        var lines = original.components(separatedBy: "\n")
        if listsOnly, lines.count == 1, linePrefix(of: lines[0]) == nil { return nil }

        var firstDelta = 0
        var changed = false
        for index in lines.indices where !(lines[index].isEmpty && lines.count > 1) {
            let before = (lines[index] as NSString).length
            if outdent {
                if lines[index].hasPrefix("\t") {
                    lines[index].removeFirst()
                } else {
                    let spaces = lines[index].prefix(while: { $0 == " " }).count
                    lines[index].removeFirst(min(spaces, 4))
                }
            } else {
                lines[index] = "\t" + lines[index]
            }
            let delta = (lines[index] as NSString).length - before
            if index == 0 { firstDelta = delta }
            if delta != 0 { changed = true }
        }
        guard changed else { return nil }
        let replacement = lines.joined(separator: "\n")
        let newSelection: NSRange
        if lines.count == 1 {
            let location = max(block.location, selection.location + firstDelta)
            newSelection = NSRange(location: location, length: selection.length)
        } else {
            newSelection = NSRange(location: block.location, length: (replacement as NSString).length)
        }
        return TextEdit(range: block, replacement: replacement, selection: newSelection)
    }

    // MARK: Checkboxes

    /// The `[ ]` / `[x]` of the task on the line containing `index`, if there is one.
    public static func taskBox(in text: String, at index: Int) -> NSRange? {
        let ns = text as NSString
        guard index <= ns.length else { return nil }
        let line = lineContent(in: ns, at: min(index, ns.length))
        let lineText = ns.substring(with: line)
        guard let prefix = linePrefix(of: lineText), case .task = prefix.kind else { return nil }
        let open = (lineText as NSString).range(of: "[")
        guard open.location != NSNotFound else { return nil }
        return NSRange(location: line.location + open.location, length: 3)
    }

    /// Ticks or unticks the task whose checkbox is at (or right next to) `index`.
    public static func toggleTask(in text: String, at index: Int, selection: NSRange) -> TextEdit? {
        guard let box = taskBox(in: text, at: index), index >= box.location - 1, index <= NSMaxRange(box) else { return nil }
        let ns = text as NSString
        let checked = ns.substring(with: NSRange(location: box.location + 1, length: 1)).lowercased() == "x"
        return TextEdit(range: NSRange(location: box.location + 1, length: 1), replacement: checked ? " " : "x", selection: selection)
    }

    // MARK: Formatting commands

    public static func apply(_ action: FormatAction, to text: String, selection: NSRange) -> TextEdit? {
        switch action {
        case .bold: toggleWrap(text, selection, marker: "**")
        case .italic: toggleWrap(text, selection, marker: "*")
        case .strikethrough: toggleWrap(text, selection, marker: "~~")
        case .inlineCode: toggleWrap(text, selection, marker: "`")
        case .link: link(text, selection)
        case .heading: cycleHeading(text, selection)
        case .checklist: toggleLines(text, selection, kind: .checklist)
        case .bulletList: toggleLines(text, selection, kind: .bullet)
        case .numberedList: toggleLines(text, selection, kind: .numbered)
        case .quote: toggleLines(text, selection, kind: .quote)
        case .codeBlock: codeBlock(text, selection)
        case .indent: indent(in: text, selection: selection, outdent: false)
        case .outdent: indent(in: text, selection: selection, outdent: true)
        }
    }

    static func toggleWrap(_ text: String, _ selection: NSRange, marker: String) -> TextEdit {
        let ns = text as NSString
        let length = (marker as NSString).length
        let selected = ns.substring(with: selection)

        // Already wrapped just outside the selection: unwrap.
        if selection.location >= length, NSMaxRange(selection) + length <= ns.length,
           ns.substring(with: NSRange(location: selection.location - length, length: length)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(selection), length: length)) == marker {
            return TextEdit(range: NSRange(location: selection.location - length, length: selection.length + 2 * length),
                            replacement: selected,
                            selection: NSRange(location: selection.location - length, length: selection.length))
        }
        // The selection includes the markers: unwrap.
        let selectedLength = (selected as NSString).length
        if selectedLength >= 2 * length, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: length, length: selectedLength - 2 * length))
            return TextEdit(range: selection, replacement: inner,
                            selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        return TextEdit(range: selection, replacement: marker + selected + marker,
                        selection: NSRange(location: selection.location + length, length: selection.length))
    }

    static func link(_ text: String, _ selection: NSRange) -> TextEdit {
        let selected = (text as NSString).substring(with: selection)
        if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
            // Selected a URL: wrap it and put the cursor where the link text goes.
            return TextEdit(range: selection, replacement: "[](\(selected))", selection: NSRange(location: selection.location + 1, length: 0))
        }
        let replacement = "[\(selected)](url)"
        let urlLocation = selection.location + 1 + (selected as NSString).length + 2
        return TextEdit(range: selection, replacement: replacement,
                        selection: selected.isEmpty ? NSRange(location: selection.location + 1, length: 0) : NSRange(location: urlLocation, length: 3))
    }

    static func cycleHeading(_ text: String, _ selection: NSRange) -> TextEdit {
        let ns = text as NSString
        let line = lineContent(in: ns, at: selection.location)
        let lineText = ns.substring(with: line)
        let hashes = lineText.prefix(while: { $0 == "#" }).count
        let isHeading = hashes > 0 && hashes <= 6 && (lineText.count == hashes || lineText.dropFirst(hashes).first == " ")
        let level = isHeading ? hashes : 0
        let next = level == 0 ? 1 : (level >= 3 ? 0 : level + 1)

        var content = isHeading ? String(lineText.dropFirst(hashes)) : lineText
        if content.hasPrefix(" ") { content.removeFirst() }
        let replacement = next == 0 ? content : String(repeating: "#", count: next) + " " + content
        let delta = (replacement as NSString).length - line.length
        let location = max(line.location, min(selection.location + delta, line.location + (replacement as NSString).length))
        return TextEdit(range: line, replacement: replacement, selection: NSRange(location: location, length: selection.length))
    }

    enum LineKind { case checklist, bullet, numbered, quote }

    /// Adds the prefix to every selected line, or removes it if they all have it already.
    static func toggleLines(_ text: String, _ selection: NSRange, kind: LineKind) -> TextEdit {
        let ns = text as NSString
        let block = linesRange(in: ns, for: selection)
        let lines = ns.substring(with: block).components(separatedBy: "\n")
        let targets = lines.indices.filter { lines.count == 1 || !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }

        func has(_ line: String) -> Bool {
            switch (linePrefix(of: line)?.kind, kind) {
            case (.task?, .checklist), (.bullet?, .bullet), (.ordered?, .numbered), (.quote?, .quote): true
            default: false
            }
        }
        let removing = targets.allSatisfy { has(lines[$0]) }
        var number = 0
        var newLines = lines
        var firstDelta = 0
        for index in targets {
            let line = lines[index]
            let prefix = linePrefix(of: line)
            let indent = prefix?.indent ?? String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let body = prefix.map { (line as NSString).substring(from: $0.length) } ?? String(line.dropFirst(indent.count))
            let newLine: String
            if removing {
                newLine = indent + body
            } else {
                number += 1
                let marker = switch kind {
                case .checklist: "- [ ] "
                case .bullet: "- "
                case .numbered: "\(number). "
                case .quote: "> "
                }
                newLine = indent + marker + body
            }
            newLines[index] = newLine
            if index == 0 { firstDelta = (newLine as NSString).length - (line as NSString).length }
        }
        let replacement = newLines.joined(separator: "\n")
        let newSelection = lines.count == 1
            ? NSRange(location: max(block.location, selection.location + firstDelta), length: selection.length)
            : NSRange(location: block.location, length: (replacement as NSString).length)
        return TextEdit(range: block, replacement: replacement, selection: newSelection)
    }

    static func codeBlock(_ text: String, _ selection: NSRange) -> TextEdit {
        let ns = text as NSString
        let block = linesRange(in: ns, for: selection)
        let content = ns.substring(with: block)
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return TextEdit(range: block, replacement: "```\n\n```", selection: NSRange(location: block.location + 4, length: 0))
        }
        let replacement = "```\n" + content + "\n```"
        return TextEdit(range: block, replacement: replacement,
                        selection: NSRange(location: block.location + 4, length: (content as NSString).length))
    }

    // MARK: Line helpers

    /// The line containing `location`, without its newline.
    static func lineContent(in text: NSString, at location: Int) -> NSRange {
        MarkdownHighlighter.withoutNewline(text.lineRange(for: NSRange(location: min(location, text.length), length: 0)), in: text)
    }

    /// Every line the selection touches, without the final newline.
    static func linesRange(in text: NSString, for selection: NSRange) -> NSRange {
        var range = selection
        // A selection ending right after a newline doesn't include the next line.
        if range.length > 0, NSMaxRange(range) <= text.length, text.character(at: NSMaxRange(range) - 1) == 10 {
            range.length -= 1
        }
        let lines = text.lineRange(for: NSRange(location: min(range.location, text.length), length: range.length))
        return MarkdownHighlighter.withoutNewline(lines, in: text)
    }
}
