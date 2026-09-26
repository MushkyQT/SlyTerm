import AppKit
import QuartzCore

final class StartupAnimationView: NSView {
    private static let introTempo: Double = 2.4
    private static let exitTempo: Double = 1.2
    private static let handover: TimeInterval = 3.35
    private static let handoverPlayed: TimeInterval = handover / introTempo

    private struct Beat {
        let start: TimeInterval, end: TimeInterval
        func progress(_ t: TimeInterval) -> CGFloat {
            CGFloat(min(1, max(0, (t - start) / (end - start))))
        }
        func contains(_ t: TimeInterval) -> Bool { t >= start && t < end }
        static func intro(_ start: TimeInterval, _ end: TimeInterval) -> Beat {
            Beat(start: start / introTempo, end: end / introTempo)
        }
        static func exit(_ start: TimeInterval, _ end: TimeInterval) -> Beat {
            Beat(start: handoverPlayed + (start - handover) / exitTempo,
                 end: handoverPlayed + (end - handover) / exitTempo)
        }
    }
    private static let draw = Beat.intro(0.00, 0.70)
    private static let prompt = Beat.intro(0.45, 0.80)
    private static let cursorOn = Beat.intro(0.80, 0.90)
    private static let blinkOff = Beat.intro(1.30, 1.55)
    private static let smirk = Beat.intro(1.85, 2.35)
    private static let winkShut = Beat.intro(2.50, 2.62)
    private static let winkHold = Beat.intro(2.62, 2.78)
    private static let winkOpen = Beat.intro(2.78, 2.98)
    private static let off = Beat.exit(3.35, 3.90)
    private static let ember = Beat.exit(3.75, 4.15)
    private static let reveal = Beat.exit(3.55, 3.80)
    static let duration: TimeInterval = Beat.exit(handover, 4.15).end
    private static let squashShare = 0.40, collapseShare = 0.32

    // Coordinates and stroke widths from Resources/StatusItemIcon.pdf's 18-unit grid, y down.

    private static let frameRect = CGRect(x: 1.55, y: 3.56, width: 15.01, height: 11.48)
    private static let frameCorner: CGFloat = 1.57
    private static let frameWidth: CGFloat = 1.10
    private static let markWidth: CGFloat = 0.92
    private static let chevron = [CGPoint(x: 4.20, y: 5.92), CGPoint(x: 6.15, y: 7.29), CGPoint(x: 4.20, y: 8.67)]
    private static let underscore = [CGPoint(x: 7.25, y: 9.13), CGPoint(x: 8.10, y: 9.13),
                                     CGPoint(x: 8.95, y: 9.13), CGPoint(x: 9.80, y: 9.13)]
    private static let smile = [CGPoint(x: 7.20, y: 9.50), CGPoint(x: 7.90, y: 10.00),
                                CGPoint(x: 9.50, y: 10.15), CGPoint(x: 10.57, y: 9.05)]
    private static let centre = CGPoint(x: 9.06, y: 9.30)

    private let face = CALayer()
    // Two halves so strokeEnd draws both sides at once; one path would sweep them in turn.
    private let frameHalves = [CAShapeLayer(), CAShapeLayer()]
    private let eye = CAShapeLayer()
    private let mouth = CAShapeLayer()
    private let glow = CALayer()
    private let beam = CALayer()
    private let dot = CALayer()
    private let ember = CALayer()

    private let foreground: CGColor
    private let foregroundColor: NSColor
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval?
    private weak var revealed: NSView?
    private var finished = false
    var onFinished: (() -> Void)?

