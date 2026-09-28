import AppKit
import SwiftTerm

final class OverlayController: NSObject, TabStripDelegate {
    let settings = Settings.shared
    let main: OverlayPanel
    let strip: StripPanel
    let stripView: TabStripView
    private let container: NSView
    private(set) var stripEdge: StripEdge

    private(set) var terminals: [TerminalTab] = []
    // In strip order, docked and floating alike.
    private(set) var webTabs: [GuideTab] = []
    private var floating: [UUID: FloatingWeb] = [:]
    // The docked web tab in front of the terminal, if any.
    private var frontWeb: GuideTab?
    private var lastWeb: GuideTab?
    private var closedWebURLs: [URL] = []
    private var lookupTabID: UUID?
    private var lastPlayedID: UUID?
    private var playPaused: [UUID] = []
    private var panicPaused: [UUID] = []
    // The docked web tab on screen, and the videos paused for leaving it.
    private var inViewID: UUID?
    private var outOfViewPaused: Set<UUID> = []
    private var filledByFloat: Set<UUID> = []
    private(set) var selectedIndex = 0
    private(set) var isGhost = false
    private var isReleasingKeyboard = false
    // Set while our own window (the lookup picker) closes: the key status AppKit then hands the
    // overlay is not the user wanting to type, and the closing window decides where it goes.
    var ignoresHandedKeyStatus = false
    private var lastOtherApp: NSRunningApplication?
    private var startupAnimation: StartupAnimationView?

    private enum FullscreenWindow: Equatable { case main, floating(UUID) }
    private var fullscreen: FullscreenWindow?
    // The SlyTerm window's frame before it filled the screen; a floating window keeps its own.
    private var fullscreenFrame = NSRect.zero
    var isFullscreen: Bool { fullscreen != nil }

    private struct PanicRestore {
        let frame: NSRect
        let ghost: Bool
        let visible: Bool
        let web: UUID?
        // A web tab asked for during panic comes in front instead.
        var arrived: UUID?
        let fullscreen: FullscreenWindow?
    }
    private var panicRestore: PanicRestore?
    var isPanic: Bool { panicRestore != nil }
    private var fillsScreen: Bool { isPanic || fullscreen == .main }

    private var isRestoringSession = false

    // Polled: stock zsh installs its OSC 7 cwd hook only for Apple_Terminal, and TERM_PROGRAM
    // here is SlyTerm, so no `cd` is ever reported.
    private var directoryPoll: Timer?
    private let activityMonitor = ActivityMonitor()
    private var firstResponderObservation: NSKeyValueObservation?
    private var focusSyncQueued = false

    static let stripHeight = TabStripView.height
    static let minSize = NSSize(width: 360, height: 200)

    var tabs: [Tab] { terminals + webTabs }
    var current: Tab? {
        if let frontWeb { return frontWeb }
        return terminals.indices.contains(selectedIndex) ? terminals[selectedIndex] : nil
    }
    var isVisible: Bool { main.isVisible }
    var hasKeyboard: Bool { main.isKeyWindow || floating.values.contains { $0.isKey } }

    override init() {
        let frame = OverlayController.initialFrame()
        let restored = Settings.shared.savedFrame == frame
        let candidate: StripEdge = restored ? (Settings.shared.savedStripEdge ?? .bottom) : .bottom
        let edge = OverlayController.edge(forStripAt: OverlayController.stripFrame(for: frame, edge: candidate),
                                          window: frame, setting: Settings.shared.stripPosition)
        stripEdge = edge
        Settings.shared.savedStripEdge = edge
        main = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        strip = StripPanel(contentRect: OverlayController.stripFrame(for: frame, edge: edge), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        stripView = TabStripView(frame: NSRect(origin: .zero, size: strip.frame.size))
        container = NSView(frame: OverlayController.containerFrame(for: frame, edge: edge))
        super.init()
        configureMain()
        configureStrip()
        observe()
        applyWindowLevel()
        Activity.host = self
        restoreSessionOrOpenFirstTab()
        startDirectoryPoll()
        startActivityMonitor()
    }

    deinit {
        directoryPoll?.invalidate()
        activityMonitor.stop()
    }

    // Only once the tabs exist: `start` scans at once and takes that as the baseline, so an
    // earlier start would announce every restored tab as an event.
    private func startActivityMonitor() {
        Activity.monitor = activityMonitor
        activityMonitor.onEvent = { [weak self] event in self?.activityDidChange(event) }
        activityMonitor.start(tabs: { [weak self] in self?.terminals ?? [] },
                              visible: { [weak self] in self?.main.isVisible ?? false })
    }

    private func configureMain() {
        main.isOpaque = false
        main.backgroundColor = .clear
        main.hasShadow = false
        main.isFloatingPanel = true
        main.hidesOnDeactivate = false
        main.becomesKeyOnlyIfNeeded = false
        main.isMovableByWindowBackground = false
        main.isReleasedWhenClosed = false
        main.animationBehavior = .none
        main.minSize = OverlayController.minSize
        main.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        main.title = "SlyTerm"

        let root = NSView(frame: NSRect(origin: .zero, size: main.frame.size))
        root.wantsLayer = true
        main.contentView = root

        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.maskedCorners = OverlayController.containerCorners(for: stripEdge)
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]
        root.addSubview(container)
        applyBackground()

        main.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
    }

    private func configureStrip() {
        strip.isOpaque = false
        strip.backgroundColor = .clear
        strip.hasShadow = false
        strip.hidesOnDeactivate = false
        strip.isReleasedWhenClosed = false
        strip.animationBehavior = .none
        strip.ignoresMouseEvents = false
        strip.collectionBehavior = main.collectionBehavior
        stripView.delegate = self
        stripView.edge = stripEdge
        stripView.autoresizingMask = [.width, .height]
        strip.contentView = stripView
        main.addChildWindow(strip, ordered: .above)
    }

