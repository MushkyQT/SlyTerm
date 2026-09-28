import Foundation

enum TranscriptTail {
    struct Reading: Equatable {
        var doing: AgentDoing?
        var request: AgentRequest?
        var lastMessage: String?
        var lastTurnDuration: TimeInterval?
        // From the transcript itself, for agents with no registry: Claude's is never set.
        var status: TeleportStatus?
        var statusSince: Date?
        var ended = false

        var isEmpty: Bool {
            doing == nil && request == nil && lastMessage == nil && lastTurnDuration == nil && status == nil
        }
    }

    static let window = 64 * 1024
    static let deepWindow = 512 * 1024

    static let labelLimit = 60

    static func read(_ url: URL) -> Reading {
        guard let (records, whole) = tail(of: url, bytes: window) else { return Reading() }
        let reading = parse(records)
        guard reading.lastMessage == nil, !whole else { return reading }
        guard let (wider, _) = tail(of: url, bytes: deepWindow) else { return reading }
        return parse(wider)
    }

    static func tail(of url: URL, bytes: Int) -> (records: [Data], whole: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let whole = size <= UInt64(bytes)
        try? handle.seek(toOffset: whole ? 0 : size - UInt64(bytes))
        let data = (try? handle.read(upToCount: bytes)) ?? Data()
        var records = SessionDiscovery.lines(in: data)
        if !whole, !records.isEmpty { records.removeFirst() }
        return (records, whole)
    }

    // Walks backwards: a `tool_result` is always written after its `tool_use`, so a result seen
    // first cancels the call, and any call left in the open turn is still in flight.
    static func parse(_ records: [Data]) -> Reading {
        let objects = decode(records)
        var answered: Set<String> = []
        var turnClosed = false
        var pending: [(tool: String, input: [String: Any], at: Date?)] = []
        var textMessageID: String?
        var textIndex = -1
        var duration: TimeInterval?
        var durationIndex = -1

        for (index, object) in objects.enumerated().reversed() {
            switch object["type"] as? String {
            case "user":
                if let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                    for block in blocks where block["type"] as? String == "tool_result" {
                        if let id = block["tool_use_id"] as? String { answered.insert(id) }
                    }
                }
                if isTypedPrompt(object) { turnClosed = true }
            case "assistant":
                guard let message = object["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                if !turnClosed {
                    for block in blocks.reversed() where block["type"] as? String == "tool_use" {
                        guard let id = block["id"] as? String, !answered.contains(id),
                              let tool = block["name"] as? String, !tool.isEmpty else { continue }
                        pending.append((tool, block["input"] as? [String: Any] ?? [:], date(object["timestamp"])))
                    }
                }
                // One API message is written as one line per content block: gather by `message.id`.
                if textMessageID == nil, blocks.contains(where: { isText($0) }) {
                    textMessageID = (message["id"] as? String) ?? ""
                    textIndex = index
                }
            case "system":
                guard durationIndex < 0, object["subtype"] as? String == "turn_duration",
                      let milliseconds = object["durationMs"] as? NSNumber else { continue }
                duration = milliseconds.doubleValue / 1000
                durationIndex = index
            default: continue
            }
        }

