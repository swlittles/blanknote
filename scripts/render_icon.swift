// Renders the app icon: a blank cream page filling the icon, its top-right corner peeled back to
// show coral, and a dark text cursor waiting on the first line.
// Usage: swift scripts/render_icon.swift [appiconset folder]
// Writes icon-ios.png plus its dark and tinted versions (full bleed; iOS rounds the corners) and
// the Mac sizes (a rounded tile with a margin and shadow, as macOS icons draw themselves).
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

struct Style {
    var page: (top: UInt32, bottom: UInt32)
    var peel: (top: UInt32, bottom: UInt32)
    var flap: UInt32
    var cursor: UInt32
    var shadow: CGFloat

    static let light = Style(page: (0xFBFAF6, 0xEBE7DC), peel: (0xE38A6C, 0xC4603F), flap: 0xDCD5C4, cursor: 0x2A2926, shadow: 0.3)
    static let dark = Style(page: (0x363530, 0x1F1E1D), peel: (0xE38A6C, 0xC4603F), flap: 0x4B4943, cursor: 0xF2F0E8, shadow: 0.5)
    /// Greyscale: iOS tints it by brightness, so the peel and cursor take the colour.
    static let tinted = Style(page: (0x1C1C1C, 0x000000), peel: (0xFFFFFF, 0xE6E6E6), flap: 0x6E6E6E, cursor: 0xEDEDED, shadow: 0.5)
}

func gradient(_ ctx: CGContext, _ colors: (top: UInt32, bottom: UInt32), _ rect: CGRect) {
    let g = CGGradient(colorsSpace: srgb, colors: [color(colors.top), color(colors.bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

/// Draws the design into a 1024-point square at the origin (scale the context for other sizes).
func draw(_ ctx: CGContext, _ style: Style) {
    let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    gradient(ctx, style.page, full)

    // The peeled corner: coral where the page has lifted away...
    let fold: CGFloat = 470
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: 1024 - fold, y: 1024))
    corner.addLine(to: CGPoint(x: 1024, y: 1024))
    corner.addLine(to: CGPoint(x: 1024, y: 1024 - fold))
    corner.closeSubpath()
    ctx.saveGState()
    ctx.addPath(corner)
    ctx.clip()
    gradient(ctx, style.peel, full)
    ctx.restoreGState()

    // ...and the back of the page folded down over it, curling slightly.
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: 1024 - fold, y: 1024))
    flap.addLine(to: CGPoint(x: 1024, y: 1024 - fold))
    flap.addLine(to: CGPoint(x: 1024 - fold + 46, y: 1024 - fold + 46))
    flap.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -12, height: -14), blur: 36, color: color(0x000000, style.shadow))
    ctx.addPath(flap)
    ctx.setFillColor(color(style.flap))
    ctx.fillPath()
    ctx.restoreGState()

    // The text cursor.
    let cursor = CGRect(x: 250, y: 290, width: 88, height: 400)
    ctx.addPath(CGPath(roundedRect: cursor, cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.setFillColor(color(style.cursor))
    ctx.fillPath()
}

func image(size: Int, _ body: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    body(ctx)
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ url: URL) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                 : "BlankNote/Resources/Assets.xcassets/AppIcon.appiconset")

for (name, style) in [("icon-ios", Style.light), ("icon-ios-dark", .dark), ("icon-ios-tinted", .tinted)] {
    write(image(size: 1024) { draw($0, style) }, output.appendingPathComponent("\(name).png"))
}

// The Mac icon: the design on a rounded tile inset from the canvas edge, with a drop shadow.
let mac = image(size: 1024) { ctx in
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(Style.light.page.bottom))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.translateBy(x: tile.minX, y: tile.minY)
    ctx.scaleBy(x: tile.width / 1024, y: tile.height / 1024)
    draw(ctx, .light)
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let resized = image(size: pixels) { $0.draw(mac, in: CGRect(x: 0, y: 0, width: pixels, height: pixels)) }
        write(resized, output.appendingPathComponent("mac-\(points)\(scale == 2 ? "@2x" : "").png"))
    }
}
print("Icons written to \(output.path)")
