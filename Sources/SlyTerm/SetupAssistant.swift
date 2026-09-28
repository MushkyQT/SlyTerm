import AppKit

// Unchecked: used only on the main thread; a probe hops back to it before touching anything.
final class SetupAssistant: NSObject, NSWindowDelegate, NSTextFieldDelegate, @unchecked Sendable {
    static let shared = SetupAssistant(snapshot: false)

    var onBeginRecording: (() -> Void)?
    var onEndRecording: (() -> Void)?
    var onClose: (() -> Void)?

    private enum Step: Int, CaseIterable { case welcome, games, shortcuts, done }

    private struct Site {
        let id = UUID()
        var host: String
        var source: LookupSource?
        var status: String
    }

    private struct CustomGame {
        let id = UUID()
        var name: String
        var app: String?
        var sources: [LookupSource]
    }

    private static let width: CGFloat = 560
    private static let height: CGFloat = 500
    private static let margin: CGFloat = 40

    private let window: NSWindow
    private var level: NSWindow.Level = .normal
    private var activation: [NSObjectProtocol] = []
    private var closeReported = true

    private var step = Step.welcome
    private var existing: [LookupGame] = []
    private var seededID: UUID?
    private var playsGames = false
    private var chosen: Set<LookupPresets.Preset> = []
    private var customGames: [CustomGame] = []
    private var formShown = false
    private var sites: [Site] = []
    private var siteProblem: String?
    private var generation = 0
    private var pending: [HotkeyAction: String] = [:]
    private var activityCards = true
    private var captureAllowed: () -> Bool = { CGPreflightScreenCaptureAccess() }

    private let dots = StepDots()
    private let icon = NSImageView()
    private var pages: [Step: NSView] = [:]
    private var back = NSButton()
    private var secondary = NSButton()
    private var primary = NSButton()

    private let gamesScroll = NSScrollView()
    private let gamesDocument = FlippedView()
    private var noGames = NSButton()
    private var yesGames = NSButton()
    private var presetSwitches: [LookupPresets.Preset: NSSwitch] = [:]
    private var presetDetails: [LookupPresets.Preset: NSTextField] = [:]
    private var versionPickers: [(control: NSSegmentedControl, presets: [LookupPresets.Preset])] = []
    private let gameList = NSStackView()
    private let gameListBox = NSBox()
    private var presetRowCount = 0
    private var addAnother = NSButton()
    private let form = NSBox()
    private let nameField = NSTextField(string: "")
    private let siteField = NSTextField(string: "")
    private var addSiteButton = NSButton()
    private let siteMessage = NSTextField(labelWithString: "")
    private let siteList = NSStackView()
    private let appPopup = NSPopUpButton()
    private var formGrid = NSGridView()
    private var addGameButton = NSButton()
    private let captureSection = NSStackView()
    private let captureLabel = NSTextField(labelWithString: "")
    private var allowCapture = NSButton()

    private var recorders: [HotkeyAction: HotkeyRecorderView] = [:]
    private var warnings: [HotkeyAction: NSTextField] = [:]
    private var shortcutRows: [HotkeyAction: [NSGridRow]] = [:]

    private let doneLines = NSGridView()

