import AppKit

// A web tab popped out over the game: the page in a resizable panel and, over its top band, a
// child panel holding the toolbar, so the toolbar stays clickable while the page lets clicks through.
final class FloatingWeb: NSObject, NSWindowDelegate {
    static let minSize = NSSize(width: 240, height: 160)
    private static let pageSize = NSSize(width: 440, height: 560)
    private static let videoWidth: CGFloat = 420
    private static let videoInset: CGFloat = 16
    private static let defaultAspect: CGFloat = 16.0 / 9.0
    private static let cascade: CGFloat = 24
    private static let cornerRadius: CGFloat = 10

    let id: UUID
    let panel: OverlayPanel
    let bar: FloatingBarPanel
    var keyHandler: ((NSEvent) -> Bool)? {
        didSet {
            panel.keyHandler = keyHandler
            bar.keyHandler = keyHandler
        }
    }
    var onKeyChange: (() -> Void)?
    var isKey: Bool { panel.isKeyWindow || bar.isKeyWindow }
    var isVideo: Bool
    var aspect: CGFloat?
    // Set while the window fills its screen: the frame it goes back to.
    private var unfilledFrame: NSRect?
    var isFilled: Bool { unfilledFrame != nil }

    private let toolbarView: NSView
    private let pageView: NSView
    private let toolbarMask: NSView.AutoresizingMask
    private let pageMask: NSView.AutoresizingMask
    private let barHeight: CGFloat
    private let container = NSView(frame: .zero)
    private let barView: FloatingBarView

    init(id: UUID, bar toolbar: NSView, page: NSView, video: Bool, aspect: CGFloat?,
         near reference: NSRect, avoiding others: [NSRect]) {
        self.id = id
        toolbarView = toolbar
        pageView = page
        toolbarMask = toolbar.autoresizingMask
        pageMask = page.autoresizingMask
        isVideo = video
        self.aspect = FloatingWeb.sane(aspect)
        barHeight = toolbar.frame.height > 0 ? toolbar.frame.height : 26
        let frame = FloatingWeb.initialFrame(video: video, aspect: self.aspect, barHeight: barHeight,
                                             near: reference, avoiding: others)
        panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        bar = FloatingBarPanel(contentRect: FloatingWeb.barFrame(for: frame, height: barHeight),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        barView = FloatingBarView(frame: NSRect(origin: .zero, size: bar.frame.size))
        super.init()

        configure(panel)
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = FloatingWeb.minSize
        container.frame = NSRect(origin: .zero, size: frame.size)
        container.wantsLayer = true
        container.layer?.cornerRadius = FloatingWeb.cornerRadius
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]
        panel.contentView = container
        page.frame = NSRect(x: 0, y: 0, width: frame.width, height: max(0, frame.height - barHeight))
        page.autoresizingMask = [.width, .height]
        container.addSubview(page)

        configure(bar)
        bar.hasShadow = false
        // Buttons and drags leave the keyboard where it is; only a text field takes it.
        bar.becomesKeyOnlyIfNeeded = true
        barView.wantsLayer = true
        barView.layer?.cornerRadius = FloatingWeb.cornerRadius
        barView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        barView.layer?.masksToBounds = true
        barView.autoresizingMask = [.width, .height]
        barView.target = panel
        barView.onMoveEnd = { [weak self] in
            self?.keepOnScreen()
            self?.saveFrame()
        }
        bar.contentView = barView
        toolbar.frame = barView.bounds
        toolbar.autoresizingMask = [.width, .height]
        barView.addSubview(toolbar)

        apply(ghost: false, dim: 1, video: nil, backgroundOpacity: CGFloat(Settings.shared.opacity))
        // Last: a frame change before this point is placement, not the user moving the window.
        panel.delegate = self
        bar.delegate = self
    }

