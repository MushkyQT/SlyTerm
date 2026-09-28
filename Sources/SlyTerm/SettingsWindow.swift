import AppKit
import UniformTypeIdentifiers
import Vision

enum SettingsTab: String, CaseIterable {
    case general, terminal, window, shortcuts, guide

    var title: String {
        switch self {
        case .general: return "General"
        case .terminal: return "Terminal"
        case .window: return "Window"
        case .shortcuts: return "Shortcuts"
        case .guide: return "Lookup"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .terminal: return "terminal"
        case .window: return "macwindow"
        case .shortcuts: return "keyboard"
        case .guide: return "book"
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    var onBeginRecording: (() -> Void)?
    var onEndRecording: (() -> Void)?
    var isRefused: ((HotkeyAction) -> Bool)?

    private let tabs = PaneTabs()
    private var panes: [SettingsTab: SettingsPane] = [:]
    private var centered = false
    private var width: CGFloat = 0

    private init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SlyTerm Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let pane = makePane(tab)
            pane.onHeightChange = { [weak self, weak pane] in
                guard let self, let pane, pane.view.window?.isVisible == true else { return }
                fit(pane, animate: true)
            }
            panes[tab] = pane
            let item = NSTabViewItem(viewController: pane)
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        // Panes keep preferredContentSize zero, or NSTabViewController resizes the window itself;
        // `fit` does it instead.
        window.contentViewController = tabs
        width = panes.values.map { $0.view.fittingSize.width }.max() ?? 0
        tabs.onSelect = { [weak self] pane in
            guard let self, window.isVisible else { return }
            fit(pane, animate: true)
        }
        let center = NotificationCenter.default
        activation = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.window?.level = .normal
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.window?.level = Settings.shared.dialogLevel
            },
        ]
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private var activation: [NSObjectProtocol] = []

    private func makePane(_ tab: SettingsTab) -> SettingsPane {
        switch tab {
        case .general: return GeneralPane()
        case .terminal: return TerminalPane()
        case .window: return WindowPane()
        case .shortcuts: return ShortcutsPane(controller: self)
        case .guide: return LookupPane()
        }
    }

    func show(tab: SettingsTab?, level: NSWindow.Level) {
        guard let window else { return }
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabs.selectedTabViewItemIndex = index
        }
        // viewWillAppear, which refreshes the pane, does not fire when an open window is re-shown.
        let index = tabs.selectedTabViewItemIndex
        if SettingsTab.allCases.indices.contains(index), let pane = panes[SettingsTab.allCases[index]] {
            pane.refresh()
            if !window.isVisible { fit(pane, animate: false) }
        }
        window.level = level
        if !centered { window.center(); centered = true }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
    }

    private func fit(_ pane: SettingsPane, animate: Bool) {
        guard let window else { return }
        let content = NSRect(origin: .zero, size: NSSize(width: width, height: pane.view.fittingSize.height))
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        }
        window.setFrame(frame, display: true, animate: animate)
    }

    // Ends any recording, which re-registers the hotkeys; otherwise they stay off after closing.
    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }
}

private final class PaneTabs: NSTabViewController {
    var onSelect: ((SettingsPane) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let pane = tabViewItem?.viewController as? SettingsPane { onSelect?(pane) }
    }
}

class SettingsPane: NSViewController {
    let settings = Settings.shared
    var onHeightChange: (() -> Void)?
    private var observer: NSObjectProtocol?

    override func loadView() {
        let content = buildContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 20),
            container.bottomAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor, constant: 20),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            guard let self, isViewLoaded, view.window?.isVisible == true else { return }
            refresh()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func buildContent() -> NSView { NSView() }
    func refresh() {}

    func section(_ title: String, _ views: [NSView]) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return [label, stack]
    }

    func grid(_ sections: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: sections)
        grid.rowSpacing = 18
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing   // only valid once the grid has columns
        grid.rowAlignment = .firstBaseline
        return grid
    }

    func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 380
        return label
    }

    func checkbox(_ title: String, _ action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    func radio(_ title: String, _ value: String, _ action: Selector) -> NSButton {
        let button = NSButton(radioButtonWithTitle: title, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(value)
        return button
    }

    func choice(of sender: NSButton) -> String { sender.identifier?.rawValue ?? "" }

    func select(_ value: String, in buttons: [NSButton]) {
        for button in buttons { button.state = choice(of: button) == value ? .on : .off }
    }

    func button(_ title: String, _ action: Selector, small: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if small { button.controlSize = .small }
        return button
    }

    func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = spacing
        return stack
    }

    func column(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    @discardableResult
    func width<V: NSView>(_ view: V, _ points: CGFloat) -> V {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: points).isActive = true
        return view
    }

    func isEditing(_ field: NSTextField) -> Bool { field.currentEditor() != nil }
}

final class GeneralPane: SettingsPane, NSTextFieldDelegate {
    private var restoreSession = NSButton()
    private var startupAnimation = NSButton()
    private var confirmQuit = NSButton()
    private var attentionSound = NSButton()
    private var activityCards = NSButton()
    private var teleportClosesSource = NSButton()
    private var teleportConfirmBusy = NSButton()
    private var autoPauseVideo = NSButton()
    private let searchURL = NSTextField(string: "")

