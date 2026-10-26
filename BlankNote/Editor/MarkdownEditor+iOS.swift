#if os(iOS)
import BlankNoteCore
import SwiftUI
import UIKit

/// The note editor on iPhone and iPad: a TextKit 2 `UITextView` that styles Markdown as you type.
struct MarkdownEditor: UIViewRepresentable {
    let model: EditorModel
    var fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, fontSize: fontSize)
    }

    func makeUIView(context: Context) -> InkTextView {
        // Not `init(usingTextLayoutManager:)`: that factory skips the subclass's stored properties.
        // A plain UITextView uses TextKit 2 anyway.
        let view = InkTextView(frame: .zero, textContainer: nil)
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: InkTextView, context: Context) {
        context.coordinator.update(model: model, fontSize: fontSize)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, NSTextStorageDelegate, NSTextLayoutManagerDelegate {
        private var model: EditorModel
        private let styler: MarkdownStyler
        private weak var textView: InkTextView?
        private var revision = -1
        private var applyingEdit = false

        init(model: EditorModel, fontSize: CGFloat) {
            self.model = model
            styler = MarkdownStyler(fontSize: fontSize)
        }

        func attach(_ view: InkTextView) {
            textView = view
            view.delegate = self
            view.accessibilityIdentifier = "editor"
            view.textStorage.delegate = self
            view.textLayoutManager?.delegate = self
            view.backgroundColor = .clear
            view.tintColor = Palette.accent
            view.alwaysBounceVertical = true
            view.keyboardDismissMode = .interactive
            view.smartQuotesType = .no
            view.smartDashesType = .no
            view.smartInsertDeleteType = .no
            view.typingAttributes = styler.baseAttributes
            view.linkTextAttributes = [.foregroundColor: Palette.accentText]
            view.inputAccessoryView = makeKeyboardBar()
            view.onFormat = { [weak self] action in self?.perform(action) }
            view.isCheckbox = { [weak self] point in self?.checkbox(at: point) != nil }
            view.checkboxTap.addTarget(self, action: #selector(checkboxTapped(_:)))
            view.addGestureRecognizer(view.checkboxTap)
        }

        func update(model: EditorModel, fontSize: CGFloat) {
            guard let textView else { return }
            self.model = model
            if styler.fontSize != fontSize {
                styler.fontSize = fontSize
                textView.typingAttributes = styler.baseAttributes
                styler.restyle(textView.textStorage, edited: nil)
            }
            if model.revision != revision {
                // A reload of the note on screen keeps the cursor and scroll position; so does a
                // new view of the note that was open (the window redrawn in a new theme).
                let isNewView = revision == -1
                revision = model.revision
                let keepsPlace = model.revisionIsReload && !isNewView
                let selection = keepsPlace ? textView.selectedRange : model.selection
                let offset = keepsPlace ? Double(textView.contentOffset.y + textView.adjustedContentInset.top) : model.scrollOffset
                textView.textStorage.setAttributedString(NSAttributedString(string: model.text, attributes: styler.baseAttributes))
                let length = textView.textStorage.length
                let location = min(selection.location, length)
                textView.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
                textView.undoManager?.removeAllActions()
                textView.setContentOffset(CGPoint(x: 0, y: -textView.adjustedContentInset.top), animated: false)
                if offset > 0 {
                    DispatchQueue.main.async { [weak textView] in
                        guard let textView else { return }
                        textView.layoutIfNeeded()
                        let top = -textView.adjustedContentInset.top
                        let bottom = max(top, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
                        textView.setContentOffset(CGPoint(x: 0, y: min(top + offset, bottom)), animated: false)
                    }
                }
            }
            textView.isEditable = !model.isReadOnly
            if model.wantsFocus {
                // After this update: the view may not be in a window yet.
                DispatchQueue.main.async {
                    if model.takeFocusRequest() { textView.becomeFirstResponder() }
                }
            }
        }

        // MARK: Styling

        nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                styler.restyle(textStorage, edited: editedRange)
            }
        }

        nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
            CodeBlockLayoutFragment.fragment(for: textElement)
        }

        // MARK: Typing

        func textViewDidChange(_ textView: UITextView) {
            model.update(text: textView.text)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            model.selection = textView.selectedRange
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            model.scrollOffset = Double(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !applyingEdit else { return true }
            if let lines = MarkdownEditing.withPlainLineBreaks(text) {
                apply(TextEdit(range: range, replacement: lines, selection: NSRange(location: range.location + (lines as NSString).length, length: 0)))
                return false
            }
            if text == "\n", let edit = MarkdownEditing.newline(in: textView.text, selection: range) {
                apply(edit)
                return false
            }
            if text == "\t", let edit = MarkdownEditing.indent(in: textView.text, selection: range, outdent: false, listsOnly: true) {
                apply(edit)
                return false
            }
            return true
        }

        func perform(_ action: FormatAction) {
            guard let textView, !model.isReadOnly,
                  let edit = MarkdownEditing.apply(action, to: textView.text, selection: textView.selectedRange) else { return }
            apply(edit)
        }

        /// Applies an edit through `UITextInput`, so it can be undone like typing.
        private func apply(_ edit: TextEdit) {
            guard let textView,
                  let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
                  let end = textView.position(from: start, offset: edit.range.length),
                  let range = textView.textRange(from: start, to: end) else { return }
            applyingEdit = true
            textView.replace(range, withText: edit.replacement)
            applyingEdit = false
            textView.selectedRange = edit.selection
            model.update(text: textView.text)
        }

        // MARK: Checkboxes

        private func checkbox(at point: CGPoint) -> NSRange? {
            guard let textView, !model.isReadOnly, let position = textView.closestPosition(to: point) else { return nil }
            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            guard let box = MarkdownEditing.taskBox(in: textView.text, at: offset),
                  let start = textView.position(from: textView.beginningOfDocument, offset: box.location),
                  let end = textView.position(from: start, offset: box.length),
                  let range = textView.textRange(from: start, to: end) else { return nil }
            // Generous target: the box plus a margin, at least 44 points wide.
            let rect = textView.firstRect(for: range).insetBy(dx: -10, dy: -8)
            let target = rect.width < 44 ? rect.insetBy(dx: (rect.width - 44) / 2, dy: 0) : rect
            return target.contains(point) ? box : nil
        }

        @objc private func checkboxTapped(_ gesture: UITapGestureRecognizer) {
            guard let textView, let box = checkbox(at: gesture.location(in: textView)),
                  let edit = MarkdownEditing.toggleTask(in: textView.text, at: box.location + 1, selection: textView.selectedRange) else { return }
            apply(edit)
            UISelectionFeedbackGenerator().selectionChanged()
        }

        // MARK: Keyboard bar

        private func makeKeyboardBar() -> KeyboardBar {
            KeyboardBar(
                items: [
                    .init(symbol: "checklist", label: "Checklist") { [weak self] in self?.perform(.checklist) },
                    .init(symbol: "list.bullet", label: "Bulleted List") { [weak self] in self?.perform(.bulletList) },
                    .init(symbol: "number", label: "Heading") { [weak self] in self?.perform(.heading) },
                    .init(symbol: "bold", label: "Bold") { [weak self] in self?.perform(.bold) },
                    .init(symbol: "italic", label: "Italic") { [weak self] in self?.perform(.italic) },
                    .init(symbol: "chevron.left.forwardslash.chevron.right", label: "Code") { [weak self] in self?.perform(.inlineCode) },
                    .init(symbol: "decrease.indent", label: "Outdent") { [weak self] in self?.perform(.outdent) },
                    .init(symbol: "increase.indent", label: "Indent") { [weak self] in self?.perform(.indent) },
                ],
                done: .init(symbol: "keyboard.chevron.compact.down", label: "Hide Keyboard") { [weak self] in
                    self?.textView?.resignFirstResponder()
                })
        }
    }
}

