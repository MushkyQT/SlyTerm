import AppKit
import CoreText

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: swift Tools/make-lookup-fixtures.swift <out dir>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let screen = CGSize(width: 1440, height: 900)
let scale: CGFloat = 2

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }

let header = { (size: CGFloat) in font("Georgia-Bold", size) }
let body = { (size: CGFloat) in font("Verdana", size) }
let bodyBold = { (size: CGFloat) in font("Verdana-Bold", size) }

final class Canvas {
    let ctx: CGContext

    init() {
        ctx = CGContext(data: nil, width: Int(screen.width * scale), height: Int(screen.height * scale),
                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: screen.height)
        ctx.scaleBy(x: 1, y: -1)
        // Without this CoreText draws glyphs upside down in the flipped context.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setShouldSmoothFonts(false)
    }

    func fill(_ r: CGRect, _ color: CGColor, radius: CGFloat = 0) {
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    func stroke(_ r: CGRect, _ color: CGColor, width: CGFloat = 1, radius: CGFloat = 0) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: width / 2, dy: width / 2), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
    }

    func ellipse(_ r: CGRect, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: r)
    }

    func gradient(_ r: CGRect, _ top: CGColor, _ bottom: CGColor) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        ctx.restoreGState()
    }

    static func width(of text: String, _ font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font, rgb(1, 1, 1)), nil, nil, nil))
    }

    static func line(_ text: String, _ font: CTFont, _ color: CGColor) -> CTLine {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        return CTLineCreateWithAttributedString(attributed)
    }

    @discardableResult
    func text(_ s: String, _ p: CGPoint, _ font: CTFont, _ color: CGColor, shadow: Bool = true) -> CGRect {
        let line = Self.line(s, font, color)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        ctx.saveGState()
        if shadow { ctx.setShadow(offset: CGSize(width: 1, height: 1), blur: 1, color: rgb(0, 0, 0, 0.9)) }
        ctx.textPosition = CGPoint(x: p.x, y: p.y + ascent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return CGRect(x: p.x, y: p.y, width: w, height: ascent + descent)
    }

    @discardableResult
    func text(_ s: String, right: CGFloat, top: CGFloat, _ font: CTFont, _ color: CGColor) -> CGRect {
        text(s, CGPoint(x: right - Self.width(of: s, font), y: top), font, color)
    }

    func wrapped(_ s: String, _ p: CGPoint, width: CGFloat, step: CGFloat, _ font: CTFont, _ color: CGColor) -> CGFloat {
        var y = p.y
        var current = ""
        for word in s.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if Self.width(of: candidate, font) > width, !current.isEmpty {
                text(current, CGPoint(x: p.x, y: y), font, color)
                y += step
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { text(current, CGPoint(x: p.x, y: y), font, color); y += step }
        return y
    }

    func write(_ name: String) -> URL {
        let url = outDir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return url
    }
}

struct Seeded {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(UInt32.max >> 1)
    }
}

func landscape(_ c: Canvas, seed: UInt64, top: CGColor = rgb(0.10, 0.13, 0.20), bottom: CGColor = rgb(0.10, 0.14, 0.07)) {
    c.gradient(CGRect(origin: .zero, size: screen), top, bottom)
    var r = Seeded(state: seed)
    for _ in 0..<40 {
        let w = 60 + r.next() * 260, h = 30 + r.next() * 120
        let x = r.next() * screen.width - w / 2, y = screen.height * 0.35 + r.next() * screen.height * 0.7
        c.ellipse(CGRect(x: x, y: y, width: w, height: h), rgb(0.05 + r.next() * 0.1, 0.08 + r.next() * 0.12, 0.04 + r.next() * 0.06, 0.6))
    }
}

func tooltipPanel(_ c: Canvas, _ r: CGRect) {
    c.fill(r, rgb(0.03, 0.04, 0.13, 0.94), radius: 4)
    c.stroke(r, rgb(0.58, 0.58, 0.62), width: 1.5, radius: 4)
}

