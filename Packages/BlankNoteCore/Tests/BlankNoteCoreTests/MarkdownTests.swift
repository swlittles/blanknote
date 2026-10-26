import Foundation
import Testing
@testable import BlankNoteCore

struct MarkdownHighlighterTests {
    private func styles(_ text: String, _ substring: String) -> Set<MarkdownStyle> {
        let range = (text as NSString).range(of: substring)
        return Set(MarkdownHighlighter.spans(in: text).filter { NSIntersectionRange($0.range, range).length == range.length }.map(\.style))
    }

    @Test func firstLineIsTitleUnlessHeading() {
        #expect(styles("My note\nbody", "My note").contains(.title))
        #expect(!styles("My note\nbody", "body").contains(.title))
        #expect(styles("## Sub\nbody", "Sub").contains(.heading(2)))
        #expect(styles("## Sub\nbody", "## ").contains(.marker))
    }

    @Test func inlineFormatting() {
        let text = "Title\nSome **bold**, *it*, ~~gone~~, `co**de**`, [site](https://a.b) #tag"
        #expect(styles(text, "bold").contains(.bold))
        #expect(styles(text, "*it*").contains(.italic))
        #expect(styles(text, "gone").contains(.strikethrough))
        #expect(styles(text, "co**de**").contains(.inlineCode))
        #expect(!styles(text, "de").contains(.bold), "nothing inside code is formatting")
        #expect(styles(text, "site").contains(.link))
        #expect(styles(text, "https://a.b").contains(.linkDestination))
        #expect(styles(text, "#tag").contains(.tag))
    }

    @Test func tasksAndLists() {
        let text = "Title\n- [ ] open\n- [x] done\n1. first"
        #expect(styles(text, "[ ]").contains(.taskBox(checked: false)))
        #expect(styles(text, "[x]").contains(.taskBox(checked: true)))
        #expect(styles(text, "done").contains(.completedTask))
        #expect(!styles(text, "open").contains(.completedTask))
        #expect(styles(text, "1.").contains(.listMarker))
    }

    @Test func codeBlocks() {
        let text = "Title\n```swift\nlet x = \"hi\" // note\n```\nafter **b**"
        #expect(styles(text, "```swift").contains(.codeBlock(.first)))
        #expect(styles(text, "let").contains(.codeKeyword))
        #expect(styles(text, "\"hi\"").contains(.codeString))
        #expect(styles(text, "// note").contains(.codeComment))
        #expect(styles(text, "let x").contains(.codeBlock(.middle)))
        #expect(styles(text, "**b**").contains(.bold))
        #expect(styles(text, "after").isEmpty)
    }

    @Test func partialPassKnowsItIsInsideAFence() {
        let text = "Title\n```\n# not a heading\n```"
        let line = (text as NSString).range(of: "# not a heading")
        let spans = MarkdownHighlighter.spans(in: text, limit: line)
        #expect(spans.contains { $0.style == .codeBlock(.middle) })
        #expect(!spans.contains { $0.style == .heading(1) })
        #expect(!spans.contains { $0.style == .title }, "only the requested lines are styled")
    }
}

struct MarkdownEditingTests {
    private func apply(_ edit: TextEdit?, to text: String) -> (String, NSRange)? {
        guard let edit else { return nil }
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    /// `|` marks the cursor; `[` … `]` would clash with Markdown, so selections use `«` and `»`.
    private func parse(_ marked: String) -> (String, NSRange) {
        if let start = marked.range(of: "«"), let end = marked.range(of: "»") {
            let location = marked.utf16.distance(from: marked.startIndex, to: start.lowerBound)
            let length = marked.utf16.distance(from: start.upperBound, to: end.lowerBound)
            return (marked.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: ""), NSRange(location: location, length: length))
        }
        let cursor = marked.range(of: "|")!
        let location = marked.utf16.distance(from: marked.startIndex, to: cursor.lowerBound)
        return (marked.replacingOccurrences(of: "|", with: ""), NSRange(location: location, length: 0))
    }

