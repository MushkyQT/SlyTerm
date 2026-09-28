import Foundation

enum AgentScreen {
    // The prompt `agent` shows on the tab's visible lines, when one of its own is up.
    static func request(lines: [String], agent: AgentKind) -> AgentRequest? {
        let rows = lines.map { line -> String in
            var row = Substring(line)
            while row.last == " " { row = row.dropLast() }
            return String(row)
        }
        switch agent {
        case .codex: return codex(rows)
        case .omp: return omp(rows)
        case .claude, .pi, .gemini, .qwen: return nil
        }
    }

    private enum CodexPrompt {
        case exec, patch, other
    }

    // Titles from Codex's approval overlay, question and elicitation views, plan popup and
    // pending-thread notice; each starts its own block in the bottom pane.
    private static func codexPrompt(_ row: String) -> CodexPrompt? {
        let text = row.drop { $0 == " " }
        switch text {
        case "Would you like to run the following command?": return .exec
        case "Would you like to make the following edits?": return .patch
        case "Would you like to grant these permissions?", "Implement this plan?": return .other
        default: break
        }
        let prefixes = ["Do you want to approve network access to ", "Would you like to send input to ",
                        "! Approval needed in "]
        if prefixes.contains(where: { text.hasPrefix($0) }) || text.hasSuffix(" needs your approval.") {
            return .other
        }
        if text.range(of: "^(Question|Field) [0-9]+/[0-9]+", options: .regularExpression) != nil {
            return .other
        }
        return option(row)?.label.hasPrefix("Verify and approve") == true ? .other : nil
    }

    private static func codex(_ rows: [String]) -> AgentRequest? {
        guard let start = rows.lastIndex(where: { codexPrompt($0) != nil }),
              let prompt = codexPrompt(rows[start]) else { return nil }
        guard prompt != .other else { return .unknown }
        let block = Array(rows[start...])
        // `y` and `n` are Codex's default keys for these two rows; a remapped key shows another hint.
        let approve = { (row: String) in
            option(row).map { $0.number == 1 && $0.label == "Yes, proceed (y)" } ?? false
        }
        let refuse = "No, and tell Codex what to do differently (esc)"
        let footer = "Press enter to confirm"
        guard let yes = block.firstIndex(where: approve),
              block[yes...].contains(where: { option($0)?.label == refuse }),
              let end = block.lastIndex(where: { $0.drop { $0 == " " }.hasPrefix(footer) }),
              end > yes, block[(end + 1)...].allSatisfy(\.isEmpty) else { return .unknown }
        let header = Array(block[1..<yes])
        let indent = rows[start].prefix { $0 == " " }.count
        // ratatui breaks a word longer than the pane at its edge, so a row that fills the pane
        // continues on the next one. The pane stops two columns short of the screen's edge.
        let widest = header.map(\.count).max() ?? 0
        let screen = rows.map(\.count).max() ?? 0
        let full = { (row: String) in row.count == widest && widest >= screen - 2 }
        switch prompt {
        case .exec: return codexCommand(header, indent: indent, full: full)
        case .patch: return codexPatch(header, indent: indent, full: full)
        case .other: return .unknown
        }
    }

    private static func codexCommand(_ rows: [String], indent: Int,
                                     full: (String) -> Bool) -> AgentRequest {
        guard let start = rows.firstIndex(where: { body($0, indent: indent)?.hasPrefix("$ ") == true }),
              let first = body(rows[start], indent: indent)?.dropFirst(2),
              !first.trimmingCharacters(in: .whitespaces).isEmpty else { return .unknown }
        var command = String(first)
        var previous = rows[start]
        for row in rows[(start + 1)...] {
            guard let text = body(row, indent: indent), !text.isEmpty else { break }
            command += (full(previous) ? "" : "\n") + text
            previous = row
        }
        let line = SessionDiscovery.trimmed(first.trimmingCharacters(in: .whitespaces), to: 60)
        return .permission(tool: "exec", summary: "run `\(line)`",
                           detail: TranscriptTail.clipped(command, lines: 8, characters: 600))
    }

    // `Destination: <path>` rows; a path that does not fit after the label starts on its own row.
    private static func codexPatch(_ rows: [String], indent: Int,
                                   full: (String) -> Bool) -> AgentRequest {
        var paths: [String] = []
        var index = 0
        while index < rows.count {
            guard let text = body(rows[index], indent: indent), text.hasPrefix("Destination:") else {
                index += 1
                continue
            }
            var path = text.dropFirst("Destination:".count).trimmingCharacters(in: .whitespaces)
            var previous = rows[index]
            index += 1
            if path.isEmpty, index < rows.count, let next = body(rows[index], indent: indent) {
                path = next
                previous = rows[index]
                index += 1
            }
            while full(previous), index < rows.count, let next = body(rows[index], indent: indent),
                  !next.isEmpty, !next.hasPrefix("Destination:") {
                path += next
                previous = rows[index]
                index += 1
            }
            if !path.isEmpty, path != "unavailable" { paths.append(path) }
        }
        guard !paths.isEmpty else { return .unknown }
        let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return .permission(tool: "apply_patch", summary: "edit " + SessionDiscovery.trimmed(names, to: 60),
                           detail: paths.joined(separator: "\n"))
    }

    // The row's text past the block's indent, or nil when it sits further left.
    private static func body(_ row: String, indent: Int) -> String? {
        guard row.prefix(indent).allSatisfy({ $0 == " " }) else { return nil }
        return String(row.dropFirst(indent))
    }

    // `› 1. Yes, proceed (y)` or `  2. …`: `›` marks the highlighted row.
    private static func option(_ row: String) -> (number: Int, label: String)? {
        var text = row.drop { $0 == " " }
        if text.hasPrefix("›") { text = text.dropFirst().drop { $0 == " " } }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard let number = Int(digits), text.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (number, String(text.dropFirst(digits.count + 2)))
    }

    // omp's tool approval is a selector titled `Allow tool: <name>` in place of the editor. Its
    // `ask` tool is read from the session file instead.
    private static func omp(_ rows: [String]) -> AgentRequest? {
        guard let top = rows.last(where: { row in
            row.drop { $0 == " " }.first.map { "╭┌┏╔".contains($0) } ?? false
        }) else { return nil }
        return top.contains("─ Allow tool: ") ? .unknown : nil
    }
}