func slot(_ c: Canvas, _ r: CGRect, icon: CGColor?, count: String? = nil) {
    c.fill(r, rgb(0.07, 0.07, 0.08), radius: 3)
    c.stroke(r, rgb(0.33, 0.30, 0.25), width: 1.5, radius: 3)
    if let icon {
        c.gradient(r.insetBy(dx: 4, dy: 4), icon, rgb(0.05, 0.05, 0.05))
        c.stroke(r.insetBy(dx: 4, dy: 4), rgb(0, 0, 0, 0.6), width: 1)
    }
    if let count { c.text(count, right: r.maxX - 4, top: r.maxY - 16, bodyBold(11), rgb(1, 1, 1)) }
}

func actionBar(_ c: Canvas) {
    let size: CGFloat = 38, gap: CGFloat = 4
    let width = 12 * size + 11 * gap
    let x0 = (screen.width - width) / 2, y = screen.height - size - 14
    let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="]
    let colours = [rgb(0.6, 0.2, 0.1), rgb(0.2, 0.3, 0.6), rgb(0.5, 0.5, 0.1), rgb(0.3, 0.5, 0.2)]
    for (i, key) in keys.enumerated() {
        let r = CGRect(x: x0 + CGFloat(i) * (size + gap), y: y, width: size, height: size)
        slot(c, r, icon: colours[i % colours.count])
        c.text(key, right: r.maxX - 3, top: r.minY + 2, bodyBold(9), rgb(0.9, 0.9, 0.9))
    }
}

func playerFrame(_ c: Canvas, name: String) {
    c.ellipse(CGRect(x: 24, y: 20, width: 58, height: 58), rgb(0.35, 0.25, 0.2))
    c.fill(CGRect(x: 86, y: 30, width: 150, height: 40), rgb(0, 0, 0, 0.55), radius: 3)
    c.text(name, CGPoint(x: 94, y: 32), bodyBold(11), rgb(1, 0.82, 0))
    c.fill(CGRect(x: 92, y: 50, width: 138, height: 12), rgb(0.1, 0.6, 0.1), radius: 2)
    c.text("340 / 340", CGPoint(x: 134, y: 50), body(9), rgb(1, 1, 1))
}

func minimap(_ c: Canvas, zone: String) {
    let r = CGRect(x: screen.width - 170, y: 34, width: 140, height: 140)
    c.ellipse(r.insetBy(dx: -4, dy: -4), rgb(0.25, 0.22, 0.18))
    c.ellipse(r, rgb(0.18, 0.28, 0.14))
    c.text(zone, CGPoint(x: r.midX - Canvas.width(of: zone, header(12)) / 2, y: 12), header(12), rgb(1, 0.82, 0))
}

func chat(_ c: Canvas, at origin: CGPoint, _ lines: [(String, CGColor)]) {
    let step: CGFloat = 17
    c.fill(CGRect(x: origin.x - 6, y: origin.y - 6, width: 380, height: CGFloat(lines.count) * step + 12), rgb(0, 0, 0, 0.35), radius: 2)
    for (i, line) in lines.enumerated() {
        c.text(line.0, CGPoint(x: origin.x, y: origin.y + CGFloat(i) * step), body(12), line.1)
    }
}

struct TooltipLine {
    var left: String
    var right: String? = nil
    var font: CTFont = body(11.5)
    var color: CGColor = rgb(1, 1, 1)
    var wrap = false
}

enum Corner { case bottomRight, bottomLeft, topLeft }

