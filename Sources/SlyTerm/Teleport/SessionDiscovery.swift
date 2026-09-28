import Foundation

// Blocking sysctl and file reads: call off the main thread. No shelling out: `ps` costs a fork
// and `claude agents --json` about a second, while the picker waits on the scan.
enum SessionDiscovery {
    static func scan() -> [TeleportCandidate] {
        let table = ProcessTable()
        let sessions = claudeSessions(in: table).sorted { $0.startedAt > $1.startedAt }
        let agents = agentSessions(in: table, besides: sessions).sorted { $0.startedAt > $1.startedAt }
        let claimed = Set((sessions + agents).compactMap(\.tty))
        let shells = shellTabs(in: table, ignoringTTYs: claimed).sorted { $0.startedAt > $1.startedAt }
        return (sessions + agents).map(TeleportCandidate.agent) + shells.map(TeleportCandidate.shell)
    }

    static func agentSession(id: String) -> AgentSessionInfo? {
        firstSession { $0.sessionID.caseInsensitiveCompare(id) == .orderedSame }
    }

    static func agentSession(pid: pid_t) -> AgentSessionInfo? {
        firstSession { $0.pid == pid }
    }

    static func agentSessions(tty: String) -> [AgentSessionInfo] {
        let name = ttyName(fromArgument: tty)
        let table = ProcessTable()
        let sessions = claudeSessions(in: table)
        return (sessions + agentSessions(in: table, besides: sessions)).filter { $0.tty == name }
    }

    private static func firstSession(where matches: (AgentSessionInfo) -> Bool) -> AgentSessionInfo? {
        let table = ProcessTable()
        let sessions = claudeSessions(in: table)
        if let found = sessions.first(where: matches) { return found }
        return agentSessions(in: table, besides: sessions).first(where: matches)
    }

    static func shellTab(tty: String) -> ShellTabInfo? {
        let name = ttyName(fromArgument: tty)
        return shellTabs(in: ProcessTable(), ignoringTTYs: []).first { $0.tty == name }
    }

    static func isRunning(_ session: AgentSessionInfo) -> Bool {
        guard kill(session.pid, 0) == 0 || errno == EPERM else { return false }
        guard let started = startTime(of: session.pid),
              startAgrees(started, procStart: session.procStart, startedAt: session.startedAt) else { return false }
        guard let inspected = arguments(of: session.pid) else { return false }
        guard session.agent == .claude else {
            guard let process = ProcessTable().entry(pid: session.pid) else { return false }
            return AgentDiscovery.kind(of: process, arguments: inspected) == session.agent
        }
        return inspected.executablePath.localizedCaseInsensitiveContains("claude")
            || inspected.arguments.contains { $0.localizedCaseInsensitiveContains("claude") }
    }

    // `procStart` is the kernel's start time to the second. Older entries have only `startedAt`,
    // stamped after the process starts, so it may lag but never lead: the window is one-sided.
    private static func startAgrees(_ started: Date, procStart: Date?, startedAt claimed: Date?) -> Bool {
        if let procStart { return abs(started.timeIntervalSince(procStart)) <= procStartTolerance }
        guard let claimed else { return true }
        return (-2...pidReuseWindow).contains(claimed.timeIntervalSince(started))
    }

    static var registryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    private static let procStartTolerance: TimeInterval = 2

    // `startedAt` has lagged the process start by 73 s for a daemon's pre-spawned spare, and
    // nothing bounds that lag, hence `procStart` first.
    private static let pidReuseWindow: TimeInterval = 120

    private struct RegistryEntry {
        var pid: pid_t
        var sessionID: String
        var cwd: String
        var startedAt: Date?
        var procStart: Date?
        var kind: String
        var name: String
        var status: String
        var statusUpdatedAt: Date?
        var jobID: String?
        var version: String?
    }

