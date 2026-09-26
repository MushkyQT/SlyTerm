import AppKit

final class TeleportPicker {
    static let shared = TeleportPicker()

    private var panel: TeleportPanel?
    private var content: TeleportPickerView?
    private var rescan: Timer?
    private var generation = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = panel ?? makePanel()
        guard let content else { return }
        generation += 1
        content.setRunning(false)
        if !panel.isVisible {
            content.update([], loading: true)
            size(panel, to: content)
            centre(panel)
        }
        panel.makeKeyAndOrderFront(nil)
        if !panel.isKeyWindow {
            // The panel can be refused key status; activate so the search field takes typing.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        panel.makeFirstResponder(content.searchField)
        scan()
        rescan?.invalidate()
        rescan = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.scan() }
    }

    func hide() {
        generation += 1
        rescan?.invalidate()
        rescan = nil
        panel?.orderOut(nil)
        if let controller = TeleportEngine.shared.controller, controller.isVisible, !controller.isGhost {
            controller.focusTerminal()
        }
    }

    func toggle() { isVisible ? hide() : show() }

    private func makePanel() -> TeleportPanel {
        let view = TeleportPickerView(frame: NSRect(x: 0, y: 0, width: TeleportPickerView.width, height: 360))
        let panel = TeleportPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = Settings.shared.dialogLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view

        panel.keyHandler = { [weak self] event in self?.handle(event) ?? false }
        view.onRowActivated = { [weak self] in self?.run(.primary) }
        view.onSelectionChange = { [weak self] in self?.content?.refreshFooter() }
        view.onPrimary = { [weak self] in self?.run(.primary) }
        view.onSecondary = { [weak self] in self?.run(.secondary) }
        view.onHeightChange = { [weak self] in
            guard let self, let panel = self.panel, let content = self.content else { return }
            self.size(panel, to: content)
        }
        self.panel = panel
        content = view
        return panel
    }

    private func centre(_ panel: NSPanel) {
        let overlay = TeleportEngine.shared.controller?.main
        let box = overlay?.isVisible == true ? overlay!.frame
                                             : (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var frame = panel.frame
        frame.origin = NSPoint(x: box.midX - frame.width / 2, y: box.midY - frame.height / 2)
        panel.setFrame(TeleportPicker.onScreen(frame), display: true)
    }

    private func size(_ panel: NSPanel, to content: TeleportPickerView) {
        var frame = panel.frame
        let room = TeleportPicker.screen(under: frame)?.visibleFrame
            .insetBy(dx: TeleportPicker.margin, dy: TeleportPicker.margin).height
        let height = min(content.fittedHeight, room ?? .infinity)
        guard abs(height - frame.height) > 0.5 else { return }
        frame.origin.y -= (height - frame.height) / 2
        frame.size.height = height
        panel.setFrame(TeleportPicker.onScreen(frame), display: true)
        panel.invalidateShadow()
    }

    private static let margin: CGFloat = 8

    // AppKit only keeps a window's title bar on screen, and this borderless panel has none.
    private static func onScreen(_ frame: NSRect) -> NSRect {
        guard let visible = screen(under: frame)?.visibleFrame else { return frame }
        return fit(frame, in: visible.insetBy(dx: margin, dy: margin))
    }

    private static func fit(_ frame: NSRect, in room: NSRect) -> NSRect {
        var frame = frame
        frame.size.width = min(frame.width, room.width)
        frame.size.height = min(frame.height, room.height)
        frame.origin.x = min(max(frame.minX, room.minX), room.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, room.minY), room.maxY - frame.height)
        return frame
    }

    private static func screen(under frame: NSRect) -> NSScreen? {
        func area(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(frame)
            return shared.isEmpty ? 0 : shared.width * shared.height
        }
        if let best = NSScreen.screens.max(by: { area($0) < area($1) }), area(best) > 0 { return best }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private enum Which { case primary, secondary }

    private func handle(_ event: NSEvent) -> Bool {
        guard let content, !event.modifierFlags.contains(.command) else { return false }
        switch event.keyCode {
        case 53: hide(); return true                                    // Esc
        case 126: content.moveSelection(by: -1); return true            // ↑
        case 125: content.moveSelection(by: 1); return true             // ↓
        case 36, 76:                                                    // Return, Enter
            run(event.modifierFlags.contains(.option) ? .secondary : .primary)
            return true
        default: return false
        }
    }

    private func run(_ which: Which) {
        guard let content, !content.running, let candidate = content.selectedCandidate else { return }
        let action: TeleportAction?
        switch which {
        case .primary: action = TeleportAction.primary(for: candidate)
        case .secondary: action = TeleportAction.secondary(for: candidate)
        }
        guard let action else { return }
        content.setRunning(true)
        Settings.log("teleport: \(action.title) on \(candidate.id)")
        TeleportEngine.shared.perform(action, on: candidate, closeSource: content.closesSource) { [weak self] result in
            guard let self else { return }
            self.content?.setRunning(false)
            switch result {
            case .success:
                self.hide()
            case .failure(.declined):
                break
            case .failure(let error):
                MainActor.assumeIsolated { Toast.shared.show(error.message, near: self.toastPoint, tint: .systemOrange) }
            }
        }
    }

    private var toastPoint: NSPoint {
        guard let frame = panel?.frame else { return NSEvent.mouseLocation }
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private func scan() {
        let current = generation
        DispatchQueue.global(qos: .utility).async {
            let found = SessionDiscovery.scan()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.generation == current, self.isVisible else { return }
                self.content?.update(found, loading: false)
                if let panel = self.panel, let content = self.content { self.size(panel, to: content) }
            }
        }
    }

    static func runSnapshotCLI(_ args: [String]) -> Bool {
        guard args.count >= 3, args[1] == "--picker-snapshot" else { return false }
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: args[2])
        let empty = URL(fileURLWithPath: output.deletingPathExtension().path + "-empty.png")
        write(render(SnapshotSamples.candidates), to: output)
        write(render([]), to: empty)
        return true
    }

    // Rows are drawn in a second pass: the scroll view's first draw makes the tree layer-backed
    // in the middle of cacheDisplay, which clears everything cached so far.
    private static func render(_ candidates: [TeleportCandidate]) -> NSImage? {
        let view = TeleportPickerView(frame: NSRect(x: 0, y: 0, width: TeleportPickerView.width, height: 360))
        view.update(candidates, loading: false)
        view.setFrameSize(NSSize(width: TeleportPickerView.width, height: view.fittedHeight))
        // cacheDisplay needs a window's backing store; an unparented view has none.
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        let list = view.snapshotList()
        view.layoutSubtreeIfNeeded()
        guard let base = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: base)

        guard let out = transparentBitmap(view.bounds.size) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        base.draw(in: view.bounds)
        // Cells draw straight into this context: cacheDisplay would first fill each bitmap with the
        // window background, a pale band across the list.
        for row in list {
            if row.selected { PickerRowView.drawHighlight(in: row.frame) }
            NSGraphicsContext.saveGraphicsState()
            let move = NSAffineTransform()
            move.translateX(by: row.frame.minX, yBy: row.frame.minY)
            move.concat()
            row.cell.draw(row.cell.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(out)
        return image
    }

    private static func transparentBitmap(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    private static func write(_ image: NSImage?, to output: URL) {
        guard let image else { return }
        let margin: CGFloat = 20
        let width = image.size.width + margin * 2, height = image.size.height + margin * 2
        guard let rep = transparentBitmap(NSSize(width: width, height: height)) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 0.32, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: margin, y: margin, width: image.size.width, height: image.size.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: output)
            print("wrote \(output.path) (\(Int(width))x\(Int(height)))")
        } catch {
            print("cannot write \(output.path): \(error.localizedDescription)")
        }
    }
}