@discardableResult
func tooltip(_ c: Canvas, _ lines: [TooltipLine], anchor: CGPoint, corner: Corner, minWidth: CGFloat = 0,
             panel: (Canvas, CGRect) -> Void = tooltipPanel) -> CGRect {
    let pad: CGFloat = 10, step: CGFloat = 16, titleStep: CGFloat = 21
    let wrapWidth = max(minWidth, Canvas.width(of: lines[0].left, lines[0].font))
    var width = wrapWidth
    for line in lines where !line.wrap {
        let w = Canvas.width(of: line.left, line.font) + (line.right.map { 30 + Canvas.width(of: $0, line.font) } ?? 0)
        width = max(width, w)
    }
    func layout(draw: Bool, origin: CGPoint) -> CGFloat {
        var y = origin.y + pad
        for (i, line) in lines.enumerated() {
            if line.wrap {
                if draw {
                    y = c.wrapped(line.left, CGPoint(x: origin.x + pad, y: y), width: width, step: step, line.font, line.color)
                } else {
                    var current = "", count = 0
                    for word in line.left.split(separator: " ") {
                        let next = current.isEmpty ? String(word) : current + " " + word
                        if Canvas.width(of: next, line.font) > width, !current.isEmpty { count += 1; current = String(word) } else { current = next }
                    }
                    y += step * CGFloat(count + (current.isEmpty ? 0 : 1))
                }
                continue
            }
            if draw {
                c.text(line.left, CGPoint(x: origin.x + pad, y: y), line.font, line.color)
                if let right = line.right { c.text(right, right: origin.x + pad + width, top: y, line.font, line.color) }
            }
            y += i == 0 ? titleStep : step
        }
        return y + pad - 4 - origin.y
    }
    let height = layout(draw: false, origin: .zero)
    let size = CGSize(width: width + 2 * pad, height: height)
    let origin: CGPoint
    switch corner {
    case .bottomRight: origin = CGPoint(x: anchor.x - size.width, y: anchor.y - size.height)
    case .bottomLeft: origin = CGPoint(x: anchor.x, y: anchor.y - size.height)
    case .topLeft: origin = anchor
    }
    let frame = CGRect(origin: origin, size: size)
    panel(c, frame)
    _ = layout(draw: true, origin: frame.origin)
    return frame
}

let linenCloth = [
    TooltipLine(left: "Linen Cloth", font: header(15)),
    TooltipLine(left: "Crafting Reagent", color: rgb(0.40, 0.73, 1)),
    TooltipLine(left: "Max Stack: 200"),
    TooltipLine(left: "Sell Price: 13"),
]

func questLog(_ c: Canvas) -> (pointer: CGPoint, parchment: CGRect) {
    let frame = CGRect(x: 60, y: 90, width: 700, height: 600)
    c.fill(frame, rgb(0.13, 0.12, 0.11, 0.97), radius: 6)
    c.stroke(frame, rgb(0.5, 0.44, 0.34), width: 2, radius: 6)
    c.text("Quest Log", CGPoint(x: frame.midX - Canvas.width(of: "Quest Log", header(14)) / 2, y: frame.minY + 10), header(14), rgb(1, 0.82, 0))
    let gold = rgb(1, 0.82, 0), grey = rgb(0.75, 0.75, 0.75)
    var y = frame.minY + 50
    var pointer = CGPoint.zero
    let list: [(String, Bool)] = [
        ("Elwynn Forest", true), ("Wolves Across the Border", false), ("A Threat Within", false),
        ("Westfall", true), ("The Defias Brotherhood", false), ("Goldtooth", false), ("Red Linen Goods", false),
        ("Redridge Mountains", true), ("Blackrock Menace", false), ("Solomon's Law", false),
    ]
    for (title, zone) in list {
        if zone {
            c.text("-", CGPoint(x: frame.minX + 18, y: y), bodyBold(12), grey)
            c.text(title, CGPoint(x: frame.minX + 32, y: y), bodyBold(12), grey)
        } else {
            let r = CGRect(x: frame.minX + 40, y: y - 2, width: 270, height: 18)
            if title == "The Defias Brotherhood" {
                c.fill(r, rgb(0.35, 0.30, 0.15), radius: 2)
                let w = Canvas.width(of: title, body(12))
                pointer = CGPoint(x: frame.minX + 44 + w * 0.4, y: y + 8)
            }
            c.text(title, CGPoint(x: frame.minX + 44, y: y), body(12), title == "The Defias Brotherhood" ? rgb(1, 1, 1) : gold)
        }
        y += 20
    }
    let parchment = CGRect(x: frame.minX + 340, y: frame.minY + 44, width: 340, height: 530)
    c.fill(parchment, rgb(0.86, 0.77, 0.58), radius: 3)
    let ink = rgb(0.18, 0.11, 0.05)
    c.text("The Defias Brotherhood", CGPoint(x: parchment.minX + 16, y: parchment.minY + 14), header(16), ink, shadow: false)
    var py = parchment.minY + 44
    for line in ["Gryan Stoutmantle wants you to find proof", "of the Defias Brotherhood's plans. Speak",
                 "with him again at Sentinel Hill."] {
        c.text(line, CGPoint(x: parchment.minX + 16, y: py), body(11.5), ink, shadow: false)
        py += 16
    }
    py += 14
    c.text("Description", CGPoint(x: parchment.minX + 16, y: py), header(14), ink, shadow: false)
    py += 24
    for line in ["The Defias Brotherhood has been causing", "trouble in Westfall for too long. Their",
                 "leader hides somewhere in the Deadmines,", "and the people of Sentinel Hill want", "him found."] {
        c.text(line, CGPoint(x: parchment.minX + 16, y: py), body(11.5), ink, shadow: false)
        py += 16
    }
    return (pointer, parchment)
}

