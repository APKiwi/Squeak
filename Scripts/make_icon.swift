import AppKit
import Foundation

// Draws the Squeak app icon: a charcoal squircle with a minimal mouse face
// (two ear dots, a coral nose, fanned whiskers). Renders every size the
// .iconset needs. Run via Scripts/make_icon.sh, which then calls iconutil.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Squeak.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!

    // Rounded-rect (squircle-ish) background with a slight vertical gradient.
    let margin = s * 0.085
    let rect = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.19, blue: 0.23, alpha: 1),
                        NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)])!
        .draw(in: rect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let white = NSColor(white: 0.96, alpha: 1)
    let coral = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.60, alpha: 1)
    let cx = s * 0.5, cy = s * 0.49

    // Ears: two small filled dots above the nose.
    white.setFill()
    let ear = s * 0.085
    for side in [-1.0, 1.0] as [CGFloat] {
        let r = NSRect(x: cx + side * s * 0.155 - ear, y: cy + s * 0.135 - ear,
                       width: ear * 2, height: ear * 2)
        NSBezierPath(ovalIn: r).fill()
    }

    // Whiskers: three per side, fanning out from beside the nose.
    let lw = max(1.0, s * 0.014)
    white.setStroke()
    for side in [-1.0, 1.0] as [CGFloat] {
        for spread in [-1.0, 0.0, 1.0] as [CGFloat] {
            let p = NSBezierPath()
            p.lineWidth = lw
            p.lineCapStyle = .round
            p.move(to: NSPoint(x: cx + side * s * 0.055, y: cy + spread * s * 0.012))
            p.curve(to: NSPoint(x: cx + side * s * 0.345, y: cy + spread * s * 0.085),
                    controlPoint1: NSPoint(x: cx + side * s * 0.18, y: cy + spread * s * 0.02),
                    controlPoint2: NSPoint(x: cx + side * s * 0.27, y: cy + spread * s * 0.07))
            p.stroke()
        }
    }

    // Nose: a small coral dot, last so it sits on top.
    coral.setFill()
    let nose = s * 0.05
    NSBezierPath(ovalIn: NSRect(x: cx - nose, y: cy - s * 0.01 - nose,
                                width: nose * 2, height: nose * 2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// name -> pixel size for a macOS .iconset
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try! render(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("wrote \(sizes.count) PNGs to \(outDir)")