private final class TeleportPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // While an input method is composing, the field editor needs the arrows and Return.
        let composing = (firstResponder as? NSTextView)?.hasMarkedText() ?? false
        if event.type == .keyDown, !composing, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }
}

private final class TeleportPickerView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let width: CGFloat = 560

    fileprivate enum Row {
        case group(String)
        case candidate(TeleportCandidate)
    }

    let searchField = NSSearchField()
    private let titleLabel = NSTextField(labelWithString: "Bring In a Session")
    private let subtitleLabel = NSTextField(labelWithString: "Claude Code conversations and terminal tabs open in other apps")
    private let scrollView = NSScrollView()
    private let table = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let closeSource = NSButton(checkboxWithTitle: "Close the tab it came from", target: nil, action: nil)
    private let primaryButton = PickerButton(title: "Bring In", target: nil, action: nil)
    private let secondaryButton = PickerButton(title: "Copy Here", target: nil, action: nil)

    private var all: [TeleportCandidate] = []
    private var rows: [Row] = []
    private var loading = true

    var onRowActivated: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onHeightChange: (() -> Void)?

    private static let padding: CGFloat = 16
    private static let rowHeight: CGFloat = 46
    private static let groupHeight: CGFloat = 26
    private static let maxListHeight = rowHeight * 8 + groupHeight * 2
    private static let minListHeight: CGFloat = 132

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        place()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }


    private func build() {
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.95)
        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.5)

        searchField.placeholderString = "Filter by name, folder or app"
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(queryChanged)

        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))

        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.drawsBackground = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.35)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3

        closeSource.font = .systemFont(ofSize: 11.5)
        closeSource.target = self
        closeSource.action = #selector(toggleCloseSource)
        closeSource.state = Settings.shared.teleportClosesSource ? .on : .off

        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryPressed)
        primaryButton.target = self
        primaryButton.action = #selector(primaryPressed)
        primaryButton.fill = TeleportPickerView.accent

        for view in [titleLabel, subtitleLabel, searchField, scrollView, statusLabel, closeSource, secondaryButton, primaryButton] {
            addSubview(view)
        }
        refreshFooter()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    private func place() {
        let pad = TeleportPickerView.padding
        let width = bounds.width - pad * 2
        var y = bounds.maxY - pad

        let titleHeight = ceil(titleLabel.fittingSize.height)
        y -= titleHeight
        titleLabel.frame = NSRect(x: pad, y: y, width: width, height: titleHeight)
        let subtitleHeight = ceil(subtitleLabel.fittingSize.height)
        y -= subtitleHeight + 2
        subtitleLabel.frame = NSRect(x: pad, y: y, width: width, height: subtitleHeight)

        y -= 12 + TeleportPickerView.searchHeight
        searchField.frame = NSRect(x: pad, y: y, width: width, height: TeleportPickerView.searchHeight)

        let footerHeight = TeleportPickerView.footerHeight
        let listTop = y - 10
        let listBottom = pad + footerHeight + 12
        let listHeight = max(0, listTop - listBottom)
        scrollView.frame = NSRect(x: pad - 4, y: listBottom, width: width + 8, height: listHeight)
        statusLabel.frame = NSRect(x: pad + 24, y: listBottom + listHeight / 2 - 20,
                                   width: width - 48, height: 40)

        var x = bounds.maxX - pad
        for button in [primaryButton, secondaryButton] {
            let size = button.fittingSize
            x -= size.width
            button.frame = NSRect(x: x, y: pad + (footerHeight - size.height) / 2, width: size.width, height: size.height)
            x -= 8
        }
        let checkHeight = ceil(closeSource.fittingSize.height)
        closeSource.frame = NSRect(x: pad, y: pad + (footerHeight - checkHeight) / 2,
                                   width: max(0, x - pad), height: checkHeight)
    }

    private static let searchHeight: CGFloat = 24
    private static let footerHeight: CGFloat = 26

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === titleLabel || hit === subtitleLabel || hit === statusLabel ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    var fittedHeight: CGFloat {
        let pad = TeleportPickerView.padding
        let content = rows.reduce(CGFloat(0)) { $0 + height(of: $1) }
        let list = min(TeleportPickerView.maxListHeight, max(TeleportPickerView.minListHeight, content))
        let header = ceil(titleLabel.fittingSize.height) + 2 + ceil(subtitleLabel.fittingSize.height)
        return pad + header + 12 + TeleportPickerView.searchHeight + 10 + list + 12
            + TeleportPickerView.footerHeight + pad
    }

    private func height(of row: Row) -> CGFloat {
        switch row {
        case .group: return TeleportPickerView.groupHeight
        case .candidate: return TeleportPickerView.rowHeight
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        TerminalTab.backgroundColor.withAlphaComponent(0.96).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
        let y = TeleportPickerView.padding + TeleportPickerView.footerHeight + 6
        NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
        NSRect(x: 1, y: y, width: bounds.width - 2, height: 1).fill()
    }

    func update(_ found: [TeleportCandidate], loading: Bool) {
        self.loading = loading
        all = found
        rebuild()
    }

    private func rebuild() {
        let keep = selectedCandidate?.id
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = query.isEmpty ? all : all.filter { matches($0, query) }
        let before = rows.count
        rows = []
        let claude = visible.filter { if case .claude = $0 { return true } else { return false } }
        let shells = visible.filter { if case .shell = $0 { return true } else { return false } }
        if !claude.isEmpty {
            rows.append(.group("Claude Code"))
            rows.append(contentsOf: claude.map { Row.candidate($0) })
        }
        if !shells.isEmpty {
            rows.append(.group("Terminal tabs"))
            rows.append(contentsOf: shells.map { Row.candidate($0) })
        }
        table.reloadData()

        if let keep, let index = rows.firstIndex(where: { if case .candidate(let c) = $0 { return c.id == keep } else { return false } }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if let first = firstSelectable(from: 0, by: 1) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            table.scrollRowToVisible(first)
        }

        let empty = rows.isEmpty
        statusLabel.isHidden = !empty
        scrollView.isHidden = empty
        if empty {
            statusLabel.stringValue = loading
                ? "Looking…"
                : (query.isEmpty
                    ? "Nothing to bring in. Claude Code conversations and shell tabs running in other terminals appear here."
                    : "Nothing matches “\(searchField.stringValue)”.")
        }
        refreshFooter()
        if rows.count != before { onHeightChange?() }
    }

    private func matches(_ candidate: TeleportCandidate, _ query: String) -> Bool {
        let folder = (candidate.cwd as NSString).abbreviatingWithTildeInPath
        return candidate.title.lowercased().contains(query)
            || folder.lowercased().contains(query)
            || candidate.host.displayName.lowercased().contains(query)
    }

    var selectedCandidate: TeleportCandidate? {
        guard rows.indices.contains(table.selectedRow), case .candidate(let c) = rows[table.selectedRow] else { return nil }
        return c
    }

    var closesSource: Bool { closeSource.isEnabled && closeSource.state == .on }

    func refreshFooter() {
        let candidate = selectedCandidate
        let primary = candidate.map { TeleportAction.primary(for: $0) }
        let secondary = candidate.flatMap { TeleportAction.secondary(for: $0) }
        primaryButton.setTitle(primary?.title ?? "Bring In", enabled: candidate != nil && !running)
        secondaryButton.setTitle(secondary?.title ?? "", enabled: !running)
        secondaryButton.isHidden = secondary == nil
        closeSource.isEnabled = candidate?.host.canCloseSource ?? false
        closeSource.state = closeSource.isEnabled && Settings.shared.teleportClosesSource ? .on : .off
        place()
    }

    // Not controlAccentColor: the offscreen snapshot does not read the user's accent and gets grey.
    static let accent = NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.94, alpha: 1)

    private static let centred: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()

    private(set) var running = false
    func setRunning(_ running: Bool) {
        self.running = running
        refreshFooter()
    }

    func moveSelection(by delta: Int) {
        let from = table.selectedRow < 0 ? (delta > 0 ? -1 : rows.count) : table.selectedRow
        guard let next = firstSelectable(from: from + delta, by: delta) else { return }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func firstSelectable(from start: Int, by delta: Int) -> Int? {
        var i = start
        let step = delta == 0 ? 1 : (delta > 0 ? 1 : -1)
        while rows.indices.contains(i) {
            if case .candidate = rows[i] { return i }
            i += step
        }
        return nil
    }

    func snapshotList() -> [(cell: NSView, frame: NSRect, selected: Bool)] {
        guard !rows.isEmpty else { return [] }
        scrollView.isHidden = true
        let list = scrollView.frame
        var result: [(NSView, NSRect, Bool)] = []
        var y = list.maxY
        for (index, row) in rows.enumerated() {
            let height = height(of: row)
            y -= height
            guard y >= list.minY - 1 else { break }
            let frame = NSRect(x: list.minX, y: y, width: list.width, height: height)
            let cell: NSView
            switch row {
            case .group(let title):
                let group = PickerGroupCell(frame: NSRect(origin: .zero, size: frame.size))
                group.title = title
                cell = group
            case .candidate(let candidate):
                let view = PickerCandidateCell(frame: NSRect(origin: .zero, size: frame.size))
                view.candidate = candidate
                cell = view
            }
            result.append((cell, frame, index == table.selectedRow))
        }
        return result
    }

    @objc private func queryChanged() { rebuild() }
    @objc private func primaryPressed() { onPrimary?() }
    @objc private func secondaryPressed() { onSecondary?() }
    // Group headers cannot be selected, so a double-click on one would otherwise run the primary
    // action on whatever row was left highlighted.
    @objc private func rowDoubleClicked() {
        let clicked = table.clickedRow
        guard rows.indices.contains(clicked), case .candidate = rows[clicked], clicked == table.selectedRow else { return }
        onRowActivated?()
    }
    @objc private func toggleCloseSource(_ sender: NSButton) {
        Settings.shared.teleportClosesSource = sender.state == .on
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) ? height(of: rows[row]) : TeleportPickerView.rowHeight
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true } else { return false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .candidate = rows[row] { return true } else { return false }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PickerRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title):
            let view = PickerGroupCell()
            view.title = title
            return view
        case .candidate(let candidate):
            let view = PickerCandidateCell()
            view.candidate = candidate
            return view
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onSelectionChange?() }
}