struct Fixture {
    let file: String
    let pointer: CGPoint
    let game: String
    let expected: String
}

var made: [Fixture] = []

do {
    let c = Canvas()
    landscape(c, seed: 1)
    playerFrame(c, name: "Aelric")
    minimap(c, zone: "Elwynn Forest")
    actionBar(c)
    chat(c, at: CGPoint(x: 22, y: 700), [
        ("[General] Aelric: anyone up for Deadmines?", rgb(1, 0.75, 0.75)),
        ("[Trade] Morvain: WTS stacks of cloth, pst", rgb(1, 0.75, 0.75)),
        ("[Guild] Tessa: grats on the new mount!", rgb(0.25, 1, 0.25)),
        ("You receive loot: Linen Cloth x2.", rgb(0, 0.67, 0)),
    ])
    var y: CGFloat = 220
    for (title, objectives) in [("The Defias Brotherhood", ["- Defias Pillager slain: 3/10", "- Defias Looter slain: 5/10"]),
                                ("Goldtooth", ["- Bernice's Necklace: 0/1"])] {
        c.text(title, CGPoint(x: 1190, y: y), header(13), rgb(1, 0.82, 0))
        y += 19
        for o in objectives {
            c.text(o, CGPoint(x: 1196, y: y), body(11.5), rgb(0.85, 0.85, 0.85))
            y += 16
        }
        y += 10
    }
    let bag = CGRect(x: 1212, y: 600, width: 208, height: 230)
    c.fill(bag, rgb(0.12, 0.11, 0.10, 0.96), radius: 6)
    c.stroke(bag, rgb(0.45, 0.40, 0.32), width: 2, radius: 6)
    c.text("Backpack", CGPoint(x: bag.minX + 10, y: bag.minY + 8), bodyBold(11), rgb(1, 0.82, 0))
    let icons = [rgb(0.8, 0.8, 0.7), rgb(0.6, 0.3, 0.2), rgb(0.3, 0.5, 0.8), nil, rgb(0.5, 0.4, 0.2), rgb(0.7, 0.7, 0.3)]
    let counts = ["", "5", "", "", "12", ""]
    var hovered = CGRect.zero
    for row in 0..<4 {
        for col in 0..<4 {
            let r = CGRect(x: bag.minX + 10 + CGFloat(col) * 48, y: bag.minY + 28 + CGFloat(row) * 48, width: 44, height: 44)
            let n = row * 4 + col
            if row == 2, col == 2 {
                hovered = r
                slot(c, r, icon: rgb(0.85, 0.82, 0.72), count: "20")
            } else {
                let icon = icons[n % icons.count]
                slot(c, r, icon: icon, count: icon == nil || counts[n % counts.count].isEmpty ? nil : counts[n % counts.count])
            }
        }
    }
    tooltip(c, linenCloth, anchor: CGPoint(x: hovered.minX - 4, y: hovered.minY + 30), corner: .bottomRight)
    let url = c.write("wow-bag-tooltip.png")
    made.append(Fixture(file: url.lastPathComponent, pointer: CGPoint(x: hovered.midX, y: hovered.midY), game: "wow", expected: "Linen Cloth"))
}

