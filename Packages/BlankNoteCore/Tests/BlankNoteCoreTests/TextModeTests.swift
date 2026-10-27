import Foundation
import Testing
@testable import BlankNoteCore

/// Text mode: Markdown underneath, syntax hidden on screen.
struct TextModeTests {
    private func apply(_ edit: TextEdit?, to text: String) -> String? {
        guard let edit else { return nil }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func hidesSyntaxButNotText() {
        let text = "# Plan\nSome **bold** and [a link](https://a.b)\n- [ ] Task\n- Item\n1. Numbered"
        let ns = text as NSString
        let hidden = TextMode.hiddenRanges(in: text, around: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0) }
        #expect(hidden == ["# ", "**", "**", "[", "](https://a.b)", "- [ ] ", "- "])
    }

    @Test func caretSkipsHiddenSyntax() {
        let text = "Some **bold** text\n# Heading"
        // Moving right into "**" lands after it; moving left lands before it.
        #expect(TextMode.caret(6, from: 5, in: text) == 7)
        #expect(TextMode.caret(6, from: 7, in: text) == 5)
        // The start of a heading line goes after its hidden "# ".
        let heading = (text as NSString).range(of: "# Heading").location
        #expect(TextMode.caret(heading, from: 3, in: text) == heading + 2)
        // Left from the heading's first letter goes to the end of the line above.
        #expect(TextMode.caret(heading, from: heading + 2, in: text) == heading - 1)
    }

    @Test func deleteAtTheStartOfAListItemRemovesTheBullet() {
        let text = "- [ ] Buy milk"
        let caret = 6
        let edit = TextMode.edit(replacing: NSRange(location: 5, length: 1), with: "", selection: NSRange(location: caret, length: 0), in: text)
        #expect(apply(edit, to: text) == "Buy milk")
    }

    @Test func deletingAHiddenCharacterDeletesTheVisibleOne() {
        // The cursor after "bold**": backspace would delete a hidden "*"; it deletes the "d" instead.
        let text = "**bold** x"
        let edit = TextMode.edit(replacing: NSRange(location: 7, length: 1), with: "", selection: NSRange(location: 8, length: 0), in: text)
        #expect(apply(edit, to: text) == "**bol** x")
    }

    @Test func replacingPartOfASpanKeepsItsSyntax() {
        let text = "a **bold** c"
        // "old** c" selected and deleted: the closing "**" stays, so "b" is still bold.
        let range = (text as NSString).range(of: "old** c")
        #expect(apply(TextMode.edit(replacing: range, with: "", selection: range, in: text), to: text) == "a **b**")
        // Typing over it keeps the new text inside the bold.
        #expect(apply(TextMode.edit(replacing: range, with: "X", selection: range, in: text), to: text) == "a **bX**")
    }

    @Test func emptyingASpanRemovesItsSyntax() {
        let text = "a **bold** c"
        let range = (text as NSString).range(of: "bold")
        #expect(apply(TextMode.edit(replacing: range, with: "", selection: range, in: text), to: text) == "a  c")
        // Ordinary edits pass through untouched.
        #expect(TextMode.edit(replacing: NSRange(location: 0, length: 1), with: "A", selection: NSRange(location: 0, length: 1), in: text) == nil)
    }

    @MainActor @Test func theChoiceIsSavedInTheNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(options: .init(root: root, indexURL: root.appendingPathComponent(".index.sqlite"), useICloud: false, watchForChanges: false))
        await store.start()
        let path = try store.createNote(in: "", body: "Plan\n**bold**")
        let editor = EditorModel(store: store)
        editor.open(path)
        #expect(editor.showsMarkdown == false)

        try editor.setShowsMarkdown(true)
        #expect(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).hasPrefix("---\neditor: markdown\n---\n"))
        editor.open(nil)
        editor.open(path)
        #expect(editor.showsMarkdown)

        try editor.setShowsMarkdown(false)
        #expect(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) == "Plan\n**bold**")
    }
}