    // JSONSerialization, not Codable: Claude Code changes this format between releases, and one
    // odd entry must not fail the rest.
    private static func registryEntries() -> [RegistryEntry] {
        let directory = registryDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            Settings.log("teleport: no Claude session registry at \(directory.path)")
            return []
        }
        var entries: [RegistryEntry] = []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                Settings.log("teleport: could not read the session record \(name)")
                continue
            }
            guard let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0,
                  let sessionID = object["sessionId"] as? String, !sessionID.isEmpty,
                  let cwd = object["cwd"] as? String, !cwd.isEmpty else {
                Settings.log("teleport: \(name) has no pid, session id or folder")
                continue
            }
            let started = (object["startedAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1000)
            }
            let procStart = (object["procStart"] as? String).flatMap(processStart)
            let statusChanged = (object["statusUpdatedAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1000)
            }
            entries.append(RegistryEntry(pid: pid,
                                         sessionID: sessionID,
                                         cwd: cwd,
                                         startedAt: started,
                                         procStart: procStart,
                                         kind: (object["kind"] as? String) ?? "",
                                         name: (object["name"] as? String) ?? "",
                                         status: (object["status"] as? String) ?? "",
                                         statusUpdatedAt: statusChanged,
                                         jobID: object["jobId"] as? String,
                                         version: object["version"] as? String))
        }
        return entries
    }

    // `ps -o lstart` text in UTC with no zone written. A one-digit day is padded with a second
    // space, hence the whitespace fold before parsing.
    private static let processStartFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    private static func processStart(_ raw: String) -> Date? {
        processStartFormat.date(from: raw.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    private static func claudeSessions(in table: ProcessTable) -> [AgentSessionInfo] {
        liveSessions(in: table).map { session in
            var named = session
            named.label = label(sessionID: session.sessionID,
                                cwd: session.cwd,
                                background: session.isBackground,
                                name: session.name)
            return named
        }
    }

    static func liveSessions(in table: ProcessTable = ProcessTable(),
                             inspect: (pid_t) -> ProcessArguments? = { arguments(of: $0) }) -> [AgentSessionInfo] {
        var sessions: [AgentSessionInfo] = []
        for entry in registryEntries() {
            guard let process = table.entry(pid: entry.pid) else { continue }
            guard let started = startTime(of: entry.pid) else { continue }
            if !startAgrees(started, procStart: entry.procStart, startedAt: entry.startedAt) {
                let claimed = entry.procStart ?? entry.startedAt ?? started
                Settings.log("teleport: pid \(entry.pid) started \(Int(started.timeIntervalSince(claimed))) s "
                             + "from what \(entry.sessionID) claims, treating it as a reused pid")
                continue
            }
            let inspected = inspect(entry.pid)
            guard looksLikeClaude(process: process, arguments: inspected) else {
                Settings.log("teleport: pid \(entry.pid) is \(process.command), not the claude \(entry.sessionID) claims")
                continue
            }
            // `kind` is `interactive` or `bg` today, but Claude may add more: anything with a
            // `jobId` is something `claude attach` can open.
            let background = entry.kind != "interactive" && (entry.kind == "bg" || entry.jobID != nil)
            let environment = inspected?.environment ?? [:]
            sessions.append(AgentSessionInfo(
                pid: entry.pid,
                sessionID: entry.sessionID,
                cwd: entry.cwd,
                name: entry.name,
                label: trimmed(entry.name),
                isBackground: background,
                attachID: background ? entry.jobID : nil,
                status: status(entry.status),
                startedAt: entry.startedAt ?? started,
                procStart: entry.procStart,
                host: host(environment: environment),
                tty: ttyName(process.tdev),
                version: entry.version,
                statusUpdatedAt: entry.statusUpdatedAt))
        }
        return sessions
    }

    struct HostedSession {
        var session: AgentSessionInfo
        var processGroup: pid_t
    }

    // SLYTERM_TAB_ID is inherited by anything started in the tab (tmux, editors) and answers type
    // into the pty, so a session belongs to a tab only while it is the foreground job on its pty.
    static func hostedSessions(tabs: [UUID: TabProbe],
                               inspect: (pid_t) -> ProcessArguments? = { arguments(of: $0) },
                               files: AgentDiscovery.Cache = AgentDiscovery.Cache()) -> [UUID: HostedSession] {
        let table = ProcessTable()
        var hosted = hostedClaudes(tabs: tabs.mapValues(\.tty), in: table, inspect: inspect)
        let open = Dictionary(tabs.filter { hosted[$0.key] == nil }.map { ($0.value.tty, $0.key) },
                              uniquingKeysWith: { first, _ in first })
        guard !open.isEmpty else { return hosted }
        let tuis = AgentDiscovery.tuis(in: table, on: Set(open.keys), inspect: inspect)
        guard !tuis.isEmpty else { return hosted }
        var names: [String: String] = [:]
        for tui in tuis where tui.agent == .codex {
            guard let tab = open[tui.tty] else { continue }
            names[tui.tty] = AgentDiscovery.threadName(inTitle: tabs[tab]?.titles[.codex]?.name)
        }
        let found = AgentDiscovery.sessionFiles(for: tuis, titleNames: names, in: table, inspect: inspect,
                                                cache: files)
        for tui in tuis {
            guard let tab = open[tui.tty] else { continue }
            if let group = tabs[tab]?.foregroundGroup, group != tui.process.pgid { continue }
            let session = agentSession(of: tui, file: found[tui.process.pid], fallbackID: "tab:" + tab.uuidString,
                                       cache: files)
            hosted[tab] = HostedSession(session: session, processGroup: tui.process.pgid)
        }
        return hosted
    }

    private static func hostedClaudes(tabs: [UUID: String], in table: ProcessTable,
                                      inspect: (pid_t) -> ProcessArguments?) -> [UUID: HostedSession] {
        let sessions = liveSessions(in: table, inspect: inspect)
        var hosted: [UUID: HostedSession] = [:]
        var background: [String: AgentSessionInfo] = [:]
        func inFront(_ process: ProcessTable.Entry, of tab: UUID) -> Bool {
            guard let tty = tabs[tab] else { return false }
            return ttyName(process.tdev) == tty && process.pgid > 0 && process.pgid == process.tpgid
        }
        for session in sessions {
            if let job = session.attachID, session.isBackground { background[job] = session }
            guard case .slyTerm(let tabID) = session.host, let tabID,
                  let process = table.entry(pid: session.pid), inFront(process, of: tabID) else { continue }
            if let known = hosted[tabID], known.session.startedAt < session.startedAt { continue }
            hosted[tabID] = HostedSession(session: session, processGroup: process.pgid)
        }
        guard !background.isEmpty else { return hosted }
        let registered = Set(sessions.map(\.pid))
        let ttys = Set(tabs.values)
        for process in table.entries where !registered.contains(process.pid) {
            guard process.tdev != ProcessTable.noDevice, couldBeClaude(process) else { continue }
            guard process.pgid == process.tpgid, let tty = ttyName(process.tdev), ttys.contains(tty) else { continue }
            guard let inspected = inspect(process.pid),
                  let tab = inspected.environment["SLYTERM_TAB_ID"].flatMap(UUID.init(uuidString:)),
                  hosted[tab] == nil, inFront(process, of: tab) else { continue }
            guard inspected.arguments.contains("attach") else { continue }
            guard let session = inspected.arguments.compactMap({ background[$0] }).first else { continue }
            hosted[tab] = HostedSession(session: session, processGroup: process.pgid)
        }
        return hosted
    }

    // Every other agent's TUI in front on a terminal, with or without a session file. Claude's
    // own groups are left out: an agent it runs as a tool is not the tab's.
    static func runningAgents(in table: ProcessTable, besides claude: [AgentSessionInfo],
                              inspect: (pid_t) -> ProcessArguments?,
                              cache: AgentDiscovery.Cache) -> [AgentSessionInfo] {
        let tuis = agentTUIs(in: table, besides: claude, inspect: inspect)
        let files = AgentDiscovery.sessionFiles(for: tuis, in: table, inspect: inspect, cache: cache)
        return tuis.map { tui in
            let tab = tui.environment["SLYTERM_TAB_ID"].flatMap(UUID.init(uuidString:))
            return agentSession(of: tui, file: files[tui.process.pid],
                                fallbackID: tab.map { "tab:" + $0.uuidString } ?? "tty:" + tui.tty, cache: cache)
        }
    }

    // The picker's rows: only a TUI with a session file can be resumed elsewhere.
    private static func agentSessions(in table: ProcessTable,
                                      besides claude: [AgentSessionInfo]) -> [AgentSessionInfo] {
        let cache = AgentDiscovery.Cache()
        let inspect: (pid_t) -> ProcessArguments? = { arguments(of: $0) }
        let tuis = agentTUIs(in: table, besides: claude, inspect: inspect)
        let files = AgentDiscovery.sessionFiles(for: tuis, in: table, inspect: inspect, cache: cache)
        return tuis.compactMap { tui in
            guard let file = files[tui.process.pid] else { return nil }
            var session = agentSession(of: tui, file: file, fallbackID: "", cache: cache)
            guard !session.sessionID.isEmpty else { return nil }
            let head = AgentDiscovery.head(of: file.url, agent: tui.agent, cache: cache)
            let reading: TranscriptTail.Reading
            var title: String?
            switch tui.agent {
            case .codex:
                reading = CodexRollout.read(file.url)
                let home = AgentDiscovery.codexHome(tui.environment)
                title = AgentDiscovery.threadNames(in: home, cache: cache)[session.sessionID]
            case .omp, .pi:
                reading = PiSession.read(file.url)
                title = head?.title
            case .claude, .gemini, .qwen:
                return nil
            }
            let text = [title, head?.firstPrompt].compactMap { $0 }.first { !$0.isEmpty }
            session.label = trimmed(text ?? (session.cwd as NSString).lastPathComponent)
            session.status = reading.status ?? .unknown
            return session
        }
    }

    private static func agentTUIs(in table: ProcessTable, besides claude: [AgentSessionInfo],
                                  inspect: (pid_t) -> ProcessArguments?) -> [AgentDiscovery.TUI] {
        let groups = Set(claude.compactMap { table.entry(pid: $0.pid)?.pgid })
        return AgentDiscovery.tuis(in: table, inspect: inspect).filter { !groups.contains($0.process.pgid) }
    }

    private static func agentSession(of tui: AgentDiscovery.TUI, file: AgentDiscovery.SessionFile?,
                                     fallbackID: String, cache: AgentDiscovery.Cache) -> AgentSessionInfo {
        let started = startTime(of: tui.process.pid)
        let head = file.flatMap { AgentDiscovery.head(of: $0.url, agent: tui.agent, cache: cache) }
        let id = head?.id ?? file.flatMap { AgentDiscovery.fileID(of: $0.url, agent: tui.agent) } ?? fallbackID
        let cwd = head.map(\.cwd).flatMap { $0.isEmpty ? nil : $0 }
            ?? workingDirectory(of: tui.process.pid) ?? ""
        return AgentSessionInfo(pid: tui.process.pid,
                                sessionID: id,
                                cwd: cwd,
                                name: head?.title ?? "",
                                label: "",
                                isBackground: false,
                                attachID: nil,
                                status: .unknown,
                                startedAt: started ?? Date(),
                                procStart: started,
                                host: host(environment: tui.environment),
                                tty: tui.tty,
                                version: nil,
                                statusUpdatedAt: nil,
                                agent: tui.agent,
                                transcript: file?.url,
                                turnsRunElsewhere: file?.runsElsewhere ?? false)
    }

    // Claude Code execs a versioned binary: its kernel name is `claude` or a version (`2.1.278`).
    private static func couldBeClaude(_ process: ProcessTable.Entry) -> Bool {
        if process.command.localizedCaseInsensitiveContains("claude") { return true }
        let parts = process.command.split(separator: ".")
        return parts.count >= 3 && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static func status(_ raw: String) -> TeleportStatus {
        switch raw {
        case "busy": return .working
        case "waiting": return .waiting
        case "idle": return .idle
        default: return .unknown
        }
    }

    private static func looksLikeClaude(process: ProcessTable.Entry, arguments: ProcessArguments?) -> Bool {
        if process.command.localizedCaseInsensitiveContains("claude") { return true }
        guard let arguments else { return false }
        if arguments.executablePath.localizedCaseInsensitiveContains("claude") { return true }
        return arguments.arguments.contains { $0.localizedCaseInsensitiveContains("claude") }
    }

    private static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "nu"]

    private static func shellTabs(in table: ProcessTable, ignoringTTYs claimed: Set<String>) -> [ShellTabInfo] {
        var byTTY: [String: [ProcessTable.Entry]] = [:]
        for process in table.entries where process.tdev != ProcessTable.noDevice {
            guard isShell(process.command) else { continue }
            guard let tty = ttyName(process.tdev), !claimed.contains(tty) else { continue }
            byTTY[tty, default: []].append(process)
        }
        var tabs: [ShellTabInfo] = []
        for (tty, shells) in byTTY {
            let pids = Set(shells.map(\.pid))
            let outermost = shells.filter { !pids.contains($0.ppid) }.min { $0.pid < $1.pid }
            guard let shell = outermost ?? shells.min(by: { $0.pid < $1.pid }) else { continue }
            let inspected = arguments(of: shell.pid)
            guard let host = host(ofShell: shell, inspected: inspected, in: table) else {
                Settings.log("teleport: \(tty) belongs to no terminal we can name, skipping it")
                continue
            }
            if host.isSlyTerm { continue }
            guard let cwd = workingDirectory(of: shell.pid), let started = startTime(of: shell.pid) else { continue }
            tabs.append(ShellTabInfo(
                shellPid: shell.pid,
                tty: tty,
                cwd: cwd,
                shellName: shellName(of: shell, arguments: inspected),
                foregroundCommand: foregroundCommand(ofShell: shell, in: table),
                host: host,
                startedAt: started))
        }
        return tabs
    }

    private static func isShell(_ command: String) -> Bool {
        shellNames.contains(command.hasPrefix("-") ? String(command.dropFirst()) : command)
    }

    private static func shellName(of shell: ProcessTable.Entry, arguments: ProcessArguments?) -> String {
        let raw = arguments?.arguments.first ?? shell.command
        let name = (raw as NSString).lastPathComponent
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    // macOS withholds the environment of SIP-protected binaries (every stock shell), so ask a
    // process in the tab that kept it (it carries ITERM_SESSION_ID too), then walk the ancestry.
    private static func host(ofShell shell: ProcessTable.Entry,
                             inspected: ProcessArguments?,
                             in table: ProcessTable) -> TeleportHost? {
        if let environment = inspected?.environment, environment["TERM_PROGRAM"] != nil {
            return host(environment: environment)
        }
        for process in table.entries
        where process.pid != shell.pid && process.tdev == shell.tdev && process.uid == shell.uid {
            guard let environment = arguments(of: process.pid)?.environment,
                  environment["TERM_PROGRAM"] != nil else { continue }
            return host(environment: environment)
        }
        var pid = shell.ppid
        for _ in 0..<8 {
            guard pid > 1, let process = table.entry(pid: pid) else { break }
            if let program = terminalProgram(executablePath: executablePath(of: pid) ?? "") {
                return TeleportHost(program: program, itermSessionID: nil, termSessionID: nil, slyTermTabID: nil)
            }
            pid = process.ppid
        }
        return nil
    }

    private static func terminalProgram(executablePath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix("iTermServer") || path.contains("/iTerm.app/") { return "iTerm.app" }
        if path.contains("/Terminal.app/") { return "Apple_Terminal" }
        if name == "SlyTerm" || path.contains("/SlyTerm.app/") { return "SlyTerm" }
        if path.contains("/Ghostty.app/") { return "ghostty" }
        if path.contains("/WezTerm.app/") { return "WezTerm" }
        if path.contains("/kitty.app/") { return "kitty" }
        if path.contains("/Alacritty.app/") { return "Alacritty" }
        if path.contains("/Warp.app/") { return "WarpTerminal" }
        if path.contains("/Hyper.app/") { return "Hyper" }
        if path.contains("/Visual Studio Code.app/") || path.contains("/Code - Insiders.app/") { return "vscode" }
        return nil
    }

    private static func host(environment: [String: String]) -> TeleportHost {
        TeleportHost(program: environment["TERM_PROGRAM"],
                     itermSessionID: environment["ITERM_SESSION_ID"],
                     termSessionID: environment["TERM_SESSION_ID"],
                     slyTermTabID: environment["SLYTERM_TAB_ID"])
    }

    private static func foregroundCommand(ofShell shell: ProcessTable.Entry, in table: ProcessTable) -> String? {
        let group = shell.tpgid
        guard group > 0, group != shell.pgid else { return nil }
        let members = table.entries.filter { $0.tdev == shell.tdev && $0.pgid == group && $0.pid != shell.pid }
        guard let leader = members.first(where: { $0.pid == group }) ?? members.min(by: { $0.pid < $1.pid }) else { return nil }
        guard let inspected = arguments(of: leader.pid), !inspected.arguments.isEmpty else { return leader.command }
        var words = inspected.arguments
        words[0] = (words[0] as NSString).lastPathComponent
        return words.joined(separator: " ")
    }

    private static let transcriptWindow = 256 * 1024

    // A foreground session's registry name is only the folder slug. Claude Code writes `ai-title`
    // records as the topic changes (last wins); older transcripts have `summary` instead.
    private static func label(sessionID: String, cwd: String, background: Bool, name: String) -> String {
        if background, !name.isEmpty { return trimmed(name) }
        guard let url = transcriptURL(cwd: cwd, sessionID: sessionID) else { return trimmed(name) }
        guard let (head, tail) = transcriptEnds(of: url) else { return trimmed(name) }
        let newestFirst = Array(tail.reversed()) + Array(head.reversed())
        if let title = firstValue(in: newestFirst, ofType: "ai-title", field: "aiTitle") { return trimmed(title) }
        if let summary = firstValue(in: newestFirst, ofType: "summary", field: "summary") { return trimmed(summary) }
        if let prompt = firstPrompt(in: head) { return trimmed(prompt) }
        return trimmed(name)
    }

    // Claude Code's slug: every non-alphanumeric character of the cwd becomes `-`.
    static func transcriptURL(cwd: String, sessionID: String) -> URL? {
        let slug = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)/\(sessionID).jsonl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func transcriptEnds(of url: URL) -> (head: [Data], tail: [Data])? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: transcriptWindow)) ?? Data()
        let whole = size <= UInt64(transcriptWindow)
        var headLines = lines(in: head)
        if !whole, !headLines.isEmpty { headLines.removeLast() }
        guard !whole else { return (headLines, []) }
        try? handle.seek(toOffset: size - UInt64(transcriptWindow))
        var tailLines = lines(in: (try? handle.read(upToCount: transcriptWindow)) ?? Data())
        if !tailLines.isEmpty { tailLines.removeFirst() }
        return (headLines, tailLines)
    }

    // Copied out: a Data slice keeps its parent's indices, which range(of:) and the JSON
    // parser mishandle.
    static func lines(in data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
    }

    private static func firstValue(in records: [Data], ofType type: String, field: String) -> String? {
        let marker = Data("\"\(type)\"".utf8)
        for line in records where line.range(of: marker) != nil {
            guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  record["type"] as? String == type,
                  let value = record[field] as? String, !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    // Claude Code's bookkeeping `user` records (`!` output caveats, `<command-name>` wrappers)
    // start with a tag; a typed prompt never does.
    private static func firstPrompt(in records: [Data]) -> String? {
        let marker = Data("\"user\"".utf8)
        for line in records where line.range(of: marker) != nil {
            guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  record["type"] as? String == "user",
                  record["isMeta"] as? Bool != true,
                  record["isSidechain"] as? Bool != true,
                  let message = record["message"] as? [String: Any] else { continue }
            var text: String?
            if let string = message["content"] as? String {
                text = string
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
            }
            guard let found = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !found.isEmpty, !found.hasPrefix("<") else { continue }
            return found
        }
        return nil
    }

    static func trimmed(_ text: String, to limit: Int = 80) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        guard let space = cut.lastIndex(of: " "), space > cut.index(cut.startIndex, offsetBy: limit / 2) else {
            return cut.trimmingCharacters(in: .whitespaces) + "…"
        }
        return cut[..<space].trimmingCharacters(in: .whitespaces) + "…"
    }

    struct ProcessTable {
        static let noDevice: dev_t = -1

        struct Entry {
            var pid: pid_t
            var ppid: pid_t
            var pgid: pid_t
            var tdev: dev_t
            var tpgid: pid_t
            var command: String
            var uid: uid_t
        }

        let entries: [Entry]
        private let byPID: [pid_t: Entry]

        init() {
            let entries = ProcessTable.read()
            self.entries = entries
            byPID = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        }

        func entry(pid: pid_t) -> Entry? { byPID[pid] }

        private static func read() -> [Entry] {
            var mib: [CInt] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var length = 0
            guard sysctl(&mib, 4, nil, &length, nil, 0) == 0, length > 0 else { return [] }
            length += length / 8
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: length / MemoryLayout<kinfo_proc>.stride + 1)
            guard sysctl(&mib, 4, &buffer, &length, nil, 0) == 0 else { return [] }
            return buffer.prefix(length / MemoryLayout<kinfo_proc>.stride).map { process in
                var name = process.kp_proc.p_comm
                let capacity = MemoryLayout.size(ofValue: name)
                let command = withUnsafePointer(to: &name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
                }
                return Entry(pid: process.kp_proc.p_pid,
                             ppid: process.kp_eproc.e_ppid,
                             pgid: process.kp_eproc.e_pgid,
                             tdev: process.kp_eproc.e_tdev,
                             tpgid: process.kp_eproc.e_tpgid,
                             command: command,
                             uid: process.kp_eproc.e_ucred.cr_uid)
            }
        }
    }

    struct ProcessArguments {
        var executablePath: String
        var arguments: [String]
        var environment: [String: String]
    }

    private static let argumentsMaximum: Int = {
        var mib: [CInt] = [CTL_KERN, KERN_ARGMAX]
        var value: CInt = 0
        var size = MemoryLayout<CInt>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 256 * 1024 }
        return Int(value)
    }()

    static func arguments(of pid: pid_t) -> ProcessArguments? {
        var mib: [CInt] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = argumentsMaximum
        // Uninitialised on purpose: zeroing a megabyte per call is the whole cost.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: argumentsMaximum, alignment: 8)
        defer { buffer.deallocate() }
        guard sysctl(&mib, 3, buffer, &length, nil, 0) == 0, length > MemoryLayout<CInt>.size else { return nil }
        let raw = UnsafeRawBufferPointer(start: buffer, count: length)
        let count = Int(raw.loadUnaligned(as: CInt.self))
        // KERN_PROCARGS2 layout: argc, exec path, NUL padding, argc arguments, then environment.
        var strings: [String] = []
        var start = MemoryLayout<CInt>.size
        for index in start..<length where raw[index] == 0 {
            strings.append(String(decoding: raw[start..<index], as: UTF8.self))
            start = index + 1
        }
        guard let path = strings.first else { return nil }
        var index = 1
        while index < strings.count, strings[index].isEmpty { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < strings.count {
            arguments.append(strings[index])
            index += 1
        }
        var environment: [String: String] = [:]
        while index < strings.count {
            let entry = strings[index]
            index += 1
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return ProcessArguments(executablePath: path, arguments: arguments, environment: environment)
    }

    static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                    + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // devname_r walks /dev, most of a millisecond a call, and a device number keeps its name.
    private static let ttyNames = NSCache<NSNumber, NSString>()

    static func ttyName(_ device: dev_t) -> String? {
        guard device != ProcessTable.noDevice else { return nil }
        let key = NSNumber(value: device)
        if let known = ttyNames.object(forKey: key) { return known as String }
        var buffer = [CChar](repeating: 0, count: 64)
        guard let named = devname_r(device, mode_t(S_IFCHR), &buffer, Int32(buffer.count)) else { return nil }
        let name = String(cString: named)
        // devname_r names an unknown device like `#C:16:1`.
        guard !name.isEmpty, !name.hasPrefix("#") else { return nil }
        ttyNames.setObject(name as NSString, forKey: key)
        return name
    }

    static func ttyName(fromArgument argument: String) -> String {
        argument.hasPrefix("/dev/") ? String(argument.dropFirst("/dev/".count)) : argument
    }
}
