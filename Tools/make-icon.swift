import AppKit
import QuartzCore

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let glyphURL = root.appendingPathComponent("Resources/StatusItemIcon.pdf")
guard let glyphPDF = NSImage(contentsOf: glyphURL) else {
    FileHandle.standardError.write("cannot read \(glyphURL.path)\n".data(using: .utf8)!)
    exit(1)
}

// Apple's icon grid: an 824 tile on a 1024 canvas, with a 185.4 continuous corner radius.
let canvas: CGFloat = 1024, corner: CGFloat = 185.4

func margin(forCanvas side: CGFloat) -> CGFloat { side <= 32 ? 40 : side <= 64 ? 70 : 100 }

// The drawing spans only x 1...17.113, y 2.406...14.996 of its 18x18 PDF page; size and centre
// the glyph from that box, not the page.
let pageSize: CGFloat = 18
let artOrigin = CGPoint(x: 1, y: 2.406), artSize = CGSize(width: 16.113, height: 12.590)

func glyphFraction(forCanvas side: CGFloat) -> CGFloat { side <= 32 ? 0.78 : side <= 64 ? 0.70 : 0.62 }

func rasterise(_ image: NSImage, width: Int, height: Int) -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

func renderIcon(side: CGFloat) -> CGImage {
    let s = side / canvas
    let px = Int(side)

    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: side, height: side)

    let inset = margin(forCanvas: side)
    let tile = canvas - 2 * inset
    let body = CAGradientLayer()
    body.frame = CGRect(x: inset * s, y: inset * s, width: tile * s, height: tile * s)
    let radius = corner * (tile / 824) * s
    body.cornerRadius = radius
    body.cornerCurve = .continuous
    body.masksToBounds = true
    body.colors = [NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.19, alpha: 1).cgColor,
                   NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 1).cgColor]
    // Explicit: in a bottom-up CGContext the default startPoint is the bottom.
    body.startPoint = CGPoint(x: 0.5, y: 1)
    body.endPoint = CGPoint(x: 0.5, y: 0)
    if side >= 64 {
        body.borderWidth = 3 * s
        body.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
    }
    if side >= 128 {
        body.shadowColor = NSColor.black.cgColor
        body.shadowOpacity = 0.28
        body.shadowRadius = 22 * s
        body.shadowOffset = CGSize(width: 0, height: 10 * s)
        body.masksToBounds = false // a clipped layer cannot cast a shadow, so a mask clips
        let clip = CALayer()
        clip.frame = CGRect(origin: .zero, size: body.frame.size)
        clip.backgroundColor = NSColor.black.cgColor
        clip.cornerRadius = radius
        clip.cornerCurve = .continuous
        body.mask = clip
    }
    root.addSublayer(body)

    let drawnWidth = glyphFraction(forCanvas: side) * tile * s
    let unit = drawnWidth / artSize.width
    let pageExtent = pageSize * unit
    let artCentre = CGPoint(x: artOrigin.x + artSize.width / 2, y: artOrigin.y + artSize.height / 2)
    let pageRect = CGRect(x: body.frame.midX - artCentre.x * unit,
                          y: body.frame.midY - artCentre.y * unit,
                          width: pageExtent, height: pageExtent)

    let glyph = CALayer()
    glyph.frame = pageRect
    glyph.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 1).cgColor
    let mask = CALayer()
    mask.frame = CGRect(origin: .zero, size: pageRect.size)
    mask.contents = rasterise(glyphPDF, width: max(1, Int(pageExtent.rounded())),
                              height: max(1, Int(pageExtent.rounded())))
    glyph.mask = mask
    root.addSublayer(glyph)

    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    // The layer tree is built bottom-up to match the context; isGeometryFlipped would invert it.
    root.render(in: ctx)
    return ctx.makeImage()!
}

let variants: [(name: String, side: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for v in variants {
    let image = renderIcon(side: v.side)
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: v.side, height: v.side)
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("\(v.name).png"))
}

let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
try? FileManager.default.removeItem(at: iconset)
print("wrote \(icns.path)")
