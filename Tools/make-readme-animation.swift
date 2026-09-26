import AppKit
import ImageIO
import UniformTypeIdentifiers

guard let out = CommandLine.arguments.dropFirst().first else {
    FileHandle.standardError.write("usage: make-readme-animation out.gif\n".data(using: .utf8)!)
    exit(2)
}

let size = NSSize(width: 480, height: 270)
let scale: CGFloat = 2
let fps = 50.0
// Between the wink's end and the power-off's start in StartupAnimationView's timeline.
let logoAt: TimeInterval = 1.30
let logoHold: TimeInterval = 1.2
let darkHold: TimeInterval = 0.8

let view = StartupAnimationView(frame: NSRect(origin: .zero, size: size),
                                foreground: NSColor(calibratedWhite: 0.92, alpha: 1), revealing: nil)
let backgroundRGB: [Double] = [0.07, 0.07, 0.09]
let background = CGColor(srgbRed: backgroundRGB[0], green: backgroundRGB[1], blue: backgroundRGB[2], alpha: 1)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// Every pixel is the background blended toward white, so a 256-step ramp indexed by green is exact;
// ImageIO's own quantiser uses far fewer steps and bands the power-off glow into rings.
let palette: [UInt8] = (0..<256).flatMap { i -> [UInt8] in
    backgroundRGB.map { UInt8((($0 + (1 - $0) * Double(i) / 255) * 255).rounded()) }
}
let indexed = CGColorSpace(indexedBaseSpace: sRGB, last: 255, colorTable: palette)!

func frame(at t: Double) -> CGImage {
    view.render(at: t)
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    view.layer!.render(in: ctx)
    let rgba = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let floor = backgroundRGB[1] * 255
    var pixels = [UInt8](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        let g = Double(rgba[i * 4 + 1])
        pixels[i] = UInt8(max(0, min(255, ((g - floor) / (255 - floor) * 255).rounded())))
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                   space: indexed, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

var frames: [(t: Double, delay: Double)] = []
let step = 1 / fps
var t = 0.0
while t < StartupAnimationView.duration {
    frames.append((t, t == logoAt ? logoHold : step))
    let next = t + step
    if t < logoAt, next > logoAt { frames.append((logoAt, logoHold)) }
    t = next
}
frames.append((StartupAnimationView.duration, darkHold))

let url = URL(fileURLWithPath: out)
guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
    FileHandle.standardError.write("cannot write \(out)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for f in frames {
    let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: f.delay]] as CFDictionary
    CGImageDestinationAddImage(gif, frame(at: f.t), properties)
}
guard CGImageDestinationFinalize(gif) else {
    FileHandle.standardError.write("cannot write \(out)\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(out): \(frames.count) frames, \(Int(size.width * scale))×\(Int(size.height * scale))")
