// Renders the app icon: a cream note with a coral "#" on warm charcoal.
// Usage: swift scripts/render_icon.swift <output folder>
// Writes icon-ios.png (full bleed; iOS rounds the corners) and icon-mac.png (rounded, with margin).
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(mac: Bool) -> Data {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let full = CGRect(x: 0, y: 0, width: size, height: size)
    // macOS icons draw their own rounded square, inset from the canvas edge.
    let tile = mac ? full.insetBy(dx: 100, dy: 100) : full
    let scale = tile.width / 1024

    ctx.saveGState()
    if mac {
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil))
        ctx.setFillColor(color(0x262624))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil))
        ctx.clip()
    }
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x34332F), color(0x1F1E1D)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])

    // The note: a cream page with its top-right corner folded.
    let page = CGRect(x: tile.minX + 262 * scale, y: tile.minY + 190 * scale, width: 500 * scale, height: 644 * scale)
    let fold = 150 * scale
    let radius = 46 * scale
    let path = CGMutablePath()
    path.move(to: CGPoint(x: page.minX + radius, y: page.minY))
    path.addArc(tangent1End: CGPoint(x: page.maxX, y: page.minY), tangent2End: CGPoint(x: page.maxX, y: page.minY + radius), radius: radius)
    path.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    path.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    path.addArc(tangent1End: CGPoint(x: page.minX, y: page.maxY), tangent2End: CGPoint(x: page.minX, y: page.maxY - radius), radius: radius)
    path.addArc(tangent1End: CGPoint(x: page.minX, y: page.minY), tangent2End: CGPoint(x: page.minX + radius, y: page.minY), radius: radius)
    path.closeSubpath()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 40 * scale, color: color(0x000000, 0.45))
    ctx.addPath(path)
    ctx.setFillColor(color(0xFAF9F5))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0)

    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    flap.addLine(to: CGPoint(x: page.maxX - fold + 18 * scale, y: page.maxY - fold))
    flap.addQuadCurve(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 18 * scale), control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    flap.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    flap.closeSubpath()
    ctx.addPath(flap)
    ctx.setFillColor(color(0xE3DFD2))
    ctx.fillPath()

    // A coral "#": two slanted verticals and two horizontals, with rounded ends.
    ctx.setStrokeColor(color(0xD97757))
    ctx.setLineCap(.round)
    ctx.setLineWidth(58 * scale)
    let cx = page.midX - 6 * scale
    let cy = page.midY + 40 * scale
    let half = 150 * scale
    let gap = 66 * scale
    let slant = 30 * scale
    for dx in [-gap, gap] {
        ctx.move(to: CGPoint(x: cx + dx - slant, y: cy - half))
        ctx.addLine(to: CGPoint(x: cx + dx + slant, y: cy + half))
    }
    for dy in [-gap, gap] {
        ctx.move(to: CGPoint(x: cx - half, y: cy + dy))
        ctx.addLine(to: CGPoint(x: cx + half, y: cy + dy))
    }
    ctx.strokePath()

    // Two text lines under it.
    ctx.setStrokeColor(color(0xC9C5B8))
    ctx.setLineWidth(26 * scale)
    for (y, width) in [(page.minY + 150 * scale, 300 * scale), (page.minY + 92 * scale, 210 * scale)] {
        ctx.move(to: CGPoint(x: page.minX + 100 * scale, y: y))
        ctx.addLine(to: CGPoint(x: page.minX + 100 * scale + width, y: y))
    }
    ctx.strokePath()
    ctx.restoreGState()

    let image = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try! render(mac: false).write(to: output.appendingPathComponent("icon-ios.png"))
try! render(mac: true).write(to: output.appendingPathComponent("icon-mac.png"))
