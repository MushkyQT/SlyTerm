import AppKit

enum ActivityAnswer {
    enum Answer {
        case allow, refuse

        var verb: String { self == .allow ? "allowed" : "refused" }
        // Claude Code's prompt has "Yes" first and highlighted: Return accepts, Escape rejects.
        var keystroke: String { self == .allow ? "\r" : "\u{1b}" }
    }

    // Claude Code records nothing until it acts on an answer, so a second press would find the same
    // prompt and type into whatever comes up next. Unstamped prompts are cleared by `forget`.
    private static var answered: [UUID: AgentPrompt] = [:]

    static func forget(tab: UUID) {
        answered[tab] = nil
    }

    // A card that came up just before the key went down was not read: the key meant the one before.
    static let readingTime: TimeInterval = 1

    static func comboName(_ combo: String) -> String? {
        combo.isEmpty ? nil : KeyCombo.pretty(combo)
    }

    @MainActor
    static func perform(_ answer: Answer, tab explicit: TerminalTab? = nil) {
        let settings = Settings.shared
        guard settings.activityCards else {
            Settings.log("answer: \(answer.verb) ignored, cards are off")
            toast("Cards are off in Settings › General", tint: .systemOrange)
            return
        }
        let host = Activity.host
        let card = Activity.card?.presentedTab.flatMap { id in host?.terminals.first { $0.id == id } }
        // A finished card lingers; it must not answer for the tab the user is actually in.
        let asking = card?.activity?.isWaiting == true ? card : nil
        guard let tab = explicit ?? asking ?? host?.selectedTerminal else {
            toast("No tab to answer in", tint: .systemOrange)
            return
        }
        // Read before the scan: it may find a newer prompt and redraw the card with it.
        let shown = Activity.card?.presentedTab == tab.id ? Activity.card?.presentedPrompt : nil
        let seen = shown ?? tab.activity?.prompt
        if shown != nil, let at = Activity.card?.presentedAt, Date().timeIntervalSince(at) < readingTime {
            Settings.log("answer: \(answer.verb) ignored, the card for \(tab.title) just came up")
            toast("Read the card first", tint: .systemOrange)
            return
        }
        // Fresh scan: the prompt may have been answered in the terminal since the last poll.
        // Assert isolation rather than hop, so no turn runs between the scan and the keystroke.
        let finish = {
            MainActor.assumeIsolated { [weak tab] in
                guard let tab else { return }
                apply(answer, in: tab, seen: seen)
            }
        }
        if let monitor = Activity.monitor {
            monitor.refreshNow(completion: finish)
        } else {
            finish()
        }
    }

    @MainActor
    private static func apply(_ answer: Answer, in tab: TerminalTab, seen: AgentPrompt?) {
        guard let activity = tab.activity, let prompt = activity.prompt else {
            Settings.log("answer: \(answer.verb) ignored, nothing is waiting in \(tab.title)")
            toast("Nothing is waiting", tint: .systemOrange)
            return
        }
        if let done = answered[tab.id], done.isSame(as: prompt) {
            Settings.log("answer: \(answer.verb) ignored, this prompt was just answered in \(tab.title)")
            toast("Already answered", tint: .systemOrange)
            return
        }
        guard seen == prompt else {
            Settings.log("answer: \(answer.verb) ignored, the prompt is not the one on screen in \(tab.title)")
            toast("Claude asks something new: read it first", tint: .systemOrange)
            return
        }
        let ghost = comboName(Settings.shared.hotkeyGhost)
        switch activity.request {
        case .permission(_, let summary, _):
            // Claude may have been suspended or exited to a shell with half a command typed,
            // which a Return would run.
            guard let group = activity.processGroup, tab.foregroundProcessGroup == group else {
                Settings.log("answer: \(answer.verb) ignored, Claude is not in front in \(tab.title)")
                toast("Claude is not in front in \(tab.title)", tint: .systemOrange)
                return
            }
            tab.send(raw: answer.keystroke)
            answered[tab.id] = prompt
            Settings.log("answer: \(answer.verb) \(summary) in \(tab.title)")
            Activity.card?.dismiss(tab: tab.id)
            Activity.host?.clearAttention(tab)
            toast("\(answer.verb.capitalized): \(summary)", tint: answer == .allow ? .systemGreen : .systemOrange,
                  duration: 1.6)
        case .question:
            // Never answered: Return would pick the highlighted option, which nobody chose.
            Settings.log("answer: \(answer.verb) ignored, Claude asks a question in \(tab.title)")
            let opens = Activity.card?.presentedTab.map { $0 == tab.id } ?? (Activity.host?.selectedTerminal === tab)
            toast(ghost.flatMap { opens ? "Claude asks a question: \($0) to answer" : nil }
                  ?? "Claude asks a question", tint: .systemOrange)
        case .unknown, .none:
            Settings.log("answer: \(answer.verb) ignored, not a yes or no in \(tab.title)")
            toast("Claude is waiting, but not for a yes or no", tint: .systemOrange)
        }
    }

    @MainActor
    private static func toast(_ text: String, tint: NSColor, duration: TimeInterval = 2) {
        let strip = Activity.host?.stripScreenFrame ?? .zero
        let point = strip.isEmpty ? NSEvent.mouseLocation : NSPoint(x: strip.maxX, y: strip.maxY)
        Toast.shared.show(text, near: point, tint: tint, duration: duration)
    }
}
