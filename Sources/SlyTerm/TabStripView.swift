import AppKit

enum StripEdge { case top, bottom }

protocol TabStripDelegate: AnyObject {
    var stripTabTitles: [String] { get }
    var stripSelectedIndex: Int? { get }
    var stripWebItems: [TabStripWebItem] { get }
    var stripIsGhost: Bool { get }
    var stripIsPanic: Bool { get }
    var stripHint: (text: String, color: NSColor)? { get }
    func stripTabNeedsAttention(_ index: Int) -> Bool
    func stripTabMark(_ index: Int) -> TabStripMark
    func stripTabToolTip(_ index: Int) -> String?
    func stripSelectTab(_ index: Int)
    func stripCloseTab(_ index: Int)
    func stripSelectWeb(_ index: Int)
    func stripCloseWeb(_ index: Int)
    func stripOpenWeb()
    func stripNewTab()
    func stripBringIn()
    func stripToggleGhost()
    func stripTogglePanic()
    func stripHide()
    func stripClicked()
    func stripDragged(to stripOrigin: NSPoint)
    func stripDragEnded()
}

extension TabStripDelegate {
    func stripBringIn() { TeleportPicker.shared.show() }
}

final class TabStripView: NSView {
    static let height: CGFloat = 28
    weak var delegate: TabStripDelegate?
    var squareCorners = false { didSet { needsDisplay = true } }
    var edge: StripEdge = .bottom { didSet { needsDisplay = true } }

    private enum Region: Equatable {
        case none, tab(Int), close(Int), web(Int), emptyWeb, moreWeb, newTab, ghost, hide, panic
    }

    private var tabRects: [NSRect] = []
    private var closeRects: [NSRect] = []
    private var webItems: [TabStripWebItem] = []
    // One per web tab shown, the first ones in order, or the empty slot's single square when
    // there is none; `moreRect` lists the web tabs that did not fit.
    private var webRects: [NSRect] = []
    private var moreRect: NSRect?
    private var newTabRect = NSRect.zero
    private var ghostRect = NSRect.zero
    private var hideRect = NSRect.zero
    private var panicRect = NSRect.zero

    private var hint: (text: String, color: NSColor)?

    private var pressed: Region = .none
    private var hover: Region = .none
    private var hoverPinned = false
    private var didDrag = false
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var trackingArea: NSTrackingArea?
    // AppKit keeps a tooltip owner by bare pointer, so the strip owns them all and maps tags.
    private var toolTipTargets: [NSView.ToolTipTag: ToolTipTarget] = [:]
    // Re-registering tooltips hides the one showing, so it happens only when a rect or target
    // changed; `addToolTip` cannot move one, only add.
    private var toolTipKeys: [String] = []
    private enum ToolTipTarget { case newTab, tab(Int), emptyWeb, moreWeb }
    private static let newTabToolTip = "New tab. Right-click to bring in a session"
    private static let emptyWebToolTip = "Open a web tab"

    private var spinnerAngle: CGFloat = 120
    private var spinnerTimer: Timer?
    private static let spinnerInterval: TimeInterval = 1.0 / 12
    private static let spinnerStep: CGFloat = 30

    private let cornerRadius: CGFloat = 10
    private static let hintFont = NSFont.systemFont(ofSize: 10)
    private static let labelFont = NSFont.systemFont(ofSize: 11)
    private static let webGap: CGFloat = 3
    private static let terminalMinWidth: CGFloat = 44

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { spinnerTimer?.invalidate() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        let r = region(at: convert(event.locationInWindow, from: nil))
        if r != hover { hover = r; needsDisplay = true }
    }

