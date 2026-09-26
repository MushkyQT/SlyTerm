import AppKit
import ScreenCaptureKit
import Vision

final class Lookup {
    static let shared = Lookup()

    static let bandThreshold = 0.72
    static let windowThreshold = 0.86
    // Tuned on Tools/make-lookup-fixtures.swift: "The Defia" must not match "The Defiant"
    // (0.818), nor "Defias Pillager slain" match "Defias Pillager".
    static let nearbyThreshold = 0.9
    static let nearbyLength = 0.2
    static let nearbyMinLength = 4
    static let underPointerThreshold = 0.80
    static let nearbyAsks = 3
    static let againSlop: CGFloat = 6
    static let againWindow: TimeInterval = 10
    static let againAsks = 6

    var openGuide: ((URL) -> Void)?
    private var running = false

    private let sessionLock = NSLock()
    private var session: Session?

    private init() {}

    func warmUp() {
        DispatchQueue.global(qos: .utility).async { [self] in refreshIndices(force: false) }
    }

    func refreshIndices(force: Bool) {
        var done = Set<ObjectIdentifier>()
        for game in LookupStore.shared.games {
            for (_, index) in LookupIndices.indexed(game) where done.insert(ObjectIdentifier(index)).inserted {
                index.prepare(force: force)
            }
        }
    }

    func indexCount(for source: LookupSource) -> Int? {
        LookupIndices.index(for: source)?.count
    }

    enum Outcome: CustomStringConvertible {
        case found(name: String, url: URL, via: String, source: String)
        case noGame
        case noText
        case noMatch(String)
        case nothingElse
        case noPermission
        case failed(String)

        var description: String {
            switch self {
            case .found(let name, let url, let via, let source): return "found via \(via) on \(source): \(name) -> \(url.absoluteString)"
            case .noGame: return "no game configured"
            case .noText: return "no text under the pointer"
            case .noMatch(let text): return "no match for \"\(text)\""
            case .nothingElse: return "nothing else near the pointer"
            case .noPermission: return "screen recording permission missing"
            case .failed(let message): return "failed: \(message)"
            }
        }

        fileprivate var page: Page? {
            guard case .found(let name, let url, _, let source) = self else { return nil }
            return Page(name: name, url: url, source: source)
        }
    }

    struct Page {
        let name: String
        let url: URL
        let source: String
    }

    enum Verdict {
        case hit(Page)
        case rejected
    }

    struct Reading {
        var analysis: LookupAnalysis?
        var candidates: [LookupCandidate] = []
        var verdicts: [String: Verdict] = [:]
        var fast: [OCR.Line] = []
        var accurate: [OCR.Line]?
        var asked = 0

        func verdict(for candidate: LookupCandidate) -> Verdict? { verdicts[Lookup.key(candidate.cleaned)] }

        mutating func adopt(_ around: Around) {
            analysis = around.analysis
            candidates = around.candidates
            fast = around.fast
            accurate = around.accurate
        }
    }

    struct Around {
        let analysis: LookupAnalysis
        let candidates: [LookupCandidate]
        let fast: [OCR.Line]
        let accurate: [OCR.Line]?
    }

    struct Clock {
        let started = Date()
        var ms: Int { Int(Date().timeIntervalSince(started) * 1000) }
    }

    private struct Press {
        var outcome: Outcome
        var game: LookupGame?
        var reading = Reading()
        var answered: Int?
        var rowText: String?
    }

    private struct Session {
        let pointer: NSPoint
        let forced: UUID?
        let dryRun: Bool
        let game: LookupGame
        let rowText: String?
        var pressed: Date
        var reading: Reading
        var opened: [Page]
        var position: Int
        var cycle: Int?

        func continues(at mouse: NSPoint, forced game: LookupGame?, dryRun: Bool, at time: Date) -> Bool {
            game?.id == forced && dryRun == self.dryRun && time.timeIntervalSince(pressed) <= Lookup.againWindow
                && hypot(mouse.x - pointer.x, mouse.y - pointer.y) <= Lookup.againSlop
        }
    }

    static func key(_ cleaned: String) -> String { LookupText.normalize(cleaned) }

