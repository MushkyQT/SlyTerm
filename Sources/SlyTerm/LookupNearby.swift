import AppKit

struct LookupCandidate: Equatable {
    enum Kind: String {
        case underPointer
        case title
        case line
    }

    let text: String
    let cleaned: String
    let kind: Kind
    // CoreGraphics points, origin top-left of the primary display (not AppKit's bottom-left).
    let frame: CGRect
    let distance: Double
    let confidence: Float
    let score: Double
    let block: Int
    var tooltip = false

    var inReach: Bool { tooltip || distance <= LookupNearby.radius }
}

struct LookupTextBlock {
    let lines: [OCR.Line]
    let frame: CGRect
    let members: [Int]
}

struct LookupTooltip {
    let blocks: [Int]
    let frame: CGRect
}

struct LookupAnalysis {
    let shot: ScreenGrabber.Shot
    let lines: [OCR.Line]
    let pointer: CGPoint
    let unit: CGFloat
    let blocks: [LookupTextBlock]
    let frames: [CGRect]
    // Nil for lines under two letters (stack counts, timers, keybinds): kept out of the layout
    // because they would glue a tooltip to the slot beside it.
    let blockOf: [Int?]
    let fills: [LookupColour?]
    let alongRow: [Int]
}

struct LookupColour: Equatable {
    var r: Double
    var g: Double
    var b: Double

    func distance(to other: LookupColour) -> Double {
        ((r - other.r) * (r - other.r) + (g - other.g) * (g - other.g) + (b - other.b) * (b - other.b)).squareRoot()
    }

    static func median(_ colours: [LookupColour]) -> LookupColour? {
        guard !colours.isEmpty else { return nil }
        func middle(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return LookupColour(r: middle(colours.map(\.r)), g: middle(colours.map(\.g)), b: middle(colours.map(\.b)))
    }

    var hex: String { String(format: "#%02x%02x%02x", Int(r), Int(g), Int(b)) }
}

enum LookupNearby {
    static let radius: Double = 10

    // Tuned on Tools/make-lookup-fixtures.swift screenshots and real game captures; distances are
    // in text heights. Retune against a fixture, not by eye.

    static let stackGap: CGFloat = 1.2
    static let stackIndent: CGFloat = 1.5
    static let stackHeights: CGFloat = 2.2
    static let rowOverlap: CGFloat = 0.5
    static let rowGap: CGFloat = 3
    static let containSlack: CGFloat = 0.5
    static let headerTallness: Double = 0.15
    static let fillTolerance: Double = 18
    static let rowReach: CGFloat = 8
    static let minConfidence: Float = 0.3
    static let underSlack = (horizontal: CGFloat(0.5), vertical: CGFloat(0.4))
    static let falloff: Double = 4
    static let tallWeight: Double = 0.25
    static let tooltipAbove: CGFloat = 1.5
    static let tooltipSections: CGFloat = 5
    static let tooltipOverlap: CGFloat = 0.5

