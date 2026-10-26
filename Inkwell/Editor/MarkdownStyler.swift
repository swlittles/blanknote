import Foundation
import InkwellCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// Marks the lines of a fenced code block (value: `CodeBlockPosition.rawValue`), so
    /// `CodeBlockLayoutFragment` can draw the block's background.
    static let inkwellCodeBlock = NSAttributedString.Key("InkwellCodeBlock")
}

/// Turns `MarkdownHighlighter`'s ranges into fonts, colours and paragraph styles in the text view's
/// storage. It only touches attributes, never characters, so typing and undo are unaffected.
final class MarkdownStyler {
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
        case .heading(let level):
            let scale: [CGFloat] = [1.45, 1.28, 1.14, 1.05, 1, 1]
            let size = fontSize * scale[min(max(level, 1), 6) - 1]
            storage.addAttributes([.font: font(size: size, weight: level <= 2 ? .bold : .semibold), .paragraphStyle: paragraph(before: 0.6, after: 0.25)], range: range)
        case .marker, .fence, .horizontalRule:
            storage.addAttribute(.foregroundColor, value: Palette.tertiaryText, range: range)
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
                .inkwellCodeBlock: position.rawValue, .paragraphStyle: codeParagraph(position),
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
            hangIndent(after: range, in: storage)
        case .taskBox(let checked):
            storage.addAttributes([.foregroundColor: checked ? Palette.green : Palette.accent, .font: monoFont(weight: .bold)], range: range)
            hangIndent(after: range, in: storage)
        case .completedTask:
            storage.addAttributes([.foregroundColor: Palette.secondaryText, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
    }

    // MARK: Attributes

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

    /// Wrapped lines of a list item line up with its text rather than its bullet.
    private func hangIndent(after marker: NSRange, in storage: NSTextStorage) {
        let text = storage.string as NSString
        let line = text.paragraphRange(for: marker)
        var end = NSMaxRange(marker)
        while end < NSMaxRange(line), text.character(at: end) == 32 || text.character(at: end) == 9 { end += 1 }
        let prefix = storage.attributedSubstring(from: NSRange(location: line.location, length: end - line.location))
        let style = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle ?? paragraph())
            .mutableCopy() as! NSMutableParagraphStyle
        style.headIndent = ceil(prefix.size().width)
        storage.addAttribute(.paragraphStyle, value: style, range: line)
    }

    private func paragraph(before: CGFloat = 0, after: CGFloat = 0.15) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
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
        style.firstLineHeadIndent = CodeBlockLayoutFragment.inset
        style.headIndent = CodeBlockLayoutFragment.inset
        style.tailIndent = -CodeBlockLayoutFragment.inset
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