    private func observe() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(mainDidResize), name: NSWindow.didResizeNotification, object: main)
        nc.addObserver(self, selector: #selector(mainDidMove), name: NSWindow.didMoveNotification, object: main)
        nc.addObserver(self, selector: #selector(mainDidResignKey), name: NSWindow.didResignKeyNotification, object: main)
        nc.addObserver(self, selector: #selector(mainDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: main)
        nc.addObserver(self, selector: #selector(settingsChanged(_:)), name: Settings.didChange, object: nil)
        firstResponderObservation = main.observe(\.firstResponder) { [weak self] _, _ in
            self?.firstResponderChanged()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastOtherApp = front
        }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastOtherApp = app
    }

    static func initialFrame() -> NSRect {
        if let saved = Settings.shared.savedFrame,
           saved.width >= minSize.width, saved.height >= minSize.height,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            return saved
        }
        return defaultFrame()
    }

    static func defaultFrame() -> NSRect {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(620, vf.width * 0.4)
        let h = vf.height * 0.6
        return NSRect(x: vf.maxX - w - 16, y: vf.minY + 16, width: w, height: h)
    }

    static func stripFrame(for f: NSRect, edge: StripEdge) -> NSRect {
        NSRect(x: f.minX, y: edge == .bottom ? f.minY : f.maxY - stripHeight, width: f.width, height: stripHeight)
    }

    static func containerFrame(for f: NSRect, edge: StripEdge) -> NSRect {
        NSRect(x: 0, y: edge == .bottom ? stripHeight : 0, width: f.width, height: f.height - stripHeight)
    }

    private static func containerCorners(for edge: StripEdge) -> CACornerMask {
        edge == .bottom ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    // Judged on the strip's band, not the window's centre: a flip moves the window across the
    // band, so a centre-based rule would undo itself on the next tick and oscillate.
    static func edge(forStripAt band: NSRect, window frame: NSRect, setting: String) -> StripEdge {
        switch setting {
        case "top": return .top
        case "bottom": return .bottom
        default: break
        }
        func overlap(_ screen: NSScreen) -> CGFloat {
            let r = screen.frame.intersection(frame)
            return r.isNull ? 0 : r.width * r.height
        }
        let under = NSScreen.screens.first { $0.frame.contains(NSPoint(x: band.midX, y: band.midY)) }
        let mostly = NSScreen.screens.filter { overlap($0) > 0 }.max { overlap($0) < overlap($1) }
        guard let screen = under ?? mostly ?? NSScreen.main ?? NSScreen.screens.first else { return .bottom }
        return band.midY > screen.frame.midY ? .top : .bottom
    }

    private func layoutStrip() {
        strip.setFrame(OverlayController.stripFrame(for: main.frame, edge: stripEdge), display: true)
    }

    private func setStripEdge(_ edge: StripEdge) {
        Settings.log("strip edge: \(edge) frame=\(main.frame)")
        stripEdge = edge
        container.frame = OverlayController.containerFrame(for: main.frame, edge: edge)
        container.layer?.maskedCorners = OverlayController.containerCorners(for: edge)
        stripView.edge = edge
        settings.savedStripEdge = edge
        Activity.card?.layout()
    }

    private func applyStripEdge(_ edge: StripEdge) {
        guard edge != stripEdge else { return }
        setStripEdge(edge)
        layoutStrip()
    }

    // The band comes from the window: `strip.frame` is stale inside a resize notification.
    private func updateStripEdge() {
        guard !fillsScreen else { return }
        let band = OverlayController.stripFrame(for: main.frame, edge: stripEdge)
        applyStripEdge(OverlayController.edge(forStripAt: band, window: main.frame,
                                              setting: settings.stripPosition))
    }

    func resetPosition() {
        if isPanic { exitPanic() }
        exitFullscreen()
        let frame = OverlayController.defaultFrame()
        main.setFrame(frame, display: true)
        applyStripEdge(OverlayController.edge(forStripAt: OverlayController.stripFrame(for: frame, edge: .bottom),
                                              window: frame, setting: settings.stripPosition))
        layoutStrip()
    }

    @objc private func mainDidResize() {
        layoutStrip()
        if !fillsScreen { settings.savedFrame = main.frame }
        updateStripEdge()
        Activity.card?.layout()
    }

    @objc private func mainDidMove() {
        if !fillsScreen { settings.savedFrame = main.frame }
        updateStripEdge()
        Activity.card?.layout()
    }

    func togglePanic() {
        if isPanic { exitPanic() } else { enterPanic() }
    }

    private var mainScreen: NSScreen {
        FloatingWeb.screen(for: main.frame) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func enterPanic() {
        endStartupAnimation()
        guard !isPanic else { return }
        let fromWeb = frontWeb != nil
        let screen = mainScreen
        // A SlyTerm window in fullscreen already fills the screen: panic keeps the frame it left.
        let frame = fullscreen == .main ? fullscreenFrame : main.frame
        panicRestore = PanicRestore(frame: frame, ghost: isGhost, visible: main.isVisible,
                                    web: frontWeb?.id, arrived: nil, fullscreen: fullscreen)
        Settings.log("enterPanic screen=\(screen.frame) restore=\(frame) web=\(fromWeb)"
                     + " fullscreen=\(fullscreen.map { "\($0)" } ?? "none")")
        // Suspension pauses the players, so which tabs were a show is noted first.
        panicPaused = webTabs.filter { $0.media.isPlaying }.map(\.id)
        // Playing again since: no longer paused, and not to end paused as a guide's pause would.
        playPaused.removeAll { panicPaused.contains($0) }
        webTabs.forEach { $0.setMediaSuspended(true) }
        floating.values.forEach { $0.hide() }
        if fullscreen == .main { fullscreen = nil } else { exitFullscreen() }
        container.layer?.cornerRadius = 0
        stripView.squareCorners = true
        applyBackground()
        setGhost(false)
        main.setFrame(screen.frame, display: true)
        layoutStrip()
        main.orderFrontRegardless()
        if fromWeb { showTerminal() }
        focusTerminal()
        stripView.needsDisplay = true
        Activity.card?.layout()
    }

    func exitPanic(hidden: Bool = false) {
        guard let restore = panicRestore else { return }
        panicRestore = nil
        var refill = hidden ? nil : restore.fullscreen
        // A floating window filling the screen again would cover the guide that came meanwhile.
        if case .floating(let id)? = refill, floating[id] == nil || restore.arrived != nil { refill = nil }
        Settings.log("exitPanic restore=\(restore.frame) ghost=\(restore.ghost) visible=\(restore.visible)"
                     + " hidden=\(hidden) fullscreen=\(refill.map { "\($0)" } ?? "none")")
        if refill == .main {
            // Back to fullscreen: the window already fills the screen, square and opaque.
            fullscreen = .main
            fullscreenFrame = restore.frame
        } else {
            container.layer?.cornerRadius = 10
            stripView.squareCorners = false
            applyBackground()
            main.setFrame(restore.frame, display: true)
            updateStripEdge()
            layoutStrip()
        }
        if !restore.visible || hidden {
            // A floating window going back to fullscreen takes the keyboard, not the game.
            if refill == nil { hide() }
            // Floating windows stay out, and must let clicks through again if they did before.
            if restore.ghost { setGhost(true) }
        } else if restore.ghost {
            setGhost(true)
        } else {
            focusTerminal()
        }
        // Last, so the page ends up first responder whichever branch ran above.
        if let id = restore.arrived ?? restore.web, let tab = webTabs.first(where: { $0.id == id }),
           tab.place == .docked {
            selectWeb(tab)
        }
        floating.values.forEach { $0.show() }
        // The video panic covered ends paused if it is no longer on screen: hidden on the way out,
        // or behind a page that came during panic.
        let inView = restore.visible && !hidden ? frontWeb : nil
        for tab in webTabs {
            if settings.autoPauseVideo, tab.id == restore.web, tab.place == .docked, tab !== inView,
               panicPaused.contains(tab.id), tab.media.hasVideo {
                tab.endSuspensionPaused()
                outOfViewPaused.insert(tab.id)
            } else if panicPaused.contains(tab.id), playPaused.contains(tab.id) {
                tab.endSuspensionPaused()
            } else {
                tab.setMediaSuspended(false)
            }
        }
        panicPaused = []
        if case .floating? = refill, let refill {
            enterFullscreen(refill)
            // The SlyTerm window was hidden before panic; the keyboard is in the floating window now.
            if !restore.visible { main.orderOut(nil) }
        }
        updateInView()
        stripView.needsDisplay = true
        Activity.card?.layout()
    }

    func toggleFullscreen() {
        guard !isPanic else { return }
        if isFullscreen { exitFullscreen(); return }
        let key = floating.first { $0.value.isKey }?.key
        enterFullscreen(key.map { .floating($0) } ?? .main)
    }

    private func enterFullscreen(_ window: FullscreenWindow) {
        endStartupAnimation()
        guard !isPanic, fullscreen == nil else { return }
        switch window {
        case .main:
            let screen = mainScreen
            fullscreenFrame = main.frame
            fullscreen = .main
            Settings.log("enterFullscreen main screen=\(screen.frame) restore=\(fullscreenFrame)")
            container.layer?.cornerRadius = 0
            stripView.squareCorners = true
            applyBackground()
            main.setFrame(screen.frame, display: true)
            layoutStrip()
            focusTerminal()
        case .floating(let id):
            guard let web = floating[id] else { return }
            fullscreen = window
            Settings.log("enterFullscreen floating \(webTabs.first { $0.id == id }?.title ?? "")")
            if isGhost { setGhost(false) }
            web.setFilled(true)
            web.show()
            if !web.isKey {
                NSApp.activate(ignoringOtherApps: true)
                web.panel.makeKeyAndOrderFront(nil)
            }
            raiseFloating()
        }
        applyAlpha()
        stripView.needsDisplay = true
        Activity.card?.layout()
    }

    // Leaves the keyboard and the mode where they are.
    func exitFullscreen() {
        guard let window = fullscreen else { return }
        fullscreen = nil
        Settings.log("exitFullscreen \(window)"
                     + (window == .main ? " restore=\(fullscreenFrame)" : ""))
        switch window {
        case .main:
            container.layer?.cornerRadius = 10
            stripView.squareCorners = false
            applyBackground()
            main.setFrame(fullscreenFrame, display: true)
            updateStripEdge()
            layoutStrip()
        case .floating(let id):
            floating[id]?.setFilled(false)
        }
        applyAlpha()
        stripView.needsDisplay = true
        Activity.card?.layout()
    }

    // Floating windows share the level of the one filling the screen, which comes to the front
    // whenever it takes the keyboard: they go back above it.
    private func raiseFloating() {
        guard let fullscreen else { return }
        for (id, web) in floating where web.panel.isVisible && fullscreen != .floating(id) {
            web.show()
        }
        Activity.card?.layout()
    }

    // A fullscreen floating window that goes away ends fullscreen; its remembered frame stays.
    private func floatingWillClose(_ id: UUID) {
        guard fullscreen == .floating(id) else { return }
        Settings.log("exitFullscreen: the floating window closed")
        fullscreen = nil
        stripView.needsDisplay = true
    }

    func toggleVisible() {
        if isPanic { exitPanic(hidden: true); return }
        if isFullscreen { hide(); return }
        if main.isVisible { hide() } else { show() }
    }

    func show() {
        main.orderFrontRegardless()
        layoutStrip()
        updateInView()
        focusTerminal()
        Activity.card?.layout()
    }

    func showKeepingGhost() {
        main.orderFrontRegardless()
        layoutStrip()
        updateInView()
        focusTerminalUnlessGhost()
        Activity.card?.layout()
    }

    func hide() {
        endStartupAnimation()
        exitFullscreen()
        if hasKeyboard {
            giveKeyboardAway {
                main.orderOut(nil)
                floating.values.forEach { $0.releaseKey() }
            }
            // Floating windows still up switch to click-through, as when the game is clicked.
            ghostIfKeyboardLeft()
        } else {
            main.orderOut(nil)
        }
        updateInView()
        Activity.card?.layout()
    }

    func focusTerminal() {
        if !main.isVisible {
            main.orderFrontRegardless()
            updateInView()
        }
        if isGhost { setGhost(false) }
        main.makeKeyAndOrderFront(nil)
        if !main.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            main.makeKeyAndOrderFront(nil)
        }
        if let view = current?.focusView { main.makeFirstResponder(view) }
        Settings.log("focusTerminal: isKey=\(main.isKeyWindow) appActive=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        clearAttentionIfViewed()
        raiseFloating()
        // Last: `makeKeyAndOrderFront` put the window above the card, which shares its level and
        // is only re-ordered by its own layout.
        Activity.card?.layout()
    }

    func setGhost(_ ghost: Bool) {
        Settings.log("setGhost(\(ghost)) wasKey=\(main.isKeyWindow)")
        if ghost {
            endStartupAnimation()
            // First, so the window that goes click-through is the one back at its own frame.
            exitFullscreen()
        }
        isGhost = ghost
        main.ignoresMouseEvents = ghost
        applyAlpha()
        stripView.needsDisplay = true
        syncFocusReports()
        if ghost, hasKeyboard { releaseKeyboard() }
        // Last: `releaseKeyboard()` re-orders the window above the card; `layout()` fixes that.
        Activity.card?.layout()
    }

    func toggleGhost(followingCard: Bool = false) {
        guard !isPanic else { return }
        if followingCard, let id = Activity.card?.presentedTab, isGhost || current?.id != id {
            select(tabID: id)
            focusTerminal()
        } else if isGhost {
            focusTerminal()
        } else {
            setGhost(true)
        }
    }

    private var hasAttention: Bool { tabs.contains { $0.needsAttention } }
    private var lastAttentionBeep = Date.distantPast

    func isBeingViewed(_ tab: Tab) -> Bool {
        if let web = floating[tab.id] { return web.isKey && !isGhost }
        return tab === current && main.isKeyWindow && !isGhost
    }

    // Must never call `show()` or `focusTerminal()`: a hidden overlay comes back click-through
    // so the game keeps the keyboard.
    func requestAttention(_ tab: Tab) { requestAttention(tab, quietly: false) }

    private func requestAttention(_ tab: Tab, quietly: Bool) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        guard !isBeingViewed(tab) else {
            Settings.log("attention ignored, tab is being viewed: \(tab.title)")
            return
        }
        Settings.log("attention: \(tab.title) visible=\(main.isVisible) ghost=\(isGhost) panic=\(isPanic)"
                     + (quietly ? " quietly" : ""))
        let wasMarked = tab.needsAttention
        tab.needsAttention = true
        guard !quietly else { return }
        if settings.attentionSound, !wasMarked || Date().timeIntervalSince(lastAttentionBeep) > 2 {
            NSSound.beep()
            lastAttentionBeep = Date()
        }
        revealWithoutKeyboard()
    }

    // A hidden overlay comes back in click-through, so the game keeps the keyboard; while a
    // floating page of ours has it, the mode is left alone rather than taking it from there.
    private func revealWithoutKeyboard() {
        guard !main.isVisible, !isPanic else { return }
        main.orderFrontRegardless()
        layoutStrip()
        // The user did not ask for the window: a video it shows stays paused until played.
        updateInView(resuming: false)
        if !hasKeyboard { setGhost(true) }
        Activity.card?.layout()
    }

    func clearAttentionIfViewed() {
        guard let tab = current, tab.needsAttention, isBeingViewed(tab) else { return }
        Settings.log("attention cleared: \(tab.title)")
        tab.needsAttention = false
        Activity.card?.dismiss(tab: tab.id)
    }

    private func attentionDidChange() {
        applyAlpha()
        stripView.needsDisplay = true
    }

    private func activityDidChange(_ event: ActivityEvent) {
        stripView.needsDisplay = true
        switch event {
        case .finished(let id, _), .asks(let id, _):
            guard let tab = terminals.first(where: { $0.id == id }) else { return }
            if case .finished = event, ActivityAnswer.justRefused(id) {
                Settings.log("activity: \(tab.title) stopped after a refusal, no card")
                return
            }
            requestAttention(tab, quietly: !settings.activityCards)
            Activity.card?.present(event, tab: tab)
        case .answered(let id), .gone(let id):
            ActivityAnswer.forget(tab: id)
            Activity.card?.dismiss(tab: id)
        case .changed(let id):
            guard let tab = terminals.first(where: { $0.id == id }) else { return }
            Activity.card?.refresh(tab)
        case .notified:
            break
        }
    }

    // With cards off, an agent SlyTerm reads only marks its tab, whatever it rings or sends. Codex
    // rings when told the terminal lost focus, which the game taking the keyboard now does.
    private func ringsQuietly(_ tab: TerminalTab) -> Bool {
        !settings.activityCards && tab.activity != nil
    }

    // An agent SlyTerm reads already gets its card from the monitor, with more in it.
    private func notificationArrived(in tab: TerminalTab, title: String?, body: String) {
        Settings.log("notification: \(tab.title)" + (title.map { " · \($0)" } ?? ""))
        requestAttention(tab, quietly: ringsQuietly(tab))
        guard settings.activityCards, tab.activity == nil else { return }
        Activity.card?.present(.notified(tab: tab.id, title: title, body: body), tab: tab)
    }

    private func firstResponderChanged() {
        for tab in terminals { tab.firstResponderChanged(main.firstResponder === tab.view) }
        syncFocusReports()
    }

    // SwiftTerm tells the program it has focus whenever its view is first responder, the game's
    // turn at the keyboard included. Async: key status and first responder move in several steps.
    private func syncFocusReports() {
        guard !focusSyncQueued else { return }
        focusSyncQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusSyncQueued = false
            for tab in self.terminals { tab.reportFocus(self.isBeingViewed(tab)) }
        }
    }

    func releaseKeyboard() {
        giveKeyboardAway {
            if main.isKeyWindow {
                main.orderOut(nil)
                main.orderFrontRegardless()
            }
            floating.values.forEach { $0.releaseKey() }
        }
        Activity.card?.layout()
        Settings.log("releaseKeyboard: isKey=\(hasKeyboard) appActive=\(NSApp.isActive) handedTo=\(lastOtherApp?.localizedName ?? "none")")
    }

    // Ordering a key window out lets AppKit hand key to another of ours, as if the user typed
    // there: our panels refuse it meanwhile, and the app that was in front is asked back first.
    private func giveKeyboardAway(_ orderOut: () -> Void) {
        isReleasingKeyboard = true
        if NSApp.isActive, let app = lastOtherApp, !app.isTerminated {
            if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: []) }
        }
        let panels = [main] + floating.values.flatMap { [$0.panel, $0.bar] as [OverlayPanel] }
        panels.forEach { $0.refusesKey = true }
        orderOut()
        panels.forEach { $0.refusesKey = false }
        isReleasingKeyboard = false
    }

    private var handedKeyNote: String? {
        if ignoresHandedKeyStatus { return "handed back by a closing window" }
        return isReleasingKeyboard ? "handed on while giving the keyboard away" : nil
    }

    @objc private func mainDidBecomeKey() {
        let handed = handedKeyNote
        Settings.log("didBecomeKey ghost=\(isGhost)" + (handed.map { ", \($0): ignored" } ?? ""))
        syncFocusReports()
        guard handed == nil else { return }
        // AppKit hands key status back when a dialog closes; in click-through, take it as typing.
        if isGhost, !isPanic { setGhost(false) }
        clearAttentionIfViewed()
        if fullscreen == .main { raiseFloating() }
    }

    @objc private func mainDidResignKey() {
        Settings.log("didResignKey autoGhost=\(settings.autoGhost) releasing=\(isReleasingKeyboard) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        syncFocusReports()
        ghostIfKeyboardLeft()
    }

    // Async: key moving between our windows resigns one before the other becomes key.
    private func ghostIfKeyboardLeft() {
        guard settings.autoGhost, !isReleasingKeyboard, !isPanic else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shown = self.main.isVisible || self.floating.values.contains { $0.panel.isVisible }
            guard shown, !self.hasKeyboard, !self.isGhost, !self.isPanic else { return }
            self.setGhost(true)
        }
    }

    private func floatingKeyChanged(_ id: UUID) {
        guard let web = floating[id], web.isKey else {
            Settings.log("floating web: resigned key")
            ghostIfKeyboardLeft()
            return
        }
        let handed = handedKeyNote
        Settings.log("floating web: became key ghost=\(isGhost)" + (handed.map { ", \($0): ignored" } ?? ""))
        // Becoming key ordered the window above the card, which shares its level.
        Activity.card?.layout()
        guard handed == nil else { return }
        if isGhost, !isPanic { setGhost(false) }
        if fullscreen == .floating(id) { raiseFloating() }
        if let tab = webTabs.first(where: { $0.id == id }), tab.needsAttention, isBeingViewed(tab) {
            tab.needsAttention = false
        }
    }

    @discardableResult
    func newTab(directory: String? = nil, runStartupCommand: Bool = true) -> TerminalTab {
        let i = TerminalTab.insets
        let frame = NSRect(x: i.left, y: i.bottom,
                           width: container.bounds.width - i.left - i.right,
                           height: container.bounds.height - i.top - i.bottom)
        let tab = TerminalTab(frame: frame, directory: directory ?? directoryForNewTab())
        tab.onTitleChange = { [weak self] in self?.stripView.needsDisplay = true }
        tab.onDirectoryChange = { [weak self] in
            guard let self else { return }
            self.stripView.needsDisplay = true
            self.saveSession()
        }
        tab.onAttentionChange = { [weak self] in self?.attentionDidChange() }
        tab.onActivityChange = { [weak self] in self?.stripView.needsDisplay = true }
        tab.onBell = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.requestAttention(tab, quietly: self.ringsQuietly(tab))
        }
        tab.onNotification = { [weak self, weak tab] title, body in
            guard let self, let tab else { return }
            self.notificationArrived(in: tab, title: title, body: body)
        }
        tab.onExit = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.close(tab)
        }
        terminals.append(tab)
        container.addSubview(tab.contentView)
        select(terminals.count - 1)
        tab.start(runStartupCommand: runStartupCommand)
        saveSession()
        return tab
    }

    @discardableResult
    func newTab(directory: String, typing command: String?, run: Bool = true, note: String? = nil) -> TerminalTab {
        let tab = newTab(directory: directory, runStartupCommand: false)
        if let note { tab.paintNote(note) }
        if let command { tab.type(command, enter: run) }
        return tab
    }

    @discardableResult
    func select(tabID id: UUID) -> Bool {
        if let index = terminals.firstIndex(where: { $0.id == id }) { select(index); return true }
        if let tab = webTabs.first(where: { $0.id == id }) { selectWeb(tab); return true }
        return false
    }

    private func directoryForNewTab() -> String {
        if settings.newTabInheritsDirectory, terminals.indices.contains(selectedIndex) {
            return terminals[selectedIndex].currentDirectory
        }
        return settings.workingDirectory
    }

    func select(_ index: Int) {
        guard terminals.indices.contains(index) else { return }
        selectedIndex = index
        frontWeb = nil
        showSelectedTab()
    }

    // A floating tab is put back first: selecting a web tab means showing it in the main window.
    // During panic nothing of the web shows: a docked tab asked for comes in front when it ends.
    func selectWeb(_ tab: GuideTab) {
        guard webTabs.contains(where: { $0 === tab }) else { return }
        if isPanic {
            if tab.place == .docked { panicRestore?.arrived = tab.id }
            return
        }
        guard tab.place == .docked else { dock(tab); return }
        frontWeb = tab
        lastWeb = tab
        showSelectedTab()
    }

    private func selectCurrentTerminal() {
        guard !terminals.isEmpty else { return }
        select(min(selectedIndex, terminals.count - 1))
    }

    private func showTerminal() {
        if terminals.isEmpty { newTab() } else { selectCurrentTerminal() }
    }

    private func showSelectedTab() {
        guard let tab = current else { return }
        endStartupAnimation()
        for other in tabs { other.contentView.isHidden = other !== tab }
        main.makeFirstResponder(tab.focusView)
        stripView.needsDisplay = true
        tab.refresh()
        updateInView()
        applyAlpha()
        saveSession()
        clearAttentionIfViewed()
        syncFocusReports()
    }

    // A tab sent elsewhere is not replaced by a fresh `claude` from the startup command.
    func close(_ tab: Tab, replacementRunsStartup: Bool = true) {
        if let web = tab as? GuideTab { closeWebTab(web); return }
        guard let index = terminals.firstIndex(where: { $0.id == tab.id }) else { return }
        // Read before terminate(): a killed shell has no cwd left.
        let replacement = terminals.count == 1 ? (tab as? TerminalTab)?.currentDirectory : nil
        let webInFront = frontWeb
        terminals.remove(at: index)
        tab.terminate()
        tab.contentView.removeFromSuperview()
        // The monitor never reports a removed tab as gone, so its card must be dismissed here.
        Activity.card?.dismiss(tab: tab.id)
        ActivityAnswer.forget(tab: tab.id)
        attentionDidChange()
        if terminals.isEmpty {
            newTab(directory: replacement, runStartupCommand: replacementRunsStartup)
        } else if webInFront != nil {
            selectedIndex = min(selectedIndex > index ? selectedIndex - 1 : selectedIndex, terminals.count - 1)
        } else {
            select(min(index, terminals.count - 1))
        }
        if let webInFront { selectWeb(webInFront) }
        saveSession()
    }

    func closeCurrent() {
        if let tab = current { close(tab) }
    }

    func nextTab() { cycle(by: 1) }
    func prevTab() { cycle(by: -1) }

    private func cycle(by step: Int) {
        if let frontWeb {
            let docked = webTabs.filter { $0.place == .docked }
            guard let from = docked.firstIndex(where: { $0 === frontWeb }) else { return }
            selectWeb(docked[(from + step + docked.count) % docked.count])
            return
        }
        guard !terminals.isEmpty else { return }
        let from = min(selectedIndex, terminals.count - 1)
        select((from + step + terminals.count) % terminals.count)
    }

    func terminateAll() {
        // Before the shells, or a late scan writes activity onto tabs with no process.
        activityMonitor.stop()
        floating.values.forEach { $0.close() }
        floating.removeAll()
        tabs.forEach { $0.terminate() }
    }

    // The lookup's pages. A floating target just loads; a docked one comes to the front.
    func showGuide(_ url: URL? = nil) {
        guard let url else { showLastWeb(); revealWithoutKeyboard(); return }
        // Decided first: the pause replaces play / pause's list, which is what marks a paused show.
        let reuse = lookupTab.flatMap { isShow($0) ? nil : $0 }
        pauseVideosForGuide()
        if let tab = reuse {
            tab.load(url)
            guard tab.place == .docked else { return }
            selectWeb(tab)
        } else {
            let tab = addWebTab(url)
            tab.openedByLookup = true
            lookupTabID = tab.id
            selectWeb(tab)
        }
        revealWithoutKeyboard()
    }

    // The web tab keys do nothing during panic.
    func toggleGuide() {
        guard !isPanic else { return }
        if frontWeb != nil { selectCurrentTerminal() } else { showLastWeb() }
    }

    func newWebTab() {
        guard !isPanic else { return }
        let tab = addWebTab(nil)
        selectWeb(tab)
        focusTerminal()
        tab.focusAddress()
    }

    func reopenClosedWebTab() {
        guard !isPanic else { return }
        guard let url = closedWebURLs.popLast() else { NSSound.beep(); return }
        selectWeb(addWebTab(url))
        focusTerminal()
    }

    private var lookupTab: GuideTab? { webTabs.first { $0.id == lookupTabID } }

    private func isShow(_ tab: GuideTab) -> Bool {
        tab.media.isPlaying || playPaused.contains(tab.id) || panicPaused.contains(tab.id)
            || outOfViewPaused.contains(tab.id)
    }

    private func showLastWeb() {
        if let lastWeb, lastWeb.place == .docked, webTabs.contains(where: { $0 === lastWeb }) {
            selectWeb(lastWeb)
        } else if let tab = webTabs.last(where: { $0.place == .docked }) {
            selectWeb(tab)
        } else {
            openHome()
        }
    }

    private func openHome() {
        let tab = addWebTab(GuideContent.home)
        tab.openedByLookup = true
        if lookupTab == nil { lookupTabID = tab.id }
        selectWeb(tab)
    }

    private func addWebTab(_ url: URL?) -> GuideTab {
        let tab = GuideTab(frame: container.bounds, url: url)
        tab.host = self
        tab.onTitleChange = { [weak self] in self?.stripView.needsDisplay = true }
        tab.onAttentionChange = { [weak self] in self?.attentionDidChange() }
        tab.contentView.isHidden = true
        // exitPanic resumes every web tab, so one opened during panic starts suspended too.
        if isPanic { tab.setMediaSuspended(true) }
        webTabs.append(tab)
        container.addSubview(tab.contentView)
        stripView.needsDisplay = true
        return tab
    }

    private func playsVideo(_ tab: GuideTab) -> Bool { tab.media.isPlaying && tab.media.hasVideo }

    private func videoAlpha(_ tab: GuideTab) -> CGFloat? {
        playsVideo(tab) ? CGFloat(settings.videoOpacity) : nil
    }

    private func applyFloating() {
        let dim = CGFloat(settings.ghostOpacity), background = CGFloat(settings.opacity)
        for tab in webTabs {
            floating[tab.id]?.apply(ghost: isGhost, dim: dim, video: videoAlpha(tab), backgroundOpacity: background)
        }
    }

    // A lookup's guide pauses every video, floating ones too; play / pause plays them again.
    private func pauseVideosForGuide() {
        guard settings.autoPauseVideo else { return }
        // Panic holds them already: noted here, they end paused instead of playing on.
        if isPanic {
            playPaused = webTabs.filter { panicPaused.contains($0.id) && $0.media.hasVideo }.map(\.id)
            Settings.log("web: a guide during panic paused \(playPaused.count)")
            return
        }
        let playing = webTabs.filter(playsVideo)
        guard !playing.isEmpty else { return }
        playing.forEach { $0.setPlaying(false) }
        playPaused = playing.map(\.id)
        Settings.log("web: a guide paused \(playing.count)")
    }

    // A docked video leaving the screen pauses, and plays again once back in front. Panic suspends
    // media on its own, and a tab popping out takes its video along.
    private func updateInView(resuming: Bool = true) {
        let now = main.isVisible && !isPanic ? frontWeb : nil
        guard now?.id != inViewID else { return }
        if settings.autoPauseVideo, !isPanic, let old = webTabs.first(where: { $0.id == inViewID }),
           old.place == .docked, playsVideo(old) {
            old.setPlaying(false)
            outOfViewPaused.insert(old.id)
            Settings.log("web: paused out of view \(old.title)")
        }
        inViewID = now?.id
        // No check that it is paused: the pause may not be reported yet, and play follows it in order.
        guard let now, resuming, outOfViewPaused.remove(now.id) != nil else { return }
        now.setPlaying(true)
        Settings.log("web: playing again in view \(now.title)")
    }

    // Held only while the page is filled: the video's shape then decides the window's.
    private func syncAspect(of tab: GuideTab) {
        guard let web = floating[tab.id] else { return }
        let aspect = tab.media.isFilled ? FloatingWeb.sane(tab.media.aspect) : nil
        guard aspect != web.aspect else { return }
        if aspect != nil { web.isVideo = true }
        web.setAspect(aspect)
    }

    @MainActor
    func playPause() {
        let point = main.isVisible ? NSPoint(x: strip.frame.maxX, y: strip.frame.maxY) : NSEvent.mouseLocation
        func names(_ tabs: [GuideTab]) -> String {
            let first = tabs.first?.title ?? ""
            return tabs.count > 1 ? "\(first) and \(tabs.count - 1) more" : first
        }
        // Panic holds every web tab; leaving it is what lets them play.
        guard !isPanic else {
            Toast.shared.show("Panic mode is on", near: point, tint: .systemOrange)
            return
        }
        let playing = webTabs.filter { $0.media.isPlaying }
        if !playing.isEmpty {
            playing.forEach { $0.setPlaying(false) }
            playPaused = playing.map(\.id)
            outOfViewPaused.subtract(playPaused)
            Settings.log("play/pause: paused \(playing.count)")
            Toast.shared.show("Paused · \(names(playing))", near: point)
            return
        }
        var again = webTabs.filter { playPaused.contains($0.id) }
        if again.isEmpty, let last = webTabs.first(where: { $0.id == lastPlayedID }) { again = [last] }
        playPaused = []
        Settings.log("play/pause: playing \(again.count)")
        guard !again.isEmpty else {
            Toast.shared.show("Nothing is playing", near: point, tint: .systemOrange)
            return
        }
        again.forEach { $0.setPlaying(true) }
        outOfViewPaused.subtract(again.map(\.id))
        Toast.shared.show("Playing · \(names(again))", near: point)
    }

    func saveSession() {
        guard !isRestoringSession, settings.restoreSession, !terminals.isEmpty else { return }
        settings.savedSession = (terminals.map { $0.knownDirectory }, min(selectedIndex, terminals.count - 1))
    }

    func refreshTabs() {
        tabs.forEach { $0.refresh() }
    }

    private func startDirectoryPoll() {
        directoryPoll?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.main.isVisible else { return }
            self.tabs.forEach { $0.refresh() }
        }
        timer.tolerance = 0.5
        directoryPoll = timer
    }

    private func restoreSessionOrOpenFirstTab() {
        guard settings.restoreSession, let saved = settings.savedSession, !saved.directories.isEmpty else {
            newTab()
            return
        }
        Settings.log("restoring session: \(saved.directories.count) tabs, selected \(saved.selected)")
        // Scoped so the flag is cleared before select(), whose saveSession() must not be skipped.
        do {
            isRestoringSession = true
            defer { isRestoringSession = false }
            for dir in saved.directories {
                newTab(directory: TerminalTab.isUsableDirectory(dir) ? dir : settings.workingDirectory,
                       runStartupCommand: false)
            }
        }
        select(min(max(0, saved.selected), terminals.count - 1))
        (current as? TerminalTab)?.sendStartupCommand()
    }

    func playStartupAnimation() {
        guard settings.startupAnimation, !isGhost, let tab = current as? TerminalTab else { return }
        let overlay = StartupAnimationView(frame: container.bounds,
                                           foreground: tab.view.nativeForegroundColor,
                                           revealing: tab.view)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        startupAnimation = overlay
        overlay.onFinished = { [weak self] in self?.startupAnimation = nil }
    }

    private func endStartupAnimation() { startupAnimation?.finish() }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Shift/Option+Return: Claude Code, Codex, pi and omp read ESC CR as a newline. Not under
        // the kitty keyboard protocol, where SwiftTerm encodes the modifiers itself.
        if event.keyCode == 36, !flags.contains(.command), !flags.intersection([.shift, .option]).isEmpty,
           let view = (current as? TerminalTab)?.view, view.getTerminal().keyboardEnhancementFlags.isEmpty {
            view.send(txt: "\u{1b}\r")
            return true
        }
        if event.keyCode == 48, flags.contains(.control) {          // Tab
            flags.contains(.shift) ? prevTab() : nextTab()
            return true
        }
        guard flags.contains(.command) else { return false }
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let web = current as? GuideTab
        if event.keyCode == 36 {                                     // Return
            // In the address field ⌘Return opens a new web tab, so the field is asked first.
            if let web, web.isEditingText, web.handleCommandKey(event, shift: shift) { return true }
            toggleFullscreen()
            return true
        }
        if option, event.keyCode == 123 { prevTab(); return true }  // Left arrow
        if option, event.keyCode == 124 { nextTab(); return true }  // Right arrow
        if option {
            guard !shift, let n = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(n) else {
                return false
            }
            stripSelectWeb(n - 1)
            return true
        }
        if let web, web.handleCommandKey(event, shift: shift) { return true }

        let terminal = current as? TerminalTab
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "t" where !shift: if web != nil { newWebTab() } else { newTab() }; return true
        // A web tab follows browsers, where ⌘⇧T brings back the tab just closed.
        case "t" where shift:
            if web != nil { reopenClosedWebTab() } else { TeleportPicker.shared.toggle() }
            return true
        case "l" where !shift: newWebTab(); return true
        case "w" where !shift: closeCurrent(); return true
        case "c" where !shift:
            if let view = terminal?.view, view.selection?.active == true { view.copy(self) }
            return true
        case "v" where !shift: terminal?.view.paste(self); return true
        case "a" where !shift: terminal?.view.selectAll(); return true
        case "g" where !shift: toggleGuide(); return true
        case "=", "+": settings.fontSize += 1; return true
        case "-": settings.fontSize -= 1; return true
        case "0" where !shift: settings.fontSize = 13; return true
        case "h" where !shift: hide(); return true
        case "q" where !shift: NSApp.terminate(nil); return true
        case "," where !shift: (NSApp.delegate as? AppDelegate)?.openSettings(); return true
        case "]" where shift: nextTab(); return true
        case "[" where shift: prevTab(); return true
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let n = Int(key) { select(n - 1) }
            return true
        default:
            return false
        }
    }

    private func handleFloatingKey(_ event: NSEvent, tab: GuideTab) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        let shift = flags.contains(.shift)
        if flags.contains(.option) {
            guard !shift, let n = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(n) else {
                return false
            }
            stripSelectWeb(n - 1)
            return true
        }
        if event.keyCode == 36 {                                     // Return
            if tab.isEditingText, tab.handleCommandKey(event, shift: shift) { return true }
            toggleFullscreen()
            return true
        }
        if tab.handleCommandKey(event, shift: shift) { return true }
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "t" where !shift: newWebTab(); return true
        case "t" where shift: reopenClosedWebTab(); return true
        case "w" where !shift: closeWebTab(tab); return true
        case "q" where !shift: NSApp.terminate(nil); return true
        case "," where !shift: (NSApp.delegate as? AppDelegate)?.openSettings(); return true
        default: return false
        }
    }

    @objc private func settingsChanged(_ note: Notification) {
        guard let key = note.object as? String else { return }
        switch key {
        case "fontSize", "fontName":
            terminals.forEach { $0.view.font = settings.font }
        case "guideZoom":
            webTabs.forEach { $0.applyZoom() }
        case "opacity":
            applyBackground()
            applyFloating()
        case "ghostOpacity", "videoOpacity":
            applyAlpha()
        case "windowLevel":
            applyWindowLevel()
        case "stripPosition":
            updateStripEdge()
        case "optionAsMeta":
            terminals.forEach { $0.view.optionAsMetaKey = settings.optionAsMeta }
        default:
            break
        }
    }

    // A video playing in front has its own level in either mode; the strip keeps the usual one.
    private func applyAlpha() {
        let dim = CGFloat(settings.ghostOpacity)
        main.alphaValue = fullscreen == .main ? 1 : frontWeb.flatMap(videoAlpha) ?? (isGhost ? dim : 1)
        strip.alphaValue = isGhost && !hasAttention ? dim : 1
        applyFloating()
    }

    private func applyBackground() {
        let alpha = fillsScreen ? 1 : CGFloat(settings.opacity)
        container.layer?.backgroundColor = TerminalTab.backgroundColor.withAlphaComponent(alpha).cgColor
    }

    func applyWindowLevel() {
        main.level = settings.levelValue
        strip.level = settings.levelValue
        floating.values.forEach { $0.setLevel(settings.levelValue) }
    }

    var stripTabTitles: [String] { terminals.map { $0.title } }
    var stripSelectedIndex: Int? { frontWeb == nil ? selectedIndex : nil }
    var stripWebItems: [TabStripWebItem] {
        webTabs.map { tab in
            let symbol = tab.openedByLookup ? "book" : tab.media.hasVideo ? "play.rectangle" : "globe"
            return TabStripWebItem(title: tab.title, icon: tab.favicon, symbol: symbol,
                                   isSelected: tab === frontWeb, isFloating: floating[tab.id] != nil,
                                   isPlaying: tab.media.isPlaying)
        }
    }
    var stripIsGhost: Bool { isGhost }
    var stripIsPanic: Bool { isPanic }
    var stripIsFullscreen: Bool { isFullscreen }
    var stripHint: (text: String, color: NSColor)? {
        if hasAttention {
            if isGhost {
                let key = hintKey(settings.hotkeyGhost).map { "\($0) or " } ?? ""
                return ("needs you: \(key)the eye button", .systemYellow)
            }
            return ("needs you: click the tab", .systemYellow)
        }
        if let activity = selectedTerminal?.activity {
            if activity.isWorking {
                let elapsed = activity.since.map { " · \(activityElapsed(since: $0))" } ?? ""
                return ("\(activity.doing?.label ?? "working")\(elapsed)", NSColor(calibratedWhite: 1, alpha: 0.55))
            }
            if activity.isWaiting { return ("waiting for you", .systemOrange) }
        }
        return nil
    }
    private func hintKey(_ combo: String) -> String? {
        let pretty = KeyCombo.pretty(combo)
        return pretty.isEmpty ? nil : pretty
    }
    private func focusTerminalUnlessGhost() {
        guard !isGhost else { return }
        focusTerminal()
    }

    func stripTabNeedsAttention(_ index: Int) -> Bool { terminals.indices.contains(index) && terminals[index].needsAttention }

    func stripTabMark(_ index: Int) -> TabStripMark {
        guard terminals.indices.contains(index) else { return .none }
        let tab = terminals[index]
        if let activity = tab.activity {
            if activity.isWaiting { return .waiting }
            if activity.isWorking { return .working }
        }
        return tab.needsAttention ? .attention : .none
    }

    func stripTabToolTip(_ index: Int) -> String? {
        guard terminals.indices.contains(index), let activity = terminals[index].activity else { return nil }
        let name = activity.agent.name
        switch activity.status {
        case .working:
            let since = activity.since.map { " for \(activityElapsed(since: $0))" } ?? ""
            let doing = activity.doing.map { " · \($0.label)" } ?? ""
            return "\(name) is working\(since)\(doing)"
        case .waiting:
            let what: String?
            switch activity.request {
            case .permission(_, let summary, _): what = summary
            case .question(let text, _): what = text
            case .unknown, nil: what = nil
            }
            return "\(name) is waiting for you" + (what.map { " · \($0)" } ?? "")
        case .idle:
            guard let since = activity.since, let line = firstLine(of: activity.lastMessage) else {
                return "\(name) is idle"
            }
            return "\(name) finished \(activityElapsed(since: since)) ago · \(line)"
        case .unknown:
            return nil
        }
    }

    private func firstLine(of message: String?, limit: Int = 80) -> String? {
        guard let line = message?.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        guard line.count > limit else { return line }
        return line.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    func stripTabMenu(_ index: Int) -> NSMenu? {
        guard terminals.indices.contains(index) else { return nil }
        let tab = terminals[index]
        let app = SendBackTerminal.current.name
        let menu = NSMenu()
        menu.autoenablesItems = false
        var items = [("Send Back to \(app)", #selector(sendTabBack(_:)))]
        if let activity = tab.activity, !activity.isBackground,
           activity.agent.copyCommand(id: activity.sessionID) != nil {
            items.append(("Copy to \(app)", #selector(copyTabBack(_:))))
        }
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = tab.id
            menu.addItem(item)
        }
        return menu
    }

    @objc private func sendTabBack(_ sender: NSMenuItem) {
        guard let tab = terminals.first(where: { $0.id == sender.representedObject as? UUID }) else { return }
        TeleportEngine.shared.sendBack(tab)
    }

    @objc private func copyTabBack(_ sender: NSMenuItem) {
        guard let tab = terminals.first(where: { $0.id == sender.representedObject as? UUID }) else { return }
        TeleportEngine.shared.sendBack(tab, copy: true)
    }

    func stripSelectTab(_ index: Int) { select(index); focusTerminalUnlessGhost() }
    func stripCloseTab(_ index: Int) { if terminals.indices.contains(index) { close(terminals[index]) } }
    func stripSelectWeb(_ index: Int) {
        guard !isPanic, webTabs.indices.contains(index) else { return }
        selectWeb(webTabs[index])
        focusTerminalUnlessGhost()
    }
    func stripCloseWeb(_ index: Int) { if webTabs.indices.contains(index) { closeWebTab(webTabs[index]) } }
    func stripOpenWeb() {
        guard !isPanic else { return }
        openHome()
        focusTerminalUnlessGhost()
    }
    func stripNewTab() { newTab(); focusTerminalUnlessGhost() }
    func stripToggleGhost() { toggleGhost() }
    // The strip belongs to the SlyTerm window, whichever window has the keyboard.
    func stripToggleFullscreen() {
        guard !isPanic else { return }
        if isFullscreen { exitFullscreen() } else { enterFullscreen(.main) }
    }
    func stripHide() { hide() }
    func stripClicked() { focusTerminalUnlessGhost() }
    func stripDragged(to stripOrigin: NSPoint) {
        guard !fillsScreen else { return }
        let band = NSRect(origin: stripOrigin, size: strip.frame.size)
        let edge = OverlayController.edge(forStripAt: band, window: main.frame, setting: settings.stripPosition)
        if edge != stripEdge { setStripEdge(edge) }
        let height = main.frame.height
        main.setFrameOrigin(NSPoint(x: band.minX, y: edge == .bottom ? band.minY : band.maxY - height))
        // A child window moves by its parent's delta, which is wrong after a flip: re-place it.
        layoutStrip()
    }
    func stripDragEnded() {
        if !fillsScreen { settings.savedFrame = main.frame }
    }
}

extension OverlayController: ActivityHost {
    var selectedTerminal: TerminalTab? { current as? TerminalTab }
    var stripScreenFrame: NSRect { strip.frame }
    var isOverlayVisible: Bool { main.isVisible }

    func clearAttention(_ tab: Tab) {
        guard tab.needsAttention else { return }
        Settings.log("attention cleared, answered: \(tab.title)")
        tab.needsAttention = false
    }
}

extension OverlayController: WebTabHost {
    @discardableResult
    func openWebTab(_ url: URL?, select: Bool, focusAddress: Bool) -> GuideTab {
        let tab = addWebTab(url)
        if select {
            selectWeb(tab)
            revealWithoutKeyboard()
        }
        if focusAddress { tab.focusAddress() }
        return tab
    }

    func float(_ tab: GuideTab) {
        guard webTabs.contains(where: { $0 === tab }), floating[tab.id] == nil else { return }
        let video = playsVideo(tab)
        // A paused video does not shape the window; one that plays or fills the page does.
        let aspect = video || tab.media.isFilled ? tab.media.aspect : nil
        Settings.log("web: float \(tab.title) video=\(video) filled=\(tab.media.isFilled)")
        tab.detachChrome()
        let near = panicRestore?.frame ?? (fullscreen == .main ? fullscreenFrame : main.frame)
        let web = FloatingWeb(id: tab.id, bar: tab.toolbar, page: tab.pageView,
                              video: video || aspect != nil, aspect: aspect,
                              near: near,
                              avoiding: floating.values.map { $0.panel.frame })
        let id = tab.id
        web.keyHandler = { [weak self, weak tab] event in
            guard let self, let tab else { return false }
            return self.handleFloatingKey(event, tab: tab)
        }
        web.onKeyChange = { [weak self] in self?.floatingKeyChanged(id) }
        web.setLevel(settings.levelValue)
        floating[tab.id] = web
        tab.setPlace(.floating)
        syncAspect(of: tab)
        applyFloating()
        if video, !tab.media.isFilled {
            tab.setFill(true)
            filledByFloat.insert(tab.id)
        }
        if tab === frontWeb { showTerminal() }
        // Panic hides floating windows; this one shows when it ends, with the others.
        if !isPanic { web.show() }
        stripView.needsDisplay = true
        Activity.card?.layout()
    }

    func dock(_ tab: GuideTab) {
        guard let web = floating.removeValue(forKey: tab.id) else { return }
        floatingWillClose(tab.id)
        let hadKeyboard = web.isKey
        Settings.log("web: put back \(tab.title) key=\(hadKeyboard)")
        web.close()
        tab.reattachChrome()
        tab.setPlace(.docked)
        if filledByFloat.remove(tab.id) != nil, tab.media.isFilled { tab.setFill(false) }
        selectWeb(tab)
        // The keyboard was already ours: it follows the page rather than being dropped.
        if hadKeyboard, !isPanic {
            if !main.isVisible {
                main.orderFrontRegardless()
                layoutStrip()
            }
            main.makeKey()
            Activity.card?.layout()
        } else {
            revealWithoutKeyboard()
        }
        updateInView()
        stripView.needsDisplay = true
    }

    func closeWebTab(_ tab: GuideTab) {
        guard let index = webTabs.firstIndex(where: { $0 === tab }) else { return }
        Settings.log("web: close \(tab.title)")
        if let url = tab.displayURL {
            closedWebURLs.append(url)
            if closedWebURLs.count > 10 { closedWebURLs.removeFirst() }
        }
        floatingWillClose(tab.id)
        let hadKeyboard = floating[tab.id]?.isKey ?? false
        let keyToMain = hadKeyboard && main.isVisible && !isGhost
        if let web = floating.removeValue(forKey: tab.id) {
            if hadKeyboard, !keyToMain {
                giveKeyboardAway { web.close() }
                ghostIfKeyboardLeft()
            } else {
                web.close()
            }
        }
        webTabs.remove(at: index)
        playPaused.removeAll { $0 == tab.id }
        panicPaused.removeAll { $0 == tab.id }
        outOfViewPaused.remove(tab.id)
        filledByFloat.remove(tab.id)
        if lookupTabID == tab.id { lookupTabID = nil }
        if lastPlayedID == tab.id { lastPlayedID = nil }
        if lastWeb === tab { lastWeb = nil }
        tab.host = nil
        tab.terminate()
        tab.contentView.removeFromSuperview()
        attentionDidChange()
        if tab === frontWeb { showTerminal() }
        if keyToMain { main.makeKey() }
        stripView.needsDisplay = true
    }

    func webTabDidChange(_ tab: GuideTab) {
        guard webTabs.contains(where: { $0 === tab }) else { return }
        if tab.media.isPlaying {
            lastPlayedID = tab.id
            if tab.id == inViewID { outOfViewPaused.remove(tab.id) }
        }
        syncAspect(of: tab)
        applyAlpha()
        stripView.needsDisplay = true
    }
}