        var reading = Reading()
        if let newest = pending.first {
            reading.doing = AgentDoing(tool: newest.tool,
                                        label: label(tool: newest.tool, input: newest.input),
                                        startedAt: newest.at)
            // Batched calls ask one at a time and results are written late, so with several pending
            // the prompt could be for any of them: only a single pending call identifies it.
            reading.request = pending.count == 1 ? request(tool: newest.tool, input: newest.input) : .unknown
        }
        reading.lastMessage = text(in: objects, messageID: textMessageID, at: textIndex)
        // A `turn_duration` older than the last text belongs to the previous turn.
        if durationIndex > textIndex { reading.lastTurnDuration = duration }
        return reading
    }

    private static func decode(_ records: [Data]) -> [[String: Any]] {
        let markers = [Data("\"assistant\"".utf8), Data("\"user\"".utf8), Data("\"turn_duration\"".utf8)]
        var objects: [[String: Any]] = []
        for line in records {
            guard markers.contains(where: { line.range(of: $0) != nil }) else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            // Sidechains are subagent conversations interleaved with the main one; their calls
            // are not what the user is being asked about.
            guard object["isSidechain"] as? Bool != true else { continue }
            switch object["type"] as? String {
            case "assistant", "user", "system": objects.append(object)
            default: continue
            }
        }
        return objects
    }

    private static func isText(_ block: [String: Any]) -> Bool {
        guard block["type"] as? String == "text", let text = block["text"] as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // `user` records Claude Code writes itself (tool results, `!` caveats, slash commands) are
    // `isMeta` or start with a tag; a typed prompt never does.
    private static func isTypedPrompt(_ object: [String: Any]) -> Bool {
        guard object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return false }
        var written: String?
        if let string = message["content"] as? String {
            written = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            written = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let text = written?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !text.isEmpty && !text.hasPrefix("<")
    }

    private static func text(in objects: [[String: Any]], messageID: String?, at index: Int) -> String? {
        guard let messageID, index >= 0 else { return nil }
        var parts: [String] = []
        for (offset, object) in objects.enumerated() {
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any] else { continue }
            let id = (message["id"] as? String) ?? ""
            guard messageID.isEmpty ? offset == index : id == messageID else { continue }
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks where isText(block) {
                if let text = block["text"] as? String { parts.append(text) }
            }
        }
        let joined = plainText(parts.joined(separator: "\n"))
        return joined.isEmpty ? nil : joined
    }

    // Older Claude Code releases wrote timestamps without fractional seconds, hence `plain`.
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    static func label(tool: String, input: [String: Any]) -> String {
        let text: String
        switch tool {
        case "Bash":
            let description = string(input["description"])
            text = description.isEmpty ? flattened(string(input["command"])) : description
        case "Edit", "MultiEdit", "NotebookEdit": text = verb("editing", file(input))
        case "Write": text = verb("writing", file(input))
        case "Read": text = verb("reading", file(input))
        case "Grep": text = verb("searching for", string(input["pattern"]))
        case "Glob": text = verb("finding", string(input["pattern"]))
        case "WebFetch": text = verb("fetching", host(of: string(input["url"])))
        case "WebSearch": text = verb("searching the web for", string(input["query"]))
        case "Agent", "Task": text = verb("agent:", string(input["description"]))
        case "Skill": text = verb("skill", string(input["skill"]))
        case "TodoWrite": text = "planning"
        case "AskUserQuestion": text = questions(input).first?.text ?? "asking you something"
        case "ExitPlanMode": text = "plan ready"
        default:
            if let mcp = mcp(tool) { text = "\(mcp.server): \(mcp.tool)" } else { text = tool.lowercased() }
        }
        let label = SessionDiscovery.trimmed(text, to: labelLimit)
        return label.isEmpty ? tool.lowercased() : label
    }

    private static func verb(_ verb: String, _ subject: String) -> String {
        subject.isEmpty ? verb : "\(verb) \(subject)"
    }

    // Allow-list: Return answers `.permission` with "Yes", so only tools known to show Claude
    // Code's plain yes/no prompt get one. Anything unrecognised must stay `.unknown`.
    static func request(tool: String, input: [String: Any]) -> AgentRequest {
        let summary: String
        var detail: String?
        switch tool {
        case "AskUserQuestion":
            guard let first = questions(input).first else { return .unknown }
            return .question(text: first.text, options: first.options)
        case "Bash":
            let command = string(input["command"])
            summary = command.isEmpty ? "run a command"
                                      : "run `\(SessionDiscovery.trimmed(firstLine(command), to: 60))`"
            detail = command.isEmpty ? nil : clipped(command, lines: 8, characters: 600)
        case "Edit", "MultiEdit", "NotebookEdit":
            summary = verb("edit", file(input))
            detail = path(input)
        case "Write":
            summary = verb("write", file(input))
            detail = path(input)
        case "Read":
            summary = verb("read", file(input))
            detail = path(input)
        case "WebFetch":
            summary = verb("fetch", host(of: string(input["url"])))
            detail = string(input["url"])
        case "WebSearch":
            summary = verb("search the web for", string(input["query"]))
        // A prompt while an agent runs is the subagent's own, recorded in a file this does not
        // read; allowing "start an agent" would approve that unseen request.
        case "Agent", "Task":
            return .unknown
        // Its highlighted first choice also switches the session to accepting edits.
        case "ExitPlanMode":
            return .unknown
        default:
            guard let mcp = mcp(tool) else { return .unknown }
            summary = "\(mcp.server): \(mcp.tool)"
        }
        if detail?.isEmpty == true { detail = nil }
        return .permission(tool: tool, summary: summary, detail: detail)
    }

    static func questions(_ input: [String: Any]) -> [(text: String, options: [String])] {
        guard let asked = input["questions"] as? [[String: Any]] else { return [] }
        return asked.compactMap { question in
            let text = string(question["question"])
            guard !text.isEmpty else { return nil }
            let options = (question["options"] as? [[String: Any]])?.compactMap { option -> String? in
                let label = string(option["label"])
                return label.isEmpty ? nil : label
            }
            return (text, options ?? [])
        }
    }

    static func plainText(_ markdown: String) -> String {
        var lines: [String] = []
        var blank = false
        for raw in markdown.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }
            var line = raw
            if let heading = line.range(of: "^\\s*#{1,6}\\s*", options: .regularExpression) {
                line.removeSubrange(heading)
            }
            if let quote = line.range(of: "^\\s*>\\s?", options: .regularExpression) {
                line.removeSubrange(quote)
            }
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "__", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            let empty = line.trimmingCharacters(in: .whitespaces).isEmpty
            if empty, blank { continue }
            blank = empty
            lines.append(empty ? "" : line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func path(_ input: [String: Any]) -> String {
        for key in ["file_path", "notebook_path", "path", "filePath"] {
            let value = string(input[key])
            if !value.isEmpty { return value }
        }
        return ""
    }

    private static func file(_ input: [String: Any]) -> String {
        let full = path(input)
        return full.isEmpty ? "" : (full as NSString).lastPathComponent
    }

    private static func host(of url: String) -> String {
        URL(string: url)?.host ?? url
    }

    static func firstLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clipped(_ text: String, lines limit: Int, characters: Int) -> String {
        var kept = text.components(separatedBy: .newlines)
        var cut = false
        if kept.count > limit { kept = Array(kept.prefix(limit)); cut = true }
        var text = kept.joined(separator: "\n")
        if text.count > characters { text = String(text.prefix(characters)); cut = true }
        return cut ? text.trimmingCharacters(in: .whitespacesAndNewlines) + "…" : text
    }

    private static func mcp(_ tool: String) -> (server: String, tool: String)? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let parts = tool.dropFirst("mcp__".count).components(separatedBy: "__")
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        let name = parts.dropFirst().joined(separator: " ")
        return (parts[0].replacingOccurrences(of: "_", with: " "),
                name.replacingOccurrences(of: "_", with: " "))
    }
}