    private func mark(_ text: String, _ selection: NSRange) -> String {
        let ns = text as NSString
        if selection.length == 0 { return ns.replacingCharacters(in: selection, with: "|") }
        return ns.substring(to: selection.location) + "«" + ns.substring(with: selection) + "»" + ns.substring(from: NSMaxRange(selection))
    }

    private func newline(_ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return apply(MarkdownEditing.newline(in: text, selection: selection), to: text).map(mark)
    }

    private func format(_ action: FormatAction, _ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return apply(MarkdownEditing.apply(action, to: text, selection: selection), to: text).map(mark)
    }

    @Test func returnContinuesLists() {
        #expect(newline("- milk|") == "- milk\n- |")
        #expect(newline("* milk|") == "* milk\n* |")
        #expect(newline("\t- [x] done|") == "\t- [x] done\n\t- [ ] |")
        #expect(newline("9. nine|") == "9. nine\n10. |")
        #expect(newline("> quote|") == "> quote\n> |")
        #expect(newline("plain|") == nil)
        #expect(newline("|- milk") == nil, "cursor before the marker types a newline")
    }

    @Test func returnOnEmptyItemEndsOrOutdents() {
        #expect(newline("- milk\n- |") == "- milk\n|")
        #expect(newline("- a\n\t- |") == "- a\n- |")
    }

    @Test func tabIndentsListItems() {
        let (text, selection) = parse("- it|em")
        #expect(apply(MarkdownEditing.indent(in: text, selection: selection, outdent: false, listsOnly: true), to: text).map(mark) == "\t- it|em")
        let (plain, plainSelection) = parse("text|")
        #expect(MarkdownEditing.indent(in: plain, selection: plainSelection, outdent: false, listsOnly: true) == nil)
        #expect(format(.outdent, "    - a|") == "- a|")
        #expect(format(.outdent, "- a|") == nil)
        #expect(format(.indent, "«a\nb»") == "«\ta\n\tb»")
    }

    @Test func checkboxToggles() {
        let text = "Title\n- [ ] task"
        let box = (text as NSString).range(of: "[ ]")
        let edit = MarkdownEditing.toggleTask(in: text, at: box.location + 1, selection: NSRange(location: 0, length: 0))
        #expect(apply(edit, to: text)?.0 == "Title\n- [x] task")
        #expect(MarkdownEditing.toggleTask(in: text, at: (text as NSString).length, selection: NSRange()) == nil, "tapping the text doesn't toggle")
        #expect(MarkdownEditing.taskBox(in: "Title", at: 2) == nil)
    }

    @Test func wrapCommands() {
        #expect(format(.bold, "a «word» b") == "a **«word»** b")
        #expect(format(.bold, "a **«word»** b") == "a «word» b")
        #expect(format(.bold, "a «**word**» b") == "a «word» b")
        #expect(format(.italic, "a «word» b") == "a *«word»* b")
        #expect(format(.italic, "a *«word»* b") == "a «word» b")
        // Italic on bold text adds italic rather than turning the bold into italic.
        #expect(format(.italic, "a **«bold»** b") == "a ***«bold»*** b")
        #expect(format(.italic, "a ***«both»*** b") == "a **«both»** b")
        #expect(format(.italic, "a «**bold**» b") == "a *«**bold**»* b")
        #expect(format(.inlineCode, "x|") == "x`|`")
        #expect(format(.link, "«site»") == "[site](«url»)")
        #expect(format(.link, "«https://a.b»") == "[|](https://a.b)")
    }

    @Test func lineCommands() {
        #expect(format(.checklist, "milk|") == "- [ ] milk|")
        #expect(format(.checklist, "- [ ] milk|") == "milk|")
        #expect(format(.checklist, "- milk|") == "- [ ] milk|")
        #expect(format(.numberedList, "«a\n\nb»") == "«1. a\n\n2. b»")
        #expect(format(.heading, "Ti|tle") == "# Ti|tle")
        #expect(format(.heading, "### Ti|tle") == "Ti|tle")
        #expect(format(.codeBlock, "|") == "```\n|\n```")
    }
}