    // A pointer that jumps into the strip sends only this, no move.
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        hover = .none
        needsDisplay = true
    }

    func hoverWeb(_ index: Int?) {
        hover = index.map { .web($0) } ?? .emptyWeb
        hoverPinned = true
        needsDisplay = true
    }

    // Squares move when a web tab comes or goes, under a pointer that has not.
    private func refreshHover() {
        guard !hoverPinned, let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hover = bounds.contains(p) ? region(at: p) : .none
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopSpinner() }
    }

    private func layoutRegions() {
        let b = bounds
        let button: CGFloat = 22, gap: CGFloat = 4, pad: CGFloat = 8
        let y = (b.height - button) / 2
        var x = b.maxX - pad - button
        hideRect = NSRect(x: x, y: y, width: button, height: button); x -= button + gap
        ghostRect = NSRect(x: x, y: y, width: button, height: button); x -= button + gap
        panicRect = NSRect(x: x, y: y, width: button, height: button); x -= button + gap
        newTabRect = NSRect(x: x, y: y, width: button, height: button)

        webItems = delegate?.stripWebItems ?? []
        let titles = delegate?.stripTabTitles ?? []
        let left = pad + 12
        let count = CGFloat(max(1, titles.count))
        let gaps = CGFloat(max(0, titles.count - 1)) * gap
        // Web squares leave the terminals 44 pt each, down to one square; the web tabs that do not
        // fit go behind a last "…" square.
        let webRight = newTabRect.minX - gap * 2
        let space = webRight - left - gap
        let reserve = min(count * TabStripView.terminalMinWidth + gaps, space - button)
        let step = button + TabStripView.webGap
        let slots = max(1, Int((space - reserve + TabStripView.webGap) / step))
        let overflows = webItems.count > slots
        webRects = []
        var wx = webRight - button
        moreRect = overflows ? NSRect(x: wx, y: y, width: button, height: button) : nil
        if overflows { wx -= step }
        for _ in 0..<(overflows ? slots - 1 : max(1, webItems.count)) {
            webRects.insert(NSRect(x: wx, y: y, width: button, height: button), at: 0)
            wx -= step
        }

        hint = delegate?.stripHint
        let hintWidth = hint.map { (($0.text as NSString).size(withAttributes: [.font: TabStripView.hintFont]).width + 18).rounded(.up) } ?? 0
        let room = webLeft - gap - left
        // Tabs make way for the hint down to 56 pt each, and for the web squares down to what fits.
        let tabWidth = min(170, max(24, min(56, (room - gaps) / count), (room - hintWidth - gaps) / count))
        tabRects = []
        closeRects = []
        var tx = left
        for _ in titles.indices {
            let r = NSRect(x: tx, y: y, width: tabWidth, height: button)
            tabRects.append(r)
            closeRects.append(NSRect(x: r.maxX - 20, y: r.minY + 3, width: 16, height: 16))
            tx += tabWidth + gap
        }
        updateToolTips()
    }

    private var webLeft: CGFloat { webRects.first?.minX ?? moreRect?.minX ?? newTabRect.minX }
    private var hiddenWebIndices: Range<Int> { moreRect == nil ? 0..<0 : webRects.count..<webItems.count }

    func webOverflowMenu() -> NSMenu? {
        guard !hiddenWebIndices.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for index in hiddenWebIndices {
            let web = webItems[index]
            // The page's own title, and a menu grows as wide as its widest item.
            var title = web.title.isEmpty ? "Web tab" : String(web.title.prefix(80))
            if web.title.count > 80 { title += "…" }
            title += (web.isPlaying ? " · playing" : "") + (web.isFloating ? " · floating" : "")
            let item = NSMenuItem(title: title, action: #selector(chooseHiddenWeb(_:)),
                                  keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.tag = index
            item.state = web.isSelected ? .on : .off
            item.image = TabStripView.menuImage(for: web)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseHiddenWeb(_ sender: NSMenuItem) { delegate?.stripSelectWeb(sender.tag) }

    private func showWebOverflow() {
        guard let menu = webOverflowMenu(), let r = moreRect else { return }
        // The point is the menu's top-left corner; it opens toward the window, away from its edge.
        let top = edge == .bottom ? r.maxY + 4 + menu.size.height : r.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: r.minX, y: top), in: self)
    }

    private static func menuImage(for web: TabStripWebItem) -> NSImage? {
        if let icon = web.icon, icon.size.width > 0, icon.size.height > 0, let copy = icon.copy() as? NSImage {
            copy.size = NSSize(width: 16, height: 16)
            return copy
        }
        return NSImage(systemSymbolName: web.symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    }

    private func updateToolTips() {
        var wanted: [(rect: NSRect, target: ToolTipTarget)] = [(newTabRect, .newTab)]
        for i in tabRects.indices where delegate?.stripTabToolTip(i)?.isEmpty == false {
            wanted.append((tabRects[i], .tab(i)))
        }
        if webItems.isEmpty, let r = webRects.first { wanted.append((r, .emptyWeb)) }
        if let moreRect { wanted.append((moreRect, .moreWeb)) }
        let keys = wanted.map { "\($0.rect)|\($0.target)" }
        guard keys != toolTipKeys else { return }
        toolTipKeys = keys
        removeAllToolTips()
        toolTipTargets = [:]
        for tip in wanted { toolTipTargets[addToolTip(tip.rect, owner: self, userData: nil)] = tip.target }
    }

    private func region(at p: NSPoint) -> Region {
        if hideRect.contains(p) { return .hide }
        if ghostRect.contains(p) { return .ghost }
        if panicRect.contains(p) { return .panic }
        if newTabRect.contains(p) { return .newTab }
        if moreRect?.contains(p) == true { return .moreWeb }
        for (i, r) in webRects.enumerated() where r.contains(p) {
            return webItems.isEmpty ? .emptyWeb : .web(i)
        }
        for (i, r) in tabRects.enumerated() where r.contains(p) {
            return closeRects[i].contains(p) ? .close(i) : .tab(i)
        }
        return .none
    }

    override func draw(_ dirtyRect: NSRect) {
        layoutRegions()
        refreshHover()
        let ghost = delegate?.stripIsGhost ?? false
        let panic = delegate?.stripIsPanic ?? false
        let b = bounds
        let cornerRadius: CGFloat = squareCorners ? 0 : self.cornerRadius

        let bg = NSBezierPath()
        switch edge {
        case .bottom:
            bg.move(to: NSPoint(x: b.minX, y: b.maxY))
            bg.line(to: NSPoint(x: b.minX, y: b.minY + cornerRadius))
            bg.appendArc(withCenter: NSPoint(x: b.minX + cornerRadius, y: b.minY + cornerRadius), radius: cornerRadius, startAngle: 180, endAngle: 270, clockwise: false)
            bg.line(to: NSPoint(x: b.maxX - cornerRadius, y: b.minY))
            bg.appendArc(withCenter: NSPoint(x: b.maxX - cornerRadius, y: b.minY + cornerRadius), radius: cornerRadius, startAngle: 270, endAngle: 360, clockwise: false)
            bg.line(to: NSPoint(x: b.maxX, y: b.maxY))
        case .top:
            bg.move(to: NSPoint(x: b.minX, y: b.minY))
            bg.line(to: NSPoint(x: b.minX, y: b.maxY - cornerRadius))
            bg.appendArc(withCenter: NSPoint(x: b.minX + cornerRadius, y: b.maxY - cornerRadius), radius: cornerRadius, startAngle: 180, endAngle: 90, clockwise: true)
            bg.line(to: NSPoint(x: b.maxX - cornerRadius, y: b.maxY))
            bg.appendArc(withCenter: NSPoint(x: b.maxX - cornerRadius, y: b.maxY - cornerRadius), radius: cornerRadius, startAngle: 90, endAngle: 0, clockwise: true)
            bg.line(to: NSPoint(x: b.maxX, y: b.minY))
        }
        bg.close()
        let background = panic ? NSColor(calibratedRed: 0.16, green: 0.09, blue: 0.09, alpha: 1)
                       : ghost ? NSColor(calibratedRed: 0.17, green: 0.13, blue: 0.09, alpha: 0.97)
                       : NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.97)
        background.setFill()
        bg.fill()

        (panic ? NSColor.systemRed : ghost ? NSColor.systemOrange : NSColor.systemGreen).setFill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: b.midY - 3, width: 6, height: 6)).fill()

        let titles = delegate?.stripTabTitles ?? []
        let selected = delegate?.stripSelectedIndex
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        var anyWorking = false
        for (i, r) in tabRects.enumerated() {
            let isSelected = i == selected
            let isHovered = hover == .tab(i) || hover == .close(i)
            let tabPath = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            if isSelected {
                NSColor(calibratedWhite: 1, alpha: 0.16).setFill(); tabPath.fill()
            } else if isHovered {
                NSColor(calibratedWhite: 1, alpha: 0.07).setFill(); tabPath.fill()
            }
            let showClose = isSelected || isHovered
            let alerting = delegate?.stripTabNeedsAttention(i) ?? false
            let color = alerting ? NSColor.systemYellow.withAlphaComponent(0.95)
                                 : NSColor(calibratedWhite: 1, alpha: isSelected ? 0.95 : 0.6)
            let mark = delegate?.stripTabMark(i) ?? (alerting ? .attention : .none)
            if mark == .working { anyWorking = true }
            var indent: CGFloat = 8
            if mark != .none {
                indent = drawMark(mark, in: NSRect(x: r.minX + 8, y: r.midY - 3, width: 6, height: 6), color: color)
            }
            let textRect = NSRect(x: r.minX + indent, y: r.minY + 4, width: r.width - indent - (showClose ? 22 : 8), height: r.height - 8)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: para,
            ]
            (titles[i] as NSString).draw(in: textRect, withAttributes: attrs)
            if showClose {
                drawSymbol("xmark", in: closeRects[i], color: NSColor(calibratedWhite: 1, alpha: hover == .close(i) ? 1 : 0.5), pointSize: 9)
            }
        }

        for (i, r) in webRects.enumerated() {
            if webItems.indices.contains(i) {
                drawWebSquare(webItems[i], in: r, hovered: hover == .web(i), background: background)
            } else {
                drawEmptyWebSquare(in: r, hovered: hover == .emptyWeb)
            }
        }
        if let moreRect {
            let hidden = webItems[hiddenWebIndices]
            let more = TabStripWebItem(title: "", icon: nil, symbol: "ellipsis",
                                       isSelected: hidden.contains { $0.isSelected }, isFloating: false,
                                       isPlaying: hidden.contains { $0.isPlaying })
            drawWebSquare(more, in: moreRect, hovered: hover == .moreWeb, background: background)
        }

        drawButton(newTabRect, symbol: "plus", hovered: hover == .newTab)
        drawButton(panicRect, symbol: panic ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                   hovered: hover == .panic, tint: panic ? .systemRed : nil)
        drawButton(ghostRect, symbol: ghost ? "eye.slash" : "eye", hovered: hover == .ghost, tint: ghost ? .systemOrange : nil)
        drawButton(hideRect, symbol: "minus", hovered: hover == .hide)

        if case .web(let i) = hover, webItems.indices.contains(i) {
            drawLabel(for: webItems[i], index: i, background: background)
        } else if let hint {
            let attrs: [NSAttributedString.Key: Any] = [.font: TabStripView.hintFont, .foregroundColor: hint.color.withAlphaComponent(0.9)]
            let size = (hint.text as NSString).size(withAttributes: attrs)
            let x = webLeft - 10 - size.width
            if x > (tabRects.last?.maxX ?? 20) + 8 {
                (hint.text as NSString).draw(at: NSPoint(x: x, y: b.midY - size.height / 2), withAttributes: attrs)
            }
        }

        updateSpinner(working: anyWorking)
    }

    @discardableResult
    private func drawMark(_ mark: TabStripMark, in slot: NSRect, color: NSColor) -> CGFloat {
        switch mark {
        case .none:
            return 8
        case .attention:
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: slot).fill()
            return 18
        case .working:
            let path = NSBezierPath()
            path.appendArc(withCenter: NSPoint(x: slot.midX, y: slot.midY), radius: 3.5,
                           startAngle: spinnerAngle, endAngle: spinnerAngle + 270)
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
            return 18
        case .waiting:
            drawSymbol("questionmark.circle.fill", in: slot, color: .systemOrange, pointSize: 11)
            return 20
        }
    }

    private func updateSpinner(working: Bool) {
        guard working, window?.isVisible == true else { return stopSpinner() }
        guard spinnerTimer == nil else { return }
        let timer = Timer(timeInterval: TabStripView.spinnerInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            // The window can be ordered out with no further draw, so the timer checks for itself.
            guard self.window?.isVisible == true else { return self.stopSpinner() }
            self.spinnerAngle -= TabStripView.spinnerStep
            if self.spinnerAngle <= -360 { self.spinnerAngle += 360 }
            self.needsDisplay = true
        }
        // `.common` so it keeps turning during a drag, when the default run loop mode does not run.
        RunLoop.main.add(timer, forMode: .common)
        spinnerTimer = timer
    }

    private func stopSpinner() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
    }

    func freezeSpinner(atDegrees degrees: CGFloat) {
        spinnerAngle = degrees
        needsDisplay = true
    }

    private func drawButton(_ r: NSRect, symbol: String, hovered: Bool, tint: NSColor? = nil) {
        if hovered {
            NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        }
        drawSymbol(symbol, in: r, color: tint ?? NSColor(calibratedWhite: 1, alpha: hovered ? 0.95 : 0.7), pointSize: 11)
    }

    private func drawWebSquare(_ item: TabStripWebItem, in r: NSRect, hovered: Bool, background: NSColor) {
        if item.isSelected || hovered {
            NSColor(calibratedWhite: 1, alpha: item.isSelected ? 0.16 : 0.07).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
        let strength: CGFloat = item.isFloating ? 0.4 : item.isSelected ? 1 : hovered ? 0.85 : 0.65
        if let icon = item.icon, icon.size.width > 0, icon.size.height > 0 {
            let side: CGFloat = 14
            icon.draw(in: NSRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver,
                      fraction: item.isFloating ? 0.5 : min(1, strength + 0.15))
        } else {
            let exists: (String) -> Bool = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            let base = exists(item.symbol) ? item.symbol : "globe"
            let name = item.isSelected && exists(base + ".fill") ? base + ".fill" : base
            drawSymbol(name, in: r, color: NSColor(calibratedWhite: 1, alpha: strength * 0.95), pointSize: 11)
        }
        if item.isFloating {
            let outline = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
            outline.lineWidth = 1
            outline.setLineDash([2.5, 2], count: 2, phase: 0)
            NSColor(calibratedWhite: 1, alpha: hovered ? 0.6 : 0.4).setStroke()
            outline.stroke()
        }
        if item.isPlaying {
            let badge = NSRect(x: r.maxX - 9, y: r.minY - 1, width: 11, height: 11)
            background.withAlphaComponent(1).setFill()
            NSBezierPath(ovalIn: badge).fill()
            drawSymbol("speaker.wave.2.fill", in: badge, color: NSColor(calibratedWhite: 1, alpha: 0.9),
                       pointSize: 6.5)
        }
    }

    // Shown at once, where a tooltip waits: the page's title and its key, over the tabs beside it.
    private func drawLabel(for item: TabStripWebItem, index: Int, background: NSColor) {
        var title = item.title.isEmpty ? "Web tab" : item.title
        if item.isFloating { title += " · click to put it back" }
        let key = index < 9 ? "⌥⌘\(index + 1)" : ""
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: TabStripView.labelFont, .paragraphStyle: para,
                                                         .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.9)]
        let keyAttrs: [NSAttributedString.Key: Any] = [.font: TabStripView.labelFont,
                                                       .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.5)]
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)
        let keyWidth = key.isEmpty ? 0 : ((key as NSString).size(withAttributes: keyAttrs).width + 8).rounded(.up)
        let right = webLeft - 4, left: CGFloat = 20
        let width = min((titleSize.width + keyWidth + 16).rounded(.up), right - left)
        guard width >= keyWidth + 40 else { return }
        let r = NSRect(x: right - width, y: (bounds.height - 22) / 2, width: width, height: 22)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        background.withAlphaComponent(1).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.1).setFill()
        path.fill()
        let y = r.midY - titleSize.height / 2
        let titleRect = NSRect(x: r.minX + 8, y: y, width: r.width - 16 - keyWidth, height: titleSize.height)
        (title as NSString).draw(in: titleRect, withAttributes: titleAttrs)
        if !key.isEmpty {
            (key as NSString).draw(at: NSPoint(x: r.maxX - keyWidth, y: y), withAttributes: keyAttrs)
        }
    }

    private func drawEmptyWebSquare(in r: NSRect, hovered: Bool) {
        if hovered {
            NSColor(calibratedWhite: 1, alpha: 0.07).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
        drawSymbol("globe", in: r, color: NSColor(calibratedWhite: 1, alpha: hovered ? 0.6 : 0.3), pointSize: 11)
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor, pointSize: CGFloat) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let symbol = base.withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold)) else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        let dst = NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
        tinted.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = region(at: convert(event.locationInWindow, from: nil))
        didDrag = false
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        let dx = m.x - dragStartMouse.x, dy = m.y - dragStartMouse.y
        if !didDrag {
            if abs(dx) < 3 && abs(dy) < 3 { return }
            didDrag = true
        }
        delegate?.stripDragged(to: NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = .none }
        if didDrag { delegate?.stripDragEnded(); return }
        switch pressed {
        case .tab(let i): delegate?.stripSelectTab(i)
        case .close(let i): delegate?.stripCloseTab(i)
        case .web(let i): delegate?.stripSelectWeb(i)
        case .emptyWeb: delegate?.stripOpenWeb()
        case .moreWeb: showWebOverflow()
        // macOS delivers Control-click as a left click with the modifier, not as `rightMouseUp`.
        case .newTab where event.modifierFlags.contains(.control): delegate?.stripBringIn()
        case .newTab: delegate?.stripNewTab()
        case .ghost: delegate?.stripToggleGhost()
        case .panic: delegate?.stripTogglePanic()
        case .hide: delegate?.stripHide()
        case .none: delegate?.stripClicked()
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if region(at: convert(event.locationInWindow, from: nil)) == .newTab { delegate?.stripBringIn() }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        switch region(at: convert(event.locationInWindow, from: nil)) {
        case .tab(let i): delegate?.stripCloseTab(i)
        case .web(let i): delegate?.stripCloseWeb(i)
        default: break
        }
    }
}