    override func buildContent() -> NSView {
        restoreSession = checkbox("Restore tabs from the last session", #selector(setRestoreSession(_:)))
        startupAnimation = checkbox("Play the logo animation", #selector(setStartupAnimation(_:)))
        confirmQuit = checkbox("Ask before quitting with several tabs or a running command", #selector(setConfirmQuit(_:)))
        attentionSound = checkbox("Play a sound when a tab needs attention", #selector(setAttentionSound(_:)))
        activityCards = checkbox("Show a card when an agent finishes or asks you something",
                                 #selector(setActivityCards(_:)))
        teleportClosesSource = checkbox("Close the tab a session came from after moving it (iTerm2, Terminal)",
                                        #selector(setTeleportClosesSource(_:)))
        teleportConfirmBusy = checkbox("Ask before interrupting an agent that is working or waiting for an answer",
                                       #selector(setTeleportConfirmBusy(_:)))
        autoPauseVideo = checkbox("Pause videos when a guide opens or they go out of view",
                                  #selector(setAutoPauseVideo(_:)))
        return grid([
            section("Launch", [restoreSession, startupAnimation]),
            section("Quitting", [confirmQuit]),
            section("Alerts", [
                attentionSound,
                activityCards,
                caption("Off, an agent finishing or asking only marks its tab: no card, no sound, and a hidden "
                        + "terminal stays hidden. The Allow and Refuse shortcuts go with it."),
            ]),
            section("Bring In", [teleportClosesSource, teleportConfirmBusy]),
            section("Web tabs", [
                row([NSTextField(labelWithString: "Search with"), searchURLField()]),
                caption("Words typed into a web tab's address field go to this address, {query} where they go."),
                autoPauseVideo,
                caption("A lookup's guide pauses every video. A video in the SlyTerm window also pauses behind "
                        + "another tab or with the window hidden, and plays again when you come back to it."),
            ]),
        ])
    }

    private func searchURLField() -> NSTextField {
        searchURL.placeholderString = WebSites.defaultSearchURL
        searchURL.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        searchURL.lineBreakMode = .byTruncatingTail
        searchURL.target = self
        searchURL.action = #selector(setSearchURL)
        searchURL.delegate = self
        return width(searchURL, 300)
    }

    override func refresh() {
        restoreSession.state = settings.restoreSession ? .on : .off
        startupAnimation.state = settings.startupAnimation ? .on : .off
        confirmQuit.state = settings.confirmQuit ? .on : .off
        attentionSound.state = settings.attentionSound ? .on : .off
        activityCards.state = settings.activityCards ? .on : .off
        teleportClosesSource.state = settings.teleportClosesSource ? .on : .off
        teleportConfirmBusy.state = settings.teleportConfirmBusy ? .on : .off
        autoPauseVideo.state = settings.autoPauseVideo ? .on : .off
        if !isEditing(searchURL), isUsable(searchURL.stringValue) {
            searchURL.stringValue = settings.webSearchURL
        }
        paintSearchURL()
    }

    // While editing, the text is drawn by the field editor, which keeps its own colour.
    private func paintSearchURL() {
        let color: NSColor = isUsable(searchURL.stringValue) ? .labelColor : .systemOrange
        searchURL.textColor = color
        (searchURL.currentEditor() as? NSTextView)?.textColor = color
    }

    private func isUsable(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.contains("{query}")
    }

    // Left unsaved, in orange, until it has {query}; emptied, it goes back to the default.
    @objc private func setSearchURL() {
        let text = searchURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsable(text) else { refresh(); return }
        settings.webSearchURL = text.isEmpty ? WebSites.defaultSearchURL : text
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === searchURL { paintSearchURL() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === searchURL { setSearchURL() }
    }

    @objc private func setRestoreSession(_ sender: NSButton) { settings.restoreSession = sender.state == .on }
    @objc private func setStartupAnimation(_ sender: NSButton) { settings.startupAnimation = sender.state == .on }
    @objc private func setConfirmQuit(_ sender: NSButton) { settings.confirmQuit = sender.state == .on }
    @objc private func setAttentionSound(_ sender: NSButton) { settings.attentionSound = sender.state == .on }
    @objc private func setActivityCards(_ sender: NSButton) { settings.activityCards = sender.state == .on }
    @objc private func setTeleportClosesSource(_ sender: NSButton) { settings.teleportClosesSource = sender.state == .on }
    @objc private func setTeleportConfirmBusy(_ sender: NSButton) { settings.teleportConfirmBusy = sender.state == .on }
    @objc private func setAutoPauseVideo(_ sender: NSButton) { settings.autoPauseVideo = sender.state == .on }
}

final class TerminalPane: SettingsPane, NSTextFieldDelegate {
    private let family = NSPopUpButton()
    private let size = NSTextField(string: "")
    private let stepper = NSStepper()
    private let folder = NSTextField(labelWithString: "")
    private let startupCommand = NSTextField(string: "")
    private var inherit = NSButton()
    private var optionAsMeta = NSButton()
    private var customFamily: NSMenuItem?

    private static let fixedPitchFamilies: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { name in
            guard let members = manager.availableMembers(ofFontFamily: name) else { return false }
            // Each member is [PostScript name, style, weight, traits].
            return members.contains { member in
                guard member.count > 3, let traits = member[3] as? UInt else { return false }
                return NSFontTraitMask(rawValue: traits).contains(.fixedPitchFontMask)
            }
        }.sorted()
    }()

    override func buildContent() -> NSView {
        family.target = self
        family.action = #selector(setFamily)
        buildFamilyMenu()

        size.alignment = .right
        size.target = self
        size.action = #selector(setSize)
        size.delegate = self
        width(size, 48)
        stepper.minValue = 8
        stepper.maxValue = 40
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepSize)

        folder.lineBreakMode = .byTruncatingMiddle
        width(folder, 240)
        inherit = checkbox("New tabs open in the current tab's folder", #selector(setInherit(_:)))
        startupCommand.placeholderString = "claude or codex"
        startupCommand.target = self
        startupCommand.action = #selector(setStartupCommand)
        startupCommand.delegate = self
        width(startupCommand, 240)
        optionAsMeta = checkbox("Option key sends Meta (Esc+)", #selector(setOptionAsMeta(_:)))

        return grid([
            section("Font", [
                row([label("Family"), family, label("Size"), size, stepper,
                     button("Reset", #selector(resetSize), small: true)]),
                caption("By default SlyTerm uses your iTerm2 font, then the first installed Nerd Font."),
            ]),
            section("Shell", [
                row([label("Default folder"), folder, button("Choose…", #selector(chooseFolder), small: true)]),
                inherit,
                row([label("Startup command"), startupCommand]),
                caption("Typed into every new tab once the shell starts."),
            ]),
            section("Keyboard", [
                optionAsMeta,
                caption("Leave off to keep { [ | ~ on French and other international layouts."),
            ]),
        ])
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func buildFamilyMenu() {
        family.removeAllItems()
        addFamily("System Monospaced", value: "")
        let nerd = FontDetection.nerdFontFamilies
        if !nerd.isEmpty {
            family.menu?.addItem(.separator())
            nerd.forEach { addFamily($0, value: $0) }
        }
        let others = Self.fixedPitchFamilies.filter { !nerd.contains($0) }
        if !others.isEmpty {
            family.menu?.addItem(.separator())
            others.forEach { addFamily($0, value: $0) }
        }
    }

    private func addFamily(_ title: String, value: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = value
        family.menu?.addItem(item)
    }

    override func refresh() {
        let name = settings.fontName
        let current = name.isEmpty ? "" : (NSFont(name: name, size: 12)?.familyName ?? name)
        if let existing = customFamily, (existing.representedObject as? String) != current {
            family.menu?.removeItem(existing)
            customFamily = nil
        }
        if let item = family.itemArray.first(where: { ($0.representedObject as? String) == current }) {
            family.select(item)
        } else {
            family.menu?.addItem(.separator())
            addFamily(current, value: current)
            customFamily = family.lastItem
            family.select(customFamily)
        }
        if !isEditing(size) { size.stringValue = "\(Int(settings.fontSize))" }
        stepper.doubleValue = settings.fontSize
        folder.stringValue = (settings.workingDirectory as NSString).abbreviatingWithTildeInPath
        folder.toolTip = settings.workingDirectory
        inherit.state = settings.newTabInheritsDirectory ? .on : .off
        if !isEditing(startupCommand) { startupCommand.stringValue = settings.startupCommand }
        optionAsMeta.state = settings.optionAsMeta ? .on : .off
    }

    @objc private func setFamily() { settings.fontName = family.selectedItem?.representedObject as? String ?? "" }
    @objc private func setSize() {
        guard let value = Double(size.stringValue.trimmingCharacters(in: .whitespaces)) else { refresh(); return }
        settings.fontSize = value
        refresh()
    }
    @objc private func stepSize() { settings.fontSize = stepper.doubleValue }
    @objc private func resetSize() { settings.fontSize = 13 }
    @objc private func setInherit(_ sender: NSButton) { settings.newTabInheritsDirectory = sender.state == .on }
    @objc private func setStartupCommand() { settings.startupCommand = startupCommand.stringValue }
    @objc private func setOptionAsMeta(_ sender: NSButton) { settings.optionAsMeta = sender.state == .on }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === size { setSize() } else if field === startupCommand { setStartupCommand() }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.workingDirectory)
        panel.message = "The first tab starts here, and new tabs too when they do not inherit the current tab's folder."
        panel.prompt = "Use folder"
        // A sheet: a standalone open panel runs out of process and opens under this raised window.
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.settings.workingDirectory = url.path
        }
    }
}

final class WindowPane: SettingsPane {
    private let opacity = NSSlider()
    private let ghostOpacity = NSSlider()
    private let videoOpacity = NSSlider()
    private let opacityValue = NSTextField(labelWithString: "")
    private let ghostOpacityValue = NSTextField(labelWithString: "")
    private let videoOpacityValue = NSTextField(labelWithString: "")
    private var autoGhost = NSButton()
    private var levels: [NSButton] = []
    private var positions: [NSButton] = []

    override func buildContent() -> NSView {
        configure(opacity, #selector(setOpacity))
        configure(ghostOpacity, #selector(setGhostOpacity))
        configure(videoOpacity, #selector(setVideoOpacity))
        autoGhost = checkbox("Switch to click-through when the terminal loses focus", #selector(setAutoGhost(_:)))
        levels = [radio("Floating", "floating", #selector(setLevel(_:))),
                  radio("Status bar", "statusBar", #selector(setLevel(_:))),
                  radio("Pop-up menu, highest", "popUpMenu", #selector(setLevel(_:)))]
        positions = [radio("Automatic", "auto", #selector(setPosition(_:))),
                     radio("Always top", "top", #selector(setPosition(_:))),
                     radio("Always bottom", "bottom", #selector(setPosition(_:)))]

        return grid([
            section("Opacity", [
                row([width(NSTextField(labelWithString: "Terminal background"), 150), opacity, opacityValue]),
                row([width(NSTextField(labelWithString: "In click-through"), 150), ghostOpacity, ghostOpacityValue]),
                row([width(NSTextField(labelWithString: "Playing video"), 150), videoOpacity, videoOpacityValue]),
                caption("A web tab playing a video, in the SlyTerm window or floating, in either mode."),
            ]),
            section("Click-through", [autoGhost]),
            section("Level", [
                column(levels, spacing: 4),
                caption("Raise it if the game covers the terminal."),
            ]),
            section("Tab bar", [
                column(positions, spacing: 4),
                caption("Automatic puts the bar on top while the window sits in the upper half of the screen, at the bottom otherwise."),
            ]),
        ])
    }

    private func configure(_ slider: NSSlider, _ action: Selector) {
        slider.minValue = 20
        slider.maxValue = 100
        slider.numberOfTickMarks = 9
        slider.tickMarkPosition = .below
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        width(slider, 200)
    }

    override func refresh() {
        opacity.doubleValue = settings.opacity * 100
        ghostOpacity.doubleValue = settings.ghostOpacity * 100
        opacityValue.stringValue = percent(settings.opacity)
        ghostOpacityValue.stringValue = percent(settings.ghostOpacity)
        videoOpacity.doubleValue = settings.videoOpacity * 100
        videoOpacityValue.stringValue = percent(settings.videoOpacity)
        autoGhost.state = settings.autoGhost ? .on : .off
        select(settings.windowLevel, in: levels)
        select(settings.stripPosition, in: positions)
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    @objc private func setOpacity() { settings.opacity = opacity.doubleValue / 100 }
    @objc private func setGhostOpacity() { settings.ghostOpacity = ghostOpacity.doubleValue / 100 }
    @objc private func setVideoOpacity() { settings.videoOpacity = videoOpacity.doubleValue / 100 }
    @objc private func setAutoGhost(_ sender: NSButton) { settings.autoGhost = sender.state == .on }
    @objc private func setLevel(_ sender: NSButton) { settings.windowLevel = choice(of: sender) }
    @objc private func setPosition(_ sender: NSButton) { settings.stripPosition = choice(of: sender) }
}

final class ShortcutsPane: SettingsPane {
    private unowned let controller: SettingsWindowController
    private var recorders: [HotkeyAction: HotkeyRecorderView] = [:]
    private var statusLabels: [HotkeyAction: NSTextField] = [:]
    private var clearButtons: [HotkeyAction: NSButton] = [:]
    private var titleLabels: [HotkeyAction: NSTextField] = [:]
    private let fingers = NSPopUpButton()
    private let gesture = NSPopUpButton()
    private var trackpadNote = NSTextField()

    init(controller: SettingsWindowController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func buildContent() -> NSView {
        let hotkeys = NSGridView()
        hotkeys.rowSpacing = 10
        hotkeys.columnSpacing = 10
        for action in HotkeyAction.allCases {
            let recorder = HotkeyRecorderView(combo: settings.hotkey(action))
            recorder.onBeginRecording = { [weak self] in self?.controller.onBeginRecording?() }
            recorder.onEndRecording = { [weak self] in
                self?.controller.onEndRecording?()
                self?.refreshStatus()
            }
            recorder.onChange = { [weak self] combo in
                self?.settings.setHotkey(action, combo)
                // Recording ended before the combo was saved, so re-register with the new one.
                self?.controller.onEndRecording?()
                self?.refreshStatus()
            }
            let clear = button("Clear", #selector(clear(_:)), small: true)
            clear.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 11)
            status.textColor = .systemOrange
            let title = NSTextField(labelWithString: action.title)
            recorders[action] = recorder
            statusLabels[action] = status
            clearButtons[action] = clear
            titleLabels[action] = title
            hotkeys.addRow(with: [title, recorder, clear, status])
        }
        hotkeys.column(at: 0).xPlacement = .trailing
        hotkeys.rowAlignment = .firstBaseline

        fingers.target = self
        fingers.action = #selector(setFingers)
        for n in 2...5 {
            let item = NSMenuItem(title: "\(n)", action: nil, keyEquivalent: "")
            item.tag = n
            fingers.menu?.addItem(item)
        }
        gesture.target = self
        gesture.action = #selector(setGesture)
        for (title, value) in [("Off", ""), ("Toggle click-through", "ghost"),
                               ("Show or hide the terminal", "toggle"), ("Panic mode", "panic")] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = value
            gesture.menu?.addItem(item)
        }
        trackpadNote = caption("")

        return grid([
            section("Hotkeys", [
                hotkeys,
                button("Restore Defaults", #selector(restoreDefaults)),
                caption("Click a field and press the new shortcut. Esc cancels, ⌫ removes the shortcut. ⌃⌥ with a key stays clear of the keys games use. macOS does not tell SlyTerm when another app has the same shortcut: if one does nothing, or does something else, choose another."),
            ]),
            section("Trackpad", [
                row([NSTextField(labelWithString: "Tap with"), fingers,
                     NSTextField(labelWithString: "fingers to"), gesture]),
                trackpadNote,
            ]),
        ])
    }

    override func refresh() {
        for action in HotkeyAction.allCases { recorders[action]?.combo = settings.hotkey(action) }
        refreshStatus()
        fingers.selectItem(withTag: settings.tapFingers)
        let action = settings.tapGesture ? settings.tapGestureAction : ""
        gesture.select(gesture.itemArray.first { ($0.representedObject as? String) == action } ?? gesture.itemArray.first)
        if let reason = TrackpadTapDetector.shared.unavailableReason {
            trackpadNote.stringValue = "Unavailable: \(reason)"
            trackpadNote.textColor = .systemOrange
            fingers.isEnabled = false
            gesture.isEnabled = false
        } else {
            trackpadNote.stringValue = "In System Settings › Trackpad, set “Look up” to Force Click or off."
            trackpadNote.textColor = .secondaryLabelColor
            fingers.isEnabled = true
            gesture.isEnabled = true
        }
    }

    private func refreshStatus() {
        let combos = HotkeyAction.allCases.map { ($0, settings.hotkey($0)) }
        for (action, combo) in combos {
            let enabled = !action.needsActivityCards || settings.activityCards
            recorders[action]?.isEnabled = enabled
            clearButtons[action]?.isEnabled = enabled
            titleLabels[action]?.textColor = enabled ? .labelColor : .disabledControlTextColor
            var message = ""
            if !enabled {
                message = "Off while the card is off (Settings › General)"
            } else if !combo.isEmpty {
                if KeyCombo.parse(combo) == nil {
                    message = "Cannot be used"
                } else if let other = combos.first(where: { $0.0 != action && $0.1 == combo }) {
                    message = "Also used by “\(other.0.title)”"
                } else if KeyCombo.isMacOSShortcut(combo) {
                    message = "Also a macOS shortcut"
                } else if controller.isRefused?(action) == true {
                    message = "macOS did not accept it"
                }
            }
            statusLabels[action]?.stringValue = message
            statusLabels[action]?.textColor = enabled ? .systemOrange : .secondaryLabelColor
        }
    }

    @objc private func clear(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let action = HotkeyAction(rawValue: id) else { return }
        settings.setHotkey(action, "")
        recorders[action]?.combo = ""
        controller.onEndRecording?()
        refreshStatus()
    }

    @objc private func restoreDefaults() {
        for action in HotkeyAction.allCases {
            settings.setHotkey(action, action.defaultCombo)
            recorders[action]?.combo = action.defaultCombo
        }
        controller.onEndRecording?()
        refreshStatus()
    }

    @objc private func setFingers() { settings.tapFingers = fingers.selectedTag() }

    @objc private func setGesture() {
        let value = gesture.selectedItem?.representedObject as? String ?? ""
        if value.isEmpty {
            settings.tapGesture = false
        } else {
            settings.tapGestureAction = value
            settings.tapGesture = true
        }
    }
}

final class LookupPane: SettingsPane, NSTableViewDataSource, NSTableViewDelegate,
                        NSTextFieldDelegate, NSTextViewDelegate {
    private let store = LookupStore.shared

    private var games: [LookupGame] = []
    private var shownSources: [LookupSource] = []
    private var selectedGame: UUID?
    private var selectedSource: UUID?
    private var probed: [UUID: Int] = [:]
    private var probing: Set<UUID> = []
    private var probeGeneration: [UUID: Int] = [:]
    private var urlProblem: String?
    private var syncingSelection = false
    // LookupStore posts didChange synchronously as it saves; this stops refresh re-entering and
    // reloading a table while AppKit is still unwinding the field editor.
    private var applying = false
    private var editingGameID: UUID?
    private var editingSourceID: UUID?
    private var popupsKey: String?

    private let gamesTable = NSTableView()
    private let sourcesTable = NSTableView()
    private let addGame = NSPopUpButton(frame: .zero, pullsDown: true)
    private var removeGame = NSButton()
    private let nameField = NSTextField(string: "")
    private let appPopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    private var sourceButtons: [NSButton] = []
    private let detection = NSTextField(labelWithString: "")
    private var advancedToggle = NSButton()
    private let advanced = NSStackView()
    private let stripPatterns = NSTextView()
    private let tooltipPatterns = NSTextView()
    private let readerCSS = NSTextView()
    private let hiddenSelectors = NSTextView()
    private var autoDetect = NSButton()
    private let fallbackGame = NSPopUpButton()
    private var destinations: [NSButton] = []
    private var inBackground = NSButton()
    private let permission = NSTextField(labelWithString: "")
    private var exportButton = NSButton()

    private static let listWidth: CGFloat = 150
    private static let detailWidth: CGFloat = 380
    private static let blankHome = URL(string: "https://example.com")!
    private static let recognitionLanguages: [String] =
        ((try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? [])
        .sorted { LookupPane.languageName($0).localizedStandardCompare(LookupPane.languageName($1)) == .orderedAscending }

    private static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    override func buildContent() -> NSView {
        let master = NSStackView(views: [gamesColumn(), detailColumn()])
        master.orientation = .horizontal
        master.alignment = .top
        master.spacing = 12

        let heading = NSTextField(labelWithString: "Games")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        autoDetect = checkbox("Detect the game from the app in front", #selector(setAutoDetect(_:)))
        width(fallbackGame, 200)
        fallbackGame.target = self
        fallbackGame.action = #selector(setFallbackGame)
        destinations = [radio("In a web tab inside SlyTerm", "app", #selector(setDestination(_:))),
                        radio("In your browser", "browser", #selector(setDestination(_:)))]
        inBackground = checkbox("Keep the game in front, load the page behind it", #selector(setInBackground(_:)))
        let indented = NSStackView(views: [inBackground])
        indented.orientation = .horizontal
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        exportButton = button("Export…", #selector(exportGame), small: true)

        let sections = grid([
            section("Active game", [
                autoDetect,
                row([NSTextField(labelWithString: "Otherwise use"), fallbackGame]),
            ]),
            section("Open guides", [destinations[0], destinations[1], indented]),
            section("Permission", [
                row([permission, button("Open System Settings…", #selector(openPrivacySettings), small: true)]),
            ]),
            section("Game files", [
                row([button("Import…", #selector(importGame), small: true), exportButton]),
            ]),
        ])
        return column([column([heading, master], spacing: 6), sections], spacing: 18)
    }

    private func gamesColumn() -> NSView {
        gamesTable.headerView = nil
        let list = scrolling(gamesTable, columns: [("name", "Name", Self.listWidth - 4)],
                             width: Self.listWidth, height: 244)
        gamesTable.usesAlternatingRowBackgroundColors = false
        buildAddMenu()
        addGame.controlSize = .small
        addGame.font = .systemFont(ofSize: 11)
        width(addGame, 44)
        removeGame = button("−", #selector(removeSelectedGame), small: true)
        width(removeGame, 30)
        return column([list, row([addGame, removeGame], spacing: 6)], spacing: 6)
    }

    private func detailColumn() -> NSView {
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(commitName)
        nameField.placeholderString = "Game"
        appPopup.target = self
        appPopup.action = #selector(setGameApp)
        languagePopup.target = self
        languagePopup.action = #selector(setLanguage)
        let fieldWidth = Self.detailWidth - 96
        width(nameField, fieldWidth)
        width(appPopup, fieldWidth)
        width(languagePopup, fieldWidth)
        let fields = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), nameField],
            [NSTextField(labelWithString: "Game app"), appPopup],
            [NSTextField(labelWithString: "Text language"), languagePopup],
        ])
        fields.rowSpacing = 8
        fields.columnSpacing = 8
        fields.column(at: 0).xPlacement = .trailing
        fields.rowAlignment = .firstBaseline

        let sources = scrolling(sourcesTable,
                                columns: [("name", "Name", 110), ("url", "Search URL", 246)],
                                width: Self.detailWidth, height: 80)
        sourceButtons = [button("+", #selector(addSource), small: true),
                         button("−", #selector(removeSource), small: true),
                         button("▲", #selector(moveSourceUp), small: true),
                         button("▼", #selector(moveSourceDown), small: true)]
        sourceButtons.forEach { width($0, 30) }
        detection.font = .systemFont(ofSize: 11)
        detection.textColor = .secondaryLabelColor
        detection.lineBreakMode = .byTruncatingTail
        width(detection, Self.detailWidth - 150)

        advancedToggle = NSButton(title: "", target: self, action: #selector(toggleAdvanced))
        advancedToggle.bezelStyle = .disclosure
        advancedToggle.setButtonType(.pushOnPushOff)
        advancedToggle.state = .off
        let advancedLabel = NSTextField(labelWithString: "Advanced")
        advancedLabel.font = .systemFont(ofSize: 11)
        advancedLabel.textColor = .secondaryLabelColor

        advanced.orientation = .vertical
        advanced.alignment = .leading
        advanced.spacing = 4
        advanced.isHidden = true
        for view in [caption("Strip patterns for this game (one regular expression per line)"),
                     editor(stripPatterns, height: 48),
                     caption("Tooltip lines for this game (one regular expression per line): lines only a tooltip has, such as Sell Price:. A group of lines with one is a tooltip, tried first wherever it is on screen. Presets have theirs built in, and strip patterns too."),
                     editor(tooltipPatterns, height: 48),
                     caption("Reader mode CSS"), editor(readerCSS, height: 40),
                     caption("Hidden selectors"), editor(hiddenSelectors, height: 40)] {
            advanced.addArrangedSubview(view)
        }

        return column([fields, sources, row(sourceButtons + [detection], spacing: 6),
                       caption("Sources with an index (a wiki or a sitemap) are matched offline first; then every source that can be asked is: a page named exactly the text wins over a near one, and among equals the source higher up. The first source's search page is the fallback."),
                       row([advancedToggle, advancedLabel], spacing: 4), advanced], spacing: 6)
    }

    private func scrolling(_ table: NSTableView, columns: [(String, String, CGFloat)],
                           width w: CGFloat, height: CGFloat) -> NSScrollView {
        for (identifier, title, columnWidth) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = columnWidth
            column.isEditable = true
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.style = .plain
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        width(scroll, w)
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func editor(_ view: NSTextView, height: CGFloat) -> NSScrollView {
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        width(scroll, Self.detailWidth)
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func buildAddMenu() {
        let menu = NSMenu()
        // A pull-down button draws its first item as its own title.
        menu.addItem(NSMenuItem(title: "+", action: nil, keyEquivalent: ""))
        var families: [String: NSMenu] = [:]
        for preset in LookupPresets.Preset.allCases {
            let item = NSMenuItem(title: "", action: #selector(addPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            if let family = preset.family {
                if families[family] == nil {
                    let parent = NSMenuItem(title: "\(family) (\(preset.siteName))", action: nil, keyEquivalent: "")
                    parent.submenu = NSMenu(title: family)
                    menu.addItem(parent)
                    families[family] = parent.submenu
                }
                item.title = preset.variant
                families[family]?.addItem(item)
            } else {
                item.title = "\(preset.title) (\(preset.siteName))"
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom Game…", action: #selector(addCustomGame), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        addGame.menu = menu
    }

    private var currentGame: LookupGame? { games.first { $0.id == selectedGame } }

    private var currentSource: LookupSource? {
        currentGame?.sources.first { $0.id == selectedSource }
    }

    override func refresh() {
        guard !applying else { return }
        let fresh = store.games
        // Set before reloadData: a dropped row moves the selection, which reports as a click.
        syncingSelection = true
        if fresh != games {
            games = fresh
            gamesTable.reloadData()
        }
        if selectedGame == nil || !games.contains(where: { $0.id == selectedGame }) {
            selectedGame = games.first?.id
        }
        if let id = selectedGame, let row = games.firstIndex(where: { $0.id == id }) {
            gamesTable.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            gamesTable.deselectAll(nil)
        }
        syncingSelection = false
        refreshDetail()
        refreshShared()
    }

    private func refreshDetail() {
        let game = currentGame
        let enabled = game != nil
        for control in [nameField, appPopup, languagePopup, removeGame, exportButton] as [NSControl] {
            control.isEnabled = enabled
        }
        sourceButtons.forEach { $0.isEnabled = enabled }
        for view in [stripPatterns, tooltipPatterns, readerCSS, hiddenSelectors] { view.isEditable = enabled }

        guard let game else {
            if !isEditing(nameField) { nameField.stringValue = "" }
            appPopup.removeAllItems()
            languagePopup.removeAllItems()
            popupsKey = nil
            shownSources = []
            syncingSelection = true
            sourcesTable.reloadData()
            syncingSelection = false
            detection.stringValue = ""
            return
        }
        if !isEditing(nameField) { nameField.stringValue = game.name }
        refreshPopups(for: game)
        syncingSelection = true
        if shownSources != game.sources {
            shownSources = game.sources
            sourcesTable.reloadData()
        }
        if selectedSource == nil || !game.sources.contains(where: { $0.id == selectedSource }) {
            selectedSource = game.sources.first?.id
        }
        if let id = selectedSource, let row = game.sources.firstIndex(where: { $0.id == id }) {
            sourcesTable.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            sourcesTable.deselectAll(nil)
        }
        syncingSelection = false
        refreshDetection()
        refreshAdvanced(game)
    }

    private func refreshDetection() {
        if let urlProblem {
            detection.stringValue = urlProblem
            detection.textColor = .systemOrange
            detection.toolTip = urlProblem
            return
        }
        detection.textColor = .secondaryLabelColor
        guard let source = currentSource else {
            detection.stringValue = ""
            detection.toolTip = nil
            return
        }
        guard !source.searchURL.isEmpty else {
            detection.stringValue = "No search URL yet"
            detection.toolTip = nil
            return
        }
        if probing.contains(source.id) {
            detection.stringValue = "Detecting…"
            detection.toolTip = nil
            return
        }
        let loaded = Lookup.shared.indexCount(for: source) ?? 0
        let count = probed[source.id] ?? (loaded > 0 ? loaded : nil)
        if let count, count > 0 {
            let pages = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            detection.stringValue = "\(source.kind.title) · \(pages) pages indexed"
        } else {
            detection.stringValue = "\(source.kind.title) · no index"
        }
        detection.toolTip = detection.stringValue
    }

    private func refreshAdvanced(_ game: LookupGame?) {
        if !isEditing(stripPatterns) {
            stripPatterns.string = (game?.stripPatterns ?? []).joined(separator: "\n")
        }
        if !isEditing(tooltipPatterns) {
            tooltipPatterns.string = (game?.tooltipPatterns ?? []).joined(separator: "\n")
        }
        let source = currentSource
        if !isEditing(readerCSS) { readerCSS.string = source?.readerCSS ?? "" }
        if !isEditing(hiddenSelectors) { hiddenSelectors.string = source?.hiddenSelectors ?? "" }
    }

    private func refreshShared() {
        autoDetect.state = store.autoDetect ? .on : .off
        fallbackGame.removeAllItems()
        for game in games {
            let item = NSMenuItem(title: game.name, action: nil, keyEquivalent: "")
            item.representedObject = game.id
            fallbackGame.menu?.addItem(item)
        }
        fallbackGame.isEnabled = !games.isEmpty
        if let active = store.activeGame?.id,
           let item = fallbackGame.itemArray.first(where: { ($0.representedObject as? UUID) == active }) {
            fallbackGame.select(item)
        }
        select(settings.questOpenInApp ? "app" : "browser", in: destinations)
        inBackground.state = settings.questOpenInBackground ? .on : .off
        inBackground.isEnabled = !settings.questOpenInApp
        let granted = CGPreflightScreenCaptureAccess()
        permission.stringValue = "Screen Recording: \(granted ? "granted" : "not granted")"
        permission.textColor = granted ? .labelColor : .systemOrange
    }

    // Rebuild only when the key changes: refresh runs on every didChange, and a rebuild closes an
    // open pop-up menu.
    private func refreshPopups(for game: LookupGame) {
        let running = Self.runningApps()
        let key = ([game.id.uuidString] + game.appBundleIDs + ["·"] + game.ocrLanguages + ["·"]
                   + running.map { $0.id }).joined(separator: "\u{1}")
        guard key != popupsKey else { return }
        popupsKey = key
        buildAppMenu(for: game, running: running)
        buildLanguageMenu(for: game)
    }

    private static func runningApps() -> [(name: String, id: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != NSRunningApplication.current.processIdentifier }
            .compactMap { app -> (name: String, id: String)? in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return (name, id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func buildAppMenu(for game: LookupGame, running: [(name: String, id: String)]) {
        appPopup.removeAllItems()
        add("Any (choose the game by hand)", "", to: appPopup)
        if !running.isEmpty { appPopup.menu?.addItem(.separator()) }
        for app in running { add(app.name, app.id, to: appPopup) }
        let current = running.first { app in game.matches(bundleID: app.id) }
        if let current, let item = appPopup.itemArray.first(where: { ($0.representedObject as? String) == current.id }) {
            appPopup.select(item)
        } else if game.appBundleIDs.isEmpty {
            appPopup.selectItem(at: 0)
        } else {
            appPopup.menu?.addItem(.separator())
            add(Self.notRunningTitle(game.appBundleIDs), nil, to: appPopup)
            appPopup.select(appPopup.lastItem)
        }
    }

    private static func notRunningTitle(_ bundleIDs: [String]) -> String {
        var names: [String] = []
        for id in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else { return bundleIDs.joined(separator: ", ") }
        return "\(names.joined(separator: ", ")) (not running)"
    }

    private func buildLanguageMenu(for game: LookupGame) {
        languagePopup.removeAllItems()
        add("Automatic", "", to: languagePopup)
        if !Self.recognitionLanguages.isEmpty { languagePopup.menu?.addItem(.separator()) }
        for language in Self.recognitionLanguages { add(Self.languageName(language), language, to: languagePopup) }
        if game.ocrLanguages.count > 1 {
            languagePopup.menu?.addItem(.separator())
            add(game.ocrLanguages.map(Self.languageName).joined(separator: " + "), nil, to: languagePopup)
            languagePopup.select(languagePopup.lastItem)
        } else if let only = game.ocrLanguages.first,
                  let item = languagePopup.itemArray.first(where: { ($0.representedObject as? String) == only }) {
            languagePopup.select(item)
        } else {
            languagePopup.selectItem(at: 0)
        }
    }

    private func add(_ title: String, _ value: String?, to popup: NSPopUpButton) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = value
        popup.menu?.addItem(item)
    }

    private func apply(_ game: LookupGame) {
        if let i = games.firstIndex(where: { $0.id == game.id }) { games[i] = game } else { games.append(game) }
        applying = true
        store.update(game)
        applying = false
    }

    // Async: reloading while AppKit unwinds the field editor leaves it editing a moved row.
    private func refreshSoon(reloading: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if reloading {
                gamesTable.reloadData()
                sourcesTable.reloadData()
            }
            refresh()
        }
    }

    @objc private func addPreset(_ sender: NSMenuItem) {
        finishEditing()
        guard let raw = sender.representedObject as? String, let preset = LookupPresets.Preset(rawValue: raw) else { return }
        let game = LookupPresets.make(preset)
        store.add(game)
        selectedGame = game.id
        selectedSource = game.sources.first?.id
        refresh()
        Lookup.shared.warmUp()
    }

    @objc private func addCustomGame() {
        finishEditing()
        let game = LookupGame(name: "New Game",
                              sources: [LookupSource(name: "", home: Self.blankHome, searchURL: "")])
        store.add(game)
        selectedGame = game.id
        selectedSource = game.sources.first?.id
        refresh()
        if let row = games.firstIndex(where: { $0.id == game.id }) {
            gamesTable.editColumn(0, row: row, with: nil, select: true)
        }
    }

    @objc private func removeSelectedGame() {
        finishEditing()
        guard let id = selectedGame else { return }
        store.remove(id)
        selectedGame = nil
        selectedSource = nil
        refresh()
    }

    @objc private func commitName() { rename(currentGame, to: nameField.stringValue) }

    private func rename(_ game: LookupGame?, to name: String) {
        guard var game else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != game.name else { refreshSoon(reloading: true); return }
        game.name = trimmed
        apply(game)
        refreshSoon()
    }

    @objc private func setGameApp() {
        guard var game = currentGame, let value = appPopup.selectedItem?.representedObject as? String else { return }
        game.appBundleIDs = value.isEmpty ? [] : [value]
        apply(game)
    }

    @objc private func setLanguage() {
        guard var game = currentGame, let value = languagePopup.selectedItem?.representedObject as? String else { return }
        game.ocrLanguages = value.isEmpty ? [] : [value]
        apply(game)
    }

    @objc private func addSource() {
        finishEditing()
        guard var game = currentGame else { return }
        let source = LookupSource(name: "", home: Self.blankHome, searchURL: "")
        game.sources.append(source)
        selectedSource = source.id
        apply(game)
        refresh()
        sourcesTable.editColumn(1, row: game.sources.count - 1, with: nil, select: true)
    }

    @objc private func removeSource() {
        finishEditing()
        guard var game = currentGame, let id = selectedSource,
              let i = game.sources.firstIndex(where: { $0.id == id }) else { return }
        game.sources.remove(at: i)
        selectedSource = game.sources.indices.contains(i) ? game.sources[i].id : game.sources.last?.id
        apply(game)
        refresh()
    }

    @objc private func moveSourceUp() { moveSource(by: -1) }
    @objc private func moveSourceDown() { moveSource(by: 1) }

    private func moveSource(by delta: Int) {
        finishEditing()
        guard var game = currentGame, let id = selectedSource,
              let i = game.sources.firstIndex(where: { $0.id == id }), game.sources.indices.contains(i + delta) else { return }
        game.sources.swapAt(i, i + delta)
        apply(game)
        refresh()
    }

    private func setSearchURL(_ text: String, of index: Int, in game: LookupGame) {
        var game = game
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = game.sources[index].id
        let previous = game.sources[index].searchURL
        urlProblem = nil
        if !trimmed.isEmpty {
            if !trimmed.contains("{query}") {
                urlProblem = "The URL needs {query} where the text goes"
            } else if LookupSource.origin(of: trimmed) == nil {
                urlProblem = "The URL needs to start with https://"
            }
        }
        guard trimmed != previous else { refreshSoon(reloading: true); return }
        game.sources[index].searchURL = trimmed
        probed[id] = nil
        let generation = (probeGeneration[id] ?? 0) + 1
        probeGeneration[id] = generation
        probing.remove(id)
        guard urlProblem == nil, !trimmed.isEmpty else { apply(game); refreshSoon(reloading: true); return }
        if let origin = LookupSource.origin(of: trimmed) { game.sources[index].home = origin }
        apply(game)
        guard let probe = game.sources[index].searchURL(for: "q") else {
            urlProblem = "The URL needs {query} where the text goes"
            refreshSoon(reloading: true)
            return
        }
        probing.insert(id)
        refreshSoon(reloading: true)
        Task { [weak self] in
            let result = await LookupProbe.detect(searchURL: probe)
            await MainActor.run { self?.finishProbe(id, result, generation: generation, of: trimmed) }
        }
    }

    private func finishProbe(_ sourceID: UUID, _ result: LookupProbe.Result, generation: Int, of url: String) {
        guard probeGeneration[sourceID] == generation else { return }
        probing.remove(sourceID)
        guard var game = games.first(where: { $0.sources.contains { $0.id == sourceID } }),
              let i = game.sources.firstIndex(where: { $0.id == sourceID }),
              game.sources[i].searchURL == url else { return }
        probed[sourceID] = result.pageCount
        game.sources[i].kind = result.kind
        game.sources[i].home = result.home
        game.sources[i].indexURL = result.indexURL
        if game.sources[i].name.isEmpty { game.sources[i].name = game.sources[i].host }
        apply(game)
        refresh()
        if result.indexURL != nil { Lookup.shared.warmUp() }
    }

    @objc private func toggleAdvanced() {
        advanced.isHidden = advancedToggle.state != .on
        onHeightChange?()
    }

    @objc private func setAutoDetect(_ sender: NSButton) { store.autoDetect = sender.state == .on }

    @objc private func setFallbackGame() {
        guard let id = fallbackGame.selectedItem?.representedObject as? UUID else { return }
        store.activeGameID = id
    }

    @objc private func setDestination(_ sender: NSButton) { settings.questOpenInApp = choice(of: sender) == "app" }
    @objc private func setInBackground(_ sender: NSButton) { settings.questOpenInBackground = sender.state == .on }

    @objc private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private struct ImportProblem: LocalizedError {
        let errorDescription: String?
    }

    @objc private func importGame() {
        finishEditing()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a game exported from SlyTerm."
        panel.prompt = "Import"
        // Sheets here and below: a standalone panel or alert opens under this raised window.
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.finishImport(of: url)
        }
    }

    private func finishImport(of url: URL) {
        do {
            var game = try store.importGame(from: Data(contentsOf: url))
            let name = game.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw ImportProblem(errorDescription: "The file does not name the game.")
            }
            game.name = uniqueName(name)
            store.add(game)
            selectedGame = game.id
            selectedSource = game.sources.first?.id
            refresh()
            Lookup.shared.warmUp()
        } catch {
            report("Could not import “\(url.lastPathComponent)”", error)
        }
    }

    private func uniqueName(_ name: String) -> String {
        let taken = Set(store.games.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }

    @objc private func exportGame() {
        finishEditing()
        guard let game = currentGame else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let safe = String(game.name.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        panel.nameFieldStringValue = "\(safe).slyterm-game.json"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.store.exportData(game).write(to: url)
            } catch {
                self.report("Could not export “\(game.name)”", error)
            }
        }
    }

    private func report(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        guard let window = view.window else { alert.runModal(); return }
        // Async: the panel's sheet is still closing, and the window takes another only next turn.
        DispatchQueue.main.async { alert.beginSheetModal(for: window) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === gamesTable ? games.count : shownSources.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        // The cell carries its column: after a reload, a detached field has none to ask for.
        field.identifier = tableColumn?.identifier
        if tableView === gamesTable {
            guard games.indices.contains(row) else { return nil }
            field.stringValue = games[row].name
            field.placeholderString = "Game"
            return field
        }
        guard shownSources.indices.contains(row) else { return nil }
        let source = shownSources[row]
        if tableColumn?.identifier.rawValue == "url" {
            field.stringValue = source.searchURL
            field.placeholderString = "https://example.wiki/w/Special:Search?search={query}"
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.toolTip = source.searchURL.isEmpty ? nil : source.searchURL
        } else {
            field.stringValue = source.name
            field.placeholderString = "Site"
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let table = notification.object as? NSTableView else { return }
        finishEditing()
        if table === gamesTable {
            // Before selectedGame changes: the blank source belongs to the game being left.
            let dropped = dropBlankSources()
            selectedGame = games.indices.contains(table.selectedRow) ? games[table.selectedRow].id : nil
            selectedSource = nil
            urlProblem = nil
            if dropped { refreshSoon(reloading: true) } else { refreshDetail() }
        } else {
            let chosen = shownSources.indices.contains(table.selectedRow) ? shownSources[table.selectedRow].id : nil
            selectedSource = chosen
            urlProblem = nil
            if dropBlankSources(keeping: chosen) { refreshSoon(reloading: true); return }
            refreshDetection()
            refreshAdvanced(currentGame)
        }
    }

    // Buttons never take first responder, so a click acts before the field commits its text; this
    // and editingGameID/editingSourceID keep the text on the game or source it was typed for.
    private func finishEditing() {
        guard let window = view.window else { return }
        guard window.firstResponder !== gamesTable, window.firstResponder !== sourcesTable else { return }
        window.makeFirstResponder(nil)
    }

    @discardableResult
    private func dropBlankSources(keeping keep: UUID? = nil) -> Bool {
        guard var game = currentGame else { return false }
        let blank = Set(game.sources.filter {
            $0.id != keep && $0.name.isEmpty && $0.searchURL.trimmingCharacters(in: .whitespaces).isEmpty
        }.map { $0.id })
        guard !blank.isEmpty else { return false }
        game.sources.removeAll { blank.contains($0.id) }
        if let selected = selectedSource, blank.contains(selected) { selectedSource = keep ?? game.sources.first?.id }
        apply(game)
        return true
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        finishEditing()
        dropBlankSources()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let gameRow = gamesTable.row(for: field)
        if gameRow >= 0 {
            editingGameID = games.indices.contains(gameRow) ? games[gameRow].id : nil
            editingSourceID = nil
            return
        }
        editingGameID = selectedGame
        let sourceRow = sourcesTable.row(for: field)
        editingSourceID = shownSources.indices.contains(sourceRow) ? shownSources[sourceRow].id : nil
    }

    func textDidBeginEditing(_ notification: Notification) {
        editingGameID = selectedGame
        editingSourceID = selectedSource
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let gameID = editingGameID
        let sourceID = editingSourceID
        editingGameID = nil
        editingSourceID = nil
        if field === nameField {
            rename(games.first(where: { $0.id == (gameID ?? selectedGame) }), to: field.stringValue)
            return
        }
        guard let sourceID else {
            rename(games.first(where: { $0.id == gameID }), to: field.stringValue)
            return
        }
        guard let game = games.first(where: { $0.id == gameID }),
              let row = game.sources.firstIndex(where: { $0.id == sourceID }) else { return }
        if field.identifier?.rawValue == "url" {
            setSearchURL(field.stringValue, of: row, in: game)
        } else {
            var edited = game
            edited.sources[row].name = field.stringValue.trimmingCharacters(in: .whitespaces)
            apply(edited)
            refreshSoon(reloading: true)
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        let gameID = editingGameID
        let sourceID = editingSourceID
        editingGameID = nil
        editingSourceID = nil
        guard var game = games.first(where: { $0.id == gameID }) else { return }
        if view === stripPatterns || view === tooltipPatterns {
            let patterns = view.string.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if view === stripPatterns { game.stripPatterns = patterns } else { game.tooltipPatterns = patterns }
            apply(game)
            return
        }
        guard let i = game.sources.firstIndex(where: { $0.id == sourceID }) else { return }
        let text = view.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if view === readerCSS {
            game.sources[i].readerCSS = text.isEmpty ? nil : text
        } else if view === hiddenSelectors {
            game.sources[i].hiddenSelectors = text.isEmpty ? nil : text
        } else {
            return
        }
        apply(game)
    }

    private func isEditing(_ view: NSTextView) -> Bool { view.window?.firstResponder === view }
}
