import Foundation

enum SessionsCLI {
    static func run(_ args: [String]) -> Bool {
        guard args.count >= 2, args[1] == "--sessions" else { return false }
        let started = Date()
        let candidates = lookup(in: args) ?? SessionDiscovery.scan()
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        if args.contains("--send-back") {
            print(candidates.map { sendBack($0, copy: args.contains("--copy")) }.joined(separator: "\n\n"))
        } else if args.contains("--json") {
            print(json(candidates))
        } else {
            print(table(candidates))
        }
        FileHandle.standardError.write(Data("scanned \(candidates.count) candidates in \(milliseconds) ms\n".utf8))
        return true
    }

    private static func lookup(in args: [String]) -> [TeleportCandidate]? {
        if let id = value(of: "--session", in: args) {
            return SessionDiscovery.agentSession(id: id).map { [.agent($0)] } ?? []
        }
        if let pid = value(of: "--pid", in: args).flatMap(pid_t.init) {
            return SessionDiscovery.agentSession(pid: pid).map { [.agent($0)] } ?? []
        }
        if let tty = value(of: "--tty", in: args) {
            let agents = SessionDiscovery.agentSessions(tty: tty).map(TeleportCandidate.agent)
            return agents + (SessionDiscovery.shellTab(tty: tty).map { [.shell($0)] } ?? [])
        }
        return nil
    }

    // What the app would do with this candidate's SlyTerm tab; nothing is stopped or opened.
    private static func sendBack(_ candidate: TeleportCandidate, copy: Bool) -> String {
        var lines = ["\(candidate.id)  \(candidate.title)"]
        if !candidate.isAlreadyHere {
            lines.append("  in \(candidate.host.displayName), not a SlyTerm tab: the app would not offer this")
        }
        let session: AgentSessionInfo?
        let busy: Bool
        switch candidate {
        case .agent(let s): session = s; busy = true
        case .shell(let tab): session = nil; busy = tab.foregroundCommand != nil
        }
        let terminal = SendBackTerminal.current
        let line: String
        switch TeleportEngine.sendBackPlan(session: session, folder: candidate.cwd, busy: busy, copy: copy) {
        case .failure(let error):
            lines.append("  stays: \(error.message)")
            return lines.joined(separator: "\n")
        case .success(.resume(let s, let typed, let command)):
            lines.append("  stop pid \(s.pid) with SIGTERM" + (s.agent == .claude ? ", then Ctrl-C twice in its tab" : ""))
            lines.append("  if \(terminal.name) fails, type here again: \(command)")
            line = typed
        case .success(.fork(let typed)):
            lines.append("  leave pid \(session?.pid ?? 0) running")
            line = typed
        case .success(.attach(let typed, _, _)):
            lines.append("  close the tab, which detaches it")
            line = typed
        case .success(.folder(let typed, let closes)):
            lines.append(closes ? "  close the tab" : "  keep the tab, it is running something")
            line = typed
        }
        lines.append("  open a tab in \(terminal.name) and type: \(line)")
        let script = TeleportEngine.openScript(typing: line, in: terminal) ?? """
            wezterm cli --no-auto-start list --format json
            wezterm cli --no-auto-start spawn --window-id <first window listed, else --new-window>
            wezterm cli --no-auto-start send-text --no-paste --pane-id <new pane> -- <line>
            """
        lines.append(script.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static let headings = ["KIND", "HOST", "STATUS", "PID", "TTY", "FOLDER", "SESSION", "ACTION", "LABEL"]

    private static func table(_ candidates: [TeleportCandidate]) -> String {
        let rows = [headings] + candidates.map(row)
        var widths = [Int](repeating: 0, count: headings.count)
        for row in rows {
            for (column, cell) in row.enumerated() where column < widths.count - 1 {
                widths[column] = max(widths[column], cell.count)
            }
        }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    private static func row(_ candidate: TeleportCandidate) -> [String] {
        let action = TeleportAction.primary(for: candidate).title
        switch candidate {
        case .agent(let session):
            return [kind(session),
                    session.host.displayName,
                    name(session.status),
                    String(session.pid),
                    session.tty ?? "-",
                    folder(session.cwd),
                    session.attachID ?? String(session.sessionID.prefix(8)),
                    action,
                    session.label]
        case .shell(let tab):
            return ["shell",
                    tab.host.displayName,
                    tab.foregroundCommand == nil ? "idle" : "running",
                    String(tab.shellPid),
                    tab.tty,
                    folder(tab.cwd),
                    "-",
                    action,
                    tab.foregroundCommand ?? tab.shellName]
        }
    }

    private static func kind(_ session: AgentSessionInfo) -> String {
        guard session.agent == .claude else { return session.agent.rawValue }
        return session.isBackground ? "bg" : "claude"
    }

    private static func folder(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private static func name(_ status: TeleportStatus) -> String {
        switch status {
        case .working: return "working"
        case .waiting: return "waiting"
        case .idle: return "idle"
        case .unknown: return "unknown"
        }
    }

    private static func json(_ candidates: [TeleportCandidate]) -> String {
        let formatter = ISO8601DateFormatter()
        let objects: [[String: Any]] = candidates.map { candidate in
            var object: [String: Any] = [
                "id": candidate.id,
                "host": host(candidate.host),
                "cwd": candidate.cwd,
                "title": candidate.title,
                "startedAt": formatter.string(from: candidate.startedAt),
                "alreadyHere": candidate.isAlreadyHere,
                "action": TeleportAction.primary(for: candidate).title,
                "secondaryAction": TeleportAction.secondary(for: candidate).map { $0.title } ?? NSNull(),
            ]
            switch candidate {
            case .agent(let session):
                object["kind"] = kind(session)
                object["agent"] = session.agent.rawValue
                object["transcript"] = session.transcript?.path ?? NSNull()
                object["turnsRunElsewhere"] = session.turnsRunElsewhere
                object["pid"] = session.pid
                object["sessionId"] = session.sessionID
                object["name"] = session.name
                object["label"] = session.label
                object["isBackground"] = session.isBackground
                object["attachId"] = session.attachID ?? NSNull()
                object["status"] = name(session.status)
                object["tty"] = session.tty ?? NSNull()
                object["version"] = session.version ?? NSNull()
                object["running"] = SessionDiscovery.isRunning(session)
            case .shell(let tab):
                object["kind"] = "shell"
                object["pid"] = tab.shellPid
                object["shellPid"] = tab.shellPid
                object["tty"] = tab.tty
                object["shellName"] = tab.shellName
                object["foregroundCommand"] = tab.foregroundCommand ?? NSNull()
            }
            return object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func host(_ host: TeleportHost) -> [String: Any] {
        var object: [String: Any] = ["name": host.displayName, "canCloseSource": host.canCloseSource]
        switch host {
        case .iTerm2(let id): object["itermSessionId"] = id ?? NSNull()
        case .appleTerminal(let id): object["termSessionId"] = id ?? NSNull()
        case .slyTerm(let id): object["slyTermTabId"] = id?.uuidString ?? NSNull()
        case .other(let program): object["termProgram"] = program
        case .unknown: break
        }
        return object
    }
}
