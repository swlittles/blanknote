import Foundation
import BlankNoteCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// Marks the lines of a fenced code block (value: `CodeBlockPosition.rawValue`), so
    /// `CodeBlockLayoutFragment` can draw the block's background.
    static let blankNoteCodeBlock = NSAttributedString.Key("BlankNoteCodeBlock")
    /// Text mode: something to draw in place of hidden syntax (value: `MarkupOverlay.rawValue`), drawn
    /// by `MarkupLayoutFragment`.
    static let blankNoteOverlay = NSAttributedString.Key("BlankNoteOverlay")
}

/// What text mode draws over hidden Markdown.
enum MarkupOverlay: String {
    case bullet, box, checkedBox, quote, rule
}

/// Turns `MarkdownHighlighter`'s ranges into fonts, colours and paragraph styles in the text view's
/// storage. It only touches attributes, never characters, so typing and undo are unaffected.
final class MarkdownStyler {
    /// Text mode (the default): hide the syntax and draw bullets, checkboxes, quotes and rules
    /// instead. Off for notes edited as Markdown.
    var hidesMarkup = true
    var fontSize: CGFloat {
        didSet { if fontSize != oldValue { fonts.removeAll() } }
    }
    private var fenceCount = -1
    private var fonts: [String: PlatformFont] = [:]

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font(size: fontSize), .foregroundColor: Palette.text, .paragraphStyle: paragraph()]
    }

    /// Re-styles the text after an edit to `edited` (`nil` restyles everything).
    ///
    /// Usually only the edited lines need it. The whole note is redone when the title line changed
    /// or a code fence appeared or disappeared, since that changes how later lines look.
    func restyle(_ storage: NSTextStorage, edited: NSRange?) {
        let text = storage.string as NSString
        let fences = Self.countFences(in: text)
        var range = NSRange(location: 0, length: text.length)
        if let edited, fences == fenceCount, edited.location > Self.titleEnd(in: text) {
            range = text.paragraphRange(for: NSRange(location: min(edited.location, text.length), length: min(edited.length, text.length - min(edited.location, text.length))))
        }
        fenceCount = fences
        guard range.length > 0 else { return }

        storage.setAttributes(baseAttributes, range: range)
        for span in MarkdownHighlighter.spans(in: storage.string, limit: range) {
            let clipped = NSIntersectionRange(span.range, NSRange(location: 0, length: text.length))
            guard clipped.length > 0 else { continue }
            apply(span.style, to: clipped, in: storage)
        }
    }

    private func apply(_ style: MarkdownStyle, to range: NSRange, in storage: NSTextStorage) {
        switch style {
        case .title:
            storage.addAttributes([.font: font(size: fontSize * 1.55, weight: .bold), .paragraphStyle: paragraph(after: 0.5)], range: range)
            if !hidesMarkup { hangHeadingMarker(in: range, of: storage) }
        case .heading(let level):
            let scale: [CGFloat] = [1.45, 1.28, 1.14, 1.05, 1, 1]
            let size = fontSize * scale[min(max(level, 1), 6) - 1]
            storage.addAttributes([.font: font(size: size, weight: level <= 2 ? .bold : .semibold), .paragraphStyle: paragraph(before: 0.6, after: 0.25)], range: range)
            if !hidesMarkup { hangHeadingMarker(in: range, of: storage) }
        case .marker, .fence:
            if hidesMarkup {
                hide(range, in: storage)
            } else {
                storage.addAttribute(.foregroundColor, value: Palette.tertiaryText, range: range)
            }
        case .horizontalRule:
            if hidesMarkup {
                storage.addAttributes([.foregroundColor: PlatformColor.clear, .blankNoteOverlay: MarkupOverlay.rule.rawValue], range: range)
            } else {
                storage.addAttribute(.foregroundColor, value: Palette.tertiaryText, range: range)
            }
        case .bold:
            addTraits(bold: true, italic: false, in: range, of: storage)
        case .italic:
            addTraits(bold: false, italic: true, in: range, of: storage)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .inlineCode:
            storage.addAttributes([.font: monoFont(), .foregroundColor: Palette.accentText, .backgroundColor: Palette.codeBackground], range: range)
        case .codeBlock(let position):
            storage.addAttributes([
                .font: monoFont(), .foregroundColor: Palette.text,
                .blankNoteCodeBlock: position.rawValue, .paragraphStyle: codeParagraph(position),
            ], range: range)
        case .codeKeyword:
            storage.addAttribute(.foregroundColor, value: Palette.accentText, range: range)
        case .codeString:
            storage.addAttribute(.foregroundColor, value: Palette.green, range: range)
        case .codeComment:
            storage.addAttribute(.foregroundColor, value: Palette.tertiaryText, range: range)
        case .codeNumber:
            storage.addAttribute(.foregroundColor, value: Palette.blue, range: range)
        case .quote:
            storage.addAttribute(.foregroundColor, value: Palette.secondaryText, range: range)
            addTraits(bold: false, italic: true, in: range, of: storage)
            if hidesMarkup { storage.addAttribute(.blankNoteOverlay, value: MarkupOverlay.quote.rawValue, range: range) }
        case .link:
            storage.addAttribute(.foregroundColor, value: Palette.accentText, range: range)
        case .linkDestination:
            storage.addAttribute(.foregroundColor, value: Palette.tertiaryText, range: range)
            addLink(range, in: storage)
        case .url:
            storage.addAttributes([.foregroundColor: Palette.accentText, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            addLink(range, in: storage)
        case .tag:
            storage.addAttributes([.foregroundColor: Palette.accentText, .backgroundColor: Palette.tagBackground], range: range)
        case .listMarker:
            storage.addAttribute(.foregroundColor, value: Palette.accent, range: range)
            if hidesMarkup, Self.isBullet(range, in: storage.string as NSString) {
                // A bullet draws as a dot; a checklist item shows only its checkbox.
                storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)
                if !Self.isTask(after: range, in: storage.string as NSString) {
                    storage.addAttribute(.blankNoteOverlay, value: MarkupOverlay.bullet.rawValue, range: range)
                }
            }
            hangIndent(after: range, in: storage)
        case .taskBox(let checked):
            storage.addAttributes([.foregroundColor: checked ? Palette.green : Palette.accent, .font: monoFont(weight: .bold)], range: range)
            if hidesMarkup {
                storage.addAttributes([.foregroundColor: PlatformColor.clear,
                                       .blankNoteOverlay: (checked ? MarkupOverlay.checkedBox : .box).rawValue], range: range)
            }
            hangIndent(after: range, in: storage)
        case .completedTask:
            storage.addAttributes([.foregroundColor: Palette.secondaryText, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
    }

    // MARK: Attributes

    /// Text mode: syntax takes no room and can't be seen (it's still in the text, and saved).
    private func hide(_ range: NSRange, in storage: NSTextStorage) {
        let text = storage.string as NSString
        var range = range
        // Never the line break: it would merge the line with the next one on screen.
        while range.length > 0, let scalar = UnicodeScalar(text.character(at: NSMaxRange(range) - 1)),
              CharacterSet.newlines.contains(scalar) { range.length -= 1 }
        guard range.length > 0 else { return }
        storage.addAttributes([.font: font(size: 0.01), .foregroundColor: PlatformColor.clear, .kern: 0], range: range)
    }

    private static func isBullet(_ marker: NSRange, in text: NSString) -> Bool {
        guard marker.length == 1 else { return false }
        return ["-", "*", "+"].contains(text.substring(with: marker))
    }

    private static func isTask(after marker: NSRange, in text: NSString) -> Bool {
        var index = NSMaxRange(marker)
        while index < text.length, text.character(at: index) == 32 || text.character(at: index) == 9 { index += 1 }
        guard index + 3 <= text.length else { return false }
        let box = text.substring(with: NSRange(location: index, length: 3)).lowercased()
        return box == "[ ]" || box == "[x]"
    }

    private func addTraits(bold: Bool, italic: Bool, in range: NSRange, of storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? PlatformFont else { return }
            storage.addAttribute(.font, value: font.adding(bold: bold, italic: italic), range: subrange)
        }
    }

    private func addLink(_ range: NSRange, in storage: NSTextStorage) {
        var text = (storage.string as NSString).substring(with: range)
        if text.lowercased().hasPrefix("www.") { text = "https://" + text }
        if let url = URL(string: text), url.scheme != nil { storage.addAttribute(.link, value: url, range: range) }
    }

    /// A list item's bullet (or number, or checkbox) hangs in the gutter, so its text starts at the
    /// same edge as other lines; wrapped lines line up with the text too. Nested items keep their
    /// indentation.
    private func hangIndent(after marker: NSRange, in storage: NSTextStorage) {
        let text = storage.string as NSString
        let line = text.paragraphRange(for: marker)
        var end = NSMaxRange(marker)
        while end < NSMaxRange(line), text.character(at: end) == 32 || text.character(at: end) == 9 { end += 1 }
        var start = line.location
        while start < end, text.character(at: start) == 32 || text.character(at: start) == 9 { start += 1 }
        // Only the bullet or number hangs; a checkbox after it stays at the text's edge.
        var bulletEnd = start
        while bulletEnd < end, text.character(at: bulletEnd) != 32, text.character(at: bulletEnd) != 9 { bulletEnd += 1 }
        while bulletEnd < end, text.character(at: bulletEnd) == 32 || text.character(at: bulletEnd) == 9 { bulletEnd += 1 }
        hang(line: line, markerStart: start, hangingEnd: bulletEnd, textStart: end, in: storage)
    }

    /// A heading's `#` marks hang in the gutter at body size, so headings line up with the text.
    private func hangHeadingMarker(in range: NSRange, of storage: NSTextStorage) {
        let text = storage.string as NSString
        let line = text.paragraphRange(for: range)
        var end = line.location
        while end < NSMaxRange(line), text.character(at: end) == 35 { end += 1 }   // #
        guard end > line.location, end - line.location <= 6, end < NSMaxRange(line), text.character(at: end) == 32 else { return }
        while end < NSMaxRange(line), text.character(at: end) == 32 { end += 1 }
        storage.addAttribute(.font, value: font(size: fontSize, weight: .semibold), range: NSRange(location: line.location, length: end - line.location))
        hang(line: line, markerStart: line.location, hangingEnd: end, textStart: end, in: storage)
    }

    /// Puts `markerStart..<hangingEnd` in the gutter; wrapped lines start where the text does (`textStart`).
    private func hang(line: NSRange, markerStart: Int, hangingEnd: Int, textStart: Int, in storage: NSTextStorage) {
        func width(_ from: Int, _ to: Int) -> CGFloat {
            ceil(storage.attributedSubstring(from: NSRange(location: from, length: to - from)).size().width)
        }
        let style = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle ?? paragraph())
            .mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = max(0, EditorGutter.leading - width(markerStart, hangingEnd))
        style.headIndent = style.firstLineHeadIndent + width(line.location, textStart)
        storage.addAttribute(.paragraphStyle, value: style, range: line)
    }

    private func paragraph(before: CGFloat = 0, after: CGFloat = 0.15) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = EditorGutter.leading
        style.headIndent = EditorGutter.leading
        style.tailIndent = -EditorGutter.trailing
        style.lineSpacing = fontSize * 0.22
        style.paragraphSpacingBefore = fontSize * before
        style.paragraphSpacing = fontSize * after
        style.defaultTabInterval = fontSize * 1.6
        style.tabStops = []
        return style
    }

    private func codeParagraph(_ position: CodeBlockPosition) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.15
        style.firstLineHeadIndent = EditorGutter.leading + CodeBlockLayoutFragment.inset
        style.headIndent = EditorGutter.leading + CodeBlockLayoutFragment.inset
        style.tailIndent = -(EditorGutter.trailing + CodeBlockLayoutFragment.inset)
        style.defaultTabInterval = fontSize * 1.6
        style.tabStops = []
        style.paragraphSpacingBefore = position == .first ? fontSize * 0.4 : 0
        style.paragraphSpacing = position == .last ? fontSize * 0.4 : 0
        return style
    }

    // MARK: Fonts

    private func font(size: CGFloat, weight: PlatformFont.Weight = .regular) -> PlatformFont {
        let key = "sys-\(size)-\(weight.rawValue)"
        if let font = fonts[key] { return font }
        let font = PlatformFont.systemFont(ofSize: size, weight: weight)
        fonts[key] = font
        return font
    }

    private func monoFont(weight: PlatformFont.Weight = .regular) -> PlatformFont {
        let key = "mono-\(weight.rawValue)"
        if let font = fonts[key] { return font }
        let font = PlatformFont.monospacedSystemFont(ofSize: (fontSize * 0.88).rounded(), weight: weight)
        fonts[key] = font
        return font
    }

    // MARK: Text scanning

    private static func countFences(in text: NSString) -> Int {
        var count = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let first = range.length > 0 ? text.character(at: range.location) : 0
            // Cheap pre-check: fences start with ` or ~ (after up to 3 spaces).
            guard first == 96 || first == 126 || first == 32 else { return }
            if MarkdownHighlighter.isFenceLine(text.substring(with: range)) { count += 1 }
        }
        return count
    }

    /// The end of the note's first non-blank line, which is drawn as the title.
    private static func titleEnd(in text: NSString) -> Int {
        var end = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, _, enclosing, stop in
            end = NSMaxRange(enclosing)
            if let line, !line.trimmingCharacters(in: .whitespaces).isEmpty { stop.pointee = true }
        }
        return end
    }
}

extension PlatformFont {
    func adding(bold: Bool, italic: Bool) -> PlatformFont {
        #if os(macOS)
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
        #else
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
        #endif
    }
}

/// Room to the left of the text column where heading and list markers hang, so every line's text
/// starts at the same edge. The text views shrink their left inset by this much to make room.
enum EditorGutter {
    #if os(macOS)
    static let leading: CGFloat = 28
    /// NSTextView's insets are the same on both sides, so lines also end this much early to keep the
    /// right margin where it was.
    static let trailing: CGFloat = 28
    #else
    static let leading: CGFloat = 24
    static let trailing: CGFloat = 0
    #endif
}
