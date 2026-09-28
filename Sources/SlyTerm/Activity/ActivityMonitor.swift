import AppKit

final class ActivityMonitor: ActivityMonitoring {
    var onEvent: ((ActivityEvent) -> Void)?

    private let interval: TimeInterval = 1
    private let hiddenEvery = 3

    private let queue = DispatchQueue(label: "com.slyterm.activity", qos: .utility)

    private var tabs: (() -> [TerminalTab])?
    private var visible: (() -> Bool)?
    private var timer: Timer?
    private var ticks = 0
    private var scanning = false
    private var rescan = false
    private var completions: [() -> Void] = []
    private var seen: [UUID: AgentActivity] = [:]
    // A title can end a turn before the session file has the answer: the tab stays working
    // meanwhile, rescanned, for up to `fileWait`.
    private var holds: [UUID: Date] = [:]
    private let fileWait: TimeInterval = 2
    private var codexPrompts: [UUID: CodexPrompt] = [:]

    // Keyed with start time because pids are reused; `KERN_PROCARGS2` costs a megabyte per call.
    private var inspected: [pid_t: (started: Date?, arguments: SessionDiscovery.ProcessArguments?)] = [:]
    private var tails: [String: (url: URL, size: UInt64, modified: Date?,
                                 reading: TranscriptTail.Reading)] = [:]
    private let files = AgentDiscovery.Cache()
    private(set) var reads = 0

    func start(tabs: @escaping () -> [TerminalTab], visible: @escaping () -> Bool) {
        self.tabs = tabs
        self.visible = visible
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        // `.common`: the default mode does not run while the strip is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        requestScan(completion: nil)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tabs = nil
        visible = nil
        seen = [:]
        holds = [:]
        codexPrompts = [:]
        completions = []
        rescan = false
    }

    func refreshNow(completion: (() -> Void)?) {
        if Thread.isMainThread {
            requestScan(completion: completion)
        } else {
            DispatchQueue.main.async { [weak self] in self?.requestScan(completion: completion) }
        }
    }

    private func tick() {
        ticks &+= 1
        guard visible?() == true || ticks % hiddenEvery == 0 else { return }
        requestScan(completion: nil)
    }

    private func requestScan(completion: (() -> Void)?) {
        if let completion { completions.append(completion) }
        // Only callers with a completion rescan: if ticks did, a scan slower than the interval
        // would chain scans forever and completions would never run.
        guard !scanning else {
            if completion != nil { rescan = true }
            return
        }
        let terminals = tabs?() ?? []
        guard !terminals.isEmpty else { return finish() }
        scanning = true
        // Main thread: `ptsname` returns a shared static buffer, and the titles and the screen are
        // SwiftTerm's.
        let probes = Dictionary(terminals.compactMap { tab in
            tab.ttyName.map { tty in
                let titles = tab.titleStates
                // Only for the agent the last scan found in front: a title left behind by a
                // program that has gone must not cost a screen read every scan.
                let waiting = tab.activity.map { titles[$0.agent]?.status == .waiting } ?? false
                let screen = waiting ? tab.visibleLines() : nil
                return (tab.id, TabProbe(tty: tty, foregroundGroup: tab.foregroundProcessGroup,
                                         titles: titles, screen: screen))
            }
        }, uniquingKeysWith: { (first: TabProbe, _: TabProbe) in first })
        queue.async { [weak self] in
            guard let self else { return }
            let found = self.scan(tabs: probes)
            DispatchQueue.main.async {
                self.scanning = false
                self.apply(found)
                if self.rescan {
                    self.rescan = false
                    // Completions stay queued: this scan may predate the state they asked about.
                    self.requestScan(completion: nil)
                } else {
                    self.finish()
                }
            }
        }
    }

    private func finish() {
        let waiting = completions
        completions = []
        for completion in waiting { completion() }
    }

    private struct Found {
        var activity: AgentActivity
        var byTitle = false
        var fromScreen = false
        var readsFile = false
        // The session file's own idle stamp: nil while it says the turn runs.
        var fileIdleSince: Date?
    }

    private struct CodexPrompt {
        var titleSince: Date
        var request: AgentRequest?
        var since: Date
    }

    private func scan(tabs: [UUID: TabProbe]) -> [UUID: Found] {
        reads = 0
        var touched: Set<pid_t> = []
        let hosted = SessionDiscovery.hostedSessions(tabs: tabs, inspect: { pid in
            touched.insert(pid)
            return inspect(pid)
        }, files: files)
        files.prune()
        var activities: [UUID: Found] = [:]
        for (tab, found) in hosted {
            let reading = reading(for: found.session)
            activities[tab] = ActivityMonitor.found(for: found.session, reading: reading,
                                                    processGroup: found.processGroup,
                                                    probe: tabs[tab])
        }
        inspected = inspected.filter { touched.contains($0.key) }
        let live = Set(hosted.values.map(\.session.sessionID))
        tails = tails.filter { live.contains($0.key) }
        return activities
    }

