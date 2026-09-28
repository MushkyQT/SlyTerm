import Foundation

enum CodexRollout {
    struct Head: Equatable {
        var id: String
        var cwd: String
        var startedAt: Date?
        var originator: String?
        var firstPrompt: String?
    }

    private static let window = 256 * 1024

    // The first line is `session_meta`, some 20 KB of instructions included.
    static func head(_ url: URL) -> Head? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let records = SessionDiscovery.lines(in: (try? handle.read(upToCount: window)) ?? Data())
        guard let first = records.first, let meta = object(first),
              meta["type"] as? String == "session_meta", let payload = meta["payload"] as? [String: Any],
              let id = payload["id"] as? String, !id.isEmpty else { return nil }
        var head = Head(id: id, cwd: payload["cwd"] as? String ?? "",
                        startedAt: TranscriptTail.date(payload["timestamp"]),
                        originator: payload["originator"] as? String)
        let markers = ["\"user_message\"", "\"UserMessage\"", "\"role\":\"user\""].map { Data($0.utf8) }
        for line in records.dropFirst() where markers.contains(where: { line.range(of: $0) != nil }) {
            guard let record = object(line), let text = typedPrompt(record) else { continue }
            head.firstPrompt = text
            break
        }
        return head
    }

    static func read(_ url: URL) -> TranscriptTail.Reading {
        guard let (records, whole) = TranscriptTail.tail(of: url, bytes: TranscriptTail.window) else {
            return TranscriptTail.Reading()
        }
        let reading = parse(records)
        // Command output can push a running turn's `task_started` out of the tail as well.
        guard reading.lastMessage == nil || reading.status == nil, !whole,
              let (wider, _) = TranscriptTail.tail(of: url, bytes: TranscriptTail.deepWindow) else {
            return reading
        }
        return parse(wider)
    }

    // Thread id → name, from `session_index.jsonl` under a Codex home (`~/.codex` by default).
    static func threadNames(in home: URL) -> [String: String] {
        let url = home.appendingPathComponent("session_index.jsonl")
        guard let (records, _) = TranscriptTail.tail(of: url, bytes: window) else { return [:] }
        var names: [String: String] = [:]
        for line in records {
            guard let record = object(line), let id = record["id"] as? String, !id.isEmpty else { continue }
            let name = (record["thread_name"] as? String) ?? ""
            names[id] = blank(name) ? nil : name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return names
    }

    private struct Call {
        var tool: String
        var label: String
        var command: String?
        var at: Date?
    }

    // Walks backwards. Outputs come after their calls, so an output seen first answers its call;
    // the newest turn record says whether a turn is open, and only its calls can be in flight.
    // Approval prompts are never written: a call waiting for one looks like a running call.
    private static func parse(_ records: [Data]) -> TranscriptTail.Reading {
        let markers = ["task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted",
                       "custom_tool_call", "function_call", "local_shell_call", "final_answer", "agent_message"]
            .map { Data("\"\($0)".utf8) }
        var reading = TranscriptTail.Reading()
        var answered: Set<String> = []
        var inTurn = true
        var pending: [Call] = []
        var closing: TimeInterval?
        var messageFound = false

        for line in records.reversed() where markers.contains(where: { line.range(of: $0) != nil }) {
            guard let record = object(line), let payload = record["payload"] as? [String: Any] else { continue }
            let at = TranscriptTail.date(record["timestamp"])
            let type = record["type"] as? String ?? ""
            let kind = payload["type"] as? String ?? ""
            switch (type, kind) {
            case ("event_msg", "task_started"), ("event_msg", "turn_started"):
                if reading.status == nil { (reading.status, reading.statusSince) = (.working, at) }
                inTurn = false
                closing = nil
            case ("event_msg", "task_complete"), ("event_msg", "turn_complete"):
                if reading.status == nil { (reading.status, reading.statusSince) = (.idle, at) }
                inTurn = false
                closing = (payload["duration_ms"] as? NSNumber).map { $0.doubleValue / 1000 }
                if !messageFound, let text = payload["last_agent_message"] as? String, !blank(text) {
                    (reading.lastMessage, reading.lastTurnDuration, messageFound) = (text, closing, true)
                }
            case ("event_msg", "turn_aborted"):
                if reading.status == nil { (reading.status, reading.statusSince) = (.idle, at) }
                inTurn = false
                closing = nil
            case ("response_item", "custom_tool_call_output"), ("response_item", "function_call_output"):
                if let id = payload["call_id"] as? String { answered.insert(id) }
            case ("response_item", "custom_tool_call"), ("response_item", "function_call"),
                 ("response_item", "local_shell_call"):
                guard inTurn, !isAnswered(payload, answered), var call = call(payload, kind: kind) else {
                    continue
                }
                call.at = at
                pending.append(call)
            default:
                guard !messageFound, let text = finalAnswer(type, payload) else { continue }
                (reading.lastMessage, reading.lastTurnDuration, messageFound) = (text, closing, true)
            }
        }

        if reading.status == .idle { pending = [] }
        if let newest = pending.first {
            reading.doing = AgentDoing(tool: newest.tool, label: newest.label, startedAt: newest.at)
            if pending.count == 1, let command = newest.command {
                let line = SessionDiscovery.trimmed(TranscriptTail.firstLine(command), to: 60)
                let detail = TranscriptTail.clipped(command, lines: 8, characters: 600)
                reading.request = .permission(tool: "exec", summary: "run `\(line)`", detail: detail)
            } else {
                reading.request = .unknown
            }
        }
        if let message = reading.lastMessage {
            let plain = TranscriptTail.plainText(message)
            reading.lastMessage = plain.isEmpty ? nil : plain
        }
        return reading
    }

    private static func isAnswered(_ payload: [String: Any], _ answered: Set<String>) -> Bool {
        if let id = payload["call_id"] as? String { return answered.contains(id) }
        // An old `local_shell_call` may carry no call id, only its own status.
        return payload["status"] as? String != "in_progress"
    }

    private static func call(_ payload: [String: Any], kind: String) -> Call? {
        switch kind {
        case "local_shell_call":
            let action = payload["action"] as? [String: Any]
            return command(commandText(action?["command"]))
        case "custom_tool_call":
            let name = payload["name"] as? String ?? ""
            let input = payload["input"] as? String ?? ""
            if name == "apply_patch" { return patch(input) }
            guard name == "exec" else { return named(name, namespace: payload["namespace"] as? String) }
            return codeMode(input)
        default:
            let name = payload["name"] as? String ?? ""
            let arguments = (payload["arguments"] as? String).flatMap { text in
                (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            } ?? [:]
            switch name {
            case "exec_command": return command(arguments["cmd"] as? String)
            case "shell", "shell_command": return command(commandText(arguments["command"]))
            case "apply_patch": return patch(arguments["input"] as? String ?? "")
            default: return named(name, namespace: payload["namespace"] as? String)
            }
        }
    }

    // Code mode runs a JavaScript cell: `await tools.exec_command({cmd:"…", …})` and the like.
    private static func codeMode(_ input: String) -> Call? {
        let calls = toolCalls(in: input)
        guard let first = calls.first else { return Call(tool: "exec", label: "exec") }
        switch first.name {
        case "exec_command":
            guard var call = command(value(of: "cmd", in: first.arguments)) else {
                return Call(tool: first.name, label: "running a command")
            }
            // With several calls in one cell, any of them could be the one waiting.
            if calls.count > 1 { call.command = nil }
            return call
        case "apply_patch": return patch(jsString(first.arguments.drop { $0.isWhitespace }) ?? "")
        default: return named(first.name, namespace: nil)
        }
    }

    private static func toolCalls(in input: String) -> [(name: String, arguments: Substring)] {
        var calls: [(name: String, arguments: Substring)] = []
        var search = input[...]
        while let range = search.range(of: "tools.") {
            let after = search[range.upperBound...]
            let name = after.prefix { isIdentifier($0) }
            let rest = after.dropFirst(name.count).drop { $0 == " " }
            let standalone = range.lowerBound == input.startIndex
                || !isIdentifier(input[input.index(before: range.lowerBound)])
            if standalone, !name.isEmpty, rest.first == "(" { calls.append((String(name), rest.dropFirst())) }
            search = after
        }
        return calls
    }

    // The string literal after `key:` (or `"key":`) in a JavaScript object.
    private static func value(of key: String, in text: Substring) -> String? {
        var search = text
        while let range = search.range(of: key) {
            let before = range.lowerBound == text.startIndex
                ? nil : text[text.index(before: range.lowerBound)]
            var after = search[range.upperBound...]
            if let quote = after.first, quote == "\"" || quote == "'" { after = after.dropFirst() }
            after = after.drop { $0 == " " }
            if !(before.map(isIdentifier) ?? false), after.first == ":",
               let value = jsString(after.dropFirst().drop { $0 == " " }) {
                return value
            }
            search = search[range.upperBound...]
        }
        return nil
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    private static func command(_ text: String?) -> Call? {
        guard let text, !blank(text) else { return nil }
        let label = TranscriptTail.label(tool: "Bash", input: ["command": text])
        return Call(tool: "exec_command", label: label, command: text)
    }

    private static func commandText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let words = value as? [String], !words.isEmpty else { return nil }
        if words.count == 3, ["-lc", "-c"].contains(words[1]) { return words[2] }
        return words.joined(separator: " ")
    }

    private static func patch(_ text: String) -> Call {
        let markers = [("*** Update File:", "Edit"), ("*** Add File:", "Write")]
        for line in text.components(separatedBy: .newlines) {
            for (marker, tool) in markers where line.hasPrefix(marker) {
                let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                return Call(tool: "apply_patch", label: TranscriptTail.label(tool: tool, input: ["path": path]))
            }
        }
        return Call(tool: "apply_patch", label: "editing files")
    }

    private static func named(_ name: String, namespace: String?) -> Call? {
        guard !name.isEmpty else { return nil }
        if name == "update_plan" { return Call(tool: name, label: "planning") }
        let full = (namespace?.hasPrefix("mcp__") == true ? namespace ?? "" : "") + name
        return Call(tool: full, label: TranscriptTail.label(tool: full, input: [:]))
    }

    // A JavaScript string literal at the start of `text`, escapes resolved.
    private static func jsString(_ text: Substring) -> String? {
        guard let quote = text.first, "\"'`".contains(quote) else { return nil }
        var result = ""
        var escaped = false
        for character in text.dropFirst() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }

    private static func finalAnswer(_ type: String?, _ payload: [String: Any]) -> String? {
        var parts: [String] = []
        switch (type, payload["type"] as? String) {
        case ("response_item", "message"):
            guard payload["role"] as? String == "assistant", payload["phase"] as? String == "final_answer",
                  let blocks = payload["content"] as? [[String: Any]] else { return nil }
            parts = blocks.compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
        case ("event_msg", "item_completed"):
            guard let item = payload["item"] as? [String: Any], item["type"] as? String == "AgentMessage",
                  item["phase"] as? String == "final_answer",
                  let blocks = item["content"] as? [[String: Any]] else { return nil }
            parts = blocks.compactMap { $0["text"] as? String }
        // Legacy threads; the oldest wrote no phase at all.
        case ("event_msg", "agent_message"):
            guard let text = payload["message"] as? String,
                  (payload["phase"] as? String).map({ $0 == "final_answer" }) ?? true else { return nil }
            parts = [text]
        default: return nil
        }
        let text = parts.joined(separator: "\n")
        return blank(text) ? nil : text
    }

    // `user` records Codex writes itself (environment, instructions) start with a tag.
    private static func typedPrompt(_ record: [String: Any]) -> String? {
        guard let payload = record["payload"] as? [String: Any] else { return nil }
        var text: String?
        switch (record["type"] as? String, payload["type"] as? String) {
        case ("event_msg", "user_message"):
            text = payload["message"] as? String
        case ("event_msg", "item_completed"):
            guard let item = payload["item"] as? [String: Any], item["type"] as? String == "UserMessage" else {
                return nil
            }
            text = texts(item["content"])
        case ("response_item", "message"):
            guard payload["role"] as? String == "user" else { return nil }
            text = texts(payload["content"])
        default: return nil
        }
        guard let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty,
              !prompt.hasPrefix("<") else { return nil }
        return prompt
    }

    private static func texts(_ content: Any?) -> String? {
        (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private static func blank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