do {
    let c = Canvas()
    landscape(c, seed: 2)
    minimap(c, zone: "Orgrimmar")
    actionBar(c)
    let pane = CGRect(x: 80, y: 96, width: 340, height: 540)
    c.fill(pane, rgb(0.13, 0.12, 0.11, 0.97), radius: 6)
    c.stroke(pane, rgb(0.5, 0.44, 0.34), width: 2, radius: 6)
    let name = "Aelric"
    c.text(name, CGPoint(x: pane.midX - Canvas.width(of: name, header(14)) / 2, y: pane.minY + 12), header(14), rgb(1, 0.82, 0))
    let level = "Level 60 Human Warrior"
    c.text(level, CGPoint(x: pane.midX - Canvas.width(of: level, body(11)) / 2, y: pane.minY + 32), body(11), rgb(1, 1, 1))
    c.gradient(CGRect(x: pane.minX + 64, y: pane.minY + 60, width: 212, height: 380), rgb(0.2, 0.18, 0.2), rgb(0.08, 0.07, 0.08))
    let colours = [rgb(0.5, 0.4, 0.3), rgb(0.3, 0.3, 0.5), rgb(0.6, 0.5, 0.2), rgb(0.4, 0.2, 0.2)]
    for i in 0..<8 {
        slot(c, CGRect(x: pane.minX + 12, y: pane.minY + 60 + CGFloat(i) * 48, width: 44, height: 44), icon: colours[i % 4])
        slot(c, CGRect(x: pane.maxX - 56, y: pane.minY + 60 + CGFloat(i) * 48, width: 44, height: 44), icon: colours[(i + 1) % 4])
    }
    var mainHand = CGRect.zero
    for i in 0..<3 {
        let r = CGRect(x: pane.midX - 70 + CGFloat(i) * 48, y: pane.minY + 450, width: 44, height: 44)
        if i == 0 { mainHand = r }
        slot(c, r, icon: i == 0 ? rgb(0.3, 0.6, 0.9) : colours[i])
    }
    var x = pane.minX + 10
    for tab in ["Character", "Reputation", "Skills", "Honor"] {
        let w = Canvas.width(of: tab, body(11)) + 24
        let r = CGRect(x: x, y: pane.maxY - 2, width: w, height: 26)
        c.fill(r, rgb(0.16, 0.14, 0.12), radius: 3)
        c.stroke(r, rgb(0.45, 0.4, 0.3), width: 1, radius: 3)
        c.text(tab, CGPoint(x: r.minX + 12, y: r.minY + 6), body(11), rgb(1, 0.82, 0))
        x += w + 4
    }
    let green = rgb(0.12, 1, 0)
    tooltip(c, [
        TooltipLine(left: "Thunderfury, Blessed Blade of the Windseeker", font: header(15), color: rgb(1, 0.5, 0)),
        TooltipLine(left: "Binds when picked up"),
        TooltipLine(left: "Unique"),
        TooltipLine(left: "One-Hand", right: "Sword"),
        TooltipLine(left: "44 - 84 Damage", right: "Speed 1.90"),
        TooltipLine(left: "+16 - 30 Nature Damage"),
        TooltipLine(left: "(36.4 damage per second)"),
        TooltipLine(left: "+5 Agility"),
        TooltipLine(left: "+8 Stamina"),
        TooltipLine(left: "+8 Fire Resistance"),
        TooltipLine(left: "+9 Nature Resistance"),
        TooltipLine(left: "Durability 125 / 125"),
        TooltipLine(left: "Requires Level 60"),
        TooltipLine(left: "Chance on hit: Blasts your enemy with lightning, dealing 300 Nature damage and then jumping to additional nearby enemies.",
                    color: green, wrap: true),
    ], anchor: CGPoint(x: mainHand.maxX + 4, y: mainHand.minY), corner: .bottomLeft)
    let url = c.write("wow-character-tooltip.png")
    made.append(Fixture(file: url.lastPathComponent, pointer: CGPoint(x: mainHand.midX, y: mainHand.midY), game: "wow",
                        expected: "Thunderfury, Blessed Blade of the Windseeker"))
}