    static func analyse(_ lines: [OCR.Line], in shot: ScreenGrabber.Shot, pointer: CGPoint) -> LookupAnalysis {
        let f = shot.frame
        // Vision boxes are normalised with a bottom-left origin.
        let frames = lines.map { line -> CGRect in
            let b = line.box
            return CGRect(x: f.minX + b.minX * f.width, y: f.minY + (1 - b.maxY) * f.height,
                          width: b.width * f.width, height: b.height * f.height)
        }
        let unit = max(4, median(frames.map(\.height)))
        let laid = lines.indices.filter { lines[$0].text.filter(\.isLetter).count >= 2 && frames[$0].height > 0 }
        let pixels = Pixels(shot)
        let inLayout = Set(laid)
        let fills = frames.indices.map { i in inLayout.contains(i) ? pixels?.fill(of: frames[i]) : nil }

        var parent = Array(lines.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for (n, i) in laid.enumerated() {
            for j in laid[(n + 1)...] where together(frames[i], frames[j]) && sameFill(fills[i], fills[j]) {
                parent[root(i)] = root(j)
            }
        }
        // A list's selected row has its own fill and would split the list: a lone line between
        // same-fill neighbours above and below rejoins them.
        var size: [Int: Int] = [:]
        for i in laid { size[root(i), default: 0] += 1 }
        for row in laid where size[root(row)] == 1 {
            let f = frames[row]
            let above = laid.filter { $0 != row && frames[$0].maxY <= f.midY && together(frames[$0], f) }
            let below = laid.filter { $0 != row && frames[$0].minY >= f.midY && together(f, frames[$0]) }
            for a in above {
                guard let c = below.first(where: { sameFill(fills[a], fills[$0]) }) else { continue }
                parent[root(row)] = root(a)
                parent[root(c)] = root(a)
                break
            }
        }
        // Absorb blocks inside another's rectangle (a tooltip's right column), but only on the
        // same fill: a tooltip drawn over a panel is inside the panel's rectangle too.
        var merged = true
        while merged {
            merged = false
            var extent: [Int: CGRect] = [:]
            var colours: [Int: [LookupColour]] = [:]
            for i in laid {
                extent[root(i)] = extent[root(i)].map { $0.union(frames[i]) } ?? frames[i]
                if let fill = fills[i] { colours[root(i), default: []].append(fill) }
            }
            let fill = colours.mapValues { LookupColour.median($0) }
            let slack = containSlack * unit
            outer: for (a, ra) in extent {
                for (b, rb) in extent where a != b && rb.insetBy(dx: -slack, dy: -slack).contains(ra)
                    && sameFill(fill[a] ?? nil, fill[b] ?? nil) {
                    parent[a] = b
                    merged = true
                    break outer
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in laid { groups[root(i), default: []].append(i) }

        var blocks = groups.values.map { members -> LookupTextBlock in
            let ordered = readingOrder(members, frames)
            let frame = ordered.dropFirst().reduce(frames[ordered[0]]) { $0.union(frames[$1]) }
            return LookupTextBlock(lines: ordered.map { lines[$0] }, frame: frame, members: ordered)
        }
        blocks.sort { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        var blockOf = [Int?](repeating: nil, count: lines.count)
        for (b, block) in blocks.enumerated() {
            for i in block.members { blockOf[i] = b }
        }
        let along = alongRow(laid, frames: frames, fills: fills, pixels: pixels, pointer: pointer, unit: unit) { i in
            blockOf[i].map { blocks[$0].frame.contains(pointer) } ?? false
        }
        return LookupAnalysis(shot: shot, lines: lines, pointer: pointer, unit: unit, blocks: blocks,
                              frames: frames, blockOf: blockOf, fills: fills, alongRow: along)
    }

    private static func sameFill(_ a: LookupColour?, _ b: LookupColour?) -> Bool {
        guard let a, let b else { return true }
        return a.distance(to: b) <= fillTolerance
    }

    private static func alongRow(_ laid: [Int], frames: [CGRect], fills: [LookupColour?], pixels: Pixels?,
                                 pointer: CGPoint, unit: CGFloat, inFrame: (Int) -> Bool) -> [Int] {
        var found: [(line: Int, gap: CGFloat)] = []
        for i in laid {
            let f = frames[i]
            guard f.minY - underSlack.vertical * unit <= pointer.y, pointer.y <= f.maxY + underSlack.vertical * unit else { continue }
            let gap = max(f.minX - pointer.x, pointer.x - f.maxX, 0)
            if inFrame(i) {
                found.append((i, gap))
            } else if gap <= rowReach * unit, let pixels, let fill = fills[i] {
                // Start a quarter height out: the box can end on the last letter's shadow.
                let start = pointer.x < f.minX ? f.minX - unit / 4 : f.maxX + unit / 4
                if pixels.runs(fill, from: start, to: pointer.x, at: f.midY, step: unit / 3) { found.append((i, gap)) }
            }
        }
        return found.sorted { $0.gap < $1.gap }.map(\.line)
    }

    private static func together(_ a: CGRect, _ b: CGRect) -> Bool {
        let small = min(a.height, b.height), large = max(a.height, b.height)
        let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let gapX = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        if overlapY >= rowOverlap * small, gapX <= rowGap * small { return true }
        guard -overlapY <= stackGap * small, large <= stackHeights * small else { return false }
        return gapX < 0 || abs(a.minX - b.minX) <= stackIndent * small
    }

    private static func readingOrder(_ members: [Int], _ frames: [CGRect]) -> [Int] {
        var rows: [[Int]] = []
        for i in members.sorted(by: { frames[$0].minY < frames[$1].minY }) {
            if let head = rows.last?.first {
                let a = frames[head], b = frames[i]
                if min(a.maxY, b.maxY) - max(a.minY, b.minY) >= rowOverlap * min(a.height, b.height) {
                    rows[rows.count - 1].append(i)
                    continue
                }
            }
            rows.append([i])
        }
        return rows.flatMap { $0.sorted { frames[$0].minX < frames[$1].minX } }
    }

    static func automatic(_ analysis: LookupAnalysis, game: LookupGame?) -> [LookupCandidate] {
        let a = analysis
        var cleaned: [Int: String] = [:]
        for i in a.lines.indices where a.blockOf[i] != nil && a.lines[i].confidence >= minConfidence {
            let text = LookupText.clean(a.lines[i].text, for: game)
            // Test the cleaned text: OSRS's `Use Pot / 2 more options` is a tooltip line only
            // until the cleaner has taken the name out of it.
            guard text.filter(\.isLetter).count >= 3, titleLike(i, in: a), !LookupText.isTooltipLine(text, for: game) else { continue }
            cleaned[i] = text
        }
        let under = underPointer(a, among: Array(cleaned.keys))
        var tooltipOf: [Int: Int] = [:]
        for (t, tooltip) in tooltips(in: a, game: game).enumerated() {
            for b in tooltip.blocks { tooltipOf[b] = t }
        }
        var named: [LookupCandidate] = []
        var titles: [LookupCandidate] = []
        for (b, block) in a.blocks.enumerated() {
            for i in block.members where i != under && (i == block.members[0] || tallness(of: i, in: block, a) >= headerTallness) {
                guard let text = cleaned[i] else { continue }
                if i == block.members[0], tooltipOf[b] != nil {
                    named.append(candidate(i, text, .title, in: a, block: b, tooltip: true))
                } else {
                    titles.append(candidate(i, text, .title, in: a, block: b))
                }
            }
        }
        named.sort { x, y in
            (tooltipOf[x.block] ?? 0, x.frame.minY, x.frame.minX) < (tooltipOf[y.block] ?? 0, y.frame.minY, y.frame.minX)
        }
        let home = under.flatMap { a.blockOf[$0] }
        titles.sort { x, y in
            let xn = x.distance <= radius, yn = y.distance <= radius
            if xn != yn { return xn }
            if (x.block == home) != (y.block == home) { return y.block == home }
            if x.score != y.score { return x.score > y.score }
            return (x.distance, x.frame.minY, x.frame.minX) < (y.distance, y.frame.minY, y.frame.minX)
        }
        var out: [LookupCandidate] = []
        if let under, let text = cleaned[under], let b = a.blockOf[under] {
            out.append(candidate(under, text, .underPointer, in: a, block: b))
        }
        var seen = Set(out.map { LookupText.normalize($0.cleaned) })
        for c in named + titles where seen.insert(LookupText.normalize(c.cleaned)).inserted { out.append(c) }
        return out
    }

    static func tooltips(in a: LookupAnalysis, game: LookupGame?) -> [LookupTooltip] {
        let sections = a.blocks.indices.filter { b in
            let members = a.blocks[b].members
            let telling = members.count == 1 ? members : Array(members.dropFirst())
            return telling.contains { LookupText.isTooltipLine(a.lines[$0].text, for: game) }
        }
        guard !sections.isEmpty else { return [] }
        var parent: [Int: Int] = [:]
        for b in sections { parent[b] = b }
        func root(_ b: Int) -> Int {
            var b = b
            while let up = parent[b], up != b { b = up }
            return b
        }
        let inSection = Set(sections)
        for b in a.blocks.indices where !inSection.contains(b) {
            let f = a.blocks[b].frame
            if let s = sections.first(where: { above(f, a.blocks[$0].frame, within: tooltipAbove * a.unit, unit: a.unit) }) {
                parent[b] = s
            }
        }
        let members = Array(parent.keys).sorted()
        for (n, x) in members.enumerated() {
            for y in members[(n + 1)...] where root(x) != root(y)
                && stacked(a.blocks[x].frame, a.blocks[y].frame, within: tooltipSections * a.unit) {
                parent[root(x)] = root(y)
            }
        }
        var groups: [Int: [Int]] = [:]
        for b in parent.keys { groups[root(b), default: []].append(b) }
        let tooltips = groups.values.map { blocks -> LookupTooltip in
            let ordered = blocks.sorted { (a.blocks[$0].frame.minY, a.blocks[$0].frame.minX) < (a.blocks[$1].frame.minY, a.blocks[$1].frame.minX) }
            let frame = ordered.dropFirst().reduce(a.blocks[ordered[0]].frame) { $0.union(a.blocks[$1].frame) }
            return LookupTooltip(blocks: ordered, frame: frame)
        }
        return tooltips.sorted { x, y in
            let dx = distance(from: a.pointer, to: x.frame), dy = distance(from: a.pointer, to: y.frame)
            return dx != dy ? dx < dy : (x.frame.minY, x.frame.minX) < (y.frame.minY, y.frame.minX)
        }
    }

    private static func stacked(_ a: CGRect, _ b: CGRect, within gap: CGFloat) -> Bool {
        max(a.minY - b.maxY, b.minY - a.maxY) <= gap && shareSpan(a, b)
    }

    private static func above(_ upper: CGRect, _ lower: CGRect, within gap: CGFloat, unit: CGFloat) -> Bool {
        let apart = lower.minY - upper.maxY
        return upper.midY < lower.minY && apart >= -containSlack * unit && apart <= gap && shareSpan(upper, lower)
    }

    private static func shareSpan(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) >= tooltipOverlap * min(a.width, b.width)
    }

    static func forPicking(_ analysis: LookupAnalysis, game: LookupGame?, limit: Int = 20) -> [LookupCandidate] {
        let a = analysis
        var cleaned: [Int: String] = [:]
        for i in a.lines.indices where a.blockOf[i] != nil && a.lines[i].confidence >= minConfidence {
            let text = LookupText.clean(a.lines[i].text, for: game)
            if text.filter(\.isLetter).count >= 2 { cleaned[i] = text }
        }
        let under = underPointer(a, among: Array(cleaned.keys))
        let home = under.flatMap { a.blockOf[$0] }
        let blockDistance = a.blocks.indices.map { b in
            b == home ? 0 : Double(distance(from: a.pointer, to: a.blocks[b].frame) / a.unit)
        }
        let tooltips = tooltips(in: a, game: game)
        var tooltipOf: [Int: Int] = [:]
        for (t, tooltip) in tooltips.enumerated() {
            for b in tooltip.blocks { tooltipOf[b] = t }
        }
        let tooltipDistance = tooltips.map { Double(distance(from: a.pointer, to: $0.frame) / a.unit) }
        let all = cleaned.map { i, text -> (candidate: LookupCandidate, order: (Int, Double, Int, Double, Int)) in
            let b = a.blockOf[i]!
            let position = a.blocks[b].members.firstIndex(of: i) ?? 0
            let kind: LookupCandidate.Kind = i == under ? .underPointer : position == 0 ? .title : .line
            let d = Double(distance(from: a.pointer, to: a.frames[i]) / a.unit)
            let candidate = LookupCandidate(text: a.lines[i].text, cleaned: text, kind: kind, frame: a.frames[i], distance: d,
                                            confidence: a.lines[i].confidence, score: exp(-d / falloff), block: b,
                                            tooltip: tooltipOf[b] != nil)
            let order: (Int, Double, Int, Double, Int)
            if blockDistance[b] == 0 {
                order = (0, d, 0, 0, position)
            } else if let t = tooltipOf[b] {
                order = (1, tooltipDistance[t], t, Double(a.blocks[b].frame.minY), position)
            } else {
                order = (2, blockDistance[b], b, 0, position)
            }
            return (candidate, order)
        }
        return Array(all.sorted { $0.order < $1.order }.prefix(limit).map(\.candidate))
    }

    static func picking(_ analysis: LookupAnalysis, game: LookupGame?, limit: Int = 20) -> (candidates: [LookupCandidate], suggested: Int) {
        let auto = automatic(analysis, game: game)
        let all = forPicking(analysis, game: game, limit: .max)
        var list = Array(all.prefix(limit))
        if limit > 0, let first = auto.first.map({ LookupText.normalize($0.cleaned) }),
           !list.contains(where: { LookupText.normalize($0.cleaned) == first }),
           let wanted = all.first(where: { LookupText.normalize($0.cleaned) == first }) {
            list[list.count - 1] = wanted
        }
        return (list, suggestion(in: list, automatic: auto))
    }

    static func suggestion(in list: [LookupCandidate], automatic: [LookupCandidate]) -> Int {
        guard let first = automatic.first.map({ LookupText.normalize($0.cleaned) }) else { return 0 }
        return list.firstIndex { LookupText.normalize($0.cleaned) == first } ?? 0
    }

    // Fast Vision recognition reads commas as `?`, so a header's punctuation is ignored:
    // dialogue is never set taller than the text around it.
    private static func titleLike(_ i: Int, in a: LookupAnalysis) -> Bool {
        let text = a.lines[i].text
        if LookupResolver.looksLikeTitle(text) { return true }
        guard let b = a.blockOf[i], tallness(of: i, in: a.blocks[b], a) >= headerTallness else { return false }
        return LookupResolver.looksLikeTitle(text.replacingOccurrences(of: "[.;!?…]", with: " ", options: .regularExpression))
    }

    private static func underPointer(_ a: LookupAnalysis, among indices: [Int]) -> Int? {
        let on = indices.filter { i in
            a.frames[i].insetBy(dx: -underSlack.horizontal * a.unit, dy: -underSlack.vertical * a.unit).contains(a.pointer)
        }.min { x, y in
            let dx = distance(from: a.pointer, to: a.frames[x]), dy = distance(from: a.pointer, to: a.frames[y])
            return dx != dy ? dx < dy : abs(a.frames[x].midY - a.pointer.y) < abs(a.frames[y].midY - a.pointer.y)
        }
        if let on { return on }
        let among = Set(indices)
        return a.alongRow.first { among.contains($0) }
    }

    private static func candidate(_ i: Int, _ cleaned: String, _ kind: LookupCandidate.Kind,
                                  in a: LookupAnalysis, block b: Int, tooltip: Bool = false) -> LookupCandidate {
        let block = a.blocks[b]
        let d = Double(distance(from: a.pointer, to: block.frame) / a.unit)
        let tall = kind == .title ? tallness(of: i, in: block, a) : 0
        let score = exp(-d / falloff) * (1 + tallWeight * tall) * (0.5 + 0.5 * Double(a.lines[i].confidence))
        return LookupCandidate(text: a.lines[i].text, cleaned: cleaned, kind: kind, frame: a.frames[i], distance: d,
                               confidence: a.lines[i].confidence, score: score, block: b, tooltip: tooltip)
    }

    private static func tallness(of i: Int, in block: LookupTextBlock, _ a: LookupAnalysis) -> Double {
        guard block.members.count > 1 else { return 0 }
        let rest = block.members[0] == i ? Array(block.members.dropFirst()) : block.members
        let reference = median(rest.map { a.frames[$0].height })
        guard reference > 0 else { return 0 }
        return min(max(Double(a.frames[i].height / reference) - 1, 0), 1)
    }

    static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

// Nearest neighbour, so each sample is one real pixel, never a letter blended with its fill.
private struct Pixels {
    static let side = 1600
    private let bytes: [UInt8]
    private let width: Int
    private let height: Int
    private let frame: CGRect

    init?(_ shot: ScreenGrabber.Shot) {
        let image = shot.image
        guard image.width > 0, image.height > 0, shot.frame.width > 0, shot.frame.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = min(1, Double(Self.side) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
        self.width = width
        self.height = height
        frame = shot.frame
    }

    func colour(at p: CGPoint) -> LookupColour? {
        let x = Int(((p.x - frame.minX) / frame.width * CGFloat(width)).rounded(.down))
        let y = Int(((p.y - frame.minY) / frame.height * CGFloat(height)).rounded(.down))
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let i = (y * width + x) * 4
        return LookupColour(r: Double(bytes[i]), g: Double(bytes[i + 1]), b: Double(bytes[i + 2]))
    }

    // Samples the box edges and a quarter height outside, not the middle: Vision's boxes are
    // tight and games outline or shadow text, so the middle can be half letter.
    func fill(of r: CGRect) -> LookupColour? {
        let columns = min(max(Int(r.width / max(r.height / 2, 1)), 6), 40)
        var samples: [LookupColour] = []
        for fy: CGFloat in [-0.25, 0.1, 0.9, 1.25] {
            for c in 0..<columns {
                let fx = (CGFloat(c) + 0.5) / CGFloat(columns)
                if let colour = colour(at: CGPoint(x: r.minX + fx * r.width, y: r.minY + fy * r.height)) { samples.append(colour) }
            }
        }
        return LookupColour.median(samples)
    }

    func runs(_ fill: LookupColour, from x0: CGFloat, to x1: CGFloat, at y: CGFloat, step: CGFloat) -> Bool {
        let count = max(1, Int((abs(x1 - x0) / max(step, 1)).rounded(.up)))
        var same = 0, seen = 0
        for n in 0...count {
            guard let colour = colour(at: CGPoint(x: x0 + (x1 - x0) * CGFloat(n) / CGFloat(count), y: y)) else { continue }
            seen += 1
            if colour.distance(to: fill) <= LookupNearby.fillTolerance { same += 1 }
        }
        return seen > 0 && Double(same) >= 0.9 * Double(seen)
    }
}

struct LookupPickRequest {
    let game: LookupGame
    let shot: ScreenGrabber.Shot
    // AppKit screen coordinates, unlike the candidates' CoreGraphics frames.
    let pointer: NSPoint
    let candidates: [LookupCandidate]
    let suggested: Int
    let dryRun: Bool
}

extension ScreenGrabber {
    static func appKitRect(fromCG r: CGRect) -> NSRect {
        let primary = NSScreen.screens.first?.frame ?? .zero
        return NSRect(x: r.minX, y: primary.height - r.maxY, width: r.width, height: r.height)
    }
}
