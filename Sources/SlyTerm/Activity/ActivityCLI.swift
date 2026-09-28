import Foundation

enum ActivityCLI {
    static func run(_ args: [String]) -> Bool {
        guard args.count >= 2, args[1] == "--activity" else { return false }
        var agent: AgentKind?
        if let name = value(of: "--agent", in: args) {
            guard let kind = AgentKind(rawValue: name.lowercased()) else {
                let names = AgentKind.allCases.map(\.rawValue).joined(separator: ", ")
                let text = "unknown agent \(name); one of \(names)\n"
                FileHandle.standardError.write(Data(text.utf8))
                return true
            }
            agent = kind
        }
        if let path = value(of: "--transcript", in: args) {
            transcript(at: path, status: value(of: "--status", in: args), agent: agent)
        } else if let text = value(of: "--title", in: args) {
            title(text, agents: agent.map { [$0] } ?? AgentTitle.kinds)
        } else if let path = value(of: "--screen", in: args) {
            screen(at: path, agents: agent.map { [$0] } ?? [.codex, .omp])
        } else if args.contains("--poll") {
            poll(times: value(of: "--times", in: args).flatMap(Int.init) ?? 2)
        } else {
            list(json: args.contains("--json"))
        }
        return true
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func list(json wantsJSON: Bool) {
        let started = Date()
        let rows = ActivityMonitor().scanEverything()
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        print(wantsJSON ? self.json(rows) : table(rows))
        FileHandle.standardError.write(Data("scanned \(rows.count) sessions in \(milliseconds) ms\n".utf8))
    }

    private static let headings = ["PID", "AGENT", "HOST", "STATUS", "SINCE", "TURN", "DOING",
                                   "ASKS", "LAST MESSAGE"]

    private static func table(
        _ rows: [(session: AgentSessionInfo, activity: AgentActivity)]) -> String {
        let cells = [headings] + rows.map { row in
            [String(row.session.pid),
             row.session.agent.rawValue,
             host(row.session.host),
             name(row.activity.status),
             row.activity.since.map { activityElapsed(since: $0) } ?? "-",
             row.activity.lastTurnDuration.map(activityDuration) ?? "-",
             row.activity.doing?.label ?? "-",
             summary(row.activity.request) ?? "-",
             firstLine(row.activity.lastMessage) ?? "-"]
        }
        var widths = [Int](repeating: 0, count: headings.count)
        for row in cells {
            for (column, cell) in row.enumerated() where column < widths.count - 1 {
                widths[column] = max(widths[column], cell.count)
            }
        }
        return cells.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    private static func host(_ host: TeleportHost) -> String {
        if case .slyTerm(let tab) = host, let tab { return "SlyTerm tab \(tab.uuidString.prefix(8))" }
        return host.displayName
    }

    private static func json(
        _ rows: [(session: AgentSessionInfo, activity: AgentActivity)]) -> String {
        let formatter = ISO8601DateFormatter()
        let objects: [[String: Any]] = rows.map { session, activity in
            var object: [String: Any] = [
                "pid": session.pid,
                "agent": session.agent.rawValue,
                "sessionId": session.sessionID,
                "cwd": session.cwd,
                "name": session.name,
                "host": host(session.host),
                "isBackground": session.isBackground,
                "status": name(activity.status),
                "since": activity.since.map(formatter.string(from:)) ?? NSNull(),
                "elapsed": activity.since.map { activityElapsed(since: $0) } ?? NSNull(),
                "lastMessage": activity.lastMessage ?? NSNull(),
                "lastTurnDuration": activity.lastTurnDuration ?? NSNull(),
            ]
            if let doing = activity.doing {
                var call: [String: Any] = ["tool": doing.tool, "label": doing.label]
                call["startedAt"] = doing.startedAt.map(formatter.string(from:)) ?? NSNull()
                object["doing"] = call
            }
            switch activity.request {
            case .permission(let tool, let summary, let detail):
                var permission: [String: Any] = ["kind": "permission", "tool": tool, "summary": summary]
                permission["detail"] = detail ?? NSNull()
                object["request"] = permission
            case .question(let text, let options):
                object["request"] = ["kind": "question", "question": text, "options": options]
            case .unknown:
                object["request"] = ["kind": "unknown"]
            case nil:
                break
            }
            return object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func transcript(at path: String, status: String?, agent forced: AgentKind?) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            FileHandle.standardError.write(Data("cannot read \(url.path)\n".utf8))
            return
        }
        let agent = forced ?? kind(of: url)
        let started = Date()
        let reading: TranscriptTail.Reading
        switch agent {
        case .codex: reading = CodexRollout.read(url)
        case .pi, .omp: reading = PiSession.read(url)
        case .claude, .gemini, .qwen: reading = TranscriptTail.read(url)
        }
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)

        print("file:      \(url.path) (\((size ?? 0) / 1024) KB)")
        if agent != .claude { head(of: url, agent: agent, reading: reading) }
        if let doing = reading.doing {
            print("pending:   \(doing.tool)")
            print("label:     \(doing.label)")
            print("issued:    \(doing.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-")")
        } else {
            print("pending:   -")
        }
        print("request:   \(describe(reading.request))")
        print("turn:      \(reading.lastTurnDuration.map { activityDuration($0) + " (\($0) s)" } ?? "-")")
        if let asked = status {
            let shows = asked == "busy" ? "doing" : (asked == "waiting" ? "request" : "neither")
            print("status:    \(asked) → the tab would show its \(shows)")
        }
        print("message:   \(reading.lastMessage == nil ? "-" : "")")
        if let message = reading.lastMessage {
            for line in message.components(separatedBy: .newlines) { print("  " + line) }
        }
        FileHandle.standardError.write(Data("parsed in \(milliseconds) ms\n".utf8))
    }

    // Codex rollouts open with `session_meta`, omp sessions with their title slot and pi sessions
    // with their header; anything else is taken for Claude Code's.
    private static func kind(of url: URL) -> AgentKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .claude }
        defer { try? handle.close() }
        let start = (try? handle.read(upToCount: 512)) ?? Data()
        let line = start.prefix { $0 != UInt8(ascii: "\n") }
        let markers: [(String, AgentKind)] = [("session_meta", .codex), ("title", .omp),
                                              ("session", .pi)]
        for (marker, agent) in markers
        where line.range(of: Data("\"type\":\"\(marker)\"".utf8)) != nil {
            return agent
        }
        return .claude
    }

    private static func head(of url: URL, agent: AgentKind, reading: TranscriptTail.Reading) {
        let formatter = ISO8601DateFormatter()
        print("agent:     \(agent.rawValue)")
        if agent == .codex, let head = CodexRollout.head(url) {
            // Rollouts sit in `sessions/YYYY/MM/DD/` under the Codex home; a copy may sit beside
            // its index.
            let folder = url.deletingLastPathComponent()
            let home = (0..<4).reduce(folder) { dir, _ in dir.deletingLastPathComponent() }
            let names = CodexRollout.threadNames(in: folder)
                .merging(CodexRollout.threadNames(in: home)) { $1 }
            print("id:        \(head.id)")
            print("cwd:       \(head.cwd)")
            print("started:   \(head.startedAt.map(formatter.string(from:)) ?? "-")")
            print("origin:    \(head.originator ?? "-")")
            print("thread:    \(names[head.id] ?? "-")")
            let prompt = head.firstPrompt.map { SessionDiscovery.trimmed($0, to: 80) }
            print("prompt:    \(prompt ?? "-")")
        } else if agent != .codex, let head = PiSession.head(url) {
            print("id:        \(head.id)")
            print("cwd:       \(head.cwd)")
            print("started:   \(head.startedAt.map(formatter.string(from:)) ?? "-")")
            print("title:     \(head.title ?? "-")")
            let prompt = head.firstPrompt.map { SessionDiscovery.trimmed($0, to: 80) }
            print("prompt:    \(prompt ?? "-")")
        } else {
            print("head:      -")
        }
        print("status:    \(reading.status.map(name) ?? "-")")
        print("since:     \(reading.statusSince.map(formatter.string(from:)) ?? "-")")
        print("ended:     \(reading.ended ? "yes" : "no")")
    }

    private static func title(_ text: String, agents: [AgentKind]) {
        print("title:     \"\(text)\"")
        for agent in agents {
            let shown = AgentTitle.parse(text, agent: agent).map { parsed in
                "\(name(parsed.status)) \(parsed.marked ? "marked" : "unmarked") \"\(parsed.name)\""
            }
            let column = agent.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)
            print(column + (shown ?? "-"))
        }
    }

    // A capture may start with a `# title: '…'` line: the tab's title when the screen was taken.
    private static func screen(at path: String, agents: [AgentKind]) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            FileHandle.standardError.write(Data("cannot read \(url.path)\n".utf8))
            return
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var title: String?
        if let first = lines.first, first.hasPrefix("# title: ") {
            lines.removeFirst()
            title = first.dropFirst("# title: ".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        }
        print("file:      \(url.path) (\(lines.count) rows)")
        for agent in agents {
            if let title {
                let status = AgentTitle.parse(title, agent: agent).map { name($0.status) } ?? "-"
                print("title:     \(agent.rawValue) \(status) \"\(title)\"")
            }
            let request = AgentScreen.request(lines: lines, agent: agent)
            print("request:   \(agent.rawValue) \(describe(request))")
        }
    }

    private static func describe(_ request: AgentRequest?) -> String {
        switch request {
        case .permission(let tool, let summary, let detail):
            return "permission(\(tool)) \(summary)" + (detail.map { "\n  detail: " + $0.replacingOccurrences(of: "\n", with: "\n          ") } ?? "")
        case .question(let text, let options):
            return "question \(text)" + (options.isEmpty ? "" : "\n  options: " + options.joined(separator: " | "))
        case .unknown: return "unknown"
        case nil: return "-"
        }
    }

    private static func poll(times: Int) {
        let monitor = ActivityMonitor()
        for pass in 1...max(1, times) {
            let started = Date()
            let rows = monitor.scanEverything()
            let milliseconds = Date().timeIntervalSince(started) * 1000
            print(String(format: "pass %d: %d sessions in %.1f ms, %d transcript%@ read",
                         pass, rows.count, milliseconds, monitor.reads, monitor.reads == 1 ? "" : "s"))
        }
    }

    private static func name(_ status: TeleportStatus) -> String {
        switch status {
        case .working: return "working"
        case .waiting: return "waiting"
        case .idle: return "idle"
        case .unknown: return "unknown"
        }
    }

    private static func summary(_ request: AgentRequest?) -> String? {
        switch request {
        case .permission(_, let summary, _): return summary
        case .question(let text, _): return "asks: " + text
        case .unknown: return "waiting"
        case nil: return nil
        }
    }

    private static func firstLine(_ text: String?) -> String? {
        guard let line = text?.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return SessionDiscovery.trimmed(line, to: 60)
    }
}