do {
    let c = Canvas()
    landscape(c, seed: 3, top: rgb(0.16, 0.20, 0.12), bottom: rgb(0.22, 0.20, 0.12))
    let cream = rgb(0.93, 0.90, 0.82)
    c.fill(CGRect(x: 20, y: 16, width: 220, height: 48), rgb(0.14, 0.13, 0.12, 0.9), radius: 6)
    c.text("Kéraly", CGPoint(x: 32, y: 22), bodyBold(12), cream)
    c.text("Niveau 45", CGPoint(x: 32, y: 40), body(11), rgb(0.7, 0.68, 0.6))
    chat(c, at: CGPoint(x: 22, y: 720), [
        ("[Général] Bonjour à tous !", rgb(0.9, 0.9, 0.9)),
        ("[Commerce] Achète ailes de Tofu, MP moi", rgb(0.9, 0.7, 0.3)),
        ("[Guilde] Quelqu'un pour le donjon ?", rgb(0.5, 0.8, 1)),
    ])
    let panel = CGRect(x: 880, y: 110, width: 470, height: 640)
    c.fill(panel, rgb(0.17, 0.16, 0.14, 0.97), radius: 8)
    c.stroke(panel, rgb(0.42, 0.39, 0.32), width: 2, radius: 8)
    c.text("Inventaire", CGPoint(x: panel.minX + 18, y: panel.minY + 14), bodyBold(14), cream)
    var x = panel.minX + 18
    for tab in ["Équipement", "Consommables", "Ressources", "Quêtes"] {
        let w = Canvas.width(of: tab, body(11)) + 20
        c.fill(CGRect(x: x, y: panel.minY + 42, width: w, height: 24), rgb(0.24, 0.22, 0.19), radius: 4)
        c.text(tab, CGPoint(x: x + 10, y: panel.minY + 47), body(11), rgb(0.82, 0.8, 0.72))
        x += w + 6
    }
    let colours = [rgb(0.6, 0.5, 0.3), rgb(0.4, 0.5, 0.3), rgb(0.5, 0.3, 0.3), rgb(0.3, 0.4, 0.5), nil]
    var hovered = CGRect.zero
    for row in 0..<9 {
        for col in 0..<8 {
            let r = CGRect(x: panel.minX + 18 + CGFloat(col) * 54, y: panel.minY + 80 + CGFloat(row) * 54, width: 50, height: 50)
            if row == 3, col == 2 {
                hovered = r
                slot(c, r, icon: rgb(0.85, 0.75, 0.55))
            } else {
                slot(c, r, icon: colours[(row * 8 + col) % colours.count])
            }
        }
    }
    c.text("12 345 K", right: panel.maxX - 18, top: panel.maxY - 28, bodyBold(12), cream)
    tooltip(c, [
        TooltipLine(left: "Coiffe du Bouftou", font: header(15), color: rgb(1, 0.78, 0.35)),
        TooltipLine(left: "Niv. 10", color: rgb(0.75, 0.73, 0.66)),
        TooltipLine(left: "Coiffe", color: rgb(0.75, 0.73, 0.66)),
        TooltipLine(left: "+10 Vitalité", color: rgb(0.55, 0.85, 0.45)),
        TooltipLine(left: "+5 Force", color: rgb(0.55, 0.85, 0.45)),
    ], anchor: CGPoint(x: hovered.midX + 18, y: hovered.midY + 18), corner: .topLeft, minWidth: 150) { c, r in
        c.fill(r, rgb(0.09, 0.09, 0.08, 0.96), radius: 6)
        c.stroke(r, rgb(0.55, 0.5, 0.38), width: 1.5, radius: 6)
    }
    let url = c.write("dofus-inventory-tooltip.png")
    made.append(Fixture(file: url.lastPathComponent, pointer: CGPoint(x: hovered.midX, y: hovered.midY), game: "dofus", expected: "Coiffe du Bouftou"))
}

