import AppKit

@MainActor
final class LookupPicker {
    static let shared = LookupPicker()

    private var panel: LookupPickerPanel?
    private var request: LookupPickRequest?
    private var content: LookupPickerView?
    private var shownAt = Date()
    private var previousApp: NSRunningApplication?
    private weak var previousKey: NSWindow?
    private var activated = false
    private var overlayWasGhost: Bool?

    var isVisible: Bool { request != nil }

    func show(_ request: LookupPickRequest) {
        let keys = LookupPicker.keys(count: request.candidates.count)
        let candidates = Array(request.candidates.prefix(keys.count))
        guard !candidates.isEmpty else {
            Settings.log("lookup: pick: nothing to offer")
            return
        }
        guard let screen = LookupPicker.screen(for: request.shot.frame) else {
            Settings.log("lookup: pick: no screen to show it on")
            return
        }
        let replacing = self.request != nil
        if !replacing {
            previousApp = NSWorkspace.shared.frontmostApplication
            previousKey = NSApp.keyWindow
            activated = false
            overlayWasGhost = TeleportEngine.shared.controller?.isGhost
        }
        let panel = self.panel ?? makePanel()
        panel.level = Settings.shared.dialogLevel
        panel.setFrame(screen.frame, display: false)
        // Converts AppKit to capture space on purpose: the flip is its own inverse.
        let view = LookupPickerView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                    image: request.shot.image, shot: request.shot.frame,
                                    canvas: ScreenGrabber.appKitRect(fromCG: screen.frame),
                                    candidates: candidates, keys: keys,
                                    highlighted: candidates.indices.contains(request.suggested) ? request.suggested : 0,
                                    topInset: screen.safeAreaInsets.top)
        view.onChoose = { [weak self] index, how in self?.choose(index, how: how) }
        view.onCancel = { [weak self] why in self?.close(why, restoringKeyboard: true) }
        panel.contentView = view
        content = view
        self.request = request
        shownAt = Date()

        if !replacing { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        if !panel.isKeyWindow {
            let wasActive = NSApp.isActive
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            activated = activated || !wasActive
        }
        panel.makeFirstResponder(view)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
        Settings.log("lookup: pick: showing \(candidates.count) lines, \"\(candidates[view.highlighted].text)\" highlighted, key=\(panel.isKeyWindow) activated=\(activated)")
    }

    func acceptSuggested() {
        guard let content else { return }
        choose(content.highlighted, how: "the lookup hotkey")
    }

    func hide() {
        close("cancelled", restoringKeyboard: true)
    }

    private func choose(_ index: Int, how: String) {
        guard let request, let content, content.candidates.indices.contains(index) else { return }
        let candidate = content.candidates[index]
        // Close first, so the keyboard is back with the game and the answer's toast is not under
        // the veil.
        close("picked \"\(candidate.text)\" with \(how)", restoringKeyboard: true)
        Lookup.shared.lookUpPicked(candidate, from: request)
    }

    private func close(_ why: String, restoringKeyboard: Bool) {
        guard let panel, request != nil else { return }
        // Clear before ordering out: resigning key re-enters close() via onResignKey.
        request = nil
        content = nil
        // Key status AppKit hands the overlay while closing must not leave click-through or
        // clear an unseen attention mark.
        let controller = TeleportEngine.shared.controller
        let quiet = restoringKeyboard && controller != nil && previousKey !== controller?.main
        if quiet { controller?.ignoresHandedKeyStatus = true }
        // Reactivate the previous app before ordering out, or AppKit hands key to the overlay
        // while SlyTerm is active with no key window.
        let handedBack = restoringKeyboard && reactivatePreviousApp()
        panel.orderOut(nil)
        panel.contentView = NSView()
        Settings.log("lookup: pick: \(why) after \(Int(Date().timeIntervalSince(shownAt) * 1000)) ms")
        if restoringKeyboard, !handedBack { giveKeyboardBack() }
        if restoringKeyboard {
            let away = previousKey == nil
            let wasGhost = overlayWasGhost
            settleOverlay(keyboardAway: away, wasGhost: wasGhost)
            // AppKit picks the next key window after this event, maybe the overlay: settle again.
            DispatchQueue.main.async { [weak self] in
                self?.settleOverlay(keyboardAway: away, wasGhost: wasGhost, late: true)
                if quiet { TeleportEngine.shared.controller?.ignoresHandedKeyStatus = false }
            }
        }
        previousApp = nil
        previousKey = nil
        activated = false
        overlayWasGhost = nil
    }