/// The formatting buttons above the keyboard. A toolbar can't fit them all on an iPhone (iOS 26 spaces
/// its items widely, and the ends were pushed off screen), so the buttons sit in a strip that spreads
/// them out when there's room and scrolls sideways when there isn't, with Hide Keyboard pinned at the end.
final class KeyboardBar: UIInputView {
    struct Item {
        let symbol: String
        let label: String
        let action: () -> Void
    }

    private static let height: CGFloat = 56
    /// Eight buttons fit an iPhone 17 or 17 Pro without scrolling; narrower screens scroll.
    private static let buttonWidth: CGFloat = 40

    init(items: [Item], done: Item) {
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: Self.height), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        allowsSelfSizing = true

        let buttons = UIStackView(arrangedSubviews: items.map(Self.button))
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(buttons)

        let strip = UIVisualEffectView(effect: UIGlassEffect())
        strip.cornerConfiguration = .capsule()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.contentView.addSubview(scroll)

        let doneButton = Self.button(done)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        let doneGlass = UIVisualEffectView(effect: UIGlassEffect())
        doneGlass.cornerConfiguration = .capsule()
        doneGlass.translatesAutoresizingMaskIntoConstraints = false
        doneGlass.contentView.addSubview(doneButton)

        // The row fills an iPhone's width; on an iPad it stays compact and centred.
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.addSubview(strip)
        row.addSubview(doneGlass)
        let fill = row.widthAnchor.constraint(equalTo: safeAreaLayoutGuide.widthAnchor, constant: -16)
        fill.priority = .defaultHigh
        let content = scroll.contentLayoutGuide, frame = scroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            row.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(items.count) * 52 + 70),
            fill,
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            strip.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            strip.topAnchor.constraint(equalTo: row.topAnchor),
            strip.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            doneGlass.leadingAnchor.constraint(equalTo: strip.trailingAnchor, constant: 6),
            doneGlass.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            doneGlass.topAnchor.constraint(equalTo: strip.topAnchor),
            doneGlass.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
            doneGlass.widthAnchor.constraint(equalTo: doneGlass.heightAnchor),
            doneButton.centerXAnchor.constraint(equalTo: doneGlass.contentView.centerXAnchor),
            doneButton.centerYAnchor.constraint(equalTo: doneGlass.contentView.centerYAnchor),

            scroll.leadingAnchor.constraint(equalTo: strip.contentView.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: strip.contentView.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: strip.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: strip.contentView.bottomAnchor),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: content.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.heightAnchor.constraint(equalTo: frame.heightAnchor),
            // At least the strip's width, so the buttons spread out; wider (and scrolling) on small screens.
            buttons.widthAnchor.constraint(greaterThanOrEqualTo: frame.widthAnchor),
            buttons.widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(items.count) * Self.buttonWidth),
        ])
        let fit = buttons.widthAnchor.constraint(equalTo: frame.widthAnchor)
        fit.priority = .defaultLow
        fit.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    private static func button(_ item: Item) -> UIButton {
        let button = UIButton(type: .system, primaryAction: UIAction { _ in item.action() })
        button.setImage(UIImage(systemName: item.symbol), for: .normal)
        button.tintColor = Palette.accent
        button.accessibilityLabel = item.label
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: buttonWidth).isActive = true
        return button
    }
}

