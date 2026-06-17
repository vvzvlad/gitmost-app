import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(_ px: Int) -> CGImage {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // Reproduces Resources/gitmost-icon.svg: a dark rounded square with the
    // gitmost "git graph" mark. The mark lives in a 96-unit space, placed by the
    // SVG transform translate(128,128) scale(2.15) translate(-48,-48) on a 256 canvas.
    let f = s / 256.0   // canvas scale: icon px per SVG-256 unit
    let k = f * 2.15    // mark scale: icon px per mark unit

    // Map a point in the 96-unit mark space to the CG (y-up) pixel canvas.
    // The CGContext here is NOT flipped, so convert the SVG y-down value to y-up.
    func P(_ mx: CGFloat, _ my: CGFloat) -> CGPoint {
        let x = f * (128 + 2.15 * (mx - 48))
        let yDown = f * (128 + 2.15 * (my - 48))
        return CGPoint(x: x, y: s - yDown)
    }

    // 1) Dark rounded-square background (#0E1117), corner radius 60 on a 256 canvas.
    let bg = CGRect(x: 0, y: 0, width: s, height: s)
    ctx.addPath(roundedPath(bg, s * 60.0 / 256.0))
    ctx.setFillColor(CGColor(srgbRed: 0x0E/255.0, green: 0x11/255.0, blue: 0x17/255.0, alpha: 1))
    ctx.fillPath()

    // 2) Light strokes (#E6EDF3): a vertical stem and a quarter-circle arc.
    ctx.setStrokeColor(CGColor(srgbRed: 0xE6/255.0, green: 0xED/255.0, blue: 0xF3/255.0, alpha: 1))
    ctx.setLineWidth(9 * k)
    ctx.setLineCap(.round)

    // Vertical stem: mark (24,12) -> (24,60).
    ctx.beginPath()
    ctx.move(to: P(24, 12))
    ctx.addLine(to: P(24, 60))
    ctx.strokePath()

    // Quarter arc, center mark (36,36), radius 36, from (72,36) down to (36,72).
    // The context is y-up, so a visually clockwise arc (bulging toward the
    // bottom-right) runs from angle 0 to -pi/2.
    ctx.beginPath()
    ctx.addArc(center: P(36, 36), radius: 36 * k,
               startAngle: 0, endAngle: -CGFloat.pi / 2, clockwise: true)
    ctx.strokePath()

    // 3) Two green nodes (#3FB950), drawn on top of the stroke ends.
    ctx.setFillColor(CGColor(srgbRed: 0x3F/255.0, green: 0xB9/255.0, blue: 0x50/255.0, alpha: 1))
    for c in [P(72, 24), P(24, 72)] {
        let r = 12 * k
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fatalError("Cannot write PNG at \(url.path)") }
}

let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let resourcesDir = cwd.appendingPathComponent("Resources")
try? fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (name, pixel size) per Apple's iconset spec.
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    writePNG(drawIcon(px), to: iconset.appendingPathComponent("\(name).png"))
}

// Build the .icns from the iconset.
let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try proc.run()
proc.waitUntilExit()
try? fm.removeItem(at: iconset)
if proc.terminationStatus != 0 { fatalError("iconutil failed") }
print("Wrote \(icnsURL.path)")