    func trigger(dryRun: Bool = false, point: NSPoint? = nil, text: String? = nil, game: LookupGame? = nil) {
        let mouse = point ?? NSEvent.mouseLocation
        guard !running else {
            Task { @MainActor in Toast.shared.show("Still looking…", near: mouse) }
            return
        }
        running = true
        let now = Date()
        let previous: Session? = sessionLock.withLock {
            let continued = text == nil
                ? session.flatMap { $0.continues(at: mouse, forced: game, dryRun: dryRun, at: now) ? $0 : nil } : nil
            if continued == nil { session = nil }
            return continued
        }
        Task.detached(priority: .userInitiated) { [self] in
            var continued = previous
            if let s = continued, await !self.rowUnchanged(since: s, at: mouse) { continued = nil }
            let outcome: Outcome
            let kept: Session?
            if var s = continued {
                outcome = await self.again(&s)
                s.pressed = Date()
                kept = s
            } else {
                let press = await self.press(at: mouse, text: text, game: game)
                outcome = press.outcome
                kept = text == nil ? Self.startSession(after: press, at: mouse, forced: game, dryRun: dryRun) : nil
            }
            let next = kept.flatMap { self.upcoming($0) }
            await MainActor.run {
                self.sessionLock.withLock { self.session = kept }
                self.running = false
                self.finish(outcome, at: mouse, dryRun: dryRun, next: next)
                if kept != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.againWindow + 1) { [weak self] in self?.expireSession() }
                }
            }
        }
    }

    private func expireSession() {
        sessionLock.withLock {
            if let s = session, Date().timeIntervalSince(s.pressed) > Self.againWindow { session = nil }
        }
    }

    func lookup(at mouse: NSPoint, text: String? = nil, game forced: LookupGame? = nil) async -> Outcome {
        await press(at: mouse, text: text, game: forced).outcome
    }

    private func press(at mouse: NSPoint, text: String?, game forced: LookupGame?) async -> Press {
        let clock = Clock()
        let permitted = CGPreflightScreenCaptureAccess()
        if !permitted, text == nil {
            _ = CGRequestScreenCaptureAccess()
            return Press(outcome: .noPermission)
        }
        do {
            let point = ScreenGrabber.cgPoint(fromAppKit: mouse)
            let grabber = permitted
                ? ScreenGrabber(content: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
                : nil
            if grabber != nil { Settings.log("lookup: shareable content in \(clock.ms) ms") }

            guard let game = await resolveGame(forced: forced, at: point, with: grabber) else { return Press(outcome: .noGame) }
            var press = Press(outcome: .noText, game: game)
            let indexed = LookupIndices.indexed(game)
            for (_, index) in indexed { index.ensureLoaded() }

            if let text {
                let cleaned = LookupText.clean(text, for: game)
                if let best = bestMatch(for: cleaned, in: indexed), best.match.score >= Self.bandThreshold {
                    Settings.log("lookup: text match \(best.match.entry.name) score=\(best.match.score)")
                    press.outcome = .found(name: best.match.entry.name, url: best.match.entry.url, via: "text", source: best.source.name)
                    return press
                }
                press.outcome = await resolve(cleaned, game: game) ?? .noMatch(text)
                return press
            }
            guard let grabber else { press.outcome = .noPermission; return press }

            var pointed: OCR.Line?
            if let band = try await grabber.captureBand(around: point) {
                let cursor = band.normalized(point)
                Settings.log("lookup: band captured in \(clock.ms) ms")
                for fast in [true, false] {
                    let near = Self.linesNear(cursor, in: try OCR.lines(in: band.image, fast: fast, languages: game.ocrLanguages))
                    Settings.log("lookup: band OCR \(fast ? "fast" : "accurate") in \(clock.ms) ms: \(near.map { "\"\($0.text)\" \(Int($0.confidence * 100))%" }.joined(separator: " | "))")
                    if fast { press.rowText = Self.rowText(near, game: game) }
                    if let line = near.first(where: { Self.readable($0) && $0.box.minX <= cursor.x && cursor.x <= $0.box.maxX }) {
                        pointed = line
                    }
                    for line in near.prefix(3) {
                        guard let best = bestMatch(for: LookupText.clean(line.text, for: game), in: indexed),
                              best.match.score >= Self.bandThreshold else { continue }
                        Settings.log("lookup: pointer match \(best.match.entry.name) score=\(best.match.score) in \(clock.ms) ms")
                        press.outcome = .found(name: best.match.entry.name, url: best.match.entry.url, via: "pointer", source: best.source.name)
                        return press
                    }
                }
            }
            let pointedText = pointed.map { LookupText.clean($0.text, for: game) }

            let resolves = Self.resolves(game)
            if indexed.isEmpty, !resolves, pointed != nil || game.primarySource == nil {
                Settings.log("lookup: nearby skipped, \(game.name) has nothing to confirm a title with")
            } else {
                var asking: Task<LookupResolver.Answer?, Never>?
                if resolves, let pointedText, pointedText.filter(\.isLetter).count >= 3 {
                    asking = Task { await LookupResolver.hit(for: pointedText, game: game) }
                }
                let window = Task { try await self.readWindow(grabber, around: point, game: game, clock: clock) }
                if let asking, let pointedText {
                    let answer = await asking.value
                    press.reading.verdicts[Self.key(pointedText)] = answer.map { Verdict.hit(Page(name: $0.hit.name, url: $0.hit.url, source: $0.source.name)) } ?? .rejected
                    Settings.log("lookup: pointer search \"\(pointedText)\" \(answer.map { "-> \($0.hit.name) on \($0.source.name)" } ?? "rejected") in \(clock.ms) ms")
                    if let answer {
                        window.cancel()
                        press.outcome = .found(name: answer.hit.name, url: answer.hit.url, via: "pointer", source: answer.source.name)
                        return press
                    }
                }
                do {
                    if let around = try await window.value { press.reading.adopt(around) }
                } catch {
                    Settings.log("lookup: window capture failed: \(error)")
                }
                if press.reading.analysis != nil,
                   let i = await nearby(&press.reading, game: game, indexed: indexed, clock: clock),
                   case .hit(let page)? = press.reading.verdict(for: press.reading.candidates[i]) {
                    press.answered = i
                    press.outcome = .found(name: page.name, url: page.url, via: "nearby", source: page.source)
                    return press
                }
            }

            if !indexed.isEmpty, let shot = press.reading.analysis?.shot {
                var best = bestWindowMatch(in: press.reading.fast, indexed: indexed, game: game)
                Settings.log("lookup: window match on \(press.reading.fast.count) fast lines in \(clock.ms) ms, best=\(best.map { "\($0.match.entry.name) \($0.match.score)" } ?? "none")")
                if best == nil {
                    let accurate = try press.reading.accurate ?? OCR.lines(in: shot.image, fast: false, languages: game.ocrLanguages)
                    press.reading.accurate = accurate
                    best = bestWindowMatch(in: accurate, indexed: indexed, game: game)
                    Settings.log("lookup: window match on \(accurate.count) accurate lines in \(clock.ms) ms, best=\(best.map { "\($0.match.entry.name) \($0.match.score)" } ?? "none")")
                }
                if let best {
                    press.outcome = .found(name: best.match.entry.name, url: best.match.entry.url, via: "window", source: best.source.name)
                    return press
                }
            }

            let fallback: (text: String, cleaned: String, pointedAt: Bool)
            if let pointed, let pointedText {
                fallback = (pointed.text, pointedText, true)
            } else if let top = Self.searched(press.reading.candidates) {
                fallback = (top.text, top.cleaned, top.kind == .underPointer)
            } else {
                Settings.log("lookup: nothing under or near the pointer in \(clock.ms) ms")
                return press
            }
            switch press.reading.verdicts[Self.key(fallback.cleaned)] {
            case .rejected?:
                press.outcome = searchPage(for: fallback.cleaned, game: game) ?? .noMatch(fallback.text)
            case nil where !fallback.pointedAt:
                // Not resolved here: `resolve` applies the lenient pointed-at rule, so "The Defia"
                // would open "The Defiant". An unasked nearby title gets the search page.
                Settings.log("lookup: \"\(fallback.cleaned)\" was not asked about within \(Self.nearbyAsks) texts, search page")
                press.outcome = searchPage(for: fallback.cleaned, game: game) ?? .noMatch(fallback.text)
            default:
                press.outcome = await resolve(fallback.cleaned, game: game) ?? .noMatch(fallback.text)
                switch press.outcome {
                case .found(let name, let url, "search", let source):
                    press.reading.verdicts[Self.key(fallback.cleaned)] = .hit(Page(name: name, url: url, source: source))
                case .found(_, _, "search page", _):
                    press.reading.verdicts[Self.key(fallback.cleaned)] = .rejected
                default:
                    break
                }
            }
            return press
        } catch {
            Settings.log("lookup: failed: \(error)")
            return Press(outcome: .failed(error.localizedDescription), game: nil)
        }
    }

    static func searched(_ candidates: [LookupCandidate]) -> LookupCandidate? {
        candidates.first { $0.kind == .underPointer }
            ?? candidates.first { $0.tooltip }
            ?? candidates.first { $0.distance <= LookupNearby.radius }
    }

    private static func readable(_ line: OCR.Line) -> Bool {
        line.confidence >= 0.3 && line.text.filter(\.isLetter).count >= 3
    }

    private static func rowText(_ near: [OCR.Line], game: LookupGame) -> String? {
        near.first(where: readable).map { key(LookupText.clean($0.text, for: game)) }
    }

    static func sameName(_ text: String, _ name: String) -> Double {
        let a = Array(text.utf8), b = Array(name.utf8)
        let longer = max(a.count, b.count)
        guard longer > 0, Double(abs(a.count - b.count)) <= nearbyLength * Double(longer) else { return 0 }
        return 1 - Double(LookupText.levenshtein(a, b)) / Double(longer)
    }

    private static func resolves(_ game: LookupGame) -> Bool {
        !game.resolvingSources.isEmpty
    }

    private func readWindow(_ grabber: ScreenGrabber, around point: CGPoint, game: LookupGame, clock: Clock) async throws -> Around? {
        var shot = try await grabber.captureWindow(around: point, game: game)
        if shot == nil { shot = try await grabber.captureDisplay(containing: point) }
        guard let shot else { return nil }
        try Task.checkCancellation()
        Settings.log("lookup: window captured in \(clock.ms) ms")
        return try Self.read(shot, pointer: point, game: game, clock: clock)
    }

    static func read(_ shot: ScreenGrabber.Shot, pointer: CGPoint, game: LookupGame, clock: Clock) throws -> Around {
        try Task.checkCancellation()
        let fast = try OCR.lines(in: shot.image, fast: true, languages: game.ocrLanguages)
        let analysis = LookupNearby.analyse(fast, in: shot, pointer: pointer)
        let candidates = LookupNearby.automatic(analysis, game: game)
        Settings.log("lookup: nearby fast OCR \(fast.count) lines, \(analysis.blocks.count) blocks in \(clock.ms) ms: \(describe(candidates))")
        return Around(analysis: analysis, candidates: candidates, fast: fast, accurate: nil)
    }

    static func readAccurately(_ around: Around, game: LookupGame, clock: Clock) throws -> Around {
        let shot = around.analysis.shot, pointer = around.analysis.pointer
        let lines = try OCR.lines(in: shot.image, fast: false, languages: game.ocrLanguages)
        let analysis = LookupNearby.analyse(lines, in: shot, pointer: pointer)
        let candidates = LookupNearby.automatic(analysis, game: game)
        Settings.log("lookup: nearby accurate OCR \(lines.count) lines, \(analysis.blocks.count) blocks in \(clock.ms) ms: \(describe(candidates))")
        return Around(analysis: analysis, candidates: candidates, fast: around.fast, accurate: lines)
    }

    private static func describe(_ candidates: [LookupCandidate]) -> String {
        let near = candidates.prefix { $0.inReach }
        guard !near.isEmpty else { return "no tooltip, and nothing within \(Int(LookupNearby.radius)) text heights" }
        return near.prefix(5).map { String(format: "\"%@\" %@%@ d=%.1f %.2f", $0.text, $0.kind.rawValue, $0.tooltip ? " tooltip" : "",
                                            $0.distance, $0.score) }
            .joined(separator: " | ")
    }

    func nearby(_ reading: inout Reading, game: LookupGame, indexed: [(source: LookupSource, index: LookupIndex)],
                clock: Clock, accurate: Bool = true) async -> Int? {
        if let i = await confirmNearby(&reading, game: game, indexed: indexed, clock: clock) { return i }
        guard accurate, reading.accurate == nil, let analysis = reading.analysis else { return nil }
        do {
            let around = Around(analysis: analysis, candidates: reading.candidates, fast: reading.fast, accurate: nil)
            reading.adopt(try Self.readAccurately(around, game: game, clock: clock))
        } catch {
            Settings.log("lookup: accurate OCR failed: \(error)")
            return nil
        }
        return await confirmNearby(&reading, game: game, indexed: indexed, clock: clock)
    }

    func confirmNearby(_ reading: inout Reading, game: LookupGame,
                       indexed: [(source: LookupSource, index: LookupIndex)], clock: Clock) async -> Int? {
        confirmByIndex(&reading, game: game, indexed: indexed)
        let near = reading.candidates.indices.filter { reading.candidates[$0].inReach }
        guard !near.isEmpty else {
            Settings.log("lookup: nearby: no tooltip, and nothing within \(Int(LookupNearby.radius)) text heights of the pointer")
            return nil
        }
        let room = Self.nearbyAsks - reading.asked
        var unknown: [Int] = []
        scan: for i in near where unknown.count < room {
            switch reading.verdict(for: reading.candidates[i]) {
            case .hit?: break scan
            case .rejected?: continue
            case nil: unknown.append(i)
            }
        }
        if !unknown.isEmpty {
            await ask(unknown, in: &reading, game: game, clock: clock)
            reading.asked += unknown.count
        }
        for i in near {
            guard case .hit(let page)? = reading.verdict(for: reading.candidates[i]) else { continue }
            Settings.log("lookup: nearby \"\(reading.candidates[i].text)\" (\(reading.candidates[i].kind.rawValue), rank \(i + 1)) -> \(page.name) on \(page.source) in \(clock.ms) ms")
            return i
        }
        Settings.log("lookup: nearby: none of \(near.count) confirmed in \(clock.ms) ms")
        return nil
    }

    private func confirmByIndex(_ reading: inout Reading, game: LookupGame, indexed: [(source: LookupSource, index: LookupIndex)]) {
        let resolves = Self.resolves(game)
        for candidate in reading.candidates {
            let key = Self.key(candidate.cleaned)
            guard reading.verdicts[key] == nil else { continue }
            if let known = indexPage(for: candidate, in: indexed) {
                reading.verdicts[key] = .hit(known.page)
                Settings.log("lookup: index knows \"\(candidate.cleaned)\" as \(known.page.name) \(String(format: "%.3f", known.score))")
            } else if !resolves {
                reading.verdicts[key] = .rejected
            }
        }
    }

    private func indexPage(for candidate: LookupCandidate, in indexed: [(source: LookupSource, index: LookupIndex)])
        -> (page: Page, score: Double)? {
        if candidate.kind == .underPointer {
            guard let best = bestMatch(for: candidate.cleaned, in: indexed), best.match.score >= Self.underPointerThreshold,
                  best.match.entry.norm.count >= Self.nearbyMinLength else { return nil }
            return (Page(name: best.match.entry.name, url: best.match.entry.url, source: best.source.name), best.match.score)
        }
        let wanted = LookupText.normalize(candidate.cleaned)
        var best: (page: Page, score: Double)?
        for (source, index) in indexed {
            for match in index.matches(for: candidate.cleaned, limit: 5) where match.entry.norm.count >= Self.nearbyMinLength {
                let score = Self.sameName(wanted, match.entry.norm)
                guard score >= Self.nearbyThreshold, score > best?.score ?? 0 else { continue }
                best = (Page(name: match.entry.name, url: match.entry.url, source: source.name), score)
            }
        }
        return best
    }

    // A cancelled request returns nil but settles nothing: it must not be recorded as rejected,
    // so a later press can ask again.
    private func ask(_ indices: [Int], in reading: inout Reading, game: LookupGame, clock: Clock) async {
        let texts = indices.map { reading.candidates[$0].cleaned }
        let strict = indices.map { reading.candidates[$0].kind != .underPointer }
        let answers: [Int: LookupResolver.Answer?] = await withTaskGroup(of: (Int, LookupResolver.Answer?, Bool).self) { group in
            for (n, text) in texts.enumerated() {
                let strict = strict[n]
                group.addTask {
                    let answer = await LookupResolver.hit(for: text, game: game) { source, hit in
                        guard strict else { return true }
                        let score = Self.sameName(LookupText.normalize(text), LookupText.normalize(hit.name))
                        guard score >= Self.nearbyThreshold else {
                            Settings.log("lookup: \"\(text)\" came back as \(hit.name) on \(source.name) \(String(format: "%.3f", score)), not the same name for a title near the pointer")
                            return false
                        }
                        return true
                    }
                    return (n, answer, answer == nil && Task.isCancelled)
                }
            }
            var answers: [Int: LookupResolver.Answer?] = [:]
            func settled() -> Bool {
                for n in texts.indices {
                    guard let answer = answers[n] else { return false }
                    if answer != nil { return true }
                }
                return true
            }
            for await (n, answer, cancelled) in group where !cancelled {
                answers[n] = .some(answer)
                if settled() {
                    group.cancelAll()
                    break
                }
            }
            return answers
        }
        var said: [String] = []
        for (n, text) in texts.enumerated() {
            guard let answer = answers[n] else { said.append("\"\(text)\" not needed"); continue }
            reading.verdicts[Self.key(text)] = answer.map { Verdict.hit(Page(name: $0.hit.name, url: $0.hit.url, source: $0.source.name)) } ?? .rejected
            said.append("\"\(text)\" \(answer.map { "-> \($0.hit.name) on \($0.source.name)" } ?? "rejected")")
        }
        Settings.log("lookup: asked \(game.resolvingSources.map(\.name).joined(separator: ", ")) about \(texts.count) in \(clock.ms) ms: \(said.joined(separator: " | "))")
    }

    private static func startSession(after press: Press, at mouse: NSPoint, forced: LookupGame?, dryRun: Bool) -> Session? {
        guard let game = press.game else { return nil }
        switch press.outcome {
        case .noPermission, .failed, .noGame: return nil
        default: break
        }
        return Session(pointer: mouse, forced: forced?.id, dryRun: dryRun, game: game, rowText: press.rowText, pressed: Date(),
                       reading: press.reading, opened: press.outcome.page.map { [$0] } ?? [], position: press.answered ?? -1, cycle: nil)
    }

    private func rowUnchanged(since s: Session, at mouse: NSPoint) async -> Bool {
        let clock = Clock()
        guard CGPreflightScreenCaptureAccess() else { return true }
        do {
            let point = ScreenGrabber.cgPoint(fromAppKit: mouse)
            let grabber = ScreenGrabber(content: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
            guard let band = try await grabber.captureBand(around: point) else { return true }
            let near = Self.linesNear(band.normalized(point), in: try OCR.lines(in: band.image, fast: true, languages: s.game.ocrLanguages))
            let now = Self.rowText(near, game: s.game)
            let same = now == s.rowText || (now.flatMap { a in s.rowText.map { Self.sameName(a, $0) >= Self.nearbyThreshold } } ?? false)
            Settings.log("lookup: again: the pointer's row reads \(now.map { "\"\($0)\"" } ?? "nothing") in \(clock.ms) ms, "
                         + (same ? "as before" : "and read \(s.rowText.map { "\"\($0)\"" } ?? "nothing") before: starting over"))
            return same
        } catch {
            Settings.log("lookup: again: the band could not be read: \(error)")
            return true
        }
    }

    private func again(_ s: inout Session) async -> Outcome {
        let clock = Clock()
        let game = s.game
        let indexed = LookupIndices.indexed(game)
        for (_, index) in indexed { index.ensureLoaded() }
        Settings.log("lookup: again, \(s.opened.count) opened, after candidate \(s.position + 1) of \(s.reading.candidates.count)")
        if s.reading.analysis == nil {
            guard CGPreflightScreenCaptureAccess() else { return .noPermission }
            do {
                let grabber = ScreenGrabber(content: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
                if var around = try await readWindow(grabber, around: ScreenGrabber.cgPoint(fromAppKit: s.pointer), game: game, clock: clock) {
                    if !around.candidates.contains(where: \.inReach) {
                        around = try Self.readAccurately(around, game: game, clock: clock)
                    }
                    s.reading.adopt(around)
                }
            } catch {
                Settings.log("lookup: failed: \(error)")
                return .failed(error.localizedDescription)
            }
            s.position = -1
        }
        confirmByIndex(&s.reading, game: game, indexed: indexed)
        if s.cycle == nil {
            var asked = 0
            scan: while true {
                switch step(s.reading, after: s.position, opened: s.opened) {
                case .found(let i, let page):
                    s.position = i
                    s.opened.append(page)
                    Settings.log("lookup: again \"\(s.reading.candidates[i].text)\" (rank \(i + 1)) -> \(page.name) in \(clock.ms) ms")
                    return .found(name: page.name, url: page.url, via: "again", source: page.source)
                case .ask(let indices):
                    let room = Self.againAsks - asked
                    guard room > 0, Self.resolves(game) else { break scan }
                    let batch = Array(indices.prefix(room))
                    await ask(batch, in: &s.reading, game: game, clock: clock)
                    asked += batch.count
                case .end:
                    break scan
                }
            }
            s.cycle = -1
        }
        guard s.opened.count >= 2, let cycle = s.cycle else {
            Settings.log("lookup: again: nothing else near the pointer in \(clock.ms) ms")
            return .nothingElse
        }
        let next = (cycle + 1) % s.opened.count
        s.cycle = next
        let page = s.opened[next]
        Settings.log("lookup: again, round to \(page.name)")
        return .found(name: page.name, url: page.url, via: "again", source: page.source)
    }

    private enum Step {
        case found(Int, Page)
        case ask([Int])
        case end
    }

    private func step(_ r: Reading, after position: Int, opened: [Page]) -> Step {
        var unknown: [Int] = []
        for i in r.candidates.indices where i > position {
            switch r.verdict(for: r.candidates[i]) {
            case .hit(let page)?:
                if opened.contains(where: { $0.url == page.url }) { continue }
                return unknown.isEmpty ? .found(i, page) : .ask(unknown)
            case .rejected?:
                continue
            case nil:
                unknown.append(i)
                if unknown.count == Self.nearbyAsks { return .ask(unknown) }
            }
        }
        return unknown.isEmpty ? .end : .ask(unknown)
    }

    private func upcoming(_ s: Session) -> String? {
        if let cycle = s.cycle {
            return s.opened.count >= 2 ? s.opened[(cycle + 1) % s.opened.count].name : nil
        }
        switch step(s.reading, after: s.position, opened: s.opened) {
        case .found(_, let page): return page.name
        case .ask: return nil
        case .end: return s.opened.count >= 2 ? s.opened[0].name : nil
        }
    }

    func pick(dryRun: Bool = false, point: NSPoint? = nil, game: LookupGame? = nil) {
        let mouse = point ?? NSEvent.mouseLocation
        guard !running else {
            Task { @MainActor in Toast.shared.show("Still looking…", near: mouse) }
            return
        }
        running = true
        sessionLock.withLock { session = nil }
        Task.detached(priority: .userInitiated) { [self] in
            let picked = await self.readForPicking(at: mouse, game: game, dryRun: dryRun)
            await MainActor.run {
                self.running = false
                switch picked {
                case .request(let request): LookupPicker.shared.show(request)
                case .nothing: Toast.shared.show("No text near the pointer", near: mouse, tint: .systemOrange)
                case .failed(let outcome): self.finish(outcome, at: mouse, dryRun: dryRun)
                }
            }
        }
    }

    func lookUpPicked(_ candidate: LookupCandidate, from request: LookupPickRequest) {
        let mouse = request.pointer
        guard !running else {
            Task { @MainActor in Toast.shared.show("Still looking…", near: mouse) }
            return
        }
        running = true
        Settings.log("lookup: picked \"\(candidate.text)\" (\(candidate.kind.rawValue), \(String(format: "%.1f", candidate.distance)) text heights away)")
        Task.detached(priority: .userInitiated) { [self] in
            let outcome = await self.lookup(at: mouse, text: candidate.text, game: request.game)
            await MainActor.run {
                self.running = false
                self.finish(outcome, at: mouse, dryRun: request.dryRun)
            }
        }
    }

    private enum Picked {
        case request(LookupPickRequest)
        case nothing
        case failed(Outcome)
    }

    private func readForPicking(at mouse: NSPoint, game forced: LookupGame?, dryRun: Bool) async -> Picked {
        let clock = Clock()
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            return .failed(.noPermission)
        }
        do {
            let point = ScreenGrabber.cgPoint(fromAppKit: mouse)
            let grabber = ScreenGrabber(content: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
            guard let game = await resolveGame(forced: forced, at: point, with: grabber) else { return .failed(.noGame) }
            var shot = try await grabber.captureWindow(around: point, game: game)
            if shot == nil { shot = try await grabber.captureDisplay(containing: point) }
            guard let shot else { return .nothing }
            Settings.log("lookup: pick: window captured in \(clock.ms) ms")
            let lines = try Self.pickLines(in: shot, pointer: point, game: game)
            let analysis = LookupNearby.analyse(lines, in: shot, pointer: point)
            let (candidates, suggested) = LookupNearby.picking(analysis, game: game)
            Settings.log("lookup: pick: \(candidates.count) candidates in \(clock.ms) ms, suggested \(candidates.indices.contains(suggested) ? "\"\(candidates[suggested].text)\"" : "none")")
            guard !candidates.isEmpty else { return .nothing }
            return .request(LookupPickRequest(game: game, shot: shot, pointer: mouse, candidates: candidates,
                                              suggested: suggested, dryRun: dryRun))
        } catch {
            Settings.log("lookup: pick failed: \(error)")
            return .failed(.failed(error.localizedDescription))
        }
    }

    static func pickLines(in shot: ScreenGrabber.Shot, pointer: CGPoint, game: LookupGame,
                          fast known: [OCR.Line]? = nil) throws -> [OCR.Line] {
        let fast = try known ?? OCR.lines(in: shot.image, fast: true, languages: game.ocrLanguages)
        if fast.count >= 3,
           LookupNearby.automatic(LookupNearby.analyse(fast, in: shot, pointer: pointer), game: game).contains(where: \.tooltip) {
            return fast
        }
        Settings.log("lookup: pick: the fast pass read \(fast.count) lines and no tooltip's name, reading accurately")
        return try OCR.lines(in: shot.image, fast: false, languages: game.ocrLanguages)
    }

    private func resolveGame(forced: LookupGame?, at point: CGPoint, with grabber: ScreenGrabber?) async -> LookupGame? {
        if let forced {
            Settings.log("lookup: game \(forced.name), asked for by name")
            return forced
        }
        let pointed = grabber?.bundleID(under: point)
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        guard let game = LookupStore.shared.resolveGame(bundleIDs: [pointed, front]) else {
            Settings.log("lookup: no game configured")
            return nil
        }
        let why: String
        if LookupStore.shared.autoDetect, game.matches(bundleID: pointed) {
            why = "\(pointed ?? "") under the pointer"
        } else if LookupStore.shared.autoDetect, game.matches(bundleID: front) {
            why = "\(front ?? "") in front"
        } else {
            why = "the game chosen by hand"
        }
        Settings.log("lookup: game \(game.name), from \(why)")
        return game
    }

    private func bestMatch(for cleaned: String, in indexed: [(source: LookupSource, index: LookupIndex)]) -> (source: LookupSource, match: LookupIndex.Match)? {
        var best: (source: LookupSource, match: LookupIndex.Match)?
        for (source, index) in indexed {
            guard let match = index.bestMatch(for: cleaned) else { continue }
            if let b = best, match.score <= b.match.score { continue }
            best = (source, match)
        }
        return best
    }

    private func bestWindowMatch(in lines: [OCR.Line], indexed: [(source: LookupSource, index: LookupIndex)], game: LookupGame)
        -> (source: LookupSource, match: LookupIndex.Match, line: OCR.Line)? {
        var best: (source: LookupSource, match: LookupIndex.Match, line: OCR.Line)?
        for line in lines where line.confidence >= 0.4 && line.text.filter(\.isLetter).count >= 4 {
            guard let hit = bestMatch(for: LookupText.clean(line.text, for: game), in: indexed),
                  hit.match.score >= Self.windowThreshold, hit.match.entry.norm.count >= 6 else { continue }
            if let b = best {
                let better = hit.match.score > b.match.score + 0.02
                    || (abs(hit.match.score - b.match.score) <= 0.02 && line.box.height > b.line.box.height)
                if !better { continue }
            }
            best = (hit.source, hit.match, line)
        }
        return best
    }

    private func resolve(_ cleaned: String, game: LookupGame) async -> Outcome? {
        guard game.primarySource != nil, cleaned.filter(\.isLetter).count >= 3 else { return nil }
        if let answer = await LookupResolver.hit(for: cleaned, game: game) {
            return .found(name: answer.hit.name, url: answer.hit.url, via: "search", source: answer.source.name)
        }
        return searchPage(for: cleaned, game: game)
    }

    private func searchPage(for cleaned: String, game: LookupGame) -> Outcome? {
        guard let source = game.primarySource, cleaned.filter(\.isLetter).count >= 3,
              let url = source.searchURL(for: cleaned) else { return nil }
        return .found(name: cleaned, url: url, via: "search page", source: source.name)
    }

    @MainActor
    private func finish(_ outcome: Outcome, at mouse: NSPoint, dryRun: Bool, next: String? = nil) {
        Settings.log("lookup: \(outcome)\(next.map { ", next: \($0)" } ?? "")")
        switch outcome {
        case .found(let name, let url, _, let source):
            let inApp = Settings.shared.questOpenInApp && openGuide != nil
            var message = dryRun ? "\(name)  →  \(Self.pageLabel(of: url))  [\(source)]"
                                 : inApp ? "Guide: \(name)" : "Opening \(name)"
            if let next {
                let combo = KeyCombo.pretty(Settings.shared.hotkey(.quest))
                message += "  ·  \(combo.isEmpty ? "" : combo + " ")again: \(next)"
            }
            Toast.shared.show(message, near: mouse, tint: .systemGreen)
            if !dryRun {
                if inApp { openGuide?(url) } else { open(url) }
            }
        case .noGame:
            Toast.shared.show("Add a game in Settings › Lookup", near: mouse, tint: .systemOrange, duration: 3)
        case .noText:
            Toast.shared.show("No text under the pointer", near: mouse, tint: .systemOrange)
        case .noMatch(let text):
            Toast.shared.show("No guide found for “\(text)”", near: mouse, tint: .systemOrange, duration: 3)
        case .nothingElse:
            Toast.shared.show("Nothing else near the pointer", near: mouse, tint: .systemOrange)
        case .noPermission:
            Toast.shared.show("Allow Screen Recording for SlyTerm in System Settings › Privacy & Security, then relaunch it",
                              near: mouse, tint: .systemRed, duration: 6)
        case .failed(let message):
            Toast.shared.show("Lookup failed: \(message)", near: mouse, tint: .systemRed, duration: 4)
        }
    }

    private static func pageLabel(of url: URL) -> String {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? (url.host ?? url.absoluteString) : last
    }

    private func open(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = !Settings.shared.questOpenInBackground
        NSWorkspace.shared.open(url, configuration: config)
    }

    static func linesNear(_ cursor: CGPoint, in lines: [OCR.Line]) -> [OCR.Line] {
        lines.filter { abs($0.box.midY - cursor.y) <= max($0.box.height * 0.6, 0.12) }
            .sorted { a, b in
                let ax = a.box.minX <= cursor.x && cursor.x <= a.box.maxX
                let bx = b.box.minX <= cursor.x && cursor.x <= b.box.maxX
                if ax != bx { return ax }
                return abs(a.box.midY - cursor.y) < abs(b.box.midY - cursor.y)
            }
    }
}

