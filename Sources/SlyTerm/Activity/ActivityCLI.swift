import Foundation

enum ActivityCLI {
    static func run(_ args: [String]) -> Bool {
        guard args.count >= 2, args[1] == "--activity" else { return false }
        if let path = value(of: "--transcript", in: args) {
            transcript(at: path, status: value(of: "--status", in: args))
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

    private static let headings = ["PID", "HOST", "STATUS", "SINCE", "TURN", "DOING", "ASKS", "LAST MESSAGE"]

    private static func table(_ rows: [(session: AgentSessionInfo, activity: AgentActivity)]) -> String {
        let cells = [headings] + rows.map { row in
            [String(row.session.pid),
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

    private static func json(_ rows: [(session: AgentSessionInfo, activity: AgentActivity)]) -> String {
        let formatter = ISO8601DateFormatter()
        let objects: [[String: Any]] = rows.map { session, activity in
            var object: [String: Any] = [
                "pid": session.pid,
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

    private static func transcript(at path: String, status: String?) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            FileHandle.standardError.write(Data("cannot read \(url.path)\n".utf8))
            return
        }
        let started = Date()
        let reading = TranscriptTail.read(url)
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)

        print("file:      \(url.path) (\((size ?? 0) / 1024) KB)")
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
