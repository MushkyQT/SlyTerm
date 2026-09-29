import AppKit
import Sparkle

// A window Sparkle opened on its own schedule would take the game's keyboard, so an update found
// by a scheduled check only waits in the menu (Sparkle's gentle reminders) until the player asks.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private static let sparkle = Bundle(for: SPUUpdater.self)
    private static let activation = [NSApplication.didBecomeActiveNotification,
                                     NSApplication.didResignActiveNotification]

    private var updater: SPUUpdater?
    private var observations: [NSKeyValueObservation] = []
    private var windows: [NSWindow] = []
    private var alert: NSWindow?
    private var alertPending = false
    private var asked = false
    private var bringForward = false
    private(set) var pendingVersion: String?

    // Only a release build's bundle has SUFeedURL: source and debug builds never update themselves.
    static var isAvailable: Bool {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        return Bundle.main.bundleURL.pathExtension == "app"
            && !feed.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isEnabled: Bool { updater != nil }
    var canCheck: Bool { updater?.canCheckForUpdates ?? false }
    var allowsAutomaticDownloads: Bool { updater?.allowsAutomaticUpdates ?? false }
    var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }
    var downloadsAutomatically: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    func start() {
        guard updater == nil, Self.isAvailable else { return }
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver,
                                 delegate: self)
        do {
            try updater.start()
        } catch {
            Settings.log("updates: Sparkle did not start: \(error.localizedDescription)")
            return
        }
        self.updater = updater
        let changed: (SPUUpdater, NSKeyValueObservedChange<Bool>) -> Void = { _, _ in
            NotificationCenter.default.post(name: Settings.didChange, object: "updater")
        }
        observations = [updater.observe(\.canCheckForUpdates, changeHandler: changed),
                        updater.observe(\.automaticallyChecksForUpdates, changeHandler: changed),
                        updater.observe(\.automaticallyDownloadsUpdates, changeHandler: changed)]
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(self, selector: #selector(windowShown(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(windowClosing(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
    }

    func check() {
        guard let updater, updater.canCheckForUpdates else { return }
        asked = true
        bringForward = true
        updater.checkForUpdates()
        // An update already found is shown before this returns; the rest come through the
        // window notifications.
        NSApp.windows.forEach(adopt)
    }

    @objc private func windowShown(_ note: Notification) {
        if let window = note.object as? NSWindow { adopt(window) }
    }

    // Sparkle's windows belong to its own window controllers. NSAlert's panel has none: it comes
    // through the modal alert callbacks.
    private func adopt(_ window: NSWindow) {
        guard window.isVisible, !windows.contains(window), let controller = window.windowController,
              Bundle(for: type(of: controller)) == Self.sparkle else { return }
        windows.append(window)
        window.level = Settings.shared.dialogLevel
        window.hidesOnDeactivate = true
        AppSwitcher.shared.windowOpened(window)
        Settings.log("updates: \"\(window.title)\" shown above the overlay"
                     + (asked ? "" : ", though nobody asked for it"))
        // A click in the menu bar item leaves SlyTerm inactive, and the window would stay hidden.
        // Only the first window after a click: later ones must not take the game's keyboard.
        guard bringForward else { return }
        bringForward = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func windowClosing(_ note: Notification) {
        if let window = note.object as? NSWindow, windows.contains(window) { release(window) }
    }

    // Sparkle closes one window just before it opens the next (checking, then the update or an
    // alert): the hold keeps SlyTerm in the Dock for it. A closed window leaves AppSwitcher at once,
    // or its Dock hand-off could bring it back with nothing behind it (seen live).
    private func release(_ window: NSWindow) {
        windows.removeAll { $0 === window }
        AppSwitcher.shared.hold(for: 0.5)
        AppSwitcher.shared.windowClosed(window)
    }

    // runModal puts the alert at the modal panel level, under the overlay, and again at each
    // activation. Sparkle runs it from a main queue block, so a block queued on the main queue
    // waits until the alert is gone; one on the run loop in its modal mode runs while it is up.
    func standardUserDriverWillShowModalAlert() {
        alertPending = true
        RunLoop.main.perform(inModes: [.modalPanel]) { [weak self] in self?.raiseAlert() }
        for name in Self.activation {
            NotificationCenter.default.addObserver(self, selector: #selector(activationChanged(_:)),
                                                   name: name, object: nil)
        }
    }

    func standardUserDriverDidShowModalAlert() {
        for name in Self.activation {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
        if let alert { release(alert) }
        alert = nil
        alertPending = false
    }

    @objc private func activationChanged(_ note: Notification) { raiseAlert() }

    // The alert level, as for the quit confirmation: Settings, where Check Now is, goes back up to
    // the dialog level at each activation and would cover it.
    private func raiseAlert() {
        guard alertPending, let window = alert ?? NSApp.modalWindow else { return }
        // A session counts a gentle reminder as shown, so an installer error in one the player
        // never opened would put an alert over the game.
        guard asked else {
            Settings.log("updates: closed an alert nobody asked for")
            NSApp.abortModal()
            return
        }
        // Not hidden on deactivation, like the quit confirmation: while it runs the overlay takes
        // no input, and a hidden alert would leave nothing on screen to say why.
        window.level = Settings.shared.alertLevel
        guard alert == nil else { return }
        alert = window
        windows.append(window)
        AppSwitcher.shared.windowOpened(window)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        pendingVersion = update.displayVersionString
        Settings.log("updates: SlyTerm \(update.displayVersionString) found, waiting in the menu")
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
        asked = false
        bringForward = false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Settings.log("updates: \(error.localizedDescription)")
    }
}