// Drawn by hand: `bezelColor` is ignored for a rounded button in dark mode.
private final class PickerButton: NSButton {
    var fill = NSColor(calibratedWhite: 1, alpha: 0.13)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        setTitle(title, enabled: true)
    }

    func setTitle(_ text: String, enabled: Bool) {
        isEnabled = enabled
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: enabled ? 0.98 : 0.35),
            .paragraphStyle: style,
        ])
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(super.intrinsicContentSize.width) + 26, height: 26)
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        (isEnabled ? fill : fill.withAlphaComponent(0.07)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        super.draw(dirtyRect)
    }
}

private final class PickerRowView: NSTableRowView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }
    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        PickerRowView.drawHighlight(in: bounds)
    }

    static func drawHighlight(in bounds: NSRect) {
        NSColor(calibratedWhite: 1, alpha: 0.13).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

private final class PickerGroupCell: NSView {
    var title = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.38),
            .kern: 0.6,
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 10, y: bounds.midY - size.height / 2 - 1), withAttributes: attrs)
    }
}

private final class PickerCandidateCell: NSView {
    var candidate: TeleportCandidate? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let candidate else { return }
        let icon = NSRect(x: 12, y: bounds.midY - 12, width: 24, height: 24)
        if let image = candidate.host.icon {
            image.draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            drawSymbol("terminal", in: icon, color: NSColor(calibratedWhite: 1, alpha: 0.55), pointSize: 17)
        }