    init(frame frameRect: NSRect, foreground: NSColor, revealing revealed: NSView?) {
        self.foreground = foreground.cgColor
        self.foregroundColor = foreground
        self.revealed = revealed
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let root = layer!
        root.masksToBounds = false
        for shape in frameHalves + [eye, mouth] {
            shape.fillColor = nil
            shape.strokeColor = self.foreground
            shape.lineCap = .round
            shape.lineJoin = .round
            face.addSublayer(shape)
        }
        root.addSublayer(face)
        for (l, grey) in [(glow, 1.0), (ember, 0.95)] as [(CALayer, CGFloat)] {
            l.contents = StartupAnimationView.disc(grey: grey)
            l.contentsGravity = .resize
            l.opacity = 0
            root.addSublayer(l)
        }
        for l in [beam, dot] {
            l.backgroundColor = CGColor(gray: 1, alpha: 1)
            l.opacity = 0
            root.addSublayer(l)
        }
        revealed?.alphaValue = 0
        updateContentsScale()
        render(at: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        guard window != nil, displayLink == nil, !finished else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for l in [face, eye, mouth, glow, beam, dot, ember] + frameHalves { l.contentsScale = scale }
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Clocked from the first frame, not init: the window can take a moment to come up.
        let now = link.targetTimestamp
        let start = startTime ?? now
        startTime = start
        let t = now - start
        if t >= StartupAnimationView.duration { finish(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        render(at: t)
        CATransaction.commit()
    }

    func finish() {
        guard !finished else { return }
        finished = true
        displayLink?.invalidate()
        displayLink = nil
        revealed?.alphaValue = 1
        removeFromSuperview()
        onFinished?()
    }

    // Must stay a pure function of t: the Tools scripts render arbitrary instants offscreen.
    func render(at t: TimeInterval) {
        typealias S = StartupAnimationView
        let b = bounds
        let unit = max(3, min(b.width * 0.40 / S.frameRect.width, b.height * 0.55 / S.frameRect.height, 24))
        let origin = CGPoint(x: b.midX - S.centre.x * unit, y: b.midY + S.centre.y * unit + 0.6 * unit)
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * unit, y: origin.y - p.y * unit) }
        let pivot = pt(S.centre)

        let off = S.off.progress(t)
        let squash = min(1, off / S.squashShare)
        let collapse = min(1, max(0, (off - S.squashShare) / S.collapseShare))
        let flash = max(0, (off - S.squashShare - S.collapseShare) / (1 - S.squashShare - S.collapseShare))
        let breath = Ease.inOut(min(1, squash / 0.25))
        let crush = squash <= 0.25 ? 0 : Ease.in((squash - 0.25) / 0.75)
        let swell = 1 + 0.03 * breath
        let sx = swell * (1 + 0.10 * crush)
        let sy = swell * (1 - 0.99 * crush)

        let drawn = Ease.out(S.draw.progress(t))
        let tilt = Ease.outBack(S.smirk.progress(t)) * 4 * (1 - crush)
        let winkLift = sin(.pi * Ease.inOut(min(1, (S.winkShut.progress(t) + S.winkOpen.progress(t)) / 2)))
        face.bounds = CGRect(origin: .zero, size: b.size)
        face.position = CGPoint(x: b.midX, y: b.midY)
        face.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, pivot.x - b.midX, pivot.y - b.midY + winkLift * 0.18 * unit, 0)
        transform = CATransform3DRotate(transform, CGFloat(tilt) * .pi / 180, 0, 0, 1)
        let scale = 0.96 + 0.04 * drawn
        transform = CATransform3DScale(transform, scale * sx, scale * sy, 1)
        transform = CATransform3DTranslate(transform, b.midX - pivot.x, b.midY - pivot.y, 0)
        face.transform = transform
        face.opacity = Float(1 - Ease.step(crush, 0.78, 1))
        let heat = min(1, 0.5 * breath + crush)
        let stroke = foregroundColor.blended(withFraction: heat, of: .white)?.cgColor ?? foreground
        for shape in frameHalves + [eye, mouth] { shape.strokeColor = stroke }

        for (half, side) in zip(frameHalves, [CGFloat(1), -1]) {
            half.lineWidth = S.frameWidth * unit
            half.path = S.frameHalf(side, in: S.frameRect, corner: S.frameCorner, unit: unit, pt: pt)
            half.strokeEnd = drawn
        }

        let pop = Ease.outBack(S.prompt.progress(t))
        let shut: CGFloat
        if S.winkShut.contains(t) || t < S.winkShut.start { shut = Ease.inOut(S.winkShut.progress(t)) }
        else if S.winkHold.contains(t) { shut = 1 }
        else { shut = 1 - Ease.outBack(S.winkOpen.progress(t)) }
        let closedY = S.chevron[1].y
        let eyePoints = S.chevron.enumerated().map { i, p -> CGPoint in
            guard i != 1 else { return CGPoint(x: p.x - 0.25 * shut, y: p.y) }
            return CGPoint(x: p.x, y: p.y + (closedY - p.y) * 0.92 * shut)
        }
        eye.lineWidth = S.markWidth * unit
        eye.path = S.polyline(eyePoints.map { S.scaled($0, about: S.eyeCentre, by: pop) }, pt: pt)
        eye.opacity = Float(min(1, pop * 2))

        let cursor = Ease.out(S.cursorOn.progress(t))
        let blink: CGFloat = S.blinkOff.contains(t) ? 0 : 1
        let bend = Ease.outBack(S.smirk.progress(t))
        let mouthPoints = zip(S.underscore, S.smile).map { u, s in
            CGPoint(x: u.x + (s.x - u.x) * bend, y: u.y + (s.y - u.y) * bend)
        }
        let grin = 1 + 0.06 * winkLift
        mouth.lineWidth = S.markWidth * unit
        mouth.path = S.cubic(mouthPoints.map { S.scaled($0, about: S.mouthCentre, by: grin) }, pt: pt)
        mouth.opacity = Float(cursor * blink)

        let frameWidth = (S.frameRect.width + S.frameWidth) * unit
        let beamHeight = max(2, 0.42 * unit)
        let run = 1 - Ease.inOut(collapse)
        let beamWidth = max(beamHeight, frameWidth * sx * run)
        beam.bounds = CGRect(x: 0, y: 0, width: beamWidth, height: beamHeight)
        beam.cornerRadius = beamHeight / 2
        beam.position = pivot
        beam.opacity = Float(Ease.step(crush, 0.6, 0.95) * (1 - Ease.step(flash, 0, 0.3)))

        let haloHeight = 2.6 * unit
        let glowWidth: CGFloat, glowHeight: CGFloat
        if flash > 0 {
            let flare = haloHeight * (1 + 4.5 * Ease.out(flash))
            glowWidth = flare; glowHeight = flare
        } else {
            glowWidth = max(haloHeight, beamWidth * 1.15 + haloHeight * 0.5)
            glowHeight = max(haloHeight, (S.frameRect.height + S.frameWidth) * unit * sy * 1.3)
        }
        glow.bounds = CGRect(x: 0, y: 0, width: glowWidth, height: glowHeight)
        glow.position = pivot
        glow.opacity = Float(flash > 0 ? 0.95 * (1 - Ease.out(flash)) : 0.10 * breath + 0.75 * crush * crush)

        let dotSize = 0.9 * unit * (1 - Ease.in(flash))
        dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        dot.cornerRadius = dotSize / 2
        dot.position = pivot
        dot.opacity = Float(flash > 0 ? 1 - Ease.in(flash) : 0)

        let emberSize = 1.4 * unit
        ember.bounds = CGRect(x: 0, y: 0, width: emberSize, height: emberSize)
        ember.position = pivot
        ember.opacity = Float(flash > 0 ? 0.4 * min(1, flash * 3) * (1 - Ease.out(S.ember.progress(t))) : 0)

        revealed?.alphaValue = Ease.inOut(S.reveal.progress(t))
    }

