// Generates AppIcon.icns for the app bundle. Run by build.sh; not part of the app.
// Without a real icon the app shows up blank in Finder, Login Items and the About
// panel, which is most of what makes a bundle look unfinished.
import AppKit

let outDir = CommandLine.arguments[1]

/// Everything below is drawn by hand rather than pulled from SF Symbols: Apple's
/// license for those covers UI, not app icons, and this app gets handed around.
/// Geometry is in a 0...1 unit square with y pointing up, scaled to the canvas.

func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ s: Double) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: (cx - rx) * s, y: (cy - ry) * s,
                                width: rx * 2 * s, height: ry * 2 * s))
}

/// An ellipse tilted about its own centre, for ears that hang outward.
func tiltedEllipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double,
                   _ degrees: Double, _ s: Double) -> NSBezierPath {
    let path = ellipse(cx, cy, rx, ry, s)
    var t = AffineTransform.identity
    t.translate(x: cx * s, y: cy * s)
    t.rotate(byDegrees: degrees)
    t.translate(x: -cx * s, y: -cy * s)
    path.transform(using: t)
    return path
}

enum Fur {
    static let ear    = NSColor(srgbRed: 0.72, green: 0.46, blue: 0.25, alpha: 1)
    static let head   = NSColor(srgbRed: 0.99, green: 0.90, blue: 0.78, alpha: 1)
    static let snout  = NSColor(srgbRed: 1.00, green: 0.97, blue: 0.93, alpha: 1)
    static let ink    = NSColor(srgbRed: 0.24, green: 0.16, blue: 0.12, alpha: 1)
    static let chest  = NSColor(srgbRed: 0.95, green: 0.83, blue: 0.68, alpha: 1)
    static let collar = NSColor(srgbRed: 0.91, green: 0.31, blue: 0.24, alpha: 1)
    static let tag    = NSColor(srgbRed: 1.00, green: 0.78, blue: 0.24, alpha: 1)
}

/// A watchdog wearing a pet tag: it is a watchdog for the Find My daemon, so the
/// tag is the bit that says which. Detail comes off in two stages as the canvas
/// shrinks — the collar survives longest because without it the head and chest
/// merge into one cream blob.
func drawDog(size s: Double, px: Int) {
    let collar = px >= 32
    let fine = px >= 64
    // Ears first, so the head overlaps them and they read as floppy rather than
    // as two slabs stuck on the sides.
    Fur.ear.setFill()
    tiltedEllipse(0.243, 0.565, 0.098, 0.172, -20, s).fill()
    tiltedEllipse(0.757, 0.565, 0.098, 0.172, 20, s).fill()

    // Chest runs off the bottom of the icon; the caller clips to the squircle,
    // so it crops cleanly instead of spilling onto the canvas.
    Fur.chest.setFill()
    ellipse(0.50, 0.160, 0.215, 0.190, s).fill()

    if collar {
        Fur.collar.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0.305 * s, y: 0.245 * s,
                                         width: 0.39 * s, height: 0.055 * s),
                     xRadius: 0.027 * s, yRadius: 0.027 * s).fill()
        Fur.tag.setFill()
        ellipse(0.50, 0.212, 0.050, 0.050, s).fill()
        if fine {
            Fur.ink.setFill()
            ellipse(0.50, 0.212, 0.015, 0.015, s).fill()
        }
    }

    Fur.head.setFill()
    ellipse(0.50, 0.545, 0.243, 0.228, s).fill()

    Fur.snout.setFill()
    ellipse(0.50, 0.447, 0.145, 0.108, s).fill()

    Fur.ink.setFill()
    ellipse(0.405, 0.600, 0.045, 0.045, s).fill()
    ellipse(0.595, 0.600, 0.045, 0.045, s).fill()
    ellipse(0.500, 0.484, 0.052, 0.038, s).fill()

    guard fine else { return }

    NSColor.white.setFill()
    ellipse(0.421, 0.616, 0.016, 0.016, s).fill()
    ellipse(0.611, 0.616, 0.016, 0.016, s).fill()

    // Nose down to a small two-arc smile.
    Fur.ink.setStroke()
    let mouth = NSBezierPath()
    mouth.move(to: NSPoint(x: 0.50 * s, y: 0.446 * s))
    mouth.line(to: NSPoint(x: 0.50 * s, y: 0.413 * s))
    mouth.lineWidth = 0.019 * s
    mouth.lineCapStyle = .round
    mouth.stroke()

    for cx in [0.468, 0.532] {
        let curve = NSBezierPath()
        curve.appendArc(withCenter: NSPoint(x: cx * s, y: 0.413 * s), radius: 0.032 * s,
                        startAngle: 0, endAngle: 180, clockwise: true)
        curve.lineWidth = 0.019 * s
        curve.lineCapStyle = .round
        curve.stroke()
    }
}

func render(px: Int) -> Data {
    let s = Double(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons sit in a rounded square inset from the canvas edge.
    let inset = s * 0.094
    let box = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = box.width * 0.2237
    let shape = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    NSGradient(colors: [NSColor(srgbRed: 0.29, green: 0.62, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.09, green: 0.28, blue: 0.72, alpha: 1)])?
        .draw(in: shape, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    drawDog(size: s, px: px)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256),
                   ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px: px).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