        let badge = PickerCandidateCell.badge(for: candidate)
        let badgeFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let badgeSize = (badge.text as NSString).size(withAttributes: [.font: badgeFont])
        let badgeRect = NSRect(x: bounds.maxX - 12 - ceil(badgeSize.width) - 16, y: bounds.midY - 9,
                               width: ceil(badgeSize.width) + 16, height: 18)
        badge.tint.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 9, yRadius: 9).fill()
        (badge.text as NSString).draw(at: NSPoint(x: badgeRect.minX + 8, y: badgeRect.midY - badgeSize.height / 2),
                                      withAttributes: [.font: badgeFont, .foregroundColor: badge.tint])

        let left = icon.maxX + 10
        let width = max(0, badgeRect.minX - 10 - left)
        let clip = NSMutableParagraphStyle()
        clip.lineBreakMode = .byTruncatingTail
        (candidate.title as NSString).draw(in: NSRect(x: left, y: bounds.midY + 1, width: width, height: 17),
                                           withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.95),
                                                            .paragraphStyle: clip])
        let subtitle = PickerCandidateCell.subtitle(for: candidate)
        (subtitle as NSString).draw(in: NSRect(x: left, y: bounds.midY - 15, width: width, height: 15),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                                     .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.48),
                                                     .paragraphStyle: clip])
    }

    static func subtitle(for candidate: TeleportCandidate) -> String {
        let folder = (candidate.cwd as NSString).abbreviatingWithTildeInPath
        return [folder, candidate.host.displayName, started(candidate.startedAt)].joined(separator: "  ·  ")
    }

    private static func started(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 90 { return "started just now" }
        if seconds < 3600 { return "started \(Int(seconds / 60)) min ago" }
        if seconds < 48 * 3600 { return "started \(Int(seconds / 3600)) h ago" }
        return "started \(Int(seconds / 86400)) d ago"
    }

    private static let working = ("Working", NSColor.systemYellow)
    private static let idle = ("Idle", NSColor(calibratedWhite: 0.72, alpha: 1))

    static func badge(for candidate: TeleportCandidate) -> (text: String, tint: NSColor) {
        if candidate.isAlreadyHere { return ("Already here", .systemGreen) }
        switch candidate {
        case .claude(let session):
            if session.isBackground { return ("Background", NSColor(calibratedRed: 0.36, green: 0.62, blue: 1, alpha: 1)) }
            return badge(for: session.status)
        case .shell(let tab):
            return tab.foregroundCommand == nil ? idle : working
        }
    }

    static func badge(for status: TeleportStatus) -> (text: String, tint: NSColor) {
        switch status {
        case .working: return working
        case .waiting: return ("Waiting", .systemOrange)
        case .idle: return idle
        case .unknown: return ("Unknown", NSColor(calibratedWhite: 0.55, alpha: 1))
        }
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor, pointSize: CGFloat) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let symbol = base.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)) else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }
}