    private func configure(_ window: NSPanel) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.level = Settings.shared.levelValue
    }

    // The bar becomes a child here, not in init: adding a child window can order it in even under
    // a hidden parent, and a FloatingWeb that was never shown must stay off screen.
    func show() {
        keepOnScreen()
        panel.orderFrontRegardless()
        if bar.parent !== panel { panel.addChildWindow(bar, ordered: .above) }
        placeBar()
        bar.orderFrontRegardless()
    }

    func hide() {
        bar.orderOut(nil)
        panel.orderOut(nil)
    }

    func close() {
        hide()
        if bar.parent === panel { panel.removeChildWindow(bar) }
        panel.delegate = nil
        bar.delegate = nil
        keyHandler = nil
        onKeyChange = nil
        // The tab may already have taken its views back.
        if toolbarView.superview === barView {
            toolbarView.removeFromSuperview()
            toolbarView.autoresizingMask = toolbarMask
        }
        if pageView.superview === container {
            pageView.removeFromSuperview()
            pageView.autoresizingMask = pageMask
        }
    }

    // `video` is the playing-video level, which replaces the click-through one.
    func apply(ghost: Bool, dim: CGFloat, video: CGFloat?, backgroundOpacity: CGFloat) {
        panel.ignoresMouseEvents = ghost
        panel.alphaValue = isFilled ? 1 : video ?? (ghost ? dim : 1)
        bar.ignoresMouseEvents = false
        bar.alphaValue = ghost ? dim : 1
        bar.allowsKey = !ghost
        let background = TerminalTab.backgroundColor.withAlphaComponent(isFilled ? 1 : backgroundOpacity)
        container.layer?.backgroundColor = background.cgColor
    }

    func setLevel(_ level: NSWindow.Level) {
        panel.level = level
        bar.level = level
    }

    func setAspect(_ aspect: CGFloat?) {
        self.aspect = FloatingWeb.sane(aspect)
        guard let ratio = self.aspect, !isFilled else { return }
        let frame = FloatingWeb.clamped(FloatingWeb.snapped(panel.frame, to: ratio, barHeight: barHeight),
                                        aspect: ratio, barHeight: barHeight)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        placeBar()
    }

    // Fullscreen: nothing is clamped, snapped, moved or saved meanwhile, and the frame comes back
    // as it was. The caller applies the opacity again.
    func setFilled(_ filled: Bool) {
        guard filled != isFilled else { return }
        if filled {
            unfilledFrame = panel.frame
            if let screen = FloatingWeb.screen(for: panel.frame) {
                panel.setFrame(screen.frame, display: true)
            }
        } else if let frame = unfilledFrame {
            unfilledFrame = nil
            panel.setFrame(frame, display: true)
        }
        let radius = filled ? 0 : FloatingWeb.cornerRadius
        container.layer?.cornerRadius = radius
        barView.layer?.cornerRadius = radius
        barView.target = filled ? nil : panel
        placeBar()
        // The video's shape may have changed while the lock was off.
        if !filled { setAspect(aspect) }
    }

    func releaseKey() {
        guard panel.isVisible, isKey else { return }
        hide()
        show()
    }

    private func placeBar() {
        let frame = FloatingWeb.barFrame(for: panel.frame, height: barHeight)
        if bar.frame != frame { bar.setFrame(frame, display: true) }
    }

    private func keepOnScreen() {
        guard !isFilled else { return }
        let frame = FloatingWeb.clamped(panel.frame, aspect: aspect, barHeight: barHeight)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        placeBar()
    }

    private func saveFrame() {
        guard !isFilled else { return }
        Settings.shared.setSavedFloatFrame(panel.frame, video: isVideo)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel else { return frameSize }
        if isFilled { return sender.frame.size }
        guard let aspect = FloatingWeb.sane(aspect) else { return frameSize }
        return FloatingWeb.lockedSize(frameSize, current: sender.frame.size, aspect: aspect, barHeight: barHeight)
    }

    // A child window follows its parent's moves but not its resizes.
    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        placeBar()
    }

    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        placeBar()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        keepOnScreen()
        saveFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) { onKeyChange?() }
    // A window keeps its first responder when it resigns key: the address field would stay
    // editing and take the page's ⌘ keys.
    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === bar { bar.makeFirstResponder(nil) }
        onKeyChange?()
    }

    static func barFrame(for frame: NSRect, height: CGFloat) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    // The aspect comes from the page's own script.
    static func sane(_ aspect: CGFloat?) -> CGFloat? {
        guard let aspect, aspect.isFinite, aspect > 0 else { return nil }
        return min(4, max(0.5, aspect))
    }

    static func initialFrame(video: Bool, aspect: CGFloat?, barHeight: CGFloat, near reference: NSRect,
                             avoiding others: [NSRect]) -> NSRect {
        var frame = Settings.shared.savedFloatFrame(video: video).flatMap(usable)
            ?? defaultFrame(video: video, aspect: aspect, barHeight: barHeight, near: reference)
        if let aspect { frame = snapped(frame, to: aspect, barHeight: barHeight) }
        frame = clamped(frame, aspect: aspect, barHeight: barHeight)
        return offset(frame, avoiding: others, aspect: aspect, barHeight: barHeight)
    }

    // AppKit rounds a window's frame outward to whole points, which would make the bar a point taller.
    private static func whole(_ frame: NSRect) -> NSRect {
        NSRect(x: frame.minX.rounded(), y: frame.minY.rounded(),
               width: frame.width.rounded(), height: frame.height.rounded())
    }

    static func defaultFrame(video: Bool, aspect: CGFloat?, barHeight: CGFloat, near reference: NSRect) -> NSRect {
        let visible = screen(for: reference)?.visibleFrame ?? reference
        if video {
            let size = self.size(width: videoWidth, aspect: aspect ?? defaultAspect, barHeight: barHeight)
            return NSRect(x: visible.maxX - videoInset - size.width, y: visible.maxY - videoInset - size.height,
                          width: size.width, height: size.height)
        }
        let gap: CGFloat = 12
        var x = reference.minX - gap - pageSize.width
        if x < visible.minX, reference.maxX + gap + pageSize.width <= visible.maxX { x = reference.maxX + gap }
        return NSRect(x: x, y: reference.maxY - pageSize.height, width: pageSize.width, height: pageSize.height)
    }

    static func lockedSize(_ proposed: NSSize, current: NSSize, aspect: CGFloat, barHeight: CGFloat) -> NSSize {
        let widthLeads = abs(proposed.width - current.width) >= abs(proposed.height - current.height)
        let width = widthLeads ? proposed.width : (proposed.height - barHeight) * aspect
        return size(width: width, aspect: aspect, barHeight: barHeight)
    }

    static func snapped(_ frame: NSRect, to aspect: CGFloat, barHeight: CGFloat) -> NSRect {
        let size = size(width: frame.width, aspect: aspect, barHeight: barHeight)
        return NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    static func clamped(_ frame: NSRect, aspect: CGFloat?, barHeight: CGFloat) -> NSRect {
        guard let visible = screen(for: frame)?.visibleFrame else { return frame }
        var size = frame.size
        if let aspect {
            if size.width > visible.width || size.height > visible.height {
                size = self.size(width: min(visible.width, (visible.height - barHeight) * aspect),
                                 aspect: aspect, barHeight: barHeight)
            }
        } else {
            size = NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        }
        let x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        let y = min(max(frame.maxY - size.height, visible.minY), visible.maxY - size.height)
        return whole(NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    static func offset(_ frame: NSRect, avoiding others: [NSRect], aspect: CGFloat?,
                       barHeight: CGFloat) -> NSRect {
        func taken(_ candidate: NSRect) -> Bool {
            others.contains { abs($0.minX - candidate.minX) < 1 && abs($0.maxY - candidate.maxY) < 1 }
        }
        guard taken(frame) else { return frame }
        for direction: CGFloat in [1, -1] {
            for step in 1...12 {
                let shift = cascade * CGFloat(step) * direction
                let moved = frame.offsetBy(dx: shift, dy: -shift)
                let candidate = clamped(moved, aspect: aspect, barHeight: barHeight)
                if !taken(candidate) { return candidate }
            }
        }
        return frame
    }

    private static func size(width: CGFloat, aspect: CGFloat, barHeight: CGFloat) -> NSSize {
        let width = max(width, minSize.width, (minSize.height - barHeight) * aspect).rounded()
        return NSSize(width: width, height: (width / aspect).rounded() + barHeight)
    }

    private static func usable(_ frame: NSRect) -> NSRect? {
        guard frame.width >= minSize.width, frame.height >= minSize.height,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }

    private static func screen(for frame: NSRect) -> NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        return NSScreen.screens.filter { overlap($0) > 0 }.max { overlap($0) < overlap($1) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }
}

final class FloatingBarPanel: OverlayPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey && !refusesKey }
}