    private func reactivatePreviousApp() -> Bool {
        guard activated, let app = previousApp, !app.isTerminated, app.processIdentifier != getpid() else { return false }
        app.activate()
        Settings.log("lookup: pick: keyboard handed back to \(app.localizedName ?? "the app in front")")
        return true
    }

    private func giveKeyboardBack() {
        if let window = previousKey, window.isVisible, window !== panel {
            window.makeKey()
            Settings.log("lookup: pick: keyboard handed back to SlyTerm's \(type(of: window))")
        } else {
            Settings.log("lookup: pick: keyboard left to \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "the app in front")")
        }
    }

    private func settleOverlay(keyboardAway: Bool, wasGhost: Bool?, late: Bool = false) {
        guard let controller = TeleportEngine.shared.controller else { return }
        let released = keyboardAway && controller.hasKeyboard
        if released { controller.releaseKeyboard() }
        let changed = wasGhost.map { controller.isGhost != $0 && controller.isVisible && !controller.isPanic } ?? false
        if changed, let wasGhost { controller.setGhost(wasGhost) }
        Settings.log("lookup: pick: closed\(late ? ", a moment later" : ""): key window \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none"), "
                     + "app active=\(NSApp.isActive), overlay ghost=\(controller.isGhost)\(changed ? " (put back)" : "")"
                     + (released ? ", keyboard taken back from the overlay" : ""))
    }

    private func makePanel() -> LookupPickerPanel {
        let panel = LookupPickerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Explicit: otherwise clicks pass through transparent pixels, and a click must cancel.
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.onResignKey = { [weak self] in self?.close("cancelled, the keyboard went elsewhere", restoringKeyboard: false) }
        panel.onCancel = { [weak self] in self?.close("cancelled with Esc", restoringKeyboard: true) }
        self.panel = panel
        return panel
    }

    private static func screen(for shot: CGRect) -> NSScreen? {
        let frame = ScreenGrabber.appKitRect(fromCG: shot)
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    // Virtual key codes (physical positions) of QWERTY's A-L, Q-P and Z-M rows, in that order.
    private static let keyCodes: [UInt16] = [0, 1, 2, 3, 5, 4, 38, 40, 37,
                                             12, 13, 14, 15, 17, 16, 32, 34, 31, 35,
                                             6, 7, 8, 9, 11, 45, 46]

    private static func keys(count: Int) -> [LookupPickerView.Key] {
        var seen = Set<String>()
        var keys: [LookupPickerView.Key] = []
        for code in keyCodes where keys.count < count {
            guard let typed = KeyCombo.character(forKeyCode: code), typed.isLetter else { continue }
            let label = String(typed).uppercased()
            guard seen.insert(label).inserted else { continue }
            keys.append(LookupPickerView.Key(code: code, label: label))
        }
        return keys
    }
}