private enum SnapshotSamples {
    static var candidates: [TeleportCandidate] {
        let home = NSHomeDirectory()
        func claude(_ label: String, _ folder: String, _ minutes: Double, background: Bool = false,
                    status: TeleportStatus = .idle, host: TeleportHost, pid: pid_t) -> TeleportCandidate {
            .claude(ClaudeSessionInfo(pid: pid, sessionID: "\(pid)-7f1661d9-1589-4587-9a06-0c273bd86d75",
                                      cwd: home + folder, name: "slyterm-\(pid)", label: label,
                                      isBackground: background, attachID: background ? "adc5721b" : nil,
                                      status: status, startedAt: Date(timeIntervalSinceNow: -minutes * 60),
                                      host: host, tty: "ttys00\(pid % 9)", version: "2.1.278"))
        }
        return [
            claude("Add rate limiting to the login endpoint", "/Projects/api", 14,
                   status: .working, host: .iTerm2(sessionID: "648BA0E4-3F1C-4C6E-9C2B-1B0A9E1D7A21"), pid: 3745),
            claude("Find why the strip loses its rounded corners in panic mode", "/Projects/slyterm", 128,
                   status: .idle, host: .iTerm2(sessionID: "9C0F2A71-55B4-41D2-8E77-2D3C4E5F6A70"), pid: 20728),
            claude("Fix the flaky date test in the invoice export", "/Projects/billing", 55,
                   status: .waiting, host: .iTerm2(sessionID: "3B7D9E21-4C5A-4F60-8A1B-2C3D4E5F6071"), pid: 4149),
            claude("Draft the release notes", "/Projects/site/.claude/worktrees/release-notes", 372,
                   background: true, status: .idle, host: .unknown, pid: 79439),
            claude("Bring a session in from another terminal", "/Projects/slyterm", 41,
                   status: .working, host: .slyTerm(tabID: UUID()), pid: 4110),
            .shell(ShellTabInfo(shellPid: 6621, tty: "ttys004", cwd: home + "/Projects/site",
                                shellName: "zsh", foregroundCommand: "npm run dev",
                                host: .iTerm2(sessionID: "11AA22BB-33CC-44DD-55EE-66FF77008811"),
                                startedAt: Date(timeIntervalSinceNow: -3 * 3600))),
            .shell(ShellTabInfo(shellPid: 8012, tty: "ttys007", cwd: home, shellName: "zsh",
                                foregroundCommand: nil, host: .appleTerminal(sessionID: "w0t1p0"),
                                startedAt: Date(timeIntervalSinceNow: -26 * 3600))),
        ]
    }
}