private final class FloatingBarView: NSView {
    weak var target: NSWindow?
    var onMoveEnd: (() -> Void)?
    private var start: (mouse: NSPoint, origin: NSPoint)?
    private var didMove = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The toolbar's buttons take their own clicks; a press on its empty space travels up to here.
    override func mouseDown(with event: NSEvent) {
        start = (NSEvent.mouseLocation, target?.frame.origin ?? .zero)
        didMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let target else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        if !didMove {
            guard abs(dx) >= 3 || abs(dy) >= 3 else { return }
            didMove = true
        }
        target.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if didMove { onMoveEnd?() }
        start = nil
        didMove = false
    }
}

enum FloatSnapshotCLI {
    private static let scale: CGFloat = 2
    private static let dim: CGFloat = 0.7
    private static let opacity: CGFloat = 0.9
    private static let videoOpacity: CGFloat = 0.85

    static func run(_ args: [String]) -> Bool {
        guard args.count >= 3, args[1] == "--float-snapshot" else { return false }
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: args[2])
        let reference = OverlayController.defaultFrame()
        report(near: reference)

        let target = SnapshotTarget()
        let page = FloatingWeb(id: UUID(), bar: toolbar(title: "The Lost Tome · Quest Wiki", target: target),
                               page: SnapshotPage(video: false), video: false, aspect: nil,
                               near: reference, avoiding: [])
        let video = FloatingWeb(id: UUID(), bar: toolbar(title: "Speedrun, any% · YouTube", target: target),
                                page: SnapshotPage(video: true), video: true, aspect: 16.0 / 9.0,
                                near: reference, avoiding: [page.panel.frame])
        print("page window: \(page.panel.frame) bar: \(page.bar.frame)")
        print("video window: \(video.panel.frame) bar: \(video.bar.frame)")
        let proposed = NSSize(width: video.panel.frame.width + 180, height: video.panel.frame.height)
        print("video window dragged 180 pt wider: \(video.windowWillResize(video.panel, to: proposed))")
        let unfilled = video.panel.frame
        video.setFilled(true)
        print("video window fullscreen: \(video.panel.frame) bar: \(video.bar.frame), "
              + "dragged 180 pt wider: \(video.windowWillResize(video.panel, to: proposed))")
        video.setFilled(false)
        print("and back: \(video.panel.frame), as before: \(video.panel.frame == unfilled)")