struct ScreenGrabber {
    let content: SCShareableContent

    struct Shot {
        let image: CGImage
        // CoreGraphics screen coordinates: points, origin top-left.
        let frame: CGRect

        func normalized(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - frame.minX) / frame.width, y: 1 - (p.y - frame.minY) / frame.height)
        }
    }

    static func cgPoint(fromAppKit p: NSPoint) -> CGPoint {
        let primary = NSScreen.screens.first?.frame ?? .zero
        return CGPoint(x: p.x, y: primary.height - p.y)
    }

    private var ownWindows: [SCWindow] {
        content.windows.filter { $0.owningApplication?.processID == getpid() }
    }

    // ScreenCaptureKit lists windows front to back: the first one containing a point is visible.
    private var candidates: [SCWindow] {
        content.windows.filter { $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != getpid() }
    }

    func bundleID(under p: CGPoint) -> String? {
        candidates.first { $0.frame.contains(p) }?.owningApplication?.bundleIdentifier
    }

    private func display(containing p: CGPoint) -> SCDisplay? {
        content.displays.first { $0.frame.contains(p) } ?? content.displays.first
    }

    func captureBand(around p: CGPoint, size: CGSize = CGSize(width: 900, height: 48)) async throws -> Shot? {
        guard let display = display(containing: p) else { return nil }
        let rect = CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
            .intersection(display.frame)
        guard !rect.isEmpty else { return nil }
        return try await capture(SCContentFilter(display: display, excludingWindows: ownWindows), rect: rect, origin: display.frame.origin)
    }

    func captureWindow(around p: CGPoint, game: LookupGame) async throws -> Shot? {
        let under = candidates.filter { $0.frame.width >= 400 && $0.frame.height >= 300 && $0.frame.contains(p) }
        let owned = under.filter { w in
            game.matches(bundleID: w.owningApplication?.bundleIdentifier)
                || w.owningApplication?.applicationName == game.name
        }
        let pool = owned.isEmpty ? under : owned
        guard let window = pool.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        return try await capture(SCContentFilter(desktopIndependentWindow: window), rect: window.frame, origin: nil)
    }

    func captureDisplay(containing p: CGPoint) async throws -> Shot? {
        guard let display = display(containing: p) else { return nil }
        return try await capture(SCContentFilter(display: display, excludingWindows: ownWindows), rect: display.frame, origin: display.frame.origin)
    }

    private func capture(_ filter: SCContentFilter, rect: CGRect, origin: CGPoint?) async throws -> Shot {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        if let origin {
            config.sourceRect = CGRect(x: rect.minX - origin.x, y: rect.minY - origin.y, width: rect.width, height: rect.height)
        }
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Shot(image: image, frame: rect)
    }
}

