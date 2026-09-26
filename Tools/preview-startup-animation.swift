import AppKit

let args = CommandLine.arguments.dropFirst()
guard let out = args.first else {
    FileHandle.standardError.write("usage: preview out.png [t...]\n".data(using: .utf8)!)
    exit(2)
}
let instants: [Double] = args.dropFirst().isEmpty
    ? stride(from: 0.0, through: StartupAnimationView.duration, by: 0.15).map { $0 }
    : args.dropFirst().compactMap(Double.init)

let size = NSSize(width: 620, height: 500)
let scale: CGFloat = 1
let view = StartupAnimationView(frame: NSRect(origin: .zero, size: size),
                                foreground: NSColor(calibratedWhite: 0.92, alpha: 1), revealing: nil)
let background = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor

func frame(at t: Double) -> CGImage {
    view.render(at: t)
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    view.layer!.render(in: ctx)
    return ctx.makeImage()!
}

let columns = min(6, instants.count)
let rows = (instants.count + columns - 1) / columns
let cell = CGSize(width: size.width * scale, height: size.height * scale)
let gutter: CGFloat = 8, label: CGFloat = 22
let sheetW = Int(CGFloat(columns) * (cell.width + gutter) + gutter)
let sheetH = Int(CGFloat(rows) * (cell.height + gutter + label) + gutter)
let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
sheet.lockFocus()
NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
                                            .foregroundColor: NSColor.white]
for (i, t) in instants.enumerated() {
    let col = i % columns, row = i / columns
    let x = gutter + CGFloat(col) * (cell.width + gutter)
    let y = CGFloat(sheetH) - gutter - CGFloat(row + 1) * (cell.height + gutter + label) + gutter + label
    let img = NSImage(cgImage: frame(at: t), size: cell)
    img.draw(in: NSRect(x: x, y: y, width: cell.width, height: cell.height))
    NSString(format: "t = %.2fs", t).draw(at: NSPoint(x: x, y: y - label + 2), withAttributes: attrs)
}
sheet.unlockFocus()
let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out): \(instants.count) frames")