    private static let eyeCentre = CGPoint(x: 5.0, y: 7.29)
    private static let mouthCentre = CGPoint(x: 8.9, y: 9.6)

    private static func scaled(_ p: CGPoint, about c: CGPoint, by k: CGFloat) -> CGPoint {
        CGPoint(x: c.x + (p.x - c.x) * k, y: c.y + (p.y - c.y) * k)
    }

    private static func frameHalf(_ side: CGFloat, in r: CGRect, corner c: CGFloat, unit: CGFloat,
                                  pt: (CGPoint) -> CGPoint) -> CGPath {
        let x = side > 0 ? r.maxX : r.minX
        let path = CGMutablePath()
        path.move(to: pt(CGPoint(x: r.midX, y: r.minY)))
        path.addArc(tangent1End: pt(CGPoint(x: x, y: r.minY)), tangent2End: pt(CGPoint(x: x, y: r.maxY)), radius: c * unit)
        path.addArc(tangent1End: pt(CGPoint(x: x, y: r.maxY)), tangent2End: pt(CGPoint(x: r.midX, y: r.maxY)), radius: c * unit)
        path.addLine(to: pt(CGPoint(x: r.midX, y: r.maxY)))
        return path
    }

    private static func polyline(_ points: [CGPoint], pt: (CGPoint) -> CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map(pt))
        return path
    }

    private static func cubic(_ p: [CGPoint], pt: (CGPoint) -> CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: pt(p[0]))
        path.addCurve(to: pt(p[3]), control1: pt(p[1]), control2: pt(p[2]))
        return path
    }

    private static var discCache: [Int: CGImage] = [:]
    private static func disc(grey: CGFloat) -> CGImage {
        let key = Int(grey * 32)
        if let hit = discCache[key] { return hit }
        let g = CGFloat(key) / 32
        let side = 96
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(gray: g, alpha: 1), CGColor(gray: g, alpha: 0.85), CGColor(gray: g, alpha: 0)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 0.45, 1])!
        let c = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(side) / 2, options: [])
        let image = ctx.makeImage()!
        discCache[key] = image
        return image
    }
}

enum Ease {
    static func `in`(_ x: CGFloat) -> CGFloat { x * x * x }
    static func out(_ x: CGFloat) -> CGFloat { 1 - pow(1 - x, 3) }
    static func inOut(_ x: CGFloat) -> CGFloat { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func step(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let u = min(1, max(0, (x - a) / (b - a)))
        return u * u * (3 - 2 * u)
    }
    static func outBack(_ x: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}
