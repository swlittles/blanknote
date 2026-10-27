import BlankNoteCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Text mode: draws formatting in place of hidden Markdown on a line: a dot for a `-` bullet, a
/// circle (ticked or not) for a `[ ]` checkbox, a bar beside a `>` quote, and a line for `---`.
/// The syntax characters stay in the text, invisible, so the note is still saved as Markdown.
final class MarkupLayoutFragment: NSTextLayoutFragment {
    static func hasOverlay(_ string: NSAttributedString) -> Bool {
        var found = false
        string.enumerateAttribute(.blankNoteOverlay, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    private var paragraph: NSAttributedString? {
        (textElement as? NSTextParagraph)?.attributedString
    }

    override var renderingSurfaceBounds: CGRect {
        // The quote bar sits in the gutter, left of the text.
        super.renderingSurfaceBounds.union(CGRect(x: -layoutFragmentFrame.minX, y: 0, width: 1, height: layoutFragmentFrame.height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let paragraph else { return }
        context.saveGState()
        defer { context.restoreGState() }
        paragraph.enumerateAttribute(.blankNoteOverlay, in: NSRange(location: 0, length: paragraph.length)) { value, range, _ in
            guard let raw = value as? String, let overlay = MarkupOverlay(rawValue: raw) else { return }
            draw(overlay, for: range, in: paragraph, at: point, context: context)
        }
    }

    private func draw(_ overlay: MarkupOverlay, for range: NSRange, in paragraph: NSAttributedString, at point: CGPoint, context: CGContext) {
        let accent = Self.resolved(Palette.accent)
        switch overlay {
        case .quote:
            let x = point.x + max(2, EditorGutter.leading - 12) - layoutFragmentFrame.minX + (textLayoutManager?.textContainer?.lineFragmentPadding ?? 0)
            // From the top of the first line to the bottom of the last, whatever the line spacing.
            let lines = textLineFragments.map(\.typographicBounds)
            let top = lines.map(\.minY).min() ?? 0
            let bottom = lines.map(\.maxY).max() ?? layoutFragmentFrame.height
            let bar = CGRect(x: x, y: point.y + top + 1, width: 3, height: max(0, bottom - top - 2))
            context.setFillColor(Self.resolved(Palette.tertiaryText))
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
        case .rule:
            let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
            let width = (textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width) - 2 * padding - EditorGutter.leading - EditorGutter.trailing
            let y = point.y + layoutFragmentFrame.height / 2
            context.setFillColor(Self.resolved(Palette.tertiaryText))
            context.fill(CGRect(x: point.x + padding + EditorGutter.leading - layoutFragmentFrame.minX, y: y.rounded() - 0.5, width: max(0, width), height: 1))
        case .bullet, .box, .checkedBox:
            guard let (rect, font) = characterBox(range, in: paragraph) else { return }
            let box = rect.offsetBy(dx: point.x, dy: point.y)
            if overlay == .bullet {
                let size = max(4, font.pointSize * 0.3)
                let center = CGPoint(x: box.midX, y: box.maxY - font.xHeight / 2)
                context.setFillColor(accent)
                context.fillEllipse(in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            } else {
                let size = (font.capHeight * 1.45).rounded()
                let center = CGPoint(x: box.midX, y: box.maxY - font.capHeight / 2)
                let circle = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
                if overlay == .checkedBox {
                    context.setFillColor(accent)
                    context.fillEllipse(in: circle)
                    context.setStrokeColor(Self.resolved(Palette.background))
                    context.setLineWidth(max(1.5, size * 0.11))
                    context.setLineCap(.round)
                    context.setLineJoin(.round)
                    context.move(to: CGPoint(x: circle.minX + size * 0.28, y: circle.midY + size * 0.02))
                    context.addLine(to: CGPoint(x: circle.minX + size * 0.44, y: circle.midY + size * 0.18))
                    context.addLine(to: CGPoint(x: circle.minX + size * 0.74, y: circle.midY - size * 0.16))
                    context.strokePath()
                } else {
                    context.setStrokeColor(accent)
                    context.setLineWidth(1.5)
                    context.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
                }
            }
        }
    }

    /// Where `range` (in this paragraph) is drawn: its rect relative to the fragment, with the bottom
    /// at the baseline, and its font.
    private func characterBox(_ range: NSRange, in paragraph: NSAttributedString) -> (CGRect, PlatformFont)? {
        guard let line = textLineFragments.first(where: { NSLocationInRange(range.location, $0.characterRange) }),
              let font = paragraph.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont else { return nil }
        let start = line.locationForCharacter(at: range.location)
        let end = line.locationForCharacter(at: NSMaxRange(range))
        let origin = line.typographicBounds.origin
        let baseline = origin.y + line.glyphOrigin.y
        return (CGRect(x: origin.x + start.x, y: baseline - font.ascender, width: max(1, end.x - start.x), height: font.ascender), font)
    }

    private static func resolved(_ color: PlatformColor) -> CGColor {
        #if os(macOS)
        color.cgColor
        #else
        color.resolvedColor(with: UITraitCollection.current).cgColor
        #endif
    }
}
