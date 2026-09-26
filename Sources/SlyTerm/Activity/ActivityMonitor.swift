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
    private var seen: [UUID: ClaudeActivity] = [:]

    // Keyed with start time because pids are reused; `KERN_PROCARGS2` costs a megabyte per call.
    private var inspected: [pid_t: (started: Date?, arguments: SessionDiscovery.ProcessArguments?)] = [:]
    private var tails: [String: (size: UInt64, modified: Date?, reading: TranscriptTail.Reading)] = [:]
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
        // Main thread: `ptsname` returns a shared static buffer.
        let ttys = Dictionary(terminals.compactMap { tab in tab.ttyName.map { (tab.id, $0) } },
                              uniquingKeysWith: { (first: String, _: String) in first })
        queue.async { [weak self] in
            guard let self else { return }
            let found = self.scan(tabs: ttys)
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

    private func scan(tabs: [UUID: String]) -> [UUID: ClaudeActivity] {
        reads = 0
        var touched: Set<pid_t> = []
        let hosted = SessionDiscovery.hostedSessions(tabs: tabs) { pid in
            touched.insert(pid)
            return inspect(pid)
        }
        var activities: [UUID: ClaudeActivity] = [:]
        for (tab, found) in hosted {
            activities[tab] = ActivityMonitor.activity(for: found.session, reading: reading(for: found.session),
                                                       processGroup: found.processGroup)
        }
        inspected = inspected.filter { touched.contains($0.key) }
        let live = Set(hosted.values.map(\.session.sessionID))
        tails = tails.filter { live.contains($0.key) }
        return activities
    }

    // Touches the poll's caches off its queue: safe only with no poll running (the CLI).
    func scanEverything() -> [(session: ClaudeSessionInfo, activity: ClaudeActivity)] {
        reads = 0
        var touched: Set<pid_t> = []
        let sessions = SessionDiscovery.liveSessions(inspect: { pid in
            touched.insert(pid)
            return inspect(pid)
        }).sorted { $0.startedAt > $1.startedAt }
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

    private func reading(for session: ClaudeSessionInfo) -> TranscriptTail.Reading? {
        guard let url = SessionDiscovery.transcriptURL(cwd: session.cwd, sessionID: session.sessionID) else {
            return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date
        if let cached = tails[session.sessionID], cached.size == size, cached.modified == modified {
            return cached.reading
        }
        let reading = TranscriptTail.read(url)
        reads += 1
        tails[session.sessionID] = (size, modified, reading)
        return reading
    }

    static func activity(for session: ClaudeSessionInfo, reading: TranscriptTail.Reading?,
                         processGroup: pid_t? = nil) -> ClaudeActivity {
        ClaudeActivity(status: session.status,
                       since: session.statusUpdatedAt,
                       sessionID: session.sessionID,
                       pid: session.pid,
                       isBackground: session.isBackground,
                       processGroup: processGroup,
                       doing: session.status == .working ? reading?.doing : nil,
                       request: session.status == .waiting ? (reading?.request ?? .unknown) : nil,
                       lastMessage: reading?.lastMessage,
                       lastTurnDuration: reading?.lastTurnDuration)
    }

    private func apply(_ found: [UUID: ClaudeActivity]) {
        let terminals = tabs?() ?? []
        var events: [ActivityEvent] = []
        for tab in terminals {
            let before = seen[tab.id]
            var after = found[tab.id]
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
        for event in events { onEvent?(event) }
    }

    private func transition(tab: TerminalTab,
                            from before: ClaudeActivity?,
                            to after: ClaudeActivity?) -> [ActivityEvent] {
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

    private func isNewPrompt(from was: ClaudeActivity, to now: ClaudeActivity) -> Bool {
        guard let before = was.prompt, let after = now.prompt else { return false }
        return !after.isSame(as: before)
    }

    // Needs the transcript to agree with the stamp: the registry is also rewritten without a turn.
    private func isUnseenTurn(from was: ClaudeActivity, to now: ClaudeActivity) -> Bool {
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