extension TabStripView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        switch toolTipTargets[tag] {
        case .newTab: return TabStripView.newTabToolTip
        case .tab(let index): return delegate?.stripTabToolTip(index) ?? ""
        case .emptyWeb: return TabStripView.emptyWebToolTip
        case .moreWeb:
            let count = hiddenWebIndices.count
            return count == 1 ? "1 more web tab" : "\(count) more web tabs"
        case nil: return ""
        }
    }
}

enum StripSnapshotCLI {
    static func run(_ args: [String]) -> Bool {
        guard args.count >= 3, args[1] == "--strip-snapshot" else { return false }
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: args[2])

        var rows: [(String, NSImage)] = []
        func add(_ caption: String, width: CGFloat = 600, selected: Int?, web: [TabStripWebItem] = [book],
                 hoverWeb: Int? = nil, hoverEmpty: Bool = false, ghost: Bool = false, attention: Int? = nil,
                 marks: [Int: TabStripMark] = [:], hint: (text: String, color: NSColor)? = nil,
                 edge: StripEdge = .bottom, titles: [String] = ["slyterm", "claude", "Projects"]) {
            let delegate = StripSnapshotDelegate(titles: titles, selected: selected, web: web)
            delegate.stripIsGhost = ghost
            delegate.attention = attention
            delegate.marks = marks
            if attention != nil { delegate.stripHint = ("needs you: click the tab", .systemYellow) }
            if let hint { delegate.stripHint = hint }
            if let image = render(delegate, width: width, hoverWeb: hoverWeb, hoverEmpty: hoverEmpty, edge: edge,
                                  caption: caption) {
                rows.append((caption, image))
            }
        }
        let three = [book, video, away]
        add("one web tab, selected", selected: nil, web: [selecting(book)])
        add("three web tabs: the lookup's, a video playing, one floating; a terminal selected",
            selected: 1, web: three)
        add("a web square hovered", selected: 1, web: three, hoverWeb: 0)
        add("the floating square hovered", selected: 1, web: three, hoverWeb: 2)
        add("a web square hovered while a Claude works: the label covers the hint", selected: 1, web: three,
            hoverWeb: 1, marks: [1: .working],
            hint: ("editing GuideTab.swift · 2m", NSColor(calibratedWhite: 1, alpha: 0.55)))
        add("the video's tab selected", selected: nil, web: [book, selecting(video), away])
        add("a video page with no icon, playing and floating", selected: 0, web: [book, floatingVideo])
        add("ghost mode, a web tab selected", selected: nil, web: [selecting(book), video], ghost: true)
        add("a terminal asking for the user", selected: 0, attention: 2)
        add("a Claude working (the spinner, frozen mid-turn)", selected: 1,
            marks: [1: .working],
            hint: ("editing GuideTab.swift · 2m", NSColor(calibratedWhite: 1, alpha: 0.55)))
        add("a Claude waiting for you", selected: 1, marks: [1: .waiting],
            hint: ("waiting for you", .systemOrange))
        add("Codex working: the tab shows its thread name, without the spinner frame", selected: 1,
            marks: [1: .working],
            hint: ("running `npm test` · 45s", NSColor(calibratedWhite: 1, alpha: 0.55)),
            titles: ["slyterm", "Fix the login test | api", "Projects"])
        add("Codex waiting on an approval, omp working in another tab", selected: 1,
            marks: [1: .waiting, 2: .working], hint: ("waiting for you", .systemOrange),
            titles: ["slyterm", "Fix the login test | api", "Run the tests"])
        add("a finished turn nobody looked at", selected: 1, attention: 2, marks: [2: .attention])
        add("all three at once: working, waiting, finished", selected: 0,
            attention: 2, marks: [0: .working, 1: .waiting, 2: .attention],
            hint: ("running the tests · 45s", NSColor(calibratedWhite: 1, alpha: 0.55)))
        add("no web tab, the globe waits", selected: 1, web: [])
        add("no web tab, the globe hovered", selected: 1, web: [], hoverEmpty: true)
        add("360 pt wide, one web tab selected", width: 360, selected: nil, web: [selecting(book)])
        add("360 pt wide, three web tabs", width: 360, selected: 1, web: three)
        add("360 pt wide, three web tabs, a Claude working", width: 360, selected: 1, web: three,
            marks: [1: .working], hint: ("editing GuideTab.swift · 2m", NSColor(calibratedWhite: 1, alpha: 0.55)))
        add("strip at the top of the window, three web tabs, a terminal selected",
            selected: 1, web: three, edge: .top)
        add("strip at the top, ghost mode", selected: 0, web: three, ghost: true, edge: .top)
        add("360 pt wide, twelve web tabs: the ones that do not fit are behind …", width: 360,
            selected: 1, web: many(12))
        add("600 pt wide, twelve web tabs", selected: 1, web: many(12))
        add("600 pt wide, sixteen web tabs, the selected one behind …", selected: nil,
            web: many(16, selected: 14))
        add("360 pt wide, twelve web tabs, the first one hovered", width: 360, selected: 0,
            web: many(12), hoverWeb: 0)
        add("360 pt wide, six terminals, twelve web tabs", width: 360, selected: 5, web: many(12),
            titles: ["slyterm", "claude", "Projects", "logs", "build", "notes"])
        write(rows, to: output)
        return true
    }

    private static func many(_ count: Int, selected: Int? = nil) -> [TabStripWebItem] {
        let plain = TabStripWebItem(title: "Forum thread", icon: nil, symbol: "globe", isSelected: false,
                                    isFloating: false, isPlaying: false)
        let kinds = [book, video, away, plain]
        return (0..<count).map { i in
            var item = kinds[i % kinds.count]
            item.title = "Page \(i + 1) · \(item.title)"
            item.isSelected = i == selected
            return item
        }
    }

    private static let book = TabStripWebItem(title: "The Lost Tome · Quest Wiki", icon: nil, symbol: "book",
                                              isSelected: false, isFloating: false, isPlaying: false)
    private static let video = TabStripWebItem(title: "Speedrun, any% · YouTube", icon: standInFavicon(),
                                               symbol: "play.rectangle", isSelected: false, isFloating: false,
                                               isPlaying: true)
    private static let away = TabStripWebItem(title: "Patch notes", icon: nil, symbol: "globe",
                                              isSelected: false, isFloating: true, isPlaying: false)
    private static let floatingVideo = TabStripWebItem(title: "Trailer", icon: nil, symbol: "play.rectangle",
                                                       isSelected: false, isFloating: true, isPlaying: true)

    private static func selecting(_ item: TabStripWebItem) -> TabStripWebItem {
        var item = item
        item.isSelected = true
        return item
    }

    private static func standInFavicon() -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
            NSColor(calibratedRed: 0.93, green: 0.13, blue: 0.13, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 6, width: 30, height: 21), xRadius: 6, yRadius: 6).fill()
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 13, y: 11))
            play.line(to: NSPoint(x: 13, y: 22))
            play.line(to: NSPoint(x: 22, y: 16.5))
            play.close()
            NSColor.white.setFill()
            play.fill()
            return true
        }
    }

    private static func render(_ delegate: StripSnapshotDelegate, width: CGFloat, hoverWeb: Int?,
                               hoverEmpty: Bool, edge: StripEdge, caption: String) -> NSImage? {
        // Never shown: `cacheDisplay` needs a window's backing store; an unparented view has none.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: TabStripView.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = TabStripView(frame: NSRect(x: 0, y: 0, width: width, height: TabStripView.height))
        view.delegate = delegate
        view.edge = edge
        window.contentView?.addSubview(view)
        view.freezeSpinner(atDegrees: 120)
        if hoverEmpty { view.hoverWeb(nil) } else if let hoverWeb { view.hoverWeb(hoverWeb) }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let menu = view.webOverflowMenu() {
            let items = menu.items.map { "[\($0.tag)\($0.state == .on ? ", selected" : "")] \($0.title)" }
            print("\(caption): … lists \(items.count): " + items.joined(separator: "; "))
        }
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func write(_ rows: [(caption: String, image: NSImage)], to output: URL) {
        let margin: CGFloat = 12, caption: CGFloat = 15
        let width = (rows.map { $0.image.size.width }.max() ?? 600) + margin * 2
        let height = rows.reduce(margin) { $0 + $1.image.size.height + caption + margin }
        // Twice the points, so the 22 pt squares and their badges can be read.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2),
                                         pixelsHigh: Int(height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 0.32, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10),
                                                    .foregroundColor: NSColor.white]
        var y = height - margin
        for row in rows {
            y -= caption
            (row.caption as NSString).draw(at: NSPoint(x: margin, y: y), withAttributes: attrs)
            y -= row.image.size.height
            row.image.draw(in: NSRect(origin: NSPoint(x: margin, y: y), size: row.image.size))
            y -= margin
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: output)
            print("wrote \(output.path) (\(rep.pixelsWide)x\(rep.pixelsHigh), \(rows.count) states)")
        } catch {
            print("cannot write \(output.path): \(error.localizedDescription)")
        }
    }
}