        var rows: [[(caption: String, image: NSImage)]] = [[], []]
        func shot(_ row: Int, _ caption: String, _ web: FloatingWeb, ghost: Bool, playing: Bool) {
            web.apply(ghost: ghost, dim: dim, video: playing ? videoOpacity : nil, backgroundOpacity: opacity)
            let state = "page alpha \(web.panel.alphaValue), ignores mouse \(web.panel.ignoresMouseEvents); "
                + "bar alpha \(web.bar.alphaValue), ignores mouse \(web.bar.ignoresMouseEvents), "
                + "can become key \(web.bar.canBecomeKey)"
            print("\(caption): \(state)")
            if let image = picture(of: web) { rows[row].append((caption, image)) }
        }
        shot(0, "page, interact", page, ghost: false, playing: false)
        shot(0, "page, click-through", page, ghost: true, playing: false)
        shot(1, "video, interact, paused", video, ghost: false, playing: false)
        shot(1, "video, interact, playing", video, ghost: false, playing: true)
        shot(1, "video, click-through, paused", video, ghost: true, playing: false)
        shot(1, "video, click-through, playing", video, ghost: true, playing: true)
        print("on screen: page \(page.panel.isVisible || page.bar.isVisible), "
              + "video \(video.panel.isVisible || video.bar.isVisible)")
        write(rows, to: output)
        page.close()
        video.close()
        return true
    }

    private static func report(near reference: NSRect) {
        let bar: CGFloat = 26
        let wide: CGFloat = 16.0 / 9.0
        print("main window (default frame): \(reference)")
        let first = FloatingWeb.defaultFrame(video: false, aspect: nil, barHeight: bar, near: reference)
        print("page, default: \(first)")
        let second = FloatingWeb.offset(first, avoiding: [first], aspect: nil, barHeight: bar)
        print("page opened on top of it: \(second)")
        print("and a third: \(FloatingWeb.offset(first, avoiding: [first, second], aspect: nil, barHeight: bar))")
        let video = FloatingWeb.defaultFrame(video: true, aspect: wide, barHeight: bar, near: reference)
        print("video 16:9, default: \(video)")
        let classic = FloatingWeb.defaultFrame(video: true, aspect: 4.0 / 3, barHeight: bar, near: reference)
        print("video 4:3, default: \(classic)")
        func locked(_ width: CGFloat, _ height: CGFloat, from current: NSSize, _ aspect: CGFloat) -> NSSize {
            FloatingWeb.lockedSize(NSSize(width: width, height: height), current: current, aspect: aspect,
                                   barHeight: bar)
        }
        print("16:9, right edge to 600 wide: \(locked(600, video.height, from: video.size, wide))")
        print("16:9, bottom edge to 400 tall: \(locked(video.width, 400, from: video.size, wide))")
        print("16:9, dragged below the minimum: \(locked(100, 80, from: video.size, wide))")
        print("4:1, at the minimum width: \(locked(240, 160, from: NSSize(width: 300, height: 160), 4))")
        print("snapped to 4:3, top edge kept: \(FloatingWeb.snapped(video, to: 4.0 / 3, barHeight: bar))")
        let huge = NSRect(x: reference.minX - 4000, y: reference.minY, width: 5000, height: 4000)
        print("5000 x 4000 page, off to the left, clamped: "
              + "\(FloatingWeb.clamped(huge, aspect: nil, barHeight: bar))")
        print("same, 16:9: \(FloatingWeb.clamped(huge, aspect: wide, barHeight: bar))")
        let aspects: [CGFloat?] = [nil, .nan, .infinity, -1, 0, 0.1, 1.5, 10]
        func text(_ value: CGFloat?) -> String { value.map { "\($0)" } ?? "nil" }
        print("aspects from a page: " + aspects.map { "\(text($0)) -> \(text(FloatingWeb.sane($0)))" }
            .joined(separator: ", "))
        let saved = [false, true].map { Settings.shared.savedFloatFrame(video: $0).map { "\($0)" } ?? "none" }
        print("saved frames: page \(saved[0]), video \(saved[1])")
    }

    private static func toolbar(title: String, target: SnapshotTarget) -> NSView {
        let width: CGFloat = 400, size: CGFloat = 20, y: CGFloat = 3
        let bar = GuideToolbarView(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        let left = [("chevron.left", "Back"), ("chevron.right", "Forward")]
        let right = [("xmark", "Close"), ("safari", "Open in browser"), ("pip.enter", "Put back"),
                     ("doc.richtext", "Reader"), ("magnifyingglass", "Find")]
        let action = #selector(SnapshotTarget.noop)
        for (i, item) in left.enumerated() {
            let button = GuideToolbarView.button(item.0, tooltip: item.1, target: target, action: action)
            button.frame = NSRect(x: 6 + CGFloat(i) * 22, y: y, width: size, height: size)
            bar.addSubview(button)
        }
        for (i, item) in right.enumerated() {
            let button = GuideToolbarView.button(item.0, tooltip: item.1, target: target, action: action)
            button.frame = NSRect(x: width - 26 - CGFloat(i) * 22, y: y, width: size, height: size)
            button.autoresizingMask = [.minXMargin]
            bar.addSubview(button)
        }
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.75)
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        let leftEdge: CGFloat = 54, rightEdge = width - 26 - CGFloat(right.count - 1) * 22 - 6
        label.frame = NSRect(x: leftEdge, y: 5, width: rightEdge - leftEdge, height: 16)
        label.autoresizingMask = [.width]
        bar.addSubview(label)
        return bar
    }

    private static func picture(of web: FloatingWeb) -> NSImage? {
        guard let page = layers(of: web.panel), let bar = layers(of: web.bar) else { return nil }
        let size = web.panel.frame.size
        let pageAlpha = web.panel.alphaValue, barAlpha = web.bar.alphaValue
        let band = NSRect(x: 0, y: size.height - bar.size.height, width: bar.size.width, height: bar.size.height)
        return NSImage(size: size, flipped: false) { _ in
            page.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: pageAlpha)
            bar.draw(in: band, from: .zero, operation: .sourceOver, fraction: barAlpha)
            return true
        }
    }

    // Offscreen, cacheDisplay skips layer backgrounds and corner masks and CALayer.render skips
    // drawn content, so backgrounds and masks come from the views' layers; picture(of:) adds alpha.
    private static func layers(of window: NSWindow) -> NSImage? {
        guard let root = window.contentView,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: rep)
        let content = NSImage(size: root.bounds.size)
        content.addRepresentation(rep)
        return NSImage(size: root.bounds.size, flipped: false) { _ in
            clipPath(root).addClip()
            for view in [root] + root.subviews {
                guard let color = view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) else { continue }
                color.setFill()
                (view === root ? root.bounds : view.frame).fill(using: .sourceOver)
            }
            content.draw(in: root.bounds)
            return true
        }
    }

    private static func clipPath(_ view: NSView) -> NSBezierPath {
        let b = view.bounds
        guard let layer = view.layer, layer.masksToBounds, layer.cornerRadius > 0 else {
            return NSBezierPath(rect: b)
        }
        func radius(_ corner: CACornerMask) -> CGFloat {
            layer.maskedCorners.contains(corner) ? layer.cornerRadius : 0
        }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: b.midX, y: b.minY))
        path.appendArc(from: NSPoint(x: b.maxX, y: b.minY), to: NSPoint(x: b.maxX, y: b.maxY),
                       radius: radius(.layerMaxXMinYCorner))
        path.appendArc(from: NSPoint(x: b.maxX, y: b.maxY), to: NSPoint(x: b.minX, y: b.maxY),
                       radius: radius(.layerMaxXMaxYCorner))
        path.appendArc(from: NSPoint(x: b.minX, y: b.maxY), to: NSPoint(x: b.minX, y: b.minY),
                       radius: radius(.layerMinXMaxYCorner))
        path.appendArc(from: NSPoint(x: b.minX, y: b.minY), to: NSPoint(x: b.maxX, y: b.minY),
                       radius: radius(.layerMinXMinYCorner))
        path.close()
        return path
    }

    private static func bitmap(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    private static func write(_ rows: [[(caption: String, image: NSImage)]], to output: URL) {
        let margin: CGFloat = 16, caption: CGFloat = 16, around: CGFloat = 18
        let rowWidths = rows.map { row in row.reduce(margin) { $0 + $1.image.size.width + around * 2 + margin } }
        let width = rowWidths.max() ?? 600
        let rowHeights = rows.map { row in (row.map { $0.image.size.height }.max() ?? 0) + around * 2 + caption }
        let height = rowHeights.reduce(margin) { $0 + $1 + margin }
        guard let rep = bitmap(NSSize(width: width, height: height)),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.32, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.white]
        var top = height - margin
        for (row, rowHeight) in zip(rows, rowHeights) {
            var x = margin
            for shot in row {
                (shot.caption as NSString).draw(at: NSPoint(x: x, y: top - caption + 2), withAttributes: attrs)
                let size = shot.image.size
                let scene = NSRect(x: x, y: top - caption - size.height - around * 2,
                                   width: size.width + around * 2, height: size.height + around * 2)
                drawGame(in: scene)
                shot.image.draw(in: NSRect(origin: NSPoint(x: scene.minX + around, y: scene.minY + around), size: size))
                x += scene.width + margin
            }
            top -= rowHeight + margin
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: output)
            print("wrote \(output.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            print("cannot write \(output.path): \(error.localizedDescription)")
        }
    }

    // A bright stand-in for the game behind the window, so translucency and dimming show.
    private static func drawGame(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        NSGradient(starting: NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.92, alpha: 1),
                   ending: NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.40, alpha: 1))?.draw(in: rect, angle: -90)
        NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.35)).fill()
        NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.20, alpha: 1).setFill()
        var x = rect.minX + 20
        while x < rect.maxX {
            NSBezierPath(ovalIn: NSRect(x: x, y: rect.minY + rect.height * 0.28, width: 34, height: 34)).fill()
            x += 90
        }
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.midY - 3, width: rect.width, height: 6)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class SnapshotTarget: NSObject {
    @objc func noop() {}
}