enum OCR {
    struct Line {
        let text: String
        let confidence: Float
        // Vision's space: normalised to the image, origin bottom-left.
        let box: CGRect
    }

    static func lines(in image: CGImage, fast: Bool, languages: [String] = []) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Line(text: candidate.string, confidence: candidate.confidence, box: observation.boundingBox)
        }
    }
}

@MainActor
final class Toast {
    static let shared = Toast()

    private let panel: NSPanel
    private let background = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92).cgColor
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.isSelectable = false
        label.maximumNumberOfLines = 3
        background.addSubview(label)
        panel.contentView = background
    }

    func show(_ text: String, near point: NSPoint, tint: NSColor = .white, duration: TimeInterval = 1.8) {
        hideWork?.cancel()
        generation += 1
        let current = generation
        label.stringValue = text
        label.textColor = tint
        let maxWidth: CGFloat = 440
        label.preferredMaxLayoutWidth = maxWidth - 24
        var size = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth - 24, height: 200)) ?? NSSize(width: 200, height: 20)
        size.width = ceil(min(size.width, maxWidth - 24))
        size.height = ceil(size.height)
        let frameSize = NSSize(width: size.width + 24, height: size.height + 16)
        label.frame = NSRect(x: 12, y: 8, width: size.width, height: size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var origin = NSPoint(x: point.x + 18, y: point.y - frameSize.height - 18)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - frameSize.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - frameSize.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.panel.orderOut(nil)
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

enum LookupCLI {
    private static let modes = ["--match", "--ocr", "--lookup", "--search", "--index", "--probe"]
    private static let valued: [String: Int] = ["--game": 1, "--preset": 1, "--at": 2]
    private static let cliWait: TimeInterval = 300

    static func run(_ args: [String]) -> Bool {
        guard args.count >= 2, modes.contains(args[1]) else { return false }
        Settings.echo = true
        let rest = Array(args.dropFirst(2))
        let words = self.words(in: rest)
        let named = value(of: "--game", in: rest)
        let preset = value(of: "--preset", in: rest)
        if args[1] == "--probe" {
            guard let url = words.first.flatMap(URL.init(string:)) else { print("usage: --probe <search url>"); return true }
            wait {
                let result = await LookupProbe.detect(searchURL: url)
                let pages = result.pageCount.map { "  \($0) pages" } ?? ""
                print("\(result.kind.rawValue)  home \(result.home.absoluteString)  index \(result.indexURL?.absoluteString ?? "none")\(pages)")
            }
            return true
        }
        if args[1] == "--index" {
            let games = named == nil && preset == nil ? LookupStore.shared.games
                : (game(named: named, preset: preset).map { [$0] } ?? [])
            index(games, refresh: rest.contains("--refresh"))
            return true
        }
        guard let game = game(named: named, preset: preset) else { return true }
        let indexed = LookupIndices.indexed(game)
        if args[1] != "--search" {
            for (source, index) in indexed {
                let t0 = Date()
                index.ensureLoaded(timeout: cliWait)
                print("index: \(source.name): \(index.count) pages, loaded in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            }
        }
        switch args[1] {
        case "--match":
            let text = LookupText.clean(words.joined(separator: " "), for: game)
            for m in merged(matches: text, in: indexed, limit: 5) {
                print(String(format: "  %.3f  %@  %@%@", m.match.score, m.match.entry.name, m.match.entry.url.absoluteString,
                             indexed.count > 1 ? "  [\(m.source.name)]" : ""))
            }
        case "--ocr":
            guard let path = words.first, let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("cannot read image"); return true
            }
            if rest.contains("--at") {
                guard let at = coordinates(after: "--at", in: rest) else { print("usage: --ocr <image> --at <x> <y>"); return true }
                nearby(image, at: at, game: game, indexed: indexed, fastOnly: rest.contains("--fast"), pick: rest.contains("--pick"))
                return true
            }
            do {
                let t1 = Date()
                let lines = try OCR.lines(in: image, fast: rest.contains("--fast"), languages: game.ocrLanguages)
                print("\(lines.count) lines, \(image.width)x\(image.height) px, OCR in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
                for line in lines {
                    let match = merged(matches: LookupText.clean(line.text, for: game), in: indexed, limit: 1).first
                    print(String(format: "  %3d%%  y=%.2f h=%.3f  \"%@\"  ->  %@", Int(line.confidence * 100), line.box.midY, line.box.height, line.text,
                                 match.map { String(format: "%.3f %@", $0.match.score, $0.match.entry.name) } ?? "-"))
                }
            } catch { print("OCR failed: \(error)") }
        case "--search":
            let text = LookupText.clean(words.joined(separator: " "), for: game)
            let sources = game.resolvingSources
            guard !sources.isEmpty else { print("\(game.name) has no source that can be asked"); return true }
            wait {
                let hits = await withTaskGroup(of: (Int, LookupHit?).self) { group in
                    for (n, source) in sources.enumerated() {
                        group.addTask { (n, await LookupResolver.hit(for: text, source: source)) }
                    }
                    var hits: [Int: LookupHit] = [:]
                    for await (n, hit) in group { hits[n] = hit }
                    return hits
                }
                for (n, source) in sources.enumerated() {
                    print("\(source.name) (\(source.kind.title)): \(hits[n].map { "\($0.name) -> \($0.url.absoluteString)" } ?? "rejected")")
                }
                let taken = LookupResolver.choose(sources.indices.map { hits[$0] }, of: sources, for: text)
                print("result: \(taken.map { "\($0.hit.name) on \($0.source.name) -> \($0.hit.url.absoluteString)" } ?? "rejected")")
            }
        default:
            var point: NSPoint?
            if words.count >= 2, let x = Double(words[0]), let y = Double(words[1]) { point = NSPoint(x: x, y: y) }
            wait {
                let outcome = await Lookup.shared.lookup(at: point ?? NSEvent.mouseLocation, game: game)
                print("result: \(outcome)")
            }
        }
        return true
    }

    private static func index(_ games: [LookupGame], refresh: Bool) {
        for game in games {
            print(game.name)
            for source in game.sources {
                guard let index = LookupIndices.index(for: source) else {
                    print("  \(source.name)  \(source.kind.rawValue)  no index")
                    continue
                }
                if refresh { index.prepare(force: true) } else { index.ensureLoaded(timeout: cliWait) }
                let age = index.age.map { "built \(duration($0)) ago" } ?? "never built"
                print("  \(source.name)  \(source.kind.rawValue)  \(index.count) titles  \(age)")
            }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<90: return "\(Int(seconds)) s"
        case ..<5400: return "\(Int(seconds / 60)) min"
        case ..<172_800: return "\(Int(seconds / 3600)) h"
        default: return "\(Int(seconds / 86400)) days"
        }
    }

    private static func merged(matches text: String, in indexed: [(source: LookupSource, index: LookupIndex)], limit: Int)
        -> [(source: LookupSource, match: LookupIndex.Match)] {
        var all: [(source: LookupSource, match: LookupIndex.Match)] = []
        for (source, index) in indexed {
            for match in index.matches(for: text, limit: limit) { all.append((source, match)) }
        }
        return all.sorted { $0.match.score > $1.match.score }.prefix(limit).map { $0 }
    }

    private static func game(named: String?, preset: String?) -> LookupGame? {
        if let preset {
            if let known = LookupPresets.Preset(rawValue: preset.lowercased()) { return LookupPresets.make(known) }
            print("no preset named \"\(preset)\": \(LookupPresets.Preset.allCases.map(\.rawValue).joined(separator: ", "))")
            return nil
        }
        guard let named else {
            let game = LookupStore.shared.activeGame
            if game == nil { print("no game configured") }
            return game
        }
        if let game = LookupStore.shared.game(named: named) { return game }
        if let preset = LookupPresets.Preset(rawValue: named.lowercased()) { return LookupPresets.make(preset) }
        print("no game or preset named \"\(named)\"")
        return nil
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func words(in args: [String]) -> [String] {
        var out: [String] = []
        var skip = 0
        for arg in args {
            if skip > 0 { skip -= 1; continue }
            if arg.hasPrefix("--") { skip = valued[arg] ?? 0; continue }
            out.append(arg)
        }
        return out
    }

    private static func coordinates(after flag: String, in args: [String]) -> CGPoint? {
        guard let i = args.firstIndex(of: flag), i + 2 < args.count,
              let x = Double(args[i + 1]), let y = Double(args[i + 2]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func nearby(_ image: CGImage, at pointer: CGPoint, game: LookupGame,
                               indexed: [(source: LookupSource, index: LookupIndex)], fastOnly: Bool, pick: Bool) {
        let shot = ScreenGrabber.Shot(image: image, frame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let clock = Lookup.Clock()
        var reading = Lookup.Reading()
        do {
            reading.adopt(try Lookup.read(shot, pointer: pointer, game: game, clock: clock))
        } catch { print("OCR failed: \(error)"); return }
        wait {
            let winner = await Lookup.shared.nearby(&reading, game: game, indexed: indexed, clock: clock, accurate: !fastOnly)
            let ms = clock.ms
            guard let a = reading.analysis else { return }
            print(String(format: "%d lines, %dx%d px, %@ OCR, stage in %d ms, text height %.1f px, pointer at %.0f, %.0f",
                         a.lines.count, image.width, image.height, reading.accurate == nil ? "fast" : "fast then accurate",
                         ms, a.unit, pointer.x, pointer.y))
            print("blocks, nearest first (tooltips numbered, * on the lines that make one):")
            let distances = a.blocks.map { Double(LookupNearby.distance(from: pointer, to: $0.frame) / a.unit) }
            var tooltipOf: [Int: Int] = [:]
            for (t, tooltip) in LookupNearby.tooltips(in: a, game: game).enumerated() {
                for b in tooltip.blocks { tooltipOf[b] = t + 1 }
            }
            func fill(_ i: Int) -> String { a.fills[i]?.hex ?? "-" }
            func mark(_ i: Int) -> String { LookupText.isTooltipLine(a.lines[i].text, for: game) ? "*" : " " }
            for b in a.blocks.indices.sorted(by: { distances[$0] < distances[$1] }) {
                let block = a.blocks[b], f = block.frame
                let tag = tooltipOf[b].map { String(format: "tooltip %-2d", $0) } ?? "          "
                print(String(format: "  %5.1f  %2d line%@  %4.0f,%-4.0f %4.0fx%-4.0f  %@  %@ %@\"%@\"", distances[b], block.lines.count,
                             block.lines.count == 1 ? " " : "s", f.minX, f.minY, f.width, f.height, fill(block.members[0]), tag,
                             mark(block.members[0]), block.lines[0].text))
                for i in block.members.dropFirst() {
                    print(String(format: "                 h=%3.0f %3d%%  %@  %@\"%@\"", a.frames[i].height, Int(a.lines[i].confidence * 100),
                                 fill(i), mark(i), a.lines[i].text))
                }
            }
            print("automatic, best first (distance in text heights):")
            var crossed = false
            for (rank, c) in reading.candidates.enumerated() {
                if !crossed, !c.inReach {
                    crossed = true
                    print("  -- no tooltip, beyond \(Int(LookupNearby.radius)) text heights: only pressing again reaches these --")
                }
                let match = merged(matches: c.cleaned, in: indexed, limit: 1).first
                let kind = c.kind.rawValue + (c.tooltip ? " tooltip" : "")
                print(String(format: "  %2d  %-20@  d=%5.1f  score=%.3f  \"%@\"%@  ->  %@", rank + 1, kind, c.distance, c.score, c.text,
                             c.cleaned == c.text ? "" : " (\"\(c.cleaned)\")",
                             match.map { String(format: "%.3f %@", $0.match.score, $0.match.entry.name) } ?? "-"))
            }
            if let winner, case .hit(let page)? = reading.verdict(for: reading.candidates[winner]) {
                let outcome = Lookup.Outcome.found(name: page.name, url: page.url, via: "nearby", source: page.source)
                print("result: \(outcome), from \"\(reading.candidates[winner].text)\" (rank \(winner + 1))")
            } else if let top = Lookup.searched(reading.candidates) {
                print("result: nothing confirmed near the pointer; the search page would get \"\(top.cleaned)\"")
            } else {
                print("result: no tooltip, and nothing within \(Int(LookupNearby.radius)) text heights of the pointer")
            }
        }
        guard pick else { return }
        do {
            let lines = try Lookup.pickLines(in: shot, pointer: pointer, game: game, fast: reading.fast)
            let (list, suggested) = LookupNearby.picking(LookupNearby.analyse(lines, in: shot, pointer: pointer), game: game)
            print("pick list, in key order:")
            for (i, c) in list.enumerated() {
                print(String(format: "  %2d  %-20@  d=%5.1f  \"%@\"%@", i, c.kind.rawValue + (c.tooltip ? " tooltip" : ""), c.distance, c.text,
                             i == suggested ? "  <- suggested" : ""))
            }
            print("suggested: \(list.isEmpty ? "none" : "\(suggested)")")
        } catch { print("OCR failed: \(error)") }
    }

    // Keeps the main run loop spinning while waiting: the capture and Vision calls need it.
    private static func wait(_ body: @escaping () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await body()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
}