do {
    let c = Canvas()
    landscape(c, seed: 4)
    playerFrame(c, name: "Aelric")
    minimap(c, zone: "Westfall")
    actionBar(c)
    let pointer = questLog(c).pointer
    let url = c.write("wow-questlog.png")
    made.append(Fixture(file: url.lastPathComponent, pointer: pointer, game: "wow", expected: "The Defias Brotherhood, under the pointer"))
}

do {
    let c = Canvas()
    landscape(c, seed: 5)
    playerFrame(c, name: "Aelric")
    minimap(c, zone: "Elwynn Forest")
    actionBar(c)
    tooltip(c, [
        TooltipLine(left: "Hogger", font: header(15), color: rgb(1, 0.15, 0.1)),
        TooltipLine(left: "Level 11 Elite"),
    ], anchor: CGPoint(x: screen.width - 24, y: screen.height - 110), corner: .bottomRight, minWidth: 110)
    let url = c.write("wow-corner-tooltip.png")
    made.append(Fixture(file: url.lastPathComponent, pointer: CGPoint(x: screen.width / 2, y: screen.height / 2), game: "wow",
                        expected: "nothing within the radius; the pick list offers Hogger"))
}

do {
    let c = Canvas()
    landscape(c, seed: 4)
    playerFrame(c, name: "Aelric")
    minimap(c, zone: "Westfall")
    actionBar(c)
    let parchment = questLog(c).parchment
    let reward = CGRect(x: parchment.minX + 113, y: parchment.minY + 206, width: 44, height: 44)
    slot(c, CGRect(x: reward.minX - 50, y: reward.minY, width: 44, height: 44), icon: rgb(0.5, 0.4, 0.2))
    slot(c, reward, icon: rgb(0.85, 0.82, 0.72), count: "5")
    tooltip(c, linenCloth, anchor: CGPoint(x: reward.midX - 60, y: reward.minY - 4), corner: .bottomLeft)
    let url = c.write("wow-questlog-reward-tooltip.png")
    made.append(Fixture(file: url.lastPathComponent, pointer: CGPoint(x: reward.midX, y: reward.midY), game: "wow", expected: "Linen Cloth"))
}

do {
    let c = Canvas()
    landscape(c, seed: 4)
    playerFrame(c, name: "Aelric")
    minimap(c, zone: "Westfall")
    actionBar(c)
    _ = questLog(c)
    let bag = CGRect(x: 150, y: 350, width: 204, height: 60)
    c.fill(bag, rgb(0.12, 0.11, 0.10, 0.96), radius: 6)
    c.stroke(bag, rgb(0.45, 0.40, 0.32), width: 2, radius: 6)
    var hovered = CGRect.zero
    for col in 0..<4 {
        let r = CGRect(x: bag.minX + 8 + CGFloat(col) * 48, y: bag.minY + 8, width: 44, height: 44)
        if col == 1 {
            hovered = r
            slot(c, r, icon: rgb(0.85, 0.82, 0.72), count: "20")
        } else {
            slot(c, r, icon: [rgb(0.6, 0.3, 0.2), nil, rgb(0.3, 0.5, 0.8), rgb(0.5, 0.4, 0.2)][col])
        }
    }
    tooltip(c, linenCloth, anchor: CGPoint(x: hovered.midX - 60, y: hovered.minY - 4), corner: .bottomLeft)
    let url = c.write("wow-questlist-tooltip.png")
    made.append(Fixture(file: url.lastPathComponent, pointer: CGPoint(x: hovered.midX, y: hovered.midY), game: "wow", expected: "Linen Cloth"))
}

for f in made {
    let x = Int((f.pointer.x * scale).rounded()), y = Int((f.pointer.y * scale).rounded())
    print("\(outDir.appendingPathComponent(f.file).path)")
    print("    --at \(x) \(y) --game \(f.game)    expected: \(f.expected)")
}