private final class StripSnapshotDelegate: TabStripDelegate {
    let stripTabTitles: [String]
    let stripSelectedIndex: Int?
    let stripWebItems: [TabStripWebItem]
    var stripIsGhost = false
    var stripIsPanic = false
    var stripHint: (text: String, color: NSColor)?
    var attention: Int?
    var marks: [Int: TabStripMark] = [:]

    init(titles: [String], selected: Int?, web: [TabStripWebItem]) {
        stripTabTitles = titles
        stripSelectedIndex = selected
        stripWebItems = web
    }

    func stripTabNeedsAttention(_ index: Int) -> Bool { attention == index }
    func stripTabMark(_ index: Int) -> TabStripMark { marks[index] ?? (attention == index ? .attention : .none) }
    func stripTabToolTip(_ index: Int) -> String? { nil }
    func stripSelectTab(_ index: Int) {}
    func stripCloseTab(_ index: Int) {}
    func stripSelectWeb(_ index: Int) {}
    func stripCloseWeb(_ index: Int) {}
    func stripOpenWeb() {}
    func stripNewTab() {}
    func stripToggleGhost() {}
    func stripTogglePanic() {}
    func stripHide() {}
    func stripClicked() {}
    func stripDragged(to stripOrigin: NSPoint) {}
    func stripDragEnded() {}
}
