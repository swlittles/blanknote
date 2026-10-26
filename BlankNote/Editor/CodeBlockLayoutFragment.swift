import BlankNoteCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A TextKit 2 layout fragment that draws a code block's rounded background across the full width
/// of the text, rather than just behind the characters.
final class CodeBlockLayoutFragment: NSTextLayoutFragment {
    /// Padding between the block's edge and its text.
    static let inset: CGFloat = 12
    private static let radius: CGFloat = 8

    var position: CodeBlockPosition = .middle

    override var renderingSurfaceBounds: CGRect {
        backgroundRect.union(super.renderingSurfaceBounds)
    }

    private var backgroundRect: CGRect {
        let frame = layoutFragmentFrame
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? frame.width
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
        // From the text column's edge (right of the marker gutter) to its end.
        var rect = CGRect(x: padding + EditorGutter.leading - frame.minX, y: 0,
                          width: max(0, containerWidth - 2 * padding - EditorGutter.leading - EditorGutter.trailing), height: frame.height)
        // The block's top and bottom margins sit outside the drawn background.
        if position == .first, let style = paragraphStyle { rect.origin.y += style.paragraphSpacingBefore; rect.size.height -= style.paragraphSpacingBefore }
        if position == .last, let style = paragraphStyle { rect.size.height -= style.paragraphSpacing }
        return rect
    }

    private var paragraphStyle: NSParagraphStyle? {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return nil }
        return paragraph.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = backgroundRect.offsetBy(dx: point.x, dy: point.y)
        let radius = Self.radius
        let path = CGMutablePath()
        let roundTop = position == .first
        let roundBottom = position == .last
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + (roundTop ? radius : 0)))
        if roundTop {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        if roundBottom {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - radius, y: rect.maxY), radius: radius)
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radius), radius: radius)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()

        context.saveGState()
        #if os(macOS)
        context.setFillColor(Palette.codeBackground.cgColor)
        #else
        context.setFillColor(Palette.codeBackground.resolvedColor(with: UITraitCollection.current).cgColor)
        #endif
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }

    /// The fragment for a paragraph: a code block fragment for code lines, the default otherwise.
    static func fragment(for textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let raw = paragraph.attributedString.attribute(.blankNoteCodeBlock, at: 0, effectiveRange: nil) as? Int,
           let position = CodeBlockPosition(rawValue: raw) {
            let fragment = CodeBlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
            fragment.position = position
            return fragment
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