    private init(snapshot: Bool) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Welcome to SlyTerm"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        guard !snapshot else { return }
        let center = NotificationCenter.default
        activation = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                               queue: .main) { [weak self] _ in self?.window.level = .normal },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                               queue: .main) { [weak self] _ in
                guard let self else { return }
                window.level = level
            },
        ]
    }

    func show(level: NSWindow.Level) {
        self.level = level
        window.level = level
        let opening = !window.isVisible
        if opening {
            var combos: [HotkeyAction: String] = [:]
            for action in HotkeyAction.allCases { combos[action] = Settings.shared.hotkey(action) }
            reset(existing: LookupStore.shared.games, firstRun: !Settings.shared.setupDone,
                  combos: combos, activityCards: Settings.shared.activityCards)
            window.center()
        }
        AppSwitcher.shared.windowOpened(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if opening { window.makeFirstResponder(nil) }
    }

    var isVisible: Bool { window.isVisible }

    private func reset(existing: [LookupGame], firstRun: Bool, combos: [HotkeyAction: String],
                       activityCards: Bool) {
        // A fresh list holds only the Dofus game LookupStore seeds. The first run treats it as not
        // added: kept if Dofus is checked, removed otherwise. Anything else is the user's own.
        let seeded = existing.count == 1 && existing[0].preset == LookupPresets.Preset.dofus.rawValue
        seededID = firstRun && seeded ? existing[0].id : nil
        self.existing = existing.filter { $0.id != seededID }
        playsGames = !self.existing.isEmpty
        chosen = []
        customGames = []
        pending = combos
        self.activityCards = activityCards
        closeReported = false
        generation += 1
        clearForm()
        formShown = false
        refreshGames()
        go(to: .welcome)
    }

    private func build() {
        let content = NSView()
        window.contentView = content
        dots.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dots)

        let area = NSView()
        area.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(area)
        pages = [.welcome: welcomePage(), .games: gamesPage(), .shortcuts: shortcutsPage(),
                 .done: donePage()]
        for page in pages.values {
            page.translatesAutoresizingMaskIntoConstraints = false
            area.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: area.topAnchor),
                page.bottomAnchor.constraint(equalTo: area.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: area.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            ])
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)
        back = button("Back", #selector(goBack))
        secondary = button("", #selector(secondaryPressed))
        primary = button("Continue", #selector(primaryPressed))
        primary.keyEquivalent = "\r"
        for control in [back, secondary, primary] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
            content.addSubview(control)
        }

        NSLayoutConstraint.activate([
            dots.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            dots.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            area.topAnchor.constraint(equalTo: dots.bottomAnchor, constant: 8),
            area.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            area.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: area.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            primary.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: primary.bottomAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: primary.trailingAnchor, constant: 20),
            secondary.trailingAnchor.constraint(equalTo: primary.leadingAnchor, constant: -12),
            secondary.centerYAnchor.constraint(equalTo: primary.centerYAnchor),
            back.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            back.centerYAnchor.constraint(equalTo: primary.centerYAnchor),
        ])
    }

    private func welcomePage() -> NSView {
        icon.image = NSImage(named: "AppIcon") ?? Self.sourceTreeIcon ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let title = label("Welcome to SlyTerm", size: 22, weight: .bold)
        let intro = label("A terminal that floats over whatever you're doing.", size: 13,
                          color: .secondaryLabelColor)
        let bullets = column([
            bullet("square.2.layers.3d", "See through it and click through it"),
            bullet("bell.badge", "See when a coding agent needs you"),
            bullet("text.magnifyingglass",
                   "Look up what's under the pointer and read it in a web tab"),
        ], spacing: 12)
        let stack = column([icon, title, intro, bullets], spacing: 8)
        stack.alignment = .centerX
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(26, after: intro)
        return centered(stack)
    }

    // A build run from .build has no bundle to find AppIcon in; the file it was built from does.
    private static let sourceTreeIcon: NSImage? = NSImage(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/AppIcon.icns"))

    private func bullet(_ symbol: String, _ text: String) -> NSView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        image.contentTintColor = .controlAccentColor
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let row = NSStackView(views: [image, label(text, size: 13)])
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    private func gamesPage() -> NSView {
        noGames = NSButton(radioButtonWithTitle: "No, skip game lookup", target: self,
                           action: #selector(setPlaysGames(_:)))
        yesGames = NSButton(radioButtonWithTitle: "Yes, these:", target: self,
                            action: #selector(setPlaysGames(_:)))

        gameList.orientation = .vertical
        gameList.alignment = .centerX
        gameList.spacing = 0
        var grouped: Set<String> = []
        for preset in LookupPresets.Preset.allCases {
            guard let family = preset.family else {
                addToList(presetRow(preset))
                continue
            }
            guard grouped.insert(family).inserted else { continue }
            addToList(versionRow(family, LookupPresets.Preset.allCases.filter { $0.family == family }))
        }
        presetRowCount = gameList.arrangedSubviews.count
        gameListBox.boxType = .custom
        gameListBox.cornerRadius = 8
        gameListBox.borderColor = .separatorColor
        gameListBox.fillColor = .controlBackgroundColor
        gameListBox.contentViewMargins = .zero
        gameListBox.contentView = gameList
        addAnother = button("Add Another Game…", #selector(revealForm))

        let games = column([gameListBox, addAnother], spacing: 10)
        buildForm()
        let formRow = form

        allowCapture = button("Allow…", #selector(requestCapture))
        allowCapture.controlSize = .small
        captureSection.orientation = .vertical
        captureSection.alignment = .leading
        captureSection.spacing = 4
        captureSection.addArrangedSubview(row([captureLabel, allowCapture]))
        captureSection.addArrangedSubview(
            caption("The lookup reads the text under the pointer from the screen."))

        let stack = column([
            label("Do you play games with SlyTerm open?", size: 17, weight: .semibold),
            column([noGames, yesGames], spacing: 6),
            games, formRow, captureSection,
        ], spacing: 12)
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(18, after: formRow)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: Self.margin, bottom: 20, right: Self.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        form.widthAnchor.constraint(equalToConstant: Self.width - Self.margin * 2).isActive = true
        gameListBox.widthAnchor.constraint(equalToConstant: Self.width - Self.margin * 2).isActive = true

        gamesDocument.translatesAutoresizingMaskIntoConstraints = false
        gamesDocument.addSubview(stack)
        gamesScroll.documentView = gamesDocument
        gamesScroll.hasVerticalScroller = true
        gamesScroll.autohidesScrollers = true
        gamesScroll.drawsBackground = false
        gamesScroll.borderType = .noBorder
        let clip = gamesScroll.contentView
        NSLayoutConstraint.activate([
            gamesDocument.topAnchor.constraint(equalTo: clip.topAnchor),
            gamesDocument.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            gamesDocument.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: gamesDocument.topAnchor),
            stack.leadingAnchor.constraint(equalTo: gamesDocument.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: gamesDocument.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: gamesDocument.bottomAnchor),
        ])
        return gamesScroll
    }

    private func presetRow(_ preset: LookupPresets.Preset) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(togglePreset(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier(preset.rawValue)
        presetSwitches[preset] = toggle
        let row = listRow(preset.title, preset.siteName, trailing: toggle)
        presetDetails[preset] = row.detail
        return row.view
    }

    // A game with versions gets one row and a segment per version, rather than a row each.
    private func versionRow(_ family: String, _ members: [LookupPresets.Preset]) -> NSView {
        let picker = NSSegmentedControl(labels: members.map(Self.shortName), trackingMode: .selectAny,
                                        target: self, action: #selector(toggleVersion(_:)))
        picker.segmentStyle = .rounded
        for (i, member) in members.enumerated() { picker.setToolTip(member.variant, forSegment: i) }
        versionPickers.append((picker, members))
        var sites: [String] = []
        for member in members where !sites.contains(member.siteName) { sites.append(member.siteName) }
        return listRow(family, sites.joined(separator: ", "), trailing: nil, below: picker).view
    }

    private static func shortName(_ preset: LookupPresets.Preset) -> String {
        switch preset {
        case .dofus: return "Dofus 3"
        case .dofusRetro: return "Retro"
        case .wow: return "Retail"
        case .wowClassic: return "Classic"
        case .wowTBC: return "TBC"
        case .wowMoP: return "MoP"
        case .wowForever: return "Forever"
        case .osrs: return "Old School"
        case .rs3: return "RuneScape 3"
        }
    }

    private func listRow(_ title: String, _ detail: String, trailing: NSView?,
                         below: NSView? = nil) -> (view: NSView, detail: NSTextField) {
        let name = label(title, size: 13, weight: .medium)
        let sites = label(detail, size: 11, color: .secondaryLabelColor)
        sites.lineBreakMode = .byTruncatingTail
        sites.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = column([name, sites] + (below.map { [$0] } ?? []), spacing: 2)
        if below != nil { text.setCustomSpacing(8, after: sites) }
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        row.addView(text, in: .leading)
        if let trailing { row.addView(trailing, in: .trailing) }
        return (row, sites)
    }

    private func addToList(_ row: NSView) {
        if !gameList.arrangedSubviews.isEmpty {
            let line = NSBox()
            line.boxType = .separator
            gameList.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: gameList.widthAnchor, constant: -28).isActive = true
        }
        gameList.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: gameList.widthAnchor).isActive = true
    }

    private func buildForm() {
        form.boxType = .primary
        form.titlePosition = .noTitle
        form.contentViewMargins = NSSize(width: 14, height: 12)

        nameField.placeholderString = "Terraria"
        siteField.placeholderString = "terraria.wiki.gg"
        for field in [nameField, siteField] {
            field.delegate = self
            width(field, 220)
        }
        addSiteButton = button("Add", #selector(addSite))
        siteMessage.font = .systemFont(ofSize: 11)
        siteMessage.textColor = .systemOrange
        siteList.orientation = .vertical
        siteList.alignment = .leading
        siteList.spacing = 4
        width(appPopup, 220)
        addGameButton = button("Add Game", #selector(addGame))
        let cancel = button("Cancel", #selector(cancelForm))
        cancel.keyEquivalent = "\u{1b}"

        let grid = NSGridView(views: [
            [label("Name", size: 13), nameField],
            [label("Site", size: 13), row([siteField, addSiteButton])],
            [NSGridCell.emptyContentView, siteMessage],
            [NSGridCell.emptyContentView, siteList],
            [label("Game app", size: 13), appPopup],
            [NSGridCell.emptyContentView,
             caption("Optional. SlyTerm switches to this game when that app is in front.")],
            [NSGridCell.emptyContentView, row([cancel, addGameButton])],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 2).topPadding = -4
        grid.row(at: 5).topPadding = -4
        grid.row(at: 6).topPadding = 4
        for index in [2, 3] { grid.row(at: index).yPlacement = .top }
        formGrid = grid
        form.contentView = grid
        refreshAppPopup(running: [])
    }

    private func shortcutsPage() -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        for action in HotkeyAction.allCases {
            let recorder = HotkeyRecorderView(combo: "")
            recorder.onBeginRecording = { [weak self] in self?.onBeginRecording?() }
            recorder.onEndRecording = { [weak self] in self?.onEndRecording?() }
            recorder.onChange = { [weak self] combo in
                self?.pending[action] = combo
                self?.refreshShortcuts()
            }
            let warning = label("", size: 11, color: .systemOrange)
            recorders[action] = recorder
            warnings[action] = warning
            let main = grid.addRow(with: [label(action.title, size: 13), recorder])
            let note = grid.addRow(with: [NSGridCell.emptyContentView, warning])
            note.topPadding = -4
            shortcutRows[action] = [main, note]
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .none
        grid.yPlacement = .center

        let stack = column([
            label("Shortcuts", size: 17, weight: .semibold),
            label("These work from any app. Click one and press the new shortcut.", size: 13),
            grid,
            button("Restore Defaults", #selector(restoreDefaults)),
            caption("Other shortcuts are in Settings › Shortcuts."),
        ], spacing: 12)
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(18, after: grid)
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[3])
        return topAligned(stack)
    }

    private func donePage() -> NSView {
        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 44, weight: .regular))
        check.contentTintColor = .systemGreen
        doneLines.rowSpacing = 8
        doneLines.columnSpacing = 12
        let stack = column([
            check,
            label("You're set.", size: 22, weight: .bold),
            doneLines,
            label("Everything else is in Settings (⌘,).", size: 13, color: .secondaryLabelColor),
        ], spacing: 10)
        stack.alignment = .centerX
        stack.setCustomSpacing(22, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(22, after: doneLines)
        return centered(stack)
    }

    private func go(to next: Step) {
        window.makeFirstResponder(nil)
        step = next
        for (key, page) in pages { page.isHidden = key != next }
        dots.current = next.rawValue
        back.isHidden = next == .welcome
        switch next {
        case .welcome:
            primary.title = "Set Up"
            secondary.title = "Use Defaults"
        case .games, .shortcuts:
            primary.title = "Continue"
            secondary.title = ""
        case .done:
            primary.title = "Start"
            secondary.title = "Open Settings"
        }
        secondary.isHidden = secondary.title.isEmpty
        if next == .games {
            refreshGames()
            gamesDocument.scroll(.zero)
        }
        if next == .shortcuts { refreshShortcuts() }
        if next == .done { refreshDone() }
    }

    @objc private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }

    @objc private func primaryPressed() {
        if let next = Step(rawValue: step.rawValue + 1) {
            go(to: next)
        } else {
            finish(openingSettings: false)
        }
    }

    @objc private func secondaryPressed() {
        if step == .done { finish(openingSettings: true) } else { window.close() }
    }

    private func finish(openingSettings: Bool) {
        window.makeFirstResponder(nil)
        apply()
        window.close()
        if openingSettings { (NSApp.delegate as? AppDelegate)?.openSettings() }
    }

    // Against the store as it is now: Settings › Lookup may have changed it meanwhile.
    private func apply() {
        let store = LookupStore.shared
        let keepSeeded = playsGames && chosen.contains(.dofus)
        let games = playsGames ? newGames(in: store.games) : []
        for game in games { store.add(game) }
        var removed = false
        if let seededID, !keepSeeded, store.game(withID: seededID) != nil {
            store.remove(seededID)
            removed = true
        }
        if !games.isEmpty { Lookup.shared.warmUp() }
        for action in shownActions where pending[action] != Settings.shared.hotkey(action) {
            Settings.shared.setHotkey(action, pending[action] ?? "")
        }
        Settings.log("setup: \(games.count) game(s) added\(removed ? ", the seeded Dofus removed" : "")")
    }

    private func newGames(in stored: [LookupGame]) -> [LookupGame] {
        let presets = LookupPresets.Preset.allCases.filter { preset in
            chosen.contains(preset) && !stored.contains { $0.preset == preset.rawValue }
        }
        let custom = customGames.filter { game in
            !stored.contains { $0.name.caseInsensitiveCompare(game.name) == .orderedSame }
        }
        return presets.map(LookupPresets.make) + custom.map {
            LookupGame(name: $0.name, appBundleIDs: $0.app.map { [$0] } ?? [], sources: $0.sources)
        }
    }

    // Ends a recording first, which re-registers the hotkeys; otherwise they stay off.
    func windowWillClose(_ notification: Notification) {
        window.makeFirstResponder(nil)
        AppSwitcher.shared.windowClosed(window)
        generation += 1
        guard !closeReported else { return }
        closeReported = true
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if step == .games { refreshCapture() }
    }

    private func isAdded(_ preset: LookupPresets.Preset) -> Bool {
        existing.contains { $0.preset == preset.rawValue }
    }

    private var shownActions: [HotkeyAction] {
        var actions: [HotkeyAction] = [.toggle, .ghost, .panic]
        if playsGames { actions += [.quest, .pick] }
        if activityCards { actions += [.allow, .refuse] }
        return actions
    }

    private func refreshGames() {
        noGames.state = playsGames ? .off : .on
        yesGames.state = playsGames ? .on : .off
        for (preset, toggle) in presetSwitches {
            let added = isAdded(preset)
            toggle.state = added || chosen.contains(preset) ? .on : .off
            toggle.isEnabled = playsGames && !added
            presetDetails[preset]?.stringValue = preset.siteName + (added ? " · already added" : "")
        }
        for (picker, presets) in versionPickers {
            for (i, preset) in presets.enumerated() {
                let added = isAdded(preset)
                picker.setSelected(added || chosen.contains(preset), forSegment: i)
                picker.setEnabled(!added, forSegment: i)
                picker.setToolTip(preset.variant + (added ? ", already added" : ""), forSegment: i)
            }
            picker.isEnabled = playsGames
        }
        gameListBox.alphaValue = playsGames ? 1 : 0.5
        refreshCustomList()
        addAnother.isEnabled = playsGames
        addAnother.isHidden = formShown
        form.isHidden = !formShown
        for control in [nameField, siteField, addSiteButton, appPopup] as [NSControl] {
            control.isEnabled = playsGames
        }
        refreshForm()
        captureSection.isHidden = !playsGames
        refreshCapture()
    }

    private func refreshCustomList() {
        for view in gameList.arrangedSubviews.dropFirst(presetRowCount) { view.removeFromSuperview() }
        for game in existing where game.preset == nil {
            addToList(gameRow(game.name, game.sources, removal: nil))
        }
        for game in customGames {
            addToList(gameRow(game.name, game.sources, removal: game.id))
        }
    }

    private func gameRow(_ name: String, _ sources: [LookupSource], removal: UUID?) -> NSView {
        let hosts = sources.map { $0.host }.joined(separator: ", ")
        guard let removal else { return listRow(name, hosts + " · already added", trailing: nil).view }
        let remove = removeButton(#selector(removeGame(_:)), removal)
        remove.isEnabled = playsGames
        return listRow(name, hosts, trailing: remove).view
    }

    private func refreshForm() {
        siteMessage.stringValue = siteProblem ?? ""
        formGrid.row(at: 2).isHidden = siteProblem == nil
        for view in siteList.arrangedSubviews { view.removeFromSuperview() }
        for site in sites {
            let host = label(site.host, size: 13)
            let status: NSView
            if site.source == nil {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.startAnimation(nil)
                status = row([spinner, label("Checking…", size: 12, color: .secondaryLabelColor)],
                             spacing: 4)
            } else {
                status = label(site.status, size: 12, color: .secondaryLabelColor)
            }
            let remove = removeButton(#selector(removeSite(_:)), site.id)
            remove.isEnabled = playsGames
            let line = NSStackView(views: [host, status, remove])
            line.spacing = 8
            line.alignment = .centerY
            siteList.addArrangedSubview(line)
        }
        formGrid.row(at: 3).isHidden = sites.isEmpty
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        addGameButton.isEnabled = playsGames && !name.isEmpty && !sites.isEmpty
            && sites.allSatisfy { $0.source != nil }
    }

    private func refreshCapture() {
        let allowed = captureAllowed()
        captureLabel.stringValue = "Screen capture: \(allowed ? "allowed" : "not allowed yet")"
        captureLabel.textColor = allowed ? .labelColor : .systemOrange
        allowCapture.isHidden = allowed
    }

    private func refreshAppPopup(running: [(name: String, id: String)]) {
        appPopup.removeAllItems()
        appPopup.addItem(withTitle: "Not set")
        appPopup.lastItem?.representedObject = nil
        if !running.isEmpty { appPopup.menu?.addItem(.separator()) }
        for app in running {
            let item = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
            item.representedObject = app.id
            appPopup.menu?.addItem(item)
        }
        appPopup.selectItem(at: 0)
    }

    @objc private func setPlaysGames(_ sender: NSButton) {
        playsGames = sender === yesGames
        refreshGames()
    }

    @objc private func togglePreset(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue, let preset = LookupPresets.Preset(rawValue: raw)
        else { return }
        if sender.state == .on { chosen.insert(preset) } else { chosen.remove(preset) }
    }

    @objc private func toggleVersion(_ sender: NSSegmentedControl) {
        guard let presets = versionPickers.first(where: { $0.control === sender })?.presets else { return }
        for (i, preset) in presets.enumerated() where !isAdded(preset) {
            if sender.isSelected(forSegment: i) { chosen.insert(preset) } else { chosen.remove(preset) }
        }
    }

    @objc private func revealForm() {
        formShown = true
        refreshAppPopup(running: LookupPane.runningApps())
        refreshGames()
        window.makeFirstResponder(nameField)
        gamesDocument.layoutSubtreeIfNeeded()
        form.scrollToVisible(form.bounds)
    }

    // Drops the half-made game; a check still running for one of its sites is ignored.
    @objc private func cancelForm() {
        generation += 1
        clearForm()
        formShown = false
        window.makeFirstResponder(nil)
        refreshGames()
    }

    @objc private func addSite() {
        let text = siteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let (origin, probe) = Self.site(from: text), let host = LookupSource.bareHost(of: origin)
        else {
            siteProblem = "Type an address like terraria.wiki.gg"
            refreshForm()
            return
        }
        guard !sites.contains(where: { $0.host == host }) else {
            siteProblem = "That site is already in the list"
            refreshForm()
            return
        }
        siteProblem = nil
        siteField.stringValue = ""
        let site = Site(host: host, source: nil, status: "")
        sites.append(site)
        refreshForm()
        let current = generation
        Task {
            let result = await LookupProbe.detect(searchURL: probe)
            DispatchQueue.main.async { [weak self] in
                self?.finishProbe(site.id, host: host, result, generation: current)
            }
        }
    }

    private func finishProbe(_ id: UUID, host: String, _ result: LookupProbe.Result, generation: Int) {
        guard generation == self.generation, let i = sites.firstIndex(where: { $0.id == id }) else { return }
        let (source, status) = Self.source(for: host, result)
        sites[i].source = source
        sites[i].status = status
        refreshForm()
    }

    // Accepts host, host/path or an http(s) address. The path goes to the probe only, where it
    // picks a Wowhead database or a DofusDB language.
    static func site(from text: String) -> (origin: URL, probe: URL)? {
        guard !text.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = text.lowercased()
        let full: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            full = text
        } else if lower.contains("://") {
            return nil
        } else {
            full = "https://" + text
        }
        guard let origin = LookupSource.origin(of: full), let host = origin.host, host.contains("."),
              var components = URLComponents(string: full) else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/search"
        components.query = "q=q"
        components.fragment = nil
        guard let probe = components.url else { return nil }
        return (origin, probe)
    }

    static func source(for host: String, _ result: LookupProbe.Result) -> (LookupSource, String) {
        var home = result.home.absoluteString
        while home.hasSuffix("/") { home.removeLast() }
        let searchURL: String
        var status = result.kind.title
        switch result.kind {
        case .mediaWiki where result.searchURL != nil:
            searchURL = result.searchURL ?? ""
            status = "Wiki" + (result.pageCount.map { ", \(count($0)) pages" } ?? "")
        case .wowhead:
            searchURL = "\(home)/search?q={query}"
        case .dofusDB:
            let sample = LookupPresets.dofusDB(language: "en")
            let path = sample.searchURL.replacingOccurrences(of: sample.home.absoluteString, with: "")
            searchURL = home + path
        case .weebly:
            searchURL = "\(home)/apps/search?q={query}"
            if let pages = result.pageCount { status += ", \(count(pages)) pages listed" }
        case .website, .mediaWiki:
            searchURL = "https://duckduckgo.com/?q=site%3A\(host)+{query}"
            status = "Searched through DuckDuckGo"
            if let pages = result.pageCount { status += ", \(count(pages)) pages listed" }
        }
        let source = LookupSource(name: host, home: result.home, searchURL: searchURL,
                                  kind: result.kind, indexURL: result.indexURL)
        return (source, status)
    }

    private static func count(_ number: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: number), number: .decimal)
    }

    @objc private func removeSite(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        sites.removeAll { $0.id == id }
        refreshForm()
    }

    @objc private func addGame() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let sources = sites.compactMap { $0.source }
        guard !name.isEmpty, !sources.isEmpty else { return }
        let taken = existing.map(\.name) + customGames.map(\.name) + chosen.map(\.title)
        guard !taken.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            siteProblem = "There is already a game named \(name)"
            refreshForm()
            return
        }
        customGames.append(CustomGame(name: name, app: appPopup.selectedItem?.representedObject as? String,
                                      sources: sources))
        clearForm()
        refreshGames()
        window.makeFirstResponder(nameField)
    }

    private func clearForm() {
        nameField.stringValue = ""
        siteField.stringValue = ""
        sites = []
        siteProblem = nil
        appPopup.selectItem(at: 0)
    }

    @objc private func removeGame(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        customGames.removeAll { $0.id == id }
        refreshGames()
    }

    @objc private func requestCapture() {
        // Only asks for the permission; nothing is captured here.
        CGRequestScreenCaptureAccess()
        refreshCapture()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === nameField { refreshForm() }
        if notification.object as? NSTextField === siteField, siteProblem != nil {
            siteProblem = nil
            refreshForm()
        }
    }

    // Return in a form field acts on the form, and a recorder takes it as a shortcut: the default
    // button would win over both and leave the step. Checked on every update, since a field gets
    // focus without any editing notification.
    func windowDidUpdate(_ notification: Notification) {
        let responder = window.firstResponder
        let delegate = (responder as? NSTextView)?.delegate
        let inForm = delegate === nameField || delegate === siteField
        let key = inForm || responder is HotkeyRecorderView ? "" : "\r"
        if primary.keyEquivalent != key { primary.keyEquivalent = key }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if control === siteField, !siteField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            addSite()
        } else if control === siteField, !addGameButton.isEnabled {
            return true
        } else if addGameButton.isEnabled {
            addGame()
        } else {
            window.makeFirstResponder(siteField)
        }
        return true
    }

    private func refreshShortcuts() {
        let shown = Set(shownActions)
        let combos = HotkeyAction.allCases.map { ($0, pending[$0] ?? "") }
        for action in HotkeyAction.allCases {
            recorders[action]?.combo = pending[action] ?? ""
            let warning = shown.contains(action) ? action.warning(among: combos) : nil
            warnings[action]?.stringValue = warning ?? ""
            shortcutRows[action]?[0].isHidden = !shown.contains(action)
            shortcutRows[action]?[1].isHidden = warning == nil
        }
    }

    @objc private func restoreDefaults() {
        window.makeFirstResponder(nil)
        for action in shownActions { pending[action] = action.defaultCombo }
        refreshShortcuts()
    }

    private func refreshDone() {
        while doneLines.numberOfRows > 0 { doneLines.removeRow(at: 0) }
        var lines: [(HotkeyAction, String)] = [
            (.toggle, "shows or hides SlyTerm"),
            (.ghost, "lets clicks through to what's behind"),
            (.panic, "covers the screen with an opaque terminal"),
        ]
        if playsGames { lines.append((.quest, "looks up what's under the pointer")) }
        if activityCards { lines.append((.allow, "allows what a coding agent asks")) }
        for (action, text) in lines {
            guard let combo = pending[action], !combo.isEmpty else { continue }
            doneLines.addRow(with: [label(KeyCombo.pretty(combo), size: 13, weight: .semibold),
                                    label(text, size: 13)])
        }
        if doneLines.numberOfColumns > 0 { doneLines.column(at: 0).xPlacement = .trailing }
        doneLines.rowAlignment = .firstBaseline
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 400
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func removeButton(_ action: Selector, _ id: UUID) -> NSButton {
        let image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove")
            ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        return button
    }

    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = spacing
        return stack
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    @discardableResult
    private func width<V: NSView>(_ view: V, _ points: CGFloat) -> V {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: points).isActive = true
        return view
    }

    private func centered(_ content: NSView) -> NSView {
        let page = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: page.centerYAnchor, constant: -6),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: Self.margin),
        ])
        return page
    }

    private func topAligned(_ content: NSView) -> NSView {
        let page = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: page.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: Self.margin),
            content.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -Self.margin),
        ])
        return page
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class StepDots: NSView {
    var current = 0 { didSet { needsDisplay = true } }
    private let count = 4
    private let size: CGFloat = 7
    private let gap: CGFloat = 9

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(count) * size + CGFloat(count - 1) * gap, height: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        for index in 0..<count {
            let rect = NSRect(x: CGFloat(index) * (size + gap), y: 0, width: size, height: size)
            (index == current ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

extension SetupAssistant {
    static func runSnapshotCLI(_ args: [String]) -> Bool {
        guard args.count >= 2, args[1] == "--setup-snapshot" else { return false }
        guard args.count >= 3, !args[2].hasPrefix("--") else {
            print("usage: --setup-snapshot <out.png> [--step 1-4]")
            return true
        }
        snapshot(args)
        return true
    }

    private static func snapshot(_ args: [String]) {
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: args[2])
        var only: Int?
        if let i = args.firstIndex(of: "--step") {
            only = args.indices.contains(i + 1) ? Int(args[i + 1]) ?? 0 : 0
        }
        if let only, !(1...Step.allCases.count).contains(only) {
            print("usage: --setup-snapshot <out.png> [--step 1-4]")
            return
        }
        var frames: [(String, NSImage)] = []
        func add(_ caption: String, _ step: Step, _ prepare: (SetupAssistant) -> Void = { _ in }) {
            guard only == nil || only == step.rawValue + 1 else { return }
            let assistant = SetupAssistant(snapshot: true)
            assistant.captureAllowed = { false }
            var combos: [HotkeyAction: String] = [:]
            for action in HotkeyAction.allCases { combos[action] = action.defaultCombo }
            assistant.reset(existing: [], firstRun: true, combos: combos, activityCards: true)
            prepare(assistant)
            assistant.go(to: step)
            if let image = assistant.render(fitting: step == .games) { frames.append((caption, image)) }
        }
        add("Welcome", .welcome)
        add("Games, no", .games)
        add("Games, yes, with another game being added", .games) { assistant in
            assistant.playsGames = true
            assistant.chosen = [.wow, .osrs]
            assistant.formShown = true
            assistant.refreshAppPopup(running: [])
            assistant.nameField.stringValue = "Terraria"
            assistant.sites = [Site(host: "terraria.wiki.gg", source: LookupSource(
                name: "terraria.wiki.gg", home: URL(string: "https://terraria.wiki.gg")!,
                searchURL: "https://terraria.wiki.gg/wiki/Special:Search?search={query}",
                kind: .mediaWiki), status: "Wiki, 5,210 pages")]
        }
        add("Shortcuts, with games", .shortcuts) { $0.playsGames = true }
        add("Done, with games", .done) { $0.playsGames = true }
        if only != nil, frames.count > 1 { frames = [frames[frames.count - 1]] }
        write(frames, to: output)
    }

    // The window is never shown: cacheDisplay needs its backing store, which an unparented view
    // lacks. The frame view draws the title bar too.
    private func render(fitting: Bool) -> NSImage? {
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        if fitting {
            let extra = max(0, gamesDocument.fittingSize.height - gamesScroll.contentView.bounds.height)
            window.setContentSize(NSSize(width: Self.width, height: Self.height + extra))
        }
        guard let frame = window.contentView?.superview else { return nil }
        frame.layoutSubtreeIfNeeded()
        // The first pass makes the scroll view layer-backed, which clears what it cached.
        var rep: NSBitmapImageRep?
        for _ in 0..<2 {
            rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
            if let rep { frame.cacheDisplay(in: frame.bounds, to: rep) }
        }
        guard let rep else { return nil }
        let image = NSImage(size: frame.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func write(_ frames: [(caption: String, image: NSImage)], to output: URL) {
        guard !frames.isEmpty else { return }
        let margin: CGFloat = 24, captionHeight: CGFloat = 22, columns = min(3, frames.count)
        let cell = NSSize(width: frames.map { $0.image.size.width }.max() ?? 0,
                          height: frames.map { $0.image.size.height }.max() ?? 0)
        let rows = (frames.count + columns - 1) / columns
        let size = NSSize(width: CGFloat(columns) * (cell.width + margin) + margin,
                          height: CGFloat(rows) * (cell.height + captionHeight + margin) + margin)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 0.62, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black,
        ]
        for (index, frame) in frames.enumerated() {
            let column = CGFloat(index % columns), row = CGFloat(index / columns)
            let top = size.height - margin - row * (cell.height + captionHeight + margin)
            let x = margin + column * (cell.width + margin)
            (frame.caption as NSString).draw(at: NSPoint(x: x, y: top - 16), withAttributes: attributes)
            let image = frame.image
            image.draw(in: NSRect(x: x, y: top - captionHeight - image.size.height,
                                  width: image.size.width, height: image.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: output)
            print("wrote \(output.path) (\(Int(size.width))x\(Int(size.height)))")
        } catch {
            print("cannot write \(output.path): \(error.localizedDescription)")
        }
    }
}
