import AppKit

final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("SlyTerm.settingsDidChange")

    private static let formerBundleIdentifier = "com.charlesmelki.hoverterm"

    private let d = UserDefaults.standard

    private init() {
        migrateFormerDefaults()
        d.register(defaults: [
            "opacity": 0.90,
            "ghostOpacity": 0.70,
            "videoOpacity": 0.85,
            "autoGhost": true,
            "fontSize": 13.0,
            "fontName": FontDetection.preferredFontName(),
            "workingDirectory": NSHomeDirectory(),
            "startupCommand": "",
            "shell": ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            "windowLevel": "statusBar",
            "stripPosition": "auto",
            "hotkeyToggle": "ctrl+alt+h",
            "hotkeyGhost": "ctrl+alt+tab",
            "hotkeyPanic": "ctrl+alt+p",
            "hotkeyFullscreen": "ctrl+alt+m",
            "hotkeyQuest": "ctrl+alt+q", // the lookup's legacy key name; renaming a stored key loses it
            "hotkeyPick": "ctrl+alt+shift+q",
            "hotkeyAllow": "ctrl+alt+y",
            "hotkeyRefuse": "ctrl+alt+n",
            "hotkeyPlayPause": "ctrl+alt+v",
            "questOpenInBackground": false,
            "questOpenInApp": true,
            "guideZoom": 1.0,
            "webSearchURL": WebSites.defaultSearchURL,
            "autoPauseVideo": true,
            "optionAsMeta": false,
            "scrollback": 10000,
            "frame": "",
            "frameEdge": "",
            "floatFrame": "",
            "floatVideoFrame": "",
            "debug": false,
            "tapGesture": true,
            "tapGestureAction": "ghost",
            "tapFingers": 3,
            "tapAlignment": 0.50,
            "restoreSession": true,
            "newTabInheritsDirectory": true,
            "confirmQuit": true,
            "attentionSound": true,
            "startupAnimation": true,
            "teleportClosesSource": true,
            "teleportConfirmBusy": true,
            "sendBackTerminal": "iterm2",
            "activityCards": true,
            "activityAnswerURLs": false,  // keep off: any local process, a Claude too, can open them
            "activityCardSeconds": 10.0,
            // Not "setupDone": decideSetup needs to see that it was never stored.
        ])
    }

    private func set(_ value: Any?, _ key: String) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: Settings.didChange, object: key)
    }

    // Must run before register(defaults:), or object(forKey:) sees the registered defaults and
    // copies nothing.
    private func migrateFormerDefaults() {
        let marker = "migratedFormerDefaults"
        guard let current = Bundle.main.bundleIdentifier, current != Self.formerBundleIdentifier,
              !d.bool(forKey: marker) else { return }
        defer { d.set(true, forKey: marker) }
        guard let former = d.persistentDomain(forName: Self.formerBundleIdentifier) else { return }
        for (key, value) in former where d.object(forKey: key) == nil {
            d.set(value, forKey: key)
        }
    }

    var opacity: Double { get { d.double(forKey: "opacity") } set { set(min(1, max(0.2, newValue)), "opacity") } }
    var ghostOpacity: Double { get { d.double(forKey: "ghostOpacity") } set { set(min(1, max(0.2, newValue)), "ghostOpacity") } }
    var videoOpacity: Double { get { d.double(forKey: "videoOpacity") } set { set(min(1, max(0.2, newValue)), "videoOpacity") } }
    var autoGhost: Bool { get { d.bool(forKey: "autoGhost") } set { set(newValue, "autoGhost") } }
    var fontSize: Double { get { d.double(forKey: "fontSize") } set { set(min(40, max(8, newValue)), "fontSize") } }
    var fontName: String { get { d.string(forKey: "fontName") ?? "" } set { set(newValue, "fontName") } }
    var workingDirectory: String { get { d.string(forKey: "workingDirectory") ?? NSHomeDirectory() } set { set(newValue, "workingDirectory") } }
    var startupCommand: String { get { d.string(forKey: "startupCommand") ?? "" } set { set(newValue, "startupCommand") } }
    var shell: String { get { d.string(forKey: "shell") ?? "/bin/zsh" } set { set(newValue, "shell") } }
    var windowLevel: String { get { d.string(forKey: "windowLevel") ?? "statusBar" } set { set(newValue, "windowLevel") } }
    var stripPosition: String {
        get {
            let value = d.string(forKey: "stripPosition") ?? "auto"
            return value == "top" || value == "bottom" ? value : "auto"
        }
        set { set(newValue, "stripPosition") }
    }
    var hotkeyToggle: String { get { d.string(forKey: "hotkeyToggle") ?? "" } set { set(newValue, "hotkeyToggle") } }
    var hotkeyGhost: String { get { d.string(forKey: "hotkeyGhost") ?? "" } set { set(newValue, "hotkeyGhost") } }
    var hotkeyPanic: String { get { d.string(forKey: "hotkeyPanic") ?? "" } set { set(newValue, "hotkeyPanic") } }
    var hotkeyFullscreen: String { get { d.string(forKey: "hotkeyFullscreen") ?? "" } set { set(newValue, "hotkeyFullscreen") } }
    var hotkeyQuest: String { get { d.string(forKey: "hotkeyQuest") ?? "" } set { set(newValue, "hotkeyQuest") } }
    var hotkeyPick: String { get { d.string(forKey: "hotkeyPick") ?? "" } set { set(newValue, "hotkeyPick") } }
    var hotkeyAllow: String { get { d.string(forKey: "hotkeyAllow") ?? "" } set { set(newValue, "hotkeyAllow") } }
    var hotkeyRefuse: String { get { d.string(forKey: "hotkeyRefuse") ?? "" } set { set(newValue, "hotkeyRefuse") } }
    var hotkeyPlayPause: String { get { d.string(forKey: "hotkeyPlayPause") ?? "" } set { set(newValue, "hotkeyPlayPause") } }
    func hotkey(_ action: HotkeyAction) -> String { d.string(forKey: action.settingsKey) ?? "" }
    func setHotkey(_ action: HotkeyAction, _ combo: String) { set(combo, action.settingsKey) }
    var optionAsMeta: Bool { get { d.bool(forKey: "optionAsMeta") } set { set(newValue, "optionAsMeta") } }
    var scrollback: Int { get { d.integer(forKey: "scrollback") } set { set(max(0, newValue), "scrollback") } }
    var debug: Bool { get { d.bool(forKey: "debug") } }
    var tapGesture: Bool { get { d.bool(forKey: "tapGesture") } set { set(newValue, "tapGesture") } }
    var tapGestureAction: String { get { d.string(forKey: "tapGestureAction") ?? "ghost" } set { set(newValue, "tapGestureAction") } }
    var tapFingers: Int { get { max(2, min(5, d.integer(forKey: "tapFingers"))) } set { set(newValue, "tapFingers") } }
    var tapAlignment: Double { get { d.double(forKey: "tapAlignment") } set { set(newValue, "tapAlignment") } }
    var questOpenInBackground: Bool { get { d.bool(forKey: "questOpenInBackground") } set { set(newValue, "questOpenInBackground") } }
    var questOpenInApp: Bool { get { d.bool(forKey: "questOpenInApp") } set { set(newValue, "questOpenInApp") } }
    var guideZoom: Double { get { d.double(forKey: "guideZoom") } set { set(min(2, max(0.5, newValue)), "guideZoom") } }
    var webSearchURL: String {
        get {
            let value = d.string(forKey: "webSearchURL") ?? ""
            return value.contains("{query}") ? value : WebSites.defaultSearchURL
        }
        set { set(newValue, "webSearchURL") }
    }
    var autoPauseVideo: Bool { get { d.bool(forKey: "autoPauseVideo") } set { set(newValue, "autoPauseVideo") } }
    var restoreSession: Bool { get { d.bool(forKey: "restoreSession") } set { set(newValue, "restoreSession") } }
    var startupAnimation: Bool { get { d.bool(forKey: "startupAnimation") } set { set(newValue, "startupAnimation") } }
    var newTabInheritsDirectory: Bool { get { d.bool(forKey: "newTabInheritsDirectory") } set { set(newValue, "newTabInheritsDirectory") } }
    var confirmQuit: Bool { get { d.bool(forKey: "confirmQuit") } set { set(newValue, "confirmQuit") } }
    var attentionSound: Bool { get { d.bool(forKey: "attentionSound") } set { set(newValue, "attentionSound") } }
    var teleportClosesSource: Bool { get { d.bool(forKey: "teleportClosesSource") } set { set(newValue, "teleportClosesSource") } }
    var teleportConfirmBusy: Bool { get { d.bool(forKey: "teleportConfirmBusy") } set { set(newValue, "teleportConfirmBusy") } }
    var sendBackTerminal: String { get { d.string(forKey: "sendBackTerminal") ?? "iterm2" } set { set(newValue, "sendBackTerminal") } }
    var activityCards: Bool { get { d.bool(forKey: "activityCards") } set { set(newValue, "activityCards") } }
    var activityAnswerURLs: Bool { get { d.bool(forKey: "activityAnswerURLs") } set { set(newValue, "activityAnswerURLs") } }
    var setupDone: Bool { get { d.bool(forKey: "setupDone") } set { set(newValue, "setupDone") } }
    var activityCardSeconds: Double {
        get { max(0, d.double(forKey: "activityCardSeconds")) }
        set { set(max(0, newValue), "activityCardSeconds") }
    }

    // Before the overlay exists: it writes frameEdge at once. These keys come only from a launch
    // of an earlier build (or HoverTerm's), which never showed the setup assistant. The persistent
    // domain, because object(forKey:) also answers from the registered defaults. The decision is
    // stored, so quitting during the assistant brings it back rather than reading as an upgrade.
    func decideSetup() {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let stored = d.persistentDomain(forName: domain) ?? [:]
        guard stored["setupDone"] == nil else { return }
        let upgrading = ["lookupGamesVersion", "frameEdge", "sessionDirectories"].contains { stored[$0] != nil }
        d.set(upgrading, forKey: "setupDone")
    }

    static var echo = false
    private static let logQueue = DispatchQueue(label: "com.slyterm.log")
    static func log(_ message: @autoclosure () -> String) {
        guard shared.debug || echo else { return }
        let text = message()
        if echo { print(text); return }
        NSLog("SlyTerm: %@", text)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SlyTerm.log")
        logQueue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    var savedFrame: NSRect? {
        get {
            guard let s = d.string(forKey: "frame"), !s.isEmpty else { return nil }
            let r = NSRectFromString(s)
            return r.isEmpty ? nil : r
        }
        set { d.set(newValue.map { NSStringFromRect($0) } ?? "", forKey: "frame") }
    }

    func savedFloatFrame(video: Bool) -> NSRect? {
        guard let s = d.string(forKey: video ? "floatVideoFrame" : "floatFrame"), !s.isEmpty else { return nil }
        let r = NSRectFromString(s)
        return r.isEmpty ? nil : r
    }

    func setSavedFloatFrame(_ frame: NSRect, video: Bool) {
        d.set(NSStringFromRect(frame), forKey: video ? "floatVideoFrame" : "floatFrame")
    }

    var savedStripEdge: StripEdge? {
        get {
            switch d.string(forKey: "frameEdge") {
            case "top": return .top
            case "bottom": return .bottom
            default: return nil
            }
        }
        set { d.set(newValue.map { $0 == .top ? "top" : "bottom" } ?? "", forKey: "frameEdge") }
    }

    var savedSession: (directories: [String], selected: Int)? {
        get {
            guard let dirs = d.stringArray(forKey: "sessionDirectories"), !dirs.isEmpty else { return nil }
            return (dirs, d.integer(forKey: "sessionSelected"))
        }
        set {
            d.set(newValue?.directories, forKey: "sessionDirectories")
            d.set(newValue?.selected, forKey: "sessionSelected")
        }
    }

    var font: NSFont {
        let size = CGFloat(fontSize)
        let base: NSFont
        if !fontName.isEmpty, let f = NSFont(name: fontName, size: size) {
            base = f
        } else {
            base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let family = base.familyName ?? ""
        let fallbacks = FontDetection.nerdFontFamilies.filter { $0 != family }.prefix(3).map { NSFontDescriptor(name: $0, size: size) }
        guard !fallbacks.isEmpty else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: Array(fallbacks)])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    var levelValue: NSWindow.Level {
        switch windowLevel {
        case "floating": return .floating
        case "popUpMenu": return .popUpMenu
        default: return .statusBar
        }
    }

    var dialogLevel: NSWindow.Level { NSWindow.Level(rawValue: levelValue.rawValue + 1) }
    // Above dialogLevel: Settings and the assistant go back up to it when the app activates, which
    // can happen after an alert has opened and would put them in front of it.
    var alertLevel: NSWindow.Level { NSWindow.Level(rawValue: levelValue.rawValue + 2) }
}