private final class LookupPickerPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    // NSPanel closes itself on Esc here; the picker must hear it or it thinks it is still up.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // AppKit would push the top edge below the menu bar, offsetting the frozen frame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class LookupPickerView: NSView {
    struct Key {
        let code: UInt16
        let label: String
    }

    let candidates: [LookupCandidate]
    private(set) var highlighted: Int
    var onChoose: ((Int, String) -> Void)?
    var onCancel: ((String) -> Void)?

    private let image: CGImage
    private let shotRect: NSRect
    private let keys: [Key]
    private let lit: [NSRect]
    private let chips: [NSRect]
    private let chipFont: NSFont
    private let hintRect: NSRect
    private var pressed: Int?

    static let hint = "Press a key to look it up  ·  ↩ the highlighted one  ·  Esc to cancel"

    init(frame: NSRect, image: CGImage, shot: CGRect, canvas: CGRect, candidates: [LookupCandidate],
         keys: [Key], highlighted: Int, topInset: CGFloat) {
        func place(_ r: CGRect) -> NSRect {
            NSRect(x: r.minX - canvas.minX, y: canvas.maxY - r.maxY, width: r.width, height: r.height)
        }
        let shotRect = place(shot)
        let lines = candidates.map { place($0.frame) }
        let lit = LookupPickerView.pad(lines, by: LookupPickerView.padding)
        let font = NSFont.systemFont(ofSize: LookupPickerView.chipFontSize(for: lines), weight: .bold)
        let bounds = NSRect(origin: .zero, size: frame.size)
        let sizes = keys.prefix(candidates.count).map { LookupPickerView.chipSize($0.label, font: font) }
        let chips = LookupPickerView.layoutChips(for: Array(lit.prefix(sizes.count)), sizes: sizes,
                                                 room: bounds.intersection(shotRect).insetBy(dx: 2, dy: 2))
        self.image = image
        self.candidates = candidates
        self.keys = keys
        self.highlighted = highlighted
        self.shotRect = shotRect
        self.lit = lit
        self.chips = chips
        chipFont = font
        hintRect = LookupPickerView.placeHint(in: bounds, topInset: topInset, avoiding: lit + chips)
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let padding: CGFloat = 3
    private static let veil = NSColor(calibratedWhite: 0, alpha: 0.55)
    // Fixed, not `controlAccentColor`: the offscreen snapshot does not read the user's accent.
    private static let accent = NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.94, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Clear first: partial redraws would stack the veil where the frame does not reach.
        context.clear(dirtyRect)
        context.draw(image, in: shotRect)
        context.setFillColor(LookupPickerView.veil.cgColor)
        context.fill(bounds)
        for rect in lit where rect.intersects(dirtyRect) {
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.clip()
            context.draw(image, in: shotRect)
            context.restoreGState()
        }
        for (index, rect) in lit.enumerated() where index != highlighted {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            ring.lineWidth = 1
            NSColor(calibratedWhite: 1, alpha: 0.35).setStroke()
            ring.stroke()
        }
        if lit.indices.contains(highlighted) {
            let ring = NSBezierPath(roundedRect: lit[highlighted].insetBy(dx: -0.5, dy: -0.5), xRadius: 4.5, yRadius: 4.5)
            ring.lineWidth = 2
            LookupPickerView.accent.setStroke()
            ring.stroke()
        }
        for (index, chip) in chips.enumerated() {
            drawChip(keys[index].label, in: chip, highlighted: index == highlighted)
        }
        drawHint()
    }

    private func drawChip(_ label: String, in rect: NSRect, highlighted: Bool) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (highlighted ? LookupPickerView.accent : NSColor(calibratedWhite: 0.08, alpha: 0.9)).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: highlighted ? 0.75 : 0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: chipFont, .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.96)]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    private func drawHint() {
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: hintRect, xRadius: 8, yRadius: 8).fill()
        let attrs = LookupPickerView.hintAttributes
        let size = (LookupPickerView.hint as NSString).size(withAttributes: attrs)
        (LookupPickerView.hint as NSString).draw(at: NSPoint(x: hintRect.midX - size.width / 2, y: hintRect.midY - size.height / 2),
                                                 withAttributes: attrs)
    }

    private static let hintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
    ]

    static func pad(_ lines: [NSRect], by padding: CGFloat) -> [NSRect] {
        lines.enumerated().map { index, line in
            var minX = line.minX - padding, maxX = line.maxX + padding
            var minY = line.minY - padding, maxY = line.maxY + padding
            for (other, near) in lines.enumerated() where other != index {
                let sameColumn = near.minX < line.maxX && line.minX < near.maxX
                let sameRow = near.minY < line.maxY && line.minY < near.maxY
                if sameColumn, near.maxY <= line.minY { minY = max(minY, (line.minY + near.maxY) / 2 + 0.5) }
                if sameColumn, near.minY >= line.maxY { maxY = min(maxY, (line.maxY + near.minY) / 2 - 0.5) }
                if sameRow, near.maxX <= line.minX { minX = max(minX, (line.minX + near.maxX) / 2 + 0.5) }
                if sameRow, near.minX >= line.maxX { maxX = min(maxX, (line.maxX + near.minX) / 2 - 0.5) }
            }
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    static func chipFontSize(for lines: [NSRect]) -> CGFloat {
        let heights = lines.map(\.height).sorted()
        let median = heights.isEmpty ? 14 : heights[heights.count / 2]
        var size = min(15, max(12, (median * 0.8).rounded()))
        var pitch = CGFloat.infinity
        for (i, a) in lines.enumerated() {
            for b in lines[(i + 1)...] where a.minX < b.maxX && b.minX < a.maxX {
                let apart = abs(a.midY - b.midY)
                if apart > max(a.height, b.height) / 2 { pitch = min(pitch, apart) }
            }
        }
        if ceil(size * chipRatio) > pitch { size = max(11, (pitch / chipRatio).rounded(.down)) }
        return size
    }

    private static let chipRatio: CGFloat = 1.3

    private static func chipSize(_ label: String, font: NSFont) -> NSSize {
        let text = (label as NSString).size(withAttributes: [.font: font])
        let height = ceil(font.pointSize * chipRatio)
        return NSSize(width: max(height, ceil(text.width) + 8), height: height)
    }

    static func layoutChips(for lines: [NSRect], sizes: [NSSize], room: NSRect) -> [NSRect] {
        let gap: CGFloat = 4
        var placed: [NSRect] = []
        for (index, line) in lines.enumerated() {
            let size = sizes[index]
            let y = line.midY - size.height / 2
            let left = NSRect(x: line.minX - gap - size.width, y: y, width: size.width, height: size.height)
            let right = NSRect(x: line.maxX + gap, y: y, width: size.width, height: size.height)
            let nudge = (line.height * 0.25).rounded(.down)
            let nudges = nudge >= 2 ? [0, -nudge / 2, nudge / 2, -nudge, nudge] : [0]
            let tries = nudges.map { left.offsetBy(dx: 0, dy: $0) } + [left.offsetBy(dx: -(size.width + 3), dy: 0)]
                + nudges.map { right.offsetBy(dx: 0, dy: $0) }
            func fits(_ chip: NSRect, sparingLines: Bool) -> Bool {
                guard room.contains(chip), !placed.contains(where: { $0.intersects(chip) }) else { return false }
                return !sparingLines || !lines.enumerated().contains { $0.offset != index && $0.element.intersects(chip) }
            }
            let inside = NSRect(x: max(room.minX, line.minX + 2), y: min(max(room.minY, y), room.maxY - size.height),
                                width: size.width, height: size.height)
            placed.append(tries.first { fits($0, sparingLines: true) } ?? tries.first { fits($0, sparingLines: false) } ?? inside)
        }
        return placed
    }

    private static func placeHint(in bounds: NSRect, topInset: CGFloat, avoiding: [NSRect]) -> NSRect {
        let text = (hint as NSString).size(withAttributes: hintAttributes)
        let size = NSSize(width: ceil(text.width) + 24, height: ceil(text.height) + 16)
        let x = (bounds.midX - size.width / 2).rounded()
        let top = NSRect(x: x, y: bounds.maxY - topInset - 16 - size.height, width: size.width, height: size.height)
        guard avoiding.contains(where: { $0.intersects(top.insetBy(dx: -6, dy: -6)) }) else { return top }
        return NSRect(x: x, y: bounds.minY + 16, width: size.width, height: size.height)
    }

    private func highlight(_ index: Int) {
        guard candidates.indices.contains(index), index != highlighted else { return }
        for old in [highlighted, index] { setNeedsDisplay(dirty(for: old)) }
        highlighted = index
    }

    private func dirty(for index: Int) -> NSRect {
        var rect = lit[index].insetBy(dx: -3, dy: -3)
        if chips.indices.contains(index) { rect = rect.union(chips[index].insetBy(dx: -2, dy: -2)) }
        return rect
    }

    private enum Direction { case up, down, left, right }

    private func step(_ direction: Direction) {
        let from = lit[highlighted]
        func gap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> CGFloat {
            max(0, max(a.lowerBound, b.lowerBound) - min(a.upperBound, b.upperBound))
        }
        var best: (index: Int, cost: CGFloat)?
        for (index, rect) in lit.enumerated() where index != highlighted {
            let along: CGFloat, across: CGFloat
            switch direction {
            case .down: along = from.midY - rect.midY; across = gap(from.minX...from.maxX, rect.minX...rect.maxX)
            case .up: along = rect.midY - from.midY; across = gap(from.minX...from.maxX, rect.minX...rect.maxX)
            case .left: along = from.midX - rect.midX; across = gap(from.minY...from.maxY, rect.minY...rect.maxY)
            case .right: along = rect.midX - from.midX; across = gap(from.minY...from.maxY, rect.minY...rect.maxY)
            }
            guard along > 1 else { continue }
            let cost = along + 2 * across
            if best.map({ cost < $0.cost }) ?? true { best = (index, cost) }
        }
        if let best { highlight(best.index) }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 53: onCancel?("cancelled with Esc")
        case 36, 76: onChoose?(highlighted, "Return")                  // Return, Enter
        case 48:                                                        // Tab, Shift-Tab
            let delta = event.modifierFlags.contains(.shift) ? -1 : 1
            highlight((highlighted + delta + candidates.count) % candidates.count)
        case 126: step(.up)
        case 125: step(.down)
        case 123: step(.left)
        case 124: step(.right)
        default:
            // Ignore repeats: that is a key held down from before the picker opened.
            guard modifiers.isEmpty, !event.isARepeat,
                  let index = keys.prefix(candidates.count).firstIndex(where: { $0.code == event.keyCode }) else { return }
            onChoose?(index, "the \(keys[index].label) key")
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
        onCancel?("cancelled with ⌘\(event.charactersIgnoringModifiers ?? "")")
        return true
    }

    // Choose on mouse up: choosing on down closes the picker and the up would reach the game.
    override func mouseDown(with event: NSEvent) {
        pressed = line(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let here = line(at: convert(event.locationInWindow, from: nil))
        if let here, here == pressed {
            onChoose?(here, "a click")
        } else {
            onCancel?("cancelled by a click outside the lines")
        }
        pressed = nil
    }

    override func rightMouseUp(with event: NSEvent) {
        onCancel?("cancelled by a right click")
    }

    private func line(at point: NSPoint) -> Int? {
        lit.indices.first { lit[$0].contains(point) || (chips.indices.contains($0) && chips[$0].contains(point)) }
    }
}

extension LookupPicker {
    nonisolated static func runSnapshotCLI(_ args: [String]) -> Bool {
        guard args.count >= 2, args[1] == "--pick-snapshot" else { return false }
        // Safe: main.swift calls this on the main thread before the app runs.
        MainActor.assumeIsolated { snapshot(Array(args.dropFirst(2))) }
        return true
    }

    private static func snapshot(_ args: [String]) {
        NSApp.setActivationPolicy(.prohibited)
        Settings.echo = true
        var words: [String] = []
        var gameName: String?
        var scale: CGFloat = 1
        var rest = args.makeIterator()
        while let arg = rest.next() {
            switch arg {
            case "--game": gameName = rest.next()
            case "--scale": scale = rest.next().flatMap(Double.init).map { CGFloat(max(1, $0)) } ?? 1
            default: words.append(arg)
            }
        }
        guard words.count >= 4, let x = Double(words[1]), let y = Double(words[2]) else {
            print("usage: --pick-snapshot <shot.png> <x> <y> <out.png> [--game g] [--scale 2]")
            return
        }
        guard let image = NSImage(contentsOfFile: words[0])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("cannot read \(words[0])")
            return
        }
        var game = LookupStore.shared.activeGame
        if let gameName {
            game = LookupStore.shared.game(named: gameName)
                ?? LookupPresets.Preset(rawValue: gameName.lowercased()).map(LookupPresets.make)
            if game == nil { print("no game or preset named \"\(gameName)\""); return }
        }
        guard let game else { print("no game configured"); return }

        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let shot = ScreenGrabber.Shot(image: image, frame: CGRect(origin: .zero, size: size))
        let pointer = CGPoint(x: x / scale, y: y / scale)
        let started = Date()
        var lines: [OCR.Line] = []
        do {
            lines = try Lookup.pickLines(in: shot, pointer: pointer, game: game)
        } catch {
            print("OCR failed: \(error)")
        }
        let analysis = LookupNearby.analyse(lines, in: shot, pointer: pointer)
        let (candidates, suggested) = LookupNearby.picking(analysis, game: game)
        print("\(lines.count) lines, \(candidates.count) to pick from in \(Int(Date().timeIntervalSince(started) * 1000)) ms, game \(game.name)")

        let keys = keys(count: candidates.count)
        let shown = Array(candidates.prefix(keys.count))
        for (index, candidate) in candidates.enumerated() {
            let key = index < keys.count ? keys[index].label : "-"
            print(String(format: "  %@ %@  %-12@ %5.1f  \"%@\"", index == suggested ? ">" : " ", key,
                         candidate.kind.rawValue, candidate.distance, candidate.text))
        }
        if shown.isEmpty { print("nothing to pick: the real picker would not open") }

        let view = LookupPickerView(frame: NSRect(origin: .zero, size: size), image: image, shot: shot.frame,
                                    canvas: shot.frame, candidates: shown, keys: keys,
                                    highlighted: shown.indices.contains(suggested) ? suggested : 0, topInset: 0)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        drawPointer(at: NSPoint(x: pointer.x, y: size.height - pointer.y))
        NSGraphicsContext.restoreGraphicsState()
        let output = URL(fileURLWithPath: words[3])
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: output)
            print("wrote \(output.path) (\(image.width)x\(image.height))")
        } catch {
            print("cannot write \(output.path): \(error.localizedDescription)")
        }
    }

    private static func drawPointer(at tip: NSPoint) {
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, -17), (4, -13), (7, -20), (9.5, -19), (6.5, -12), (12, -12)]
        let arrow = NSBezierPath()
        for (index, p) in points.enumerated() {
            let point = NSPoint(x: tip.x + p.0, y: tip.y + p.1)
            if index == 0 { arrow.move(to: point) } else { arrow.line(to: point) }
        }
        arrow.close()
        NSColor.black.setFill()
        arrow.fill()
        arrow.lineWidth = 1.5
        NSColor.white.setStroke()
        arrow.stroke()
    }
}
