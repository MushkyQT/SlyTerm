import AppKit

final class ActivityCard: ActivityCardPresenting {
    static let shared = ActivityCard()

    private let panel: CardPanel
    private let card = ActivityCardView()
    private let settings = Settings.shared

    private(set) var presentedTab: UUID?
    private(set) var presentedPrompt: AgentPrompt?
    private(set) var presentedAt: Date?
    // Holds other requests back after a click: a new card now would take the answer key the user
    // meant for the tab they just brought forward.
    private var held: UUID?
    private var standing: [UUID: AgentPrompt] = [:]
    private var lastFinished: (tab: UUID, message: String)?
    private var dismissWork: DispatchWorkItem?
    private var generation = 0

    private init() {
        panel = CardPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = settings.levelValue
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = card
        card.onClose = { [weak self] in self?.close() }
        card.onClick = { [weak self] in self?.reveal() }
    }

    func present(_ event: ActivityEvent, tab: TerminalTab) {
        guard settings.activityCards else { return }
        let content: ActivityCardView.Content
        switch event {
        case .finished(_, let activity):
            // The Stop hook and the poll can report one turn twice. Compare text only: matching
            // on nil would hide every text-less turn after the first.
            if let message = activity.lastMessage, let last = lastFinished,
               last.tab == tab.id, last.message == message { return }
            guard let host = Activity.host, !host.isBeingViewed(tab),
                  !isBehindRequest(tab, news: "finished", host: host) else { return }
            lastFinished = activity.lastMessage.map { (tab: tab.id, message: $0) }
            content = finishedContent(tab: tab, activity: activity)
        case .asks(_, let activity):
            guard let host = Activity.host, !host.isBeingViewed(tab) else { return }
            showRequest(activity, of: tab)
            return
        case .notified(_, let title, let body):
            guard let host = Activity.host, !host.isBeingViewed(tab),
                  !isBehindRequest(tab, news: "sent a notification", host: host) else { return }
            content = notifiedContent(tab: tab, title: title, body: body)
        case .answered, .gone, .changed:
            return
        }
        show(content, for: tab.id, prompt: nil)
    }

    func refresh(_ tab: TerminalTab) {
        guard presentedTab == tab.id, let shown = presentedPrompt,
              let activity = tab.activity, let prompt = activity.prompt,
              prompt != shown, prompt.isSame(as: shown) else { return }
        showRequest(activity, of: tab)
    }

    func dismiss(tab: UUID?) {
        guard let tab else {
            standing = [:]
            held = nil
            if presentedTab != nil { takeDown() }
            return
        }
        standing[tab] = nil
        if presentedTab == tab {
            takeDown()
            showNextStanding()
        } else if held == tab {
            held = nil
            if presentedTab == nil { showNextStanding() }
        }
    }

    func layout() {
        guard presentedTab != nil, let host = Activity.host else { return }
        guard host.isOverlayVisible else { panel.orderOut(nil); return }
        panel.level = settings.levelValue
        panel.setFrame(frame(for: panel.frame.size, host: host), display: true)
        panel.orderFrontRegardless()
    }

    private func showRequest(_ activity: AgentActivity, of tab: TerminalTab) {
        guard let prompt = activity.prompt else { return }
        standing[tab.id] = prompt
        show(asksContent(tab: tab, activity: activity), for: tab.id, prompt: prompt)
    }

    // News that needs no answer never covers a request that does.
    private func isBehindRequest(_ tab: TerminalTab, news: String, host: ActivityHost) -> Bool {
        guard let up = presentedTab, presentedPrompt != nil,
              let asking = standingActivity(of: up, host: host) else { return false }
        Settings.log("card: \(tab.title) \(news), kept behind \(asking.tab.title)'s request")
        return true
    }

    private func standingActivity(of id: UUID, host: ActivityHost)
        -> (tab: TerminalTab, activity: AgentActivity)? {
        guard let prompt = standing[id], let tab = host.terminals.first(where: { $0.id == id }),
              let activity = tab.activity, let now = activity.prompt, now.isSame(as: prompt),
              !host.isBeingViewed(tab) else { return nil }
        return (tab, activity)
    }