/// `UITextView` with tappable checkboxes, a readable line length and the Format menu's actions.
final class InkTextView: UITextView {
    var onFormat: ((FormatAction) -> Void)?
    var isCheckbox: ((CGPoint) -> Bool)?
    let checkboxTap = UITapGestureRecognizer()
    static let maxTextWidth: CGFloat = 720

    override func layoutSubviews() {
        super.layoutSubviews()
        // The text starts at `side`; heading and list markers hang in the gutter to its left.
        let side = max(20, (bounds.width - Self.maxTextWidth) / 2)
        let inset = UIEdgeInsets(top: 16, left: max(2, side - EditorGutter.leading), bottom: 60, right: side)
        if textContainerInset != inset { textContainerInset = inset }
    }

    /// Taps on a checkbox toggle it instead of moving the cursor (or bringing up the keyboard).
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        let onCheckbox = isCheckbox?(gesture.location(in: self)) ?? false
        if gesture === checkboxTap { return onCheckbox }
        if gesture is UITapGestureRecognizer, onCheckbox { return false }
        return super.gestureRecognizerShouldBegin(gesture)
    }

    @objc func performFormatCommand(_ sender: Any?) {
        guard let command = sender as? FormatCommand else { return }
        onFormat?(command.action)
    }
}
#endif