    // Touches the poll's caches off its queue: safe only with no poll running (the CLI).
    func scanEverything() -> [(session: AgentSessionInfo, activity: AgentActivity)] {
        reads = 0
        var touched: Set<pid_t> = []
        let table = SessionDiscovery.ProcessTable()
        let inspect = { (pid: pid_t) -> SessionDiscovery.ProcessArguments? in
            touched.insert(pid)
            return self.inspect(pid)
        }
        let claude = SessionDiscovery.liveSessions(in: table, inspect: inspect)
            .sorted { $0.startedAt > $1.startedAt }
        let agents = SessionDiscovery.runningAgents(in: table, besides: claude, inspect: inspect,
                                                    cache: files)
            .sorted { $0.startedAt > $1.startedAt }
        files.prune()
        let sessions = claude + agents
        let rows = sessions.map { ($0, ActivityMonitor.activity(for: $0, reading: reading(for: $0))) }
        inspected = inspected.filter { touched.contains($0.key) }
        let live = Set(sessions.map(\.sessionID))
        tails = tails.filter { live.contains($0.key) }
        return rows
    }

    private func inspect(_ pid: pid_t) -> SessionDiscovery.ProcessArguments? {
        let started = SessionDiscovery.startTime(of: pid)
        if let known = inspected[pid], known.started == started { return known.arguments }
        let arguments = SessionDiscovery.arguments(of: pid)
        inspected[pid] = (started, arguments)
        return arguments
    }

    private func reading(for session: AgentSessionInfo) -> TranscriptTail.Reading? {
        let found = session.agent == .claude
            ? SessionDiscovery.transcriptURL(cwd: session.cwd, sessionID: session.sessionID)
            : session.transcript
        guard let url = found else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date
        if let cached = tails[session.sessionID], cached.url == url, cached.size == size,
           cached.modified == modified {
            return cached.reading
        }
        let reading: TranscriptTail.Reading
        switch session.agent {
        case .claude: reading = TranscriptTail.read(url)
        case .codex: reading = CodexRollout.read(url)
        case .omp, .pi: reading = PiSession.read(url)
        case .gemini, .qwen: return nil
        }
        reads += 1
        tails[session.sessionID] = (url, size, modified, reading)
        return reading
    }

    static func activity(for session: AgentSessionInfo, reading: TranscriptTail.Reading?,
                         processGroup: pid_t? = nil, probe: TabProbe? = nil) -> AgentActivity {
        found(for: session, reading: reading, processGroup: processGroup, probe: probe).activity
    }

    // Claude's status is its registry's. A title agent's is its title's once the title has shown
    // one of its marks since this process started (Codex's and Qwen's idle titles have none);
    // until then, and always for pi, the session file's.
    private static func found(for session: AgentSessionInfo, reading: TranscriptTail.Reading?,
                              processGroup: pid_t?, probe: TabProbe?) -> Found {
        let agent = session.agent
        var status = reading?.status ?? .unknown
        var since = reading?.statusSince
        var byTitle = false
        if agent == .claude {
            (status, since) = (session.status, session.statusUpdatedAt)
        } else if let title = probe?.titles[agent], let marked = title.markedAt,
                  marked >= session.startedAt.addingTimeInterval(-titleSlack) {
            (status, since, byTitle) = (title.status, max(title.since, session.startedAt), true)
        }
        var request: AgentRequest?
        var fromScreen = false
        if status == .waiting {
            let screen = probe?.screen.flatMap { AgentScreen.request(lines: $0, agent: agent) }
            // Codex writes no prompt down: its screen shows the one in front, its rollout only a
            // call that has not returned.
            let first = agent == .codex ? screen ?? reading?.request : reading?.request ?? screen
            request = first ?? .unknown
            fromScreen = screen != nil && request == screen
        }
        let activity = AgentActivity(agent: agent,
                                     status: status,
                                     since: since,
                                     sessionID: session.sessionID,
                                     pid: session.pid,
                                     isBackground: session.isBackground,
                                     processGroup: processGroup,
                                     doing: status == .working ? reading?.doing : nil,
                                     request: request,
                                     lastMessage: reading?.lastMessage,
                                     lastTurnDuration: reading?.lastTurnDuration)
        return Found(activity: activity, byTitle: byTitle, fromScreen: fromScreen,
                     readsFile: agent != .claude && reading != nil,
                     fileIdleSince: reading?.status == .idle ? reading?.statusSince : nil)
    }

    // The title is parsed in SlyTerm and the start time is the kernel's, a little after the exec.
    private static let titleSlack: TimeInterval = 2

