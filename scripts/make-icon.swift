// Draws the app icon and writes an .iconset.
// Usage: ./build.sh --icon
//
// Same layout as the WatchDiary logo and the other hub icons (PhotoHub, TakeoutHub, FileHub,
// BackupHub): a tile in the main color at 18 % opacity over white, inside it a square in the full
// main color, and inside that only the glyph in white. ClearHub's main color is orange; the glyph is
// a tilted broom with a sparkle.
// Drawn in the logo's coordinates (viewBox 512, y pointing down); the logo's tile (8…504) sits on
// Apple's icon grid (824 × 824 with a 100 px margin at 1024).
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// ClearHub's main color: orange.
let mainColor: UInt32 = 0xE0701E
/// Stroke width of the other hub icons on the 340 square.
let barWidth: CGFloat = 30

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let s = CGFloat(pixels) / 1024
    let k = 824 / 496 * s
    let transform = NSAffineTransform()
    transform.translateX(by: 100 * s - 8 * k, yBy: CGFloat(pixels) - 100 * s + 8 * k)
    transform.scaleX(by: k, yBy: -k)
    transform.concat()

    // Tile: white with a shadow, the main color at 18 % opacity on top.
    let tile = NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 496, height: 496), xRadius: 112, yRadius: 112)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 16 * s
    shadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    shadow.set()
    NSColor.white.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(mainColor, 0.18).setFill()
    tile.fill()

    // Square in the full main color: 86…426 with radius 68.
    color(mainColor).setFill()
    NSBezierPath(roundedRect: NSRect(x: 86, y: 86, width: 340, height: 340), xRadius: 68, yRadius: 68).fill()

    // Broom, drawn upright around (0, 0) and then tilted, with its bristles towards the bottom left.
    NSGraphicsContext.saveGraphicsState()
    let tilt = NSAffineTransform()
    tilt.translateX(by: 270, yBy: 262)
    tilt.rotate(byDegrees: 35)
    tilt.concat()

    let handle = NSBezierPath()
    handle.lineWidth = barWidth
    handle.lineCapStyle = .round
    handle.move(to: NSPoint(x: 0, y: -140))
    handle.line(to: NSPoint(x: 0, y: -10))
    NSColor.white.setStroke()
    handle.stroke()

    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: -44, y: -20, width: 88, height: 34), xRadius: 10, yRadius: 10).fill()

    // Bristles: a trapezoid that widens downwards, split by gaps in the main color.
    let bristles = NSBezierPath()
    bristles.move(to: NSPoint(x: -44, y: 24))
    bristles.line(to: NSPoint(x: 44, y: 24))
    bristles.line(to: NSPoint(x: 76, y: 128))
    bristles.curve(to: NSPoint(x: 62, y: 140), controlPoint1: NSPoint(x: 78, y: 135), controlPoint2: NSPoint(x: 72, y: 140))
    bristles.line(to: NSPoint(x: -62, y: 140))
    bristles.curve(to: NSPoint(x: -76, y: 128), controlPoint1: NSPoint(x: -72, y: 140), controlPoint2: NSPoint(x: -78, y: 135))
    bristles.close()
    bristles.fill()

    let gaps = NSBezierPath()
    gaps.lineWidth = 10
    gaps.lineCapStyle = .round
    for x: CGFloat in [-22, 0, 22] {
        gaps.move(to: NSPoint(x: x, y: 62))
        gaps.line(to: NSPoint(x: x * 1.6, y: 150))
    }
    color(mainColor).setStroke()
    gaps.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Sparkle at the top left: four-pointed star with concave sides.
    func sparkle(_ c: NSPoint, _ r: CGFloat) {
        let star = NSBezierPath()
        let points = [NSPoint(x: c.x, y: c.y - r), NSPoint(x: c.x + r, y: c.y), NSPoint(x: c.x, y: c.y + r), NSPoint(x: c.x - r, y: c.y)]
        star.move(to: points[0])
        for i in 1...4 {
            star.curve(to: points[i % 4], controlPoint1: NSPoint(x: c.x + (points[i - 1].x - c.x) * 0.12, y: c.y + (points[i - 1].y - c.y) * 0.12),
                       controlPoint2: NSPoint(x: c.x + (points[i % 4].x - c.x) * 0.12, y: c.y + (points[i % 4].y - c.y) * 0.12))
        }
        star.close()
        NSColor.white.setFill()
        star.fill()
    }
    sparkle(NSPoint(x: 160, y: 168), 44)
    sparkle(NSPoint(x: 214, y: 128), 20)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in sizes {
    try render(pixels: entry.pixels).write(to: output.appendingPathComponent("\(entry.name).png"))
}
print("Icon set written: \(output.path)")
