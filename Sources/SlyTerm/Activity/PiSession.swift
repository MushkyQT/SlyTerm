import Foundation

// pi's session files, and omp's, which add a title line before the header.
enum PiSession {
    struct Head: Equatable {
        var id: String
        var cwd: String
        var startedAt: Date?
        var title: String?
        var firstPrompt: String?
    }

    // omp's title line is a fixed 256-byte slot it rewrites in place; pi names a session with
    // `session_info` entries, the newest winning and an empty name clearing it.
    static func head(_ url: URL) -> Head? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: TranscriptTail.window)) ?? Data()
        let objects = SessionDiscovery.lines(in: data).compactMap(object)
        guard let header = objects.prefix(2).first(where: { $0["type"] as? String == "session" }),
              let id = header["id"] as? String, !id.isEmpty else { return nil }
        var head = Head(id: id, cwd: header["cwd"] as? String ?? "",
                        startedAt: TranscriptTail.date(header["timestamp"]))
        var name: String?
        for object in objects {
            switch object["type"] as? String {
            case "session_info":
                name = nonBlank(object["name"] as? String)
            case "message":
                guard head.firstPrompt == nil, let message = object["message"] as? [String: Any],
                      isTyped(message) else { continue }
                head.firstPrompt = nonBlank(text(of: message).joined(separator: "\n"))
            default: continue
            }
        }
        let slot = objects.first.flatMap { $0["type"] as? String == "title" ? $0["title"] as? String : nil }
        head.title = nonBlank(slot) ?? name
        return head
    }

    static func read(_ url: URL) -> TranscriptTail.Reading {
        guard let (records, whole) = TranscriptTail.tail(of: url, bytes: TranscriptTail.window) else {
            return TranscriptTail.Reading()
        }
        let reading = parse(records)
        guard reading.lastMessage == nil, !whole,
              let (wider, _) = TranscriptTail.tail(of: url, bytes: TranscriptTail.deepWindow) else {
            return reading
        }
        return parse(wider)
    }

    private struct Entry {
        var role: String
        var message: [String: Any]
        var at: Date?

        var stop: String? { message["stopReason"] as? String }
        var endsTurn: Bool { role == "assistant" && ["stop", "aborted", "error", "length"].contains(stop) }
    }

    // One line per finished message: while a reply streams, the last line is the user message or
    // the tool results it answers.
    private static func parse(_ records: [Data]) -> TranscriptTail.Reading {
        let markers = [Data("\"message\"".utf8), Data("\"session_exit\"".utf8)]
        var entries: [Entry] = []
        var exitedAfter = -1
        for line in records where markers.contains(where: { line.range(of: $0) != nil }) {
            guard let object = object(line) else { continue }
            switch object["type"] as? String {
            case "message":
                guard let message = object["message"] as? [String: Any], let role = message["role"] as? String,
                      ["user", "assistant", "toolResult"].contains(role) else { continue }
                let at = TranscriptTail.date(object["timestamp"])
                entries.append(Entry(role: role, message: message, at: at))
            case "custom" where object["customType"] as? String == "session_exit":
                exitedAfter = entries.count
            default: continue
            }
        }

        var reading = TranscriptTail.Reading()
        reading.ended = exitedAfter >= 0 && exitedAfter == entries.count
        finalMessage(in: entries, into: &reading)
        guard let last = entries.indices.last else { return reading }
        if entries[last].endsTurn {
            (reading.status, reading.statusSince) = (.idle, entries[last].at)
            return reading
        }

        var answered: Set<String> = []
        var index = last
        while index >= 0, entries[index].role == "toolResult" {
            if let id = entries[index].message["toolCallId"] as? String { answered.insert(id) }
            index -= 1
        }
        reading.status = .working
        reading.statusSince = turnStart(entries, upTo: last) ?? entries[last].at
        guard index >= 0, entries[index].role == "assistant" else { return reading }
        let owner = entries[index]
        let pending = calls(in: owner.message).filter { !answered.contains($0.id) }
        guard let newest = pending.last else { return reading }
        reading.doing = AgentDoing(tool: newest.name, label: label(newest), startedAt: owner.at)
        if pending.count == 1, newest.name == "ask",
           let first = TranscriptTail.questions(newest.arguments).first {
            reading.request = .question(text: first.text, options: first.options)
            (reading.status, reading.statusSince) = (.waiting, owner.at)
        }
        return reading
    }

    private static func turnStart(_ entries: [Entry], upTo last: Int) -> Date? {
        var start: Date?
        for entry in entries[...last].reversed() {
            if entry.endsTurn { break }
            if entry.role == "user" { start = entry.at }
        }
        return start
    }

    // The newest reply that ended a turn, timed from the prompt the user typed for it.
    private static func finalMessage(in entries: [Entry], into reading: inout TranscriptTail.Reading) {
        guard let index = entries.lastIndex(where: { $0.stop == "stop" && $0.role == "assistant"
            && nonBlank(text(of: $0.message).joined(separator: "\n")) != nil }) else { return }
        let final = entries[index]
        let plain = TranscriptTail.plainText(text(of: final.message).joined(separator: "\n"))
        reading.lastMessage = plain.isEmpty ? nil : plain
        guard let typed = entries[..<index].last(where: { isTyped($0.message) }),
              let start = typed.at, let end = final.at else { return }
        reading.lastTurnDuration = end.timeIntervalSince(start)
    }

    private struct Call {
        var id: String
        var name: String
        var arguments: [String: Any]
        var intent: String?
    }

    private static func calls(in message: [String: Any]) -> [Call] {
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "toolCall", let id = block["id"] as? String,
                  let name = block["name"] as? String, !name.isEmpty else { return nil }
            let arguments = block["arguments"] as? [String: Any] ?? [:]
            return Call(id: id, name: name, arguments: arguments,
                        intent: nonBlank(block["intent"] as? String) ?? nonBlank(arguments["i"] as? String))
        }
    }

    // omp has the model state its intent with every call.
    private static func label(_ call: Call) -> String {
        if let intent = call.intent { return SessionDiscovery.trimmed(intent, to: TranscriptTail.labelLimit) }
        let tools = ["bash": "Bash", "read": "Read", "edit": "Edit", "write": "Write", "grep": "Grep",
                     "find": "Glob", "ask": "AskUserQuestion", "todo_write": "TodoWrite"]
        return TranscriptTail.label(tool: tools[call.name] ?? call.name, input: call.arguments)
    }

    // omp flags the prompts it sends on its own (plan mode, advisors).
    private static func isTyped(_ message: [String: Any]) -> Bool {
        message["role"] as? String == "user" && message["synthetic"] as? Bool != true
            && message["attribution"] as? String != "agent"
    }

    private static func text(of message: [String: Any]) -> [String] {
        if let text = message["content"] as? String { return [text] }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    }

    private static func nonBlank(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}
