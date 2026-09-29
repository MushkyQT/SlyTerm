import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var controller: OverlayController!
    private var statusItem: NSStatusItem!
    private var hotkeyOK: [String: Bool] = [:]
    private var pendingURLs: [URL] = []
    private var quitPending = false
    private var reopenOnQuit = false
    private var setupOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only asks whether the grant is there; nothing is captured.
        Lookup.captureGrantedAtLaunch = CGPreflightScreenCaptureAccess()
        Settings.shared.decideSetup()
        controller = OverlayController()
        TeleportEngine.shared.controller = controller
        Activity.card = ActivityCard.shared
        registerHotkeys()
        configureGesture()
        // Only here: the command-line modes share these defaults and must not migrate them.
        LookupStore.shared.migrate()
        Lookup.shared.warmUp()
        GuideContent.prepare()
        Lookup.shared.openGuide = { [weak self] url in self?.controller.showGuide(url) }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)), name: Settings.didChange, object: nil)
        buildStatusItem()
        Updater.shared.start()
        if Settings.shared.setupDone {
            controller.show()
            controller.playStartupAnimation()
        } else {
            // The overlay floats above normal windows, so it waits until the assistant closes.
            runSetupAssistant { [weak self] in
                // A hotkey, the menu or a URL may have shown it already.
                guard let self, !controller.isVisible else { return }
                controller.show()
                controller.playStartupAnimation()
            }
        }
        if !pendingURLs.isEmpty {
            RemoteControl.handle(pendingURLs, controller: controller)
            pendingURLs.removeAll()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if setupOpen { SetupAssistant.shared.keepForNextLaunch() }
        TrackpadTapDetector.shared.stop()
        // Refresh and save before terminateAll: a dead shell has no cwd, and the poll stops while
        // the overlay is hidden.
        controller.refreshTabs()
        controller.saveSession()
        controller.terminateAll()
        if reopenOnQuit { ScreenRecording.launchAfterExit() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let s = Settings.shared
        // A second ⌘Q while tabs are being sent back.
        guard !quitPending else { return .terminateCancel }
        guard s.confirmQuit, !isSystemInitiatedQuit else { return .terminateNow }
        let busy = controller.terminals.filter { $0.isRunningForegroundJob }.count
        if controller.terminals.count <= 1, busy == 0 { return .terminateNow }

        let front = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit SlyTerm?"
        var text = controller.terminals.count == 1 ? "1 tab is open" : "\(controller.terminals.count) tabs are open"
        switch busy {
        case 0: text += ", none are running a command."
        case 1: text += ", 1 is running a command."
        default: text += ", \(busy) are running a command."
        }
        if s.restoreSession { text += " Tabs and their folders come back at next launch." }
        let agents = controller.terminals.filter(TeleportEngine.sendsBackAgent)
        let names = agents.map { SendBackTerminal.destination(for: $0).name }
        let terminal = ListFormatter.localizedString(byJoining:
            names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
        if !agents.isEmpty {
            text += agents.count == 1 ? " Send Back and Quit resumes the agent in 1 tab in \(terminal)."
                : " Send Back and Quit resumes the agents in \(agents.count) tabs in \(terminal)."
            if agents.contains(where: { $0.activity?.isWorking == true || $0.activity?.isWaiting == true }) {
                text += " A turn under way is interrupted; what the agent has said so far is kept."
            }
            alert.addButton(withTitle: "Send Back and Quit")
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal(level: s.alertLevel)
        let sendBack = !agents.isEmpty && response == .alertFirstButtonReturn
        let quit = sendBack || response == (agents.isEmpty ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        let suppress = alert.suppressionButton?.state == .on
        guard sendBack else {
            if quit, suppress { s.confirmQuit = false }
            return quit ? .terminateNow : .terminateCancel
        }
        quitPending = true
        TeleportEngine.shared.sendBack(agents, copy: false, confirm: false,
                                       front: front) { [weak self] stayed in
            self?.quitPending = false
            guard let first = stayed.first else {
                // Only now: the dialog is the only place Send Back and Quit is offered.
                if suppress { s.confirmQuit = false }
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            self?.reopenOnQuit = false
            Settings.log("quit: \(stayed.count) tab(s) could not be sent back, not quitting")
            let lead = stayed.count == 1 ? "1 tab stayed" : "\(stayed.count) tabs stayed"
            MainActor.assumeIsolated {
                Toast.shared.show("\(lead): \(first.error.message)", near: NSEvent.mouseLocation,
                                  tint: .systemOrange, duration: 4)
            }
            NSApp.reply(toApplicationShouldTerminate: false)
        }
        return .terminateLater
    }

    // A modal alert during logout, restart or shutdown stalls it, and Cancel or its timeout
    // aborts the logout.
    private var isSystemInitiatedQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart,
                kAEShowShutdownDialog, kAEShutDown].contains(reason)
    }

    private func configureGesture() {
        let s = Settings.shared
        let detector = TrackpadTapDetector.shared
        detector.fingers = s.tapFingers
        detector.alignTolerance = Float(s.tapAlignment)
        detector.onTap = { [weak self] in self?.performGestureAction() }
        if s.tapGesture { detector.start() } else { detector.stop() }
    }

    private func performGestureAction() {
        // The assistant lets the player try the tap; hiding or covering the screen behind it would
        // lose the window they are reading.
        if setupOpen {
            SetupAssistant.shared.tapRecognised()
            Settings.log("tap gesture: held while the setup assistant is open")
            return
        }
        switch Settings.shared.tapGestureAction {
        case "toggle": controller.toggleVisible()
        case "panic": controller.togglePanic()
        case "fullscreen": controller.toggleFullscreen()
        default: controller.toggleGhost()
        }
    }

    @objc private func settingsChanged(_ note: Notification) {
        guard let key = note.object as? String else { return }
        if key.hasPrefix("tap") { configureGesture() }
        if key == "activityCards" {
            registerHotkeys()
            if !Settings.shared.activityCards { Activity.card?.dismiss(tab: nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller else { pendingURLs.append(contentsOf: urls); return }
        RemoteControl.handle(urls, controller: controller)
    }

    private func registerHotkeys() {
        HotKeyCenter.shared.unregisterAll()
        for action in HotkeyAction.allCases {
            guard !action.needsActivityCards || Settings.shared.activityCards else {
                hotkeyOK[action.rawValue] = true; continue
            }
            let combo = Settings.shared.hotkey(action)
            guard !combo.isEmpty else { hotkeyOK[action.rawValue] = true; continue }
            hotkeyOK[action.rawValue] = HotKeyCenter.shared.register(combo) { [weak self] in self?.perform(action) }
        }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .toggle: controller.toggleVisible()
        case .ghost: controller.toggleGhost(followingCard: true)
        case .panic: controller.togglePanic()
        case .fullscreen: controller.toggleFullscreen()
        // Carbon calls hotkey handlers on the main thread, which assumeIsolated relies on.
        case .quest:
            MainActor.assumeIsolated {
                if LookupPicker.shared.isVisible { LookupPicker.shared.acceptSuggested() } else { Lookup.shared.trigger() }
            }
        case .pick:
            MainActor.assumeIsolated {
                if LookupPicker.shared.isVisible { LookupPicker.shared.hide() } else { Lookup.shared.pick() }
            }
        case .allow: MainActor.assumeIsolated { ActivityAnswer.perform(.allow) }
        case .refuse: MainActor.assumeIsolated { ActivityAnswer.perform(.refuse) }
        case .playPause: MainActor.assumeIsolated { controller.playPause() }
        }
    }

    func openSettings(tab: SettingsTab? = nil) {
        let window = SettingsWindowController.shared
        // A registered Carbon hotkey never reaches the app as a keystroke, so it could not be
        // re-recorded: unregister all while a field is recording.
        window.onBeginRecording = {
            HotKeyCenter.shared.unregisterAll()
            Settings.log("recording a shortcut: hotkeys paused")
        }
        window.onEndRecording = { [weak self] in
            self?.registerHotkeys()
            Settings.log("shortcut recorded: hotkeys registered again")
        }
        window.isRefused = { [weak self] action in self?.hotkeyOK[action.rawValue] == false }
        window.show(tab: tab, level: Settings.shared.dialogLevel)
    }

    func reopen() {
        guard ScreenRecording.canReopen else { return }
        reopenOnQuit = true
        NSApp.terminate(nil)
        // Still running: the quit was cancelled, or it waits on Send Back and Quit.
        if !quitPending { reopenOnQuit = false }
    }

    func runSetupAssistant(then: (() -> Void)? = nil) {
        let assistant = SetupAssistant.shared
        // Open already: keep its onClose, which may still owe the first launch its overlay.
        guard !assistant.isVisible else { assistant.show(level: Settings.shared.dialogLevel); return }
        assistant.onBeginRecording = {
            HotKeyCenter.shared.unregisterAll()
            Settings.log("recording a shortcut: hotkeys paused")
        }
        assistant.onEndRecording = { [weak self] in self?.registerHotkeys() }
        assistant.onClose = { [weak self] in
            self?.setupOpen = false
            Settings.shared.setupDone = true
            self?.registerHotkeys()
            then?()
        }
        setupOpen = true
        assistant.show(level: Settings.shared.dialogLevel)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(named: "StatusItemIcon")
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.setAccessibilityLabel("SlyTerm")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        if let version = Updater.shared.pendingVersion {
            menu.addItem(item("Update to SlyTerm \(version)…", #selector(checkForUpdates)))
            menu.addItem(.separator())
        }
        menu.addItem(item(controller.isVisible ? "Hide Terminal" : "Show Terminal", #selector(toggleVisible), hotkey: .toggle))
        menu.addItem(item("New Tab", #selector(newTab), key: "t", modifiers: .command))
        menu.addItem(item("Bring In a Session…", #selector(bringIn), key: "t", modifiers: [.command, .shift]))
        let back = controller.selectedTerminal.map(SendBackTerminal.destination) ?? .current
        let sendBack = item("Send Tab Back to \(back.name)", #selector(sendTabBack))
        sendBack.isEnabled = controller.selectedTerminal != nil
        menu.addItem(sendBack)
        menu.addItem(.separator())

        let ghost = item("Click-Through", #selector(toggleGhost), hotkey: .ghost)
        ghost.state = controller.isGhost ? .on : .off
        menu.addItem(ghost)
        let panic = item("Panic Mode", #selector(togglePanic), hotkey: .panic)
        panic.state = controller.isPanic ? .on : .off
        menu.addItem(panic)
        let fullscreen = item("Fullscreen", #selector(toggleFullscreen), hotkey: .fullscreen)
        fullscreen.state = controller.isFullscreen ? .on : .off
        menu.addItem(fullscreen)
        menu.addItem(item("Look Up Under Pointer", #selector(lookUp), hotkey: .quest))
        menu.addItem(item("Pick Text Near Pointer…", #selector(pickText), hotkey: .pick))
        let games = NSMenuItem(title: "Lookup Game", action: nil, keyEquivalent: "")
        games.submenu = lookupGamesMenu()
        menu.addItem(games)
        menu.addItem(item("New Web Tab", #selector(newWebTab), key: "l", modifiers: .command))
        menu.addItem(item("Play / Pause", #selector(playPause), hotkey: .playPause))
        menu.addItem(.separator())

        let opacity = NSMenu()
        opacity.addItem(.sectionHeader(title: "Terminal"))
        for value in stride(from: 40, through: 100, by: 10) {
            opacity.addItem(percentItem(value, of: s.opacity, #selector(setOpacity(_:))))
        }
        opacity.addItem(.separator())
        opacity.addItem(.sectionHeader(title: "Click-Through"))
        for value in stride(from: 30, through: 100, by: 10) {
            opacity.addItem(percentItem(value, of: s.ghostOpacity, #selector(setGhostOpacity(_:))))
        }
        opacity.addItem(.separator())
        opacity.addItem(.sectionHeader(title: "Playing Video"))
        for value in [40, 50, 60, 70, 80, 85, 90, 100] {
            opacity.addItem(percentItem(value, of: s.videoOpacity, #selector(setVideoOpacity(_:))))
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacity
        menu.addItem(opacityItem)
        menu.addItem(.separator())

        menu.addItem(item("Shortcuts…", #selector(showShortcuts)))
        menu.addItem(item("Help", #selector(openHelp)))
        menu.addItem(item("Settings…", #selector(showSettings), key: ",", modifiers: .command))
        menu.addItem(item("Reset Window Position", #selector(resetPosition)))
        menu.addItem(item("About SlyTerm", #selector(showAbout)))
        if Updater.shared.isEnabled {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit SlyTerm", #selector(quit), key: "q", modifiers: .command))
    }

    private func lookupGamesMenu() -> NSMenu {
        let store = LookupStore.shared
        let menu = NSMenu()
        guard !store.games.isEmpty else {
            // Needs an action: AppKit auto-enabling greys out an actionless item, and the submenu.
            let empty = NSMenuItem(title: "No game configured — Settings › Lookup",
                                   action: #selector(openLookupSettings), keyEquivalent: "")
            empty.target = self
            menu.addItem(empty)
            return menu
        }
        let automatic = NSMenuItem(title: "Automatic (from the app in front)",
                                   action: #selector(toggleLookupAutoDetect), keyEquivalent: "")
        automatic.target = self
        automatic.state = store.autoDetect ? .on : .off
        menu.addItem(automatic)
        menu.addItem(.separator())
        let active = store.activeGame?.id
        for game in store.games {
            let item = NSMenuItem(title: game.name, action: #selector(setLookupGame(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = game.id
            item.state = game.id == active ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector, hotkey: HotkeyAction? = nil,
                      key: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        guard let hotkey else { return item }
        let combo = Settings.shared.hotkey(hotkey)
        if !combo.isEmpty {
            if let equivalent = KeyCombo.menuKeyEquivalent(combo) {
                item.keyEquivalent = equivalent.key
                item.keyEquivalentModifierMask = equivalent.modifiers
            } else {
                item.title = "\(title)    \(KeyCombo.pretty(combo))"
            }
        }
        if hotkeyOK[hotkey.rawValue] == false {
            if #available(macOS 14.4, *) {
                item.subtitle = "Shortcut unavailable"
            } else {
                item.title += " (shortcut unavailable)"
            }
        }
        return item
    }

    private func percentItem(_ value: Int, of current: Double, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "\(value)%", action: action, keyEquivalent: "")
        item.target = self
        item.tag = value
        item.state = Int((current * 100).rounded()) == value ? .on : .off
        return item
    }

    @objc private func toggleVisible() { controller.toggleVisible() }
    @objc private func toggleGhost() { controller.toggleGhost() }
    @objc private func togglePanic() { controller.togglePanic() }
    @objc private func toggleFullscreen() { controller.toggleFullscreen() }
    @objc private func lookUp() { Lookup.shared.trigger() }
    @objc private func pickText() { Lookup.shared.pick() }
    @objc private func toggleLookupAutoDetect() { LookupStore.shared.autoDetect.toggle() }
    @objc private func openLookupSettings() { openSettings(tab: .guide) }
    @objc private func setLookupGame(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        LookupStore.shared.activeGameID = id
    }
    @objc private func newTab() { controller.newTab(); controller.focusTerminal() }
    @objc private func newWebTab() { controller.newWebTab() }
    @objc private func playPause() { MainActor.assumeIsolated { controller.playPause() } }
    @objc private func bringIn() { TeleportPicker.shared.show() }
    @objc private func sendTabBack() {
        if let tab = controller.selectedTerminal { TeleportEngine.shared.sendBack(tab) }
    }
    @objc private func setOpacity(_ sender: NSMenuItem) { Settings.shared.opacity = Double(sender.tag) / 100 }
    @objc private func setGhostOpacity(_ sender: NSMenuItem) { Settings.shared.ghostOpacity = Double(sender.tag) / 100 }
    @objc private func setVideoOpacity(_ sender: NSMenuItem) { Settings.shared.videoOpacity = Double(sender.tag) / 100 }
    @objc private func showSettings() { openSettings() }
    @objc private func showShortcuts() { openSettings(tab: .shortcuts) }
    @objc private func openHelp() {
        guard let url = URL(string: "https://github.com/MushkyQT/slyterm#shortcuts") else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func showAbout() { AppSwitcher.shared.showAbout() }
    @objc private func checkForUpdates() { Updater.shared.check() }
    @objc private func resetPosition() { controller.resetPosition() }
    @objc private func quit() { NSApp.terminate(nil) }

    // The status menu enables its items itself, so isEnabled set on one has no effect.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(checkForUpdates) || Updater.shared.canCheck
    }
}

// Settings and the setup assistant fall behind other apps' windows when SlyTerm is not active, and
// an accessory app is not in ⌘Tab, so the app is a regular one while either is open.
final class AppSwitcher: NSObject, NSMenuItemValidation {
    static let shared = AppSwitcher()

    private var open: [NSWindow] = []
    private var holds = 0
    private var about: NSWindow?
    private var aboutClosing: NSObjectProtocol?

    func windowOpened(_ window: NSWindow) {
        if !open.contains(window) { open.append(window) }
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.mainMenu = makeMenu()
        NSApp.setActivationPolicy(.regular)
        // An app already active when it turns regular does not get the menu bar until it is
        // activated again; the Dock has no windows, so handing it activation shows nothing.
        guard NSApp.isActive,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        dock.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            // The newest: the window that asked may have closed meanwhile, replaced by another.
            guard let front = open.last else { return }
            NSApp.activate(ignoringOtherApps: true)
            front.makeKeyAndOrderFront(nil)
        }
    }

    // Keeps SlyTerm in the Dock for a moment after a window closes, for one that replaces it.
    func hold(for seconds: TimeInterval) {
        holds += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            holds -= 1
            if open.isEmpty, holds == 0 { becomeAccessory() }
        }
    }

    // AppKit gives no handle on the standard panel, so it is the window that was not there before.
    func showAbout() {
        let known = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(options: [:])
        if let fresh = NSApp.windows.first(where: { !known.contains(ObjectIdentifier($0)) && $0.isVisible }) {
            if let aboutClosing { NotificationCenter.default.removeObserver(aboutClosing) }
            about = fresh
            aboutClosing = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: fresh, queue: .main
            ) { [weak self, weak fresh] _ in if let fresh { self?.windowClosed(fresh) } }
        }
        guard let about else { return }
        // Above the overlay like Settings; hidden while another app is active, so it does not
        // float over that app's windows.
        about.level = Settings.shared.dialogLevel
        about.hidesOnDeactivate = true
        about.center()
        windowOpened(about)
        NSApp.activate(ignoringOtherApps: true)
        about.makeKeyAndOrderFront(nil)
    }

    func windowClosed(_ window: NSWindow) {
        guard let index = open.firstIndex(of: window) else { return }
        open.remove(at: index)
        if open.isEmpty, holds == 0 { becomeAccessory() }
    }

    private func becomeAccessory() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = nil
    }

    // Without an Edit menu ⌘V and ⌘C do nothing in a text field.
    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        submenu("SlyTerm", [NSMenuItem(title: "Quit SlyTerm", action: #selector(NSApplication.terminate(_:)),
                                       keyEquivalent: "q")])
        submenu("Edit", [forwarding("Undo", "undo:", "z"), forwarding("Redo", "redo:", "Z"), .separator(),
                         forwarding("Cut", "cut:", "x"), forwarding("Copy", "copy:", "c"),
                         forwarding("Paste", "paste:", "v"), forwarding("Select All", "selectAll:", "a")])
        submenu("Window", [forwarding("Close", "performClose:", "w")])
        return main
    }

    private func forwarding(_ title: String, _ action: String, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(forward(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = action
        return item
    }

    @objc private func forward(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        NSApp.sendAction(NSSelectorFromString(action), to: nil, from: sender)
    }

    // The menu sees a key before the overlay's own handler does, and a disabled item passes it on,
    // so these work only in Settings, the assistant or a sheet on them.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let key = NSApp.keyWindow else { return false }
        return open.contains { $0 === key || $0 === key.sheetParent }
    }
}

enum ScreenRecording {
    case notGranted, granted, needsReopen

    static func state(granted: Bool, atLaunch: Bool) -> ScreenRecording {
        granted ? (atLaunch ? .granted : .needsReopen) : .notGranted
    }

    static var current: ScreenRecording {
        state(granted: CGPreflightScreenCaptureAccess(), atLaunch: Lookup.captureGrantedAtLaunch)
    }

    // The debug binary is not in a bundle, so there is nothing to open again.
    static var canReopen: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var label: String {
        switch self {
        case .notGranted: return "Screen Recording: not granted"
        case .granted: return "Screen Recording: granted"
        case .needsReopen: return "Screen Recording: granted, reopen SlyTerm to use it"
        }
    }

    var color: NSColor { self == .granted ? .labelColor : .systemOrange }

    // `open` on a bundle that is still running only brings it forward, so the shell waits for
    // this process to exit first, for 20 s at most.
    static func launchAfterExit() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 100 ]; do "
                             + "sleep 0.2; i=$((i+1)); done; exec /usr/bin/open \"$2\"",
                             "sh", "\(ProcessInfo.processInfo.processIdentifier)",
                             Bundle.main.bundlePath]
        do { try process.run() } catch { Settings.log("reopen: \(error.localizedDescription)") }
    }
}

extension NSAlert {
    // runModal, and each activation while it runs, put the alert back at the modal panel level,
    // under the overlay and Settings. The main queue does not run during it; the run loop does.
    func runModal(level: NSWindow.Level) -> NSApplication.ModalResponse {
        let raise: () -> Void = { [weak self] in self?.window.level = level }
        RunLoop.main.perform(inModes: [.modalPanel]) { raise() }
        let center = NotificationCenter.default
        let observers = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
            .map { center.addObserver(forName: $0, object: nil, queue: nil) { _ in raise() } }
        defer { observers.forEach(center.removeObserver) }
        return runModal()
    }
}
