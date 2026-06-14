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

    // 1) Squircle body with margin (macOS icon grid leaves padding around the body).
    let margin = s * 0.09
    let body = CGRect(x: margin, y: margin, width: s - 2*margin, height: s - 2*margin)
    let bodyRadius = body.width * 0.2237
    ctx.saveGState()
    ctx.addPath(roundedPath(body, bodyRadius))
    ctx.clip()
    let top = CGColor(srgbRed: 0.922, green: 0.737, blue: 0.275, alpha: 1)    // #ebbc46
    let bottom = CGColor(srgbRed: 0.898, green: 0.671, blue: 0.098, alpha: 1) // #e5ab19
    let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    // 2) White document card with a soft shadow.
    let docW = body.width * 0.52
    let docH = body.height * 0.60
    let docRect = CGRect(x: body.midX - docW/2, y: body.midY - docH/2, width: docW, height: docH)
    let docRadius = docW * 0.10
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s*0.012), blur: s*0.03,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
    ctx.addPath(roundedPath(docRect, docRadius))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 3) Two tabs along the top edge of the document.
    let tabH = docH * 0.12
    let tabW = docW * 0.26
    let tabY = docRect.maxY - tabH * 0.5
    let tabColors = [CGColor(srgbRed: 0.898, green: 0.671, blue: 0.098, alpha: 1),
                     CGColor(srgbRed: 0.78,  green: 0.56,  blue: 0.08,  alpha: 1)]
    for i in 0..<2 {
        let tx = docRect.minX + docW*0.10 + CGFloat(i)*(tabW + docW*0.06)
        let tr = CGRect(x: tx, y: tabY, width: tabW, height: tabH)
        ctx.addPath(roundedPath(tr, tabH*0.35))
        ctx.setFillColor(tabColors[i])
        ctx.fillPath()
    }

    // 4) Four light-gray text lines (last one shorter).
    ctx.setFillColor(CGColor(srgbRed: 0.80, green: 0.82, blue: 0.85, alpha: 1))
    let lineH = docH * 0.055
    let lineX = docRect.minX + docW*0.14
    let lineW = docW * 0.72
    let startY = docRect.maxY - docH*0.34
    for i in 0..<4 {
        let ly = startY - CGFloat(i)*(lineH*2.1)
        let w = (i == 3) ? lineW*0.6 : lineW
        ctx.addPath(roundedPath(CGRect(x: lineX, y: ly, width: w, height: lineH), lineH/2))
        ctx.fillPath()
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