private final class SnapshotPage: NSView {
    private let video: Bool

    init(video: Bool) {
        self.video = video
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        guard video else {
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .bold),
                                                        .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 1)]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13),
                                                       .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)]
            ("The Lost Tome" as NSString).draw(at: NSPoint(x: 20, y: b.maxY - 44), withAttributes: title)
            let text = "Stand-in for a web page. Speak to the archivist in the east wing, then take the "
                + "stairs down to the flooded vault. The tome sits behind the third pillar."
            (text as NSString).draw(in: NSRect(x: 20, y: b.maxY - 140, width: b.width - 40, height: 84),
                                    withAttributes: body)
            NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: NSRect(x: 20, y: b.maxY - 300, width: b.width - 40, height: 140),
                         xRadius: 6, yRadius: 6).fill()
            return
        }
        NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.30, alpha: 1),
                   ending: NSColor(calibratedRed: 0.45, green: 0.15, blue: 0.35, alpha: 1))?.draw(in: b, angle: 30)
        let circle = NSRect(x: b.midX - 22, y: b.midY - 22, width: 44, height: 44)
        NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let play = NSBezierPath()
        play.move(to: NSPoint(x: circle.minX + 17, y: circle.minY + 12))
        play.line(to: NSPoint(x: circle.minX + 17, y: circle.maxY - 12))
        play.line(to: NSPoint(x: circle.maxX - 12, y: circle.midY))
        play.close()
        NSColor.black.setFill()
        play.fill()
        NSColor(calibratedWhite: 1, alpha: 0.35).setFill()
        NSRect(x: 12, y: 12, width: b.width - 24, height: 3).fill()
        NSColor.systemRed.setFill()
        NSRect(x: 12, y: 12, width: (b.width - 24) * 0.4, height: 3).fill()
    }
}
