// Zeichnet das App-Icon und erzeugt Resources/AppIcon.icns.
// Aufruf: swift Scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024

func drawIcon() -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        // macOS-Icon-Raster: 824 pt Fläche mit 100 pt Rand, Eckenradius ~185.
        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.shadowBlurRadius = 28
        shadow.set()
        NSColor.black.setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Hintergrund: Indigo → Türkis
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        NSGradient(colors: [
            NSColor(red: 0.27, green: 0.25, blue: 0.86, alpha: 1),
            NSColor(red: 0.10, green: 0.62, blue: 0.86, alpha: 1),
            NSColor(red: 0.12, green: 0.80, blue: 0.70, alpha: 1),
        ])!.draw(in: tile, angle: -60)
        // weicher Lichtschein oben
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Ordner (leicht nach links unten versetzt)
        let folderBack = NSBezierPath()
        folderBack.move(to: NSPoint(x: 250, y: 300))
        folderBack.line(to: NSPoint(x: 250, y: 640))
        folderBack.curve(to: NSPoint(x: 290, y: 680), controlPoint1: NSPoint(x: 250, y: 662), controlPoint2: NSPoint(x: 268, y: 680))
        folderBack.line(to: NSPoint(x: 430, y: 680))
        folderBack.curve(to: NSPoint(x: 470, y: 660), controlPoint1: NSPoint(x: 448, y: 680), controlPoint2: NSPoint(x: 458, y: 672))
        folderBack.line(to: NSPoint(x: 500, y: 630))
        folderBack.line(to: NSPoint(x: 700, y: 630))
        folderBack.curve(to: NSPoint(x: 740, y: 590), controlPoint1: NSPoint(x: 722, y: 630), controlPoint2: NSPoint(x: 740, y: 612))
        folderBack.line(to: NSPoint(x: 740, y: 300))
        folderBack.close()
        NSColor.white.withAlphaComponent(0.55).setFill()
        folderBack.fill()

        let folderFront = NSBezierPath(roundedRect: NSRect(x: 250, y: 260, width: 490, height: 320), xRadius: 40, yRadius: 40)
        NSGraphicsContext.saveGraphicsState()
        let frontShadow = NSShadow()
        frontShadow.shadowColor = NSColor(red: 0.1, green: 0.1, blue: 0.4, alpha: 0.35)
        frontShadow.shadowOffset = NSSize(width: 0, height: -10)
        frontShadow.shadowBlurRadius = 24
        frontShadow.set()
        NSColor.white.setFill()
        folderFront.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Kehr-Linien im Ordner: „wird geleert“
        let accent = NSColor(red: 0.20, green: 0.45, blue: 0.90, alpha: 1)
        for (i, width) in [260.0, 200.0, 130.0].enumerated() {
            let y = 480 - CGFloat(i) * 70
            let line = NSBezierPath(roundedRect: NSRect(x: 310, y: y, width: width, height: 30), xRadius: 15, yRadius: 15)
            accent.withAlphaComponent(0.85 - Double(i) * 0.25).setFill()
            line.fill()
        }

        // Partikel, die nach rechts oben davonfliegen
        let particles: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (620, 470, 30, 0.95), (680, 520, 24, 0.85), (735, 580, 19, 0.7),
            (690, 430, 17, 0.75), (770, 500, 13, 0.55), (790, 640, 11, 0.5),
        ]
        for (x, y, r, a) in particles {
            accent.withAlphaComponent(a).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2), xRadius: r * 0.35, yRadius: r * 0.35).fill()
        }

        // Funkeln oben rechts: „sauber“
        func sparkle(center c: NSPoint, radius r: CGFloat, alpha: CGFloat) {
            let path = NSBezierPath()
            let inner = r * 0.22
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4 + .pi / 2
                let rr = i.isMultiple(of: 2) ? r : inner
                let p = NSPoint(x: c.x + cos(angle) * rr, y: c.y + sin(angle) * rr)
                i == 0 ? path.move(to: p) : path.line(to: p)
            }
            path.close()
            NSColor.white.withAlphaComponent(alpha).setFill()
            path.fill()
        }
        sparkle(center: NSPoint(x: 770, y: 760), radius: 78, alpha: 1)
        sparkle(center: NSPoint(x: 660, y: 810), radius: 34, alpha: 0.85)
        return true
    }
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

let icon = drawIcon()
for base in [16, 32, 128, 256, 512] {
    try writePNG(icon, pixels: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(icon, pixels: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try writePNG(icon, pixels: 1024, to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Fertig: Resources/AppIcon.icns")