    private func showNextStanding() {
        guard settings.activityCards, let host = Activity.host else { standing = [:]; return }
        var next: (tab: TerminalTab, activity: AgentActivity)?
        for id in Array(standing.keys) {
            guard let found = standingActivity(of: id, host: host) else {
                standing[id] = nil
                continue
            }
            if next == nil || (found.activity.since ?? .distantPast) > (next?.activity.since ?? .distantPast) {
                next = found
            }
        }
        guard let next else { return }
        Settings.log("card: \(next.tab.title)'s request is back")
        showRequest(next.activity, of: next.tab)
    }

    private func close() {
        guard let tab = presentedTab else { return }
        standing[tab] = nil
        takeDown()
        showNextStanding()
    }

    private func show(_ content: ActivityCardView.Content, for tab: UUID, prompt: AgentPrompt?) {
        dismissWork?.cancel()
        generation += 1
        presentedTab = tab
        presentedPrompt = prompt
        presentedAt = Date()
        held = nil
        let host = Activity.host
        let width = cardWidth(host: host)
        card.configure(content)
        let size = NSSize(width: width, height: card.height(forWidth: width))
        if let host {
            panel.setFrame(frame(for: size, host: host), display: true)
        } else {
            panel.setContentSize(size)
        }
        panel.level = settings.levelValue
        panel.alphaValue = 1
        card.layoutCard()
        // While hidden: `requestAttention` brings the overlay back and `layout()` shows the card.
        if host?.isOverlayVisible ?? true { panel.orderFrontRegardless() }
        Settings.log("card: \(content.title)")

        let seconds = settings.activityCardSeconds
        guard prompt == nil, seconds > 0 else { return }
        let current = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == current else { return }
            fadeOut(generation: current)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func takeDown() {
        dismissWork?.cancel()
        generation += 1
        presentedTab = nil
        presentedPrompt = nil
        presentedAt = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func fadeOut(generation current: Int) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.takeDown()
            }
        })
    }

    private func reveal() {
        guard let tab = presentedTab, Activity.host?.select(tabID: tab) == true else { return }
        let asked = presentedPrompt != nil
        standing[tab] = nil
        takeDown()
        if asked { held = tab } else { showNextStanding() }
    }

    private func cardWidth(host: ActivityHost?) -> CGFloat {
        let strip = host?.stripScreenFrame.width ?? 420
        return max(260, min(420, strip))
    }

    private func frame(for size: NSSize, host: ActivityHost) -> NSRect {
        let strip = host.stripScreenFrame
        let gap: CGFloat = 6
        let x = strip.maxX - size.width
        let below = NSRect(x: x, y: strip.minY - gap - size.height, width: size.width, height: size.height)
        let above = NSRect(x: x, y: strip.maxY + gap, width: size.width, height: size.height)
        let away = host.stripEdge == .bottom ? below : above
        let over = host.stripEdge == .bottom ? above : below
        let visible = (NSScreen.screens.first { $0.frame.intersects(strip) } ?? NSScreen.main)?.visibleFrame
        var chosen = away
        if let visible, !visible.contains(away) { chosen = over }
        guard let visible else { return chosen }
        chosen.origin.x = min(max(chosen.origin.x, visible.minX + 6), max(visible.minX, visible.maxX - size.width - 6))
        chosen.origin.y = min(max(chosen.origin.y, visible.minY + 6), max(visible.minY, visible.maxY - size.height - 6))
        return chosen
    }

    private func finishedContent(tab: TerminalTab,
                                 activity: AgentActivity) -> ActivityCardView.Content {
        var title = "\(tab.title) · finished"
        if let duration = activity.lastTurnDuration { title += " · \(activityDuration(duration))" }
        let ghost = ActivityAnswer.comboName(settings.hotkeyGhost)
        return ActivityCardView.Content(
            accent: .systemYellow,
            title: title,
            body: Self.clamp(activity.lastMessage) ?? "Turn finished.",
            mono: nil,
            footer: footer([ghost.map { "\($0) to read" }]))
    }

    private func notifiedContent(tab: TerminalTab, title: String?,
                                 body: String) -> ActivityCardView.Content {
        let ghost = ActivityAnswer.comboName(settings.hotkeyGhost)
        return ActivityCardView.Content(
            accent: .systemYellow,
            title: "\(tab.title) · \(title ?? "notification")",
            body: Self.clamp(body) ?? body,
            mono: nil,
            footer: footer([ghost.map { "\($0) to read" }]))
    }

    private func asksContent(tab: TerminalTab,
                             activity: AgentActivity) -> ActivityCardView.Content {
        let ghost = ActivityAnswer.comboName(settings.hotkeyGhost)
        switch activity.request {
        case .permission(_, let summary, let detail):
            let allow = ActivityAnswer.comboName(settings.hotkey(.allow))
            let refuse = ActivityAnswer.comboName(settings.hotkey(.refuse))
            return ActivityCardView.Content(
                accent: .systemOrange,
                title: "\(tab.title) · needs an answer",
                body: "Wants to \(summary)",
                mono: detail.map { Self.clampCharacters(Self.clampLines($0, max: 6), to: 600) },
                footer: footer([allow.map { "\($0) allow" }, refuse.map { "\($0) refuse" },
                                ghost.map { "\($0) to look" }]))
        case .question(let text, let options):
            let listed = options.prefix(5).map { "· \($0)" }.joined(separator: "\n")
            return ActivityCardView.Content(
                accent: .systemOrange,
                title: "\(tab.title) · asks a question",
                body: listed.isEmpty ? text : "\(text)\n\(listed)",
                mono: nil,
                footer: footer([ghost.map { "\($0) to answer" }]))
        case .unknown, .none:
            return ActivityCardView.Content(
                accent: .systemOrange,
                title: "\(tab.title) · is waiting for you",
                body: "Open the terminal to see what it asks.",
                mono: nil,
                footer: footer([ghost.map { "\($0) to answer" }]))
        }
    }

    private func footer(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: " · ")
    }

    static func clamp(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = clampLines(text, max: 6).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : clampCharacters(trimmed, to: 500)
    }

    // Blank lines are dropped: with a bounded line count AppKit stops laying out a label at an
    // empty paragraph, so the text after it would not be drawn.
    static func clampLines(_ text: String, max lines: Int) -> String {
        let all = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard all.count > lines else { return all.joined(separator: "\n") }
        return all.prefix(lines).joined(separator: "\n") + " …"
    }

    private static func clampCharacters(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let cut = head.lastIndex(of: " ").map { head[head.startIndex..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ActivityCardView: NSView {
    struct Content {
        var accent: NSColor
        var title: String
        var body: String
        var mono: String?
        var footer: String
    }

    var onClose: (() -> Void)?
    var onClick: (() -> Void)?

    static let background = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.97)
    private static let cornerRadius: CGFloat = 8
    private static let accentWidth: CGFloat = 3
    private static let inset = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
    private static let closeSize: CGFloat = 16
    private static let maxHeight: CGFloat = 220

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let monoLabel = NSTextField(wrappingLabelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private var accent = NSColor.systemYellow
    private var closeRect = NSRect.zero
    private var closeHovered = false { didSet { if closeHovered != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        style(titleLabel, font: .systemFont(ofSize: 12, weight: .semibold), alpha: 0.9, lines: 1)
        style(bodyLabel, font: .systemFont(ofSize: 12), alpha: 0.8, lines: 6)
        style(monoLabel, font: .monospacedSystemFont(ofSize: 11, weight: .regular), alpha: 0.75, lines: 6)
        style(footerLabel, font: .systemFont(ofSize: 10.5), alpha: 0.5, lines: 1)
        for label in [titleLabel, bodyLabel, monoLabel, footerLabel] { addSubview(label) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // Multi-line labels need word wrap plus `truncatesLastVisibleLine`: `.byTruncatingTail`
    // turns wrapping off and leaves a paragraph on one line.
    private func style(_ label: NSTextField, font: NSFont, alpha: CGFloat, lines: Int) {
        label.font = font
        label.textColor = NSColor(calibratedWhite: 1, alpha: alpha)
        label.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        (label.cell as? NSTextFieldCell)?.truncatesLastVisibleLine = lines > 1
        label.maximumNumberOfLines = lines
        label.isSelectable = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = true
    }

    func configure(_ content: Content) {
        accent = content.accent
        titleLabel.stringValue = content.title
        bodyLabel.stringValue = content.body
        bodyLabel.maximumNumberOfLines = 6
        monoLabel.stringValue = content.mono ?? ""
        monoLabel.maximumNumberOfLines = 6
        monoLabel.isHidden = content.mono == nil
        footerLabel.stringValue = content.footer
        footerLabel.isHidden = content.footer.isEmpty
        needsDisplay = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        ceil(min(Self.maxHeight, rows(width: width).total))
    }

    func layoutCard() {
        let laid = rows(width: bounds.width)
        let height = max(bounds.height, laid.total)
        for row in laid.rows {
            row.label.frame = NSRect(x: row.x, y: height - row.top - row.height, width: row.width, height: row.height)
        }
        closeRect = NSRect(x: bounds.maxX - Self.inset.right - Self.closeSize,
                           y: bounds.maxY - Self.inset.top - Self.closeSize + 2,
                           width: Self.closeSize, height: Self.closeSize)
    }

    override func layout() {
        super.layout()
        layoutCard()
    }

    private struct Row {
        let label: NSTextField
        let x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat
    }

    private func rows(width: CGFloat) -> (rows: [Row], total: CGFloat) {
        let left = Self.accentWidth + Self.inset.left
        let textWidth = max(40, width - left - Self.inset.right)
        let titleWidth = max(40, textWidth - Self.closeSize - 6)

        func measure() -> (rows: [Row], total: CGFloat) {
            var rows: [Row] = []
            var y = Self.inset.top
            func add(_ label: NSTextField, width: CGFloat, gap: CGFloat) {
                y += gap
                let height = fit(label, width: width)
                rows.append(Row(label: label, x: left, top: y, width: width, height: height))
                y += height
            }
            add(titleLabel, width: titleWidth, gap: 0)
            add(bodyLabel, width: textWidth, gap: 6)
            if !monoLabel.isHidden { add(monoLabel, width: textWidth, gap: 6) }
            if !footerLabel.isHidden { add(footerLabel, width: textWidth, gap: 8) }
            return (rows, y + Self.inset.bottom)
        }

        var laid = measure()
        while laid.total > Self.maxHeight {
            if !monoLabel.isHidden, monoLabel.maximumNumberOfLines > 2 {
                monoLabel.maximumNumberOfLines -= 1
            } else if bodyLabel.maximumNumberOfLines > 1 {
                bodyLabel.maximumNumberOfLines -= 1
            } else {
                break
            }
            laid = measure()
        }
        return laid
    }

    // Line cap applied here too: `cellSize(forBounds:)` in a tall rect can ignore
    // `maximumNumberOfLines` and answer for the whole string.
    private func fit(_ label: NSTextField, width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = width
        let natural = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 16
        let font = label.font ?? .systemFont(ofSize: 12)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        return ceil(min(natural, line * CGFloat(label.maximumNumberOfLines) + 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        Self.background.setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.setClip()
        accent.setFill()
        NSRect(x: 0, y: 0, width: Self.accentWidth, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        drawClose()
    }

    private func drawClose() {
        guard let base = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss"),
              let symbol = base.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) else { return }
        let color = NSColor(calibratedWhite: 1, alpha: closeHovered ? 0.95 : 0.45)
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        tinted.draw(in: NSRect(x: closeRect.midX - size.width / 2, y: closeRect.midY - size.height / 2,
                               width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        closeHovered = closeRect.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { closeHovered = false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseUp(with event: NSEvent) {
        if closeRect.contains(convert(event.locationInWindow, from: nil)) { onClose?() } else { onClick?() }
    }
}

enum ActivityCardSnapshotCLI {
    static func run(_ args: [String]) -> Bool {
        guard args.count >= 3, args[1] == "--card-snapshot" else { return false }
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: args[2])

        var rows: [(String, NSImage)] = []
        func add(_ caption: String, _ content: ActivityCardView.Content, width: CGFloat = 420) {
            if let image = render(content, width: width) { rows.append((caption, image)) }
        }
        add("a finished turn", ActivityCardView.Content(
            accent: .systemYellow,
            title: "claude · finished · 2m 14s",
            body: """
                  Done. The strip now draws a spinner for a working Claude and an orange question \
                  mark for one that is waiting, and the tooltip on each tab says which it is and \
                  for how long. I left the yellow dot alone: it still means a bell or a notify.
                  """,
            mono: nil,
            footer: "⌃⌥Tab to read"))
        add("a permission prompt, with the command", ActivityCardView.Content(
            accent: .systemOrange,
            title: "slyterm · needs an answer",
            body: "Wants to run `swift build 2>&1 | tail -40`",
            mono: "swift build 2>&1 | tail -40\nswift build -c release 2>&1 | tail -20",
            footer: "⌃⌥Y allow · ⌃⌥N refuse · ⌃⌥Tab to look"))
        add("a question, with its options", ActivityCardView.Content(
            accent: .systemOrange,
            title: "Projects · asks a question",
            body: "Which strip edge should the card prefer when both sides fit?\n· Away from the terminal\n· Always below\n· Follow the window",
            mono: nil,
            footer: "⌃⌥Tab to answer"))
        add("a long answer, cut where the card runs out", ActivityCardView.Content(
            accent: .systemYellow,
            title: "slyterm · finished · 4m 02s",
            body: ActivityCard.clamp("""
                  The monitor now polls Claude Code's session registry once a second while the \
                  overlay is up and once every three seconds while it is not, maps each live \
                  `claude` to the tab it was started in through SLYTERM_TAB_ID, and reads a \
                  bounded tail of the transcript only when the file changed.

                  The label on the strip comes from the pending tool call, so a tab says "editing \
                  GuideTab.swift" rather than just "working", and the tooltip adds how long it has \
                  been at it. Everything is best effort: a line that does not parse is skipped, \
                  and nothing in the poll can crash the app.
                  """) ?? "",
            mono: nil,
            footer: "⌃⌥Tab to read"))
        add("Codex asks to run a command, read off its screen", ActivityCardView.Content(
            accent: .systemOrange,
            title: "Fix the login test | api · needs an answer",
            body: "Wants to run `npm test -- --grep login`",
            mono: "npm test -- --grep login",
            footer: "⌃⌥Y allow · ⌃⌥N refuse · ⌃⌥Tab to look"))
        add("a notification from a program SlyTerm does not read", ActivityCardView.Content(
            accent: .systemYellow,
            title: "build · Build finished",
            body: "All 214 targets built in 3m 12s, 2 warnings.",
            mono: nil,
            footer: "⌃⌥Tab to read"))
        add("a long command and a narrow strip", ActivityCardView.Content(
            accent: .systemOrange,
            title: "a tab with a very long name indeed · needs an answer",
            body: "Wants to run `rg --hidden --glob '!.git' 'activityCards' -n Sources`",
            mono: "rg --hidden --glob '!.git' 'activityCards' -n Sources README.md build.sh",
            footer: "⌃⌥Y allow · ⌃⌥N refuse · ⌃⌥Tab to look"), width: 260)
        write(rows, to: output)
        return true
    }

    private static func render(_ content: ActivityCardView.Content, width: CGFloat) -> NSImage? {
        // The window is never shown: `cacheDisplay` needs a backing store an unparented view lacks.
        let view = ActivityCardView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.configure(content)
        let height = view.height(forWidth: width)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.addSubview(view)
        view.layoutCard()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func write(_ rows: [(caption: String, image: NSImage)], to output: URL) {
        let margin: CGFloat = 12, caption: CGFloat = 15
        let width = (rows.map { $0.image.size.width }.max() ?? 420) + margin * 2
        let height = rows.reduce(margin) { $0 + $1.image.size.height + caption + margin }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
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
            print("wrote \(output.path) (\(Int(width))x\(Int(height)), \(rows.count) cards)")
        } catch {
            print("cannot write \(output.path): \(error.localizedDescription)")
        }
    }
}
