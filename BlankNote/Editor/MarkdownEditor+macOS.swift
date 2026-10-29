#if os(macOS)
import AppKit
import BlankNoteCore
import SwiftUI

/// The note editor on the Mac: a TextKit 2 `NSTextView` that styles Markdown as you type.
struct MarkdownEditor: NSViewRepresentable {
    let model: EditorModel
    var fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, fontSize: fontSize)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InkTextView(usingTextLayoutManager: true)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        context.coordinator.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(model: model, fontSize: fontSize)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, NSTextLayoutManagerDelegate {
        private var model: EditorModel
        private let styler: MarkdownStyler
        private weak var textView: InkTextView?
        private var revision = -1
        private var applyingEdit = false
        /// Text mode: the cursor's last place, to tell which way it moved, and a guard while moving it.
        private var lastCaret = 0
        private var snappingCaret = false
        /// Text changed since it was last styled. It's styled just after each edit rather than during
        /// it: TextKit 2 moves the cursor to the end of everything an edit touched, so restyling the
        /// line (or the whole note, for a title) as part of the edit took the cursor there too.
        private var unstyled: NSRange?

        init(model: EditorModel, fontSize: CGFloat) {
            self.model = model
            styler = MarkdownStyler(fontSize: fontSize)
        }

        func attach(_ view: InkTextView) {
            textView = view
            view.delegate = self
            if let clip = view.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: clip)
            }
            view.setAccessibilityIdentifier("editor")
            view.textStorage?.delegate = self
            view.textLayoutManager?.delegate = self
            view.drawsBackground = false
            view.isRichText = false
            view.allowsUndo = true
            view.usesFindBar = true
            view.isIncrementalSearchingEnabled = true
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticLinkDetectionEnabled = false
            view.isContinuousSpellCheckingEnabled = true
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            view.minSize = .zero
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.insertionPointColor = Palette.accent
            view.selectedTextAttributes = [.backgroundColor: Palette.selection]
            view.linkTextAttributes = [.foregroundColor: Palette.accentText, .cursor: NSCursor.pointingHand]
            view.typingAttributes = styler.baseAttributes
            view.onFormat = { [weak self] action in self?.perform(action) }
            view.onClick = { [weak self] index in self?.toggleCheckbox(at: index) ?? false }
        }

        func update(model: EditorModel, fontSize: CGFloat) {
            guard let textView, let storage = textView.textStorage else { return }
            self.model = model
            if styler.fontSize != fontSize {
                styler.fontSize = fontSize
                textView.typingAttributes = styler.baseAttributes
                storage.beginEditing()
                styler.restyle(storage, edited: nil)
                storage.endEditing()
            }
            if styler.hidesMarkup == model.showsMarkdown {
                // Text mode or Markdown editing: set before a new note's text arrives, which styles it.
                styler.hidesMarkup = !model.showsMarkdown
                if model.revision == revision {
                    storage.beginEditing()
                    styler.restyle(storage, edited: nil)
                    storage.endEditing()
                }
            }
            if model.revision != revision {
                // A reload of the note on screen keeps the cursor and scroll position; so does a
                // new view of the note that was open (the window redrawn in a new theme).
                let isNewView = revision == -1
                revision = model.revision
                let keepsPlace = model.revisionIsReload && !isNewView
                let selection = keepsPlace ? textView.selectedRange() : model.selection
                let offset = keepsPlace ? Double(textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0) : model.scrollOffset
                storage.setAttributedString(NSAttributedString(string: model.text, attributes: styler.baseAttributes))
                styleEdits()
                textView.setSelectedRange(Self.clamp(selection, to: storage.length))
                textView.undoManager?.removeAllActions()
                if offset > 0 {
                    DispatchQueue.main.async { [weak textView] in
                        guard let textView, let clip = textView.enclosingScrollView?.contentView else { return }
                        if let layout = textView.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
                        clip.scroll(to: NSPoint(x: 0, y: offset))
                        textView.enclosingScrollView?.reflectScrolledClipView(clip)
                    }
                } else {
                    textView.scroll(.zero)
                }
            }
            textView.isEditable = !model.isReadOnly
            if model.wantsFocus {
                // After this update: the view may not be in a window yet.
                DispatchQueue.main.async {
                    if model.takeFocusRequest() { textView.window?.makeFirstResponder(textView) }
                }
            }
        }

        // MARK: Styling

        nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                unstyled = unstyled.map { NSUnionRange($0, editedRange) } ?? editedRange
                // Typing styles in `textDidChange`; this catches any other edit.
                DispatchQueue.main.async { [weak self] in self?.styleEdits() }
            }
        }

        private func styleEdits() {
            guard let range = unstyled, let textView, let storage = textView.textStorage else { return }
            unstyled = nil
            let selection = textView.selectedRanges
            storage.beginEditing()
            styler.restyle(storage, edited: range)
            storage.endEditing()
            if textView.selectedRanges != selection { textView.selectedRanges = selection }
        }

        nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
            CodeBlockLayoutFragment.fragment(for: textElement)
        }

        static func clamp(_ range: NSRange, to length: Int) -> NSRange {
            let location = min(range.location, length)
            return NSRange(location: location, length: min(range.length, length - location))
        }

        @objc private func scrolled(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView else { return }
            model.scrollOffset = Double(clip.bounds.origin.y)
        }

        // MARK: Typing

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            styleEdits()
            model.update(text: textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            var selection = textView.selectedRange()
            if styler.hidesMarkup, !snappingCaret, selection.length == 0 {
                let caret = TextMode.caret(selection.location, from: lastCaret, in: textView.string)
                if caret != selection.location {
                    snappingCaret = true
                    textView.setSelectedRange(NSRange(location: caret, length: 0))
                    snappingCaret = false
                    selection = textView.selectedRange()
                }
            }
            lastCaret = selection.location
            model.selection = selection
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard !applyingEdit, let text else { return true }
            if let lines = MarkdownEditing.withPlainLineBreaks(text) {
                apply(TextEdit(range: range, replacement: lines, selection: NSRange(location: range.location + (lines as NSString).length, length: 0)))
                return false
            }
            if styler.hidesMarkup, let edit = TextMode.edit(replacing: range, with: text, selection: textView.selectedRange(), in: textView.string) {
                apply(edit)
                return false
            }
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let text = textView.string
            let selection = textView.selectedRange()
            let edit: TextEdit? = switch selector {
            case #selector(NSResponder.insertNewline(_:)): MarkdownEditing.newline(in: text, selection: selection)
            case #selector(NSResponder.insertTab(_:)): MarkdownEditing.indent(in: text, selection: selection, outdent: false, listsOnly: true)
            case #selector(NSResponder.insertBacktab(_:)): MarkdownEditing.indent(in: text, selection: selection, outdent: true)
            default: nil
            }
            guard let edit else { return false }
            apply(edit)
            return true
        }

        func perform(_ action: FormatAction) {
            guard let textView, !model.isReadOnly,
                  let edit = MarkdownEditing.apply(action, to: textView.string, selection: textView.selectedRange()) else { return }
            apply(edit)
        }

        /// Applies an edit the way typing does, so it can be undone.
        private func apply(_ edit: TextEdit) {
            applyingEdit = true
            defer { applyingEdit = false }
            guard let textView, let storage = textView.textStorage,
                  textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
            textView.setSelectedRange(edit.selection)
        }

        private func toggleCheckbox(at index: Int) -> Bool {
            guard let textView, !model.isReadOnly,
                  let edit = MarkdownEditing.toggleTask(in: textView.string, at: index, selection: textView.selectedRange()) else { return false }
            apply(edit)
            return true
        }
    }
}

/// `NSTextView` with clickable checkboxes, a readable line length and the Format menu's actions.
final class InkTextView: NSTextView {
    var onFormat: ((FormatAction) -> Void)?
    /// Called with the character index of a click; returns true if it handled the click.
    var onClick: ((Int) -> Bool)?
    static let maxTextWidth: CGFloat = 760

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The text starts at `side`; heading and list markers hang in the gutter to its left.
        let side = max(28, (newSize.width - Self.maxTextWidth) / 2) - EditorGutter.leading
        if textContainerInset.width != side { textContainerInset = NSSize(width: side, height: 22) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, !event.modifierFlags.contains(.shift), onClick?(characterIndexForInsertion(at: point)) == true {
            return
        }
        super.mouseDown(with: event)
    }

    @objc func performFormatCommand(_ sender: Any?) {
        guard let command = sender as? FormatCommand else { return }
        onFormat?(command.action)
    }
}
#endif