    private func apply(_ found: [UUID: Found]) {
        let terminals = tabs?() ?? []
        let now = Date()
        var events: [ActivityEvent] = []
        var again = false
        for tab in terminals {
            let before = seen[tab.id]
            var after = found[tab.id]?.activity
            if var activity = after {
                let onScreen = found[tab.id]?.fromScreen ?? false
                stampCodexPrompt(&activity, tab: tab.id, onScreen: onScreen)
                after = activity
            } else {
                codexPrompts[tab.id] = nil
            }
            // The finished card is to carry this turn's answer, not the one before.
            if let was = before, was.isWorking, let from = was.since, let scanned = found[tab.id],
               scanned.byTitle, scanned.readsFile, scanned.activity.status == .idle,
               (scanned.fileIdleSince ?? .distantPast) < from {
                let held = holds[tab.id] ?? now
                holds[tab.id] = held
                if now.timeIntervalSince(held) < fileWait {
                    after = was
                    again = true
                }
            } else {
                holds[tab.id] = nil
            }
            // Claude Code skips `turn_duration` for some turns (interrupted ones); use the stamps.
            if var activity = after, activity.lastTurnDuration == nil,
               let previous = before, previous.isWorking, activity.status == .idle,
               let from = previous.since, let to = activity.since, to > from {
                activity.lastTurnDuration = to.timeIntervalSince(from)
                after = activity
            }
            tab.activity = after
            seen[tab.id] = after
            events.append(contentsOf: transition(tab: tab, from: before, to: after))
        }
        let live = Set(terminals.map(\.id))
        seen = seen.filter { live.contains($0.key) }
        holds = holds.filter { live.contains($0.key) }
        codexPrompts = codexPrompts.filter { live.contains($0.key) }
        for event in events { onEvent?(event) }
        if again {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.requestScan(completion: nil)
            }
        }
    }

    // Codex's title stays on "Action Required" from one approval to the next: another command on
    // its screen is another prompt, with its own card and its own answer.
    private func stampCodexPrompt(_ activity: inout AgentActivity, tab: UUID, onScreen: Bool) {
        guard activity.agent == .codex, activity.isWaiting, let from = activity.since else {
            codexPrompts[tab] = nil
            return
        }
        var prompt = codexPrompts[tab].flatMap { $0.titleSince == from ? $0 : nil }
            ?? CodexPrompt(titleSince: from, request: nil, since: from)
        if onScreen, let request = activity.request, request.isAnswerableByKey,
           request != prompt.request {
            if prompt.request != nil { prompt.since = Date() }
            prompt.request = request
        }
        codexPrompts[tab] = prompt
        activity.since = prompt.since
    }

    private func transition(tab: TerminalTab,
                            from before: AgentActivity?,
                            to after: AgentActivity?) -> [ActivityEvent] {
        switch (before, after) {
        case (nil, nil):
            return []
        case (nil, .some(let now)):
            log(tab, "\(name(now.status)) (first seen)")
            return [.changed(tab: tab.id)]
        case (.some(let was), nil):
            log(tab, "\(name(was.status)) → gone")
            return was.isWaiting ? [.answered(tab: tab.id), .gone(tab: tab.id)] : [.gone(tab: tab.id)]
        case (.some(let was), .some(let now)):
            guard was.status != now.status else {
                // The same status twice can hide a round trip between scans: a prompt answered and
                // replaced within a second, or a turn shorter than the poll.
                if now.isWaiting, isNewPrompt(from: was, to: now) {
                    log(tab, "waiting → waiting, a new prompt")
                    return [.answered(tab: tab.id), .asks(tab: tab.id, activity: now)]
                }
                if now.status == .idle, isUnseenTurn(from: was, to: now) {
                    log(tab, "idle → idle, a turn between two scans")
                    return [.finished(tab: tab.id, activity: now)]
                }
                let moved = was.doing?.label != now.doing?.label || was.request != now.request
                return moved ? [.changed(tab: tab.id)] : []
            }
            log(tab, "\(name(was.status)) → \(name(now.status))" + (now.lastTurnDuration.map {
                " in \(activityDuration($0))"
            } ?? ""))
            if was.isWaiting { return [.answered(tab: tab.id), .changed(tab: tab.id)] }
            if now.isWaiting { return [.asks(tab: tab.id, activity: now)] }
            if was.isWorking, now.status == .idle { return [.finished(tab: tab.id, activity: now)] }
            return [.changed(tab: tab.id)]
        }
    }

    private func isNewPrompt(from was: AgentActivity, to now: AgentActivity) -> Bool {
        guard let before = was.prompt, let after = now.prompt else { return false }
        return !after.isSame(as: before)
    }

    // Needs the transcript to agree with the stamp: the registry is also rewritten without a turn.
    private func isUnseenTurn(from was: AgentActivity, to now: AgentActivity) -> Bool {
        guard was.sessionID == now.sessionID, let from = was.since, let to = now.since, to > from else { return false }
        if was.lastMessage != now.lastMessage { return true }
        // Only Claude Code's own record: `was`'s duration may be computed from stamps and differ.
        guard let duration = now.lastTurnDuration else { return false }
        return duration != was.lastTurnDuration
    }

    private func log(_ tab: TerminalTab, _ what: String) {
        Settings.log("activity: \(tab.title) \(what)")
    }

    private func name(_ status: TeleportStatus) -> String {
        switch status {
        case .working: return "working"
        case .waiting: return "waiting"
        case .idle: return "idle"
        case .unknown: return "unknown"
        }
    }
}
