import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: OverlayController!
    private var statusItem: NSStatusItem!
    private var hotkeyOK: [String: Bool] = [:]
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        controller.show()
        controller.playStartupAnimation()
        if !pendingURLs.isEmpty {
            RemoteControl.handle(pendingURLs, controller: controller)
            pendingURLs.removeAll()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TrackpadTapDetector.shared.stop()
        // Refresh and save before terminateAll: a dead shell has no cwd, and the poll stops while
        // the overlay is hidden.
        controller.refreshTabs()
        controller.saveSession()
        controller.terminateAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let s = Settings.shared
        guard s.confirmQuit, !isSystemInitiatedQuit else { return .terminateNow }
        let busy = controller.terminals.filter { $0.isRunningForegroundJob }.count
        if controller.terminals.count <= 1, busy == 0 { return .terminateNow }

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
        alert.informativeText = text
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.window.level = s.dialogLevel
        let quit = alert.runModal() == .alertFirstButtonReturn
        if quit, alert.suppressionButton?.state == .on { s.confirmQuit = false }
        return quit ? .terminateNow : .terminateCancel
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

        menu.addItem(item(controller.isVisible ? "Hide Terminal" : "Show Terminal", #selector(toggleVisible), hotkey: .toggle))
        menu.addItem(item("New Tab", #selector(newTab), key: "t", modifiers: .command))
        menu.addItem(item("Bring In a Session…", #selector(bringIn), key: "t", modifiers: [.command, .shift]))
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

        menu.addItem(item("Settings…", #selector(showSettings), key: ",", modifiers: .command))
        menu.addItem(item("Reset Window Position", #selector(resetPosition)))
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
    @objc private func setOpacity(_ sender: NSMenuItem) { Settings.shared.opacity = Double(sender.tag) / 100 }
    @objc private func setGhostOpacity(_ sender: NSMenuItem) { Settings.shared.ghostOpacity = Double(sender.tag) / 100 }
    @objc private func setVideoOpacity(_ sender: NSMenuItem) { Settings.shared.videoOpacity = Double(sender.tag) / 100 }
    @objc private func showSettings() { openSettings() }
    @objc private func resetPosition() { controller.resetPosition() }
    @objc private func quit() { NSApp.terminate(nil) }
}
