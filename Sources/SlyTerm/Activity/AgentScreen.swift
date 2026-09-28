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
        let prefixes = ["Do you want to approve network access to ",
                        "Would you like to send input to ", "! Approval needed in "]
        if prefixes.contains(where: { text.hasPrefix($0) })
            || text.hasSuffix(" needs your approval.") {
            return .other
        }
        if text.range(of: "^(Question|Field) [0-9]+/[0-9]+", options: .regularExpression) != nil {
            return .other
        }
        return option(row)?.label.hasPrefix("Verify and approve") == true ? .other : nil
    }

    private static func codex(_ rows: [String]) -> AgentRequest? {
        let titles = rows.indices.filter { codexPrompt(rows[$0]) != nil }
        let footer = rows.lastIndex { !$0.isEmpty }
        let footed = footer.map { text(rows[$0]) == "Press enter to confirm or esc to cancel" }
            ?? false
        guard let title = titles.last else { return footed ? .unknown : nil }
        // Codex draws its prompt last on the screen, the list right above the footer. A second
        // title can be part of the command's own text, so neither is trusted.
        guard footed, let footer, titles.count == 1, let prompt = codexPrompt(rows[title]),
              let list = codexOptions(rows, above: footer), list.start > title,
              codexAnswers(list.labels, prompt: prompt) else { return .unknown }
        var end = list.start
        while end > title + 1, rows[end - 1].isEmpty { end -= 1 }
        let indent = rows[title].prefix { $0 == " " }.count
        let header = rows[(title + 1)..<end].compactMap { body($0, indent: indent) }
        // `[… 12 lines]` is where Codex cut a header too tall for the pane.
        guard header.count == end - title - 1,
              !header.contains(where: { option($0) != nil || $0.hasPrefix("[… ") }) else {
            return .unknown
        }
        // ratatui breaks a word longer than the pane at its edge, so a row that fills the pane
        // continues on the next one. The pane stops two columns short of the screen's edge.
        let widest = header.map(\.count).max() ?? 0
        let screen = rows.map(\.count).max() ?? 0
        let full = { (text: String) in text.count == widest && widest + indent >= screen - 2 }
        switch prompt {
        case .exec: return codexCommand(header, full: full) ?? .unknown
        case .patch: return codexPatch(header, full: full) ?? .unknown
        case .other: return .unknown
        }
    }

    // The rows right above the footer, bottom-up: `1.` to `n.`, a label too long for the pane
    // wrapped onto rows indented past its number.
    private static func codexOptions(_ rows: [String],
                                     above footer: Int) -> (start: Int, labels: [String])? {
        var index = footer - 1
        while index >= 0, rows[index].isEmpty { index -= 1 }
        var options: [(number: Int, label: String)] = []
        var wrapped: [String] = []
        while index >= 0 {
            let row = rows[index]
            if let found = option(row) {
                let label = ([found.label] + wrapped).joined(separator: " ")
                options.insert((found.number, label), at: 0)
                wrapped = []
            } else if row.hasPrefix("     "), row.dropFirst(5).first.map({ $0 != " " }) == true {
                wrapped.insert(String(row.dropFirst(5)), at: 0)
            } else {
                break
            }
            index -= 1
        }
        guard wrapped.isEmpty, !options.isEmpty,
              options.map(\.number) == Array(1...options.count) else { return nil }
        return (index + 1, options.map(\.label))
    }

    // Codex's own lists with its default keys: `y` on the first row, esc (and `n`) on the last.
    // Other hints mean a keymap that may have moved the letters SlyTerm types.
    private static func codexAnswers(_ labels: [String], prompt: CodexPrompt) -> Bool {
        guard labels.count >= 2, labels.first == "Yes, proceed (y)",
              labels.last == "No, and tell Codex what to do differently (esc)",
              !labels.contains(where: { $0.hasSuffix("(n)") }) else { return false }
        let middle = labels.dropFirst().dropLast()
        switch prompt {
        case .exec:
            let prefix = middle.filter {
                $0.hasPrefix("Yes, and don't ask again for commands that start with `")
                    && $0.hasSuffix("` (p)")
            }
            let session = middle.filter {
                $0 == "Yes, and don't ask again for this command in this session (a)"
                    || $0 == "Yes, and allow these permissions for this session (a)"
            }
            return prefix.count <= 1 && session.count <= 1
                && prefix.count + session.count == middle.count
        case .patch:
            return Array(middle) == ["Yes, and don't ask again for these files (a)"]
        case .other:
            return false
        }
    }

    // approval_overlay.rs ends each of these with a blank row. A wrapped reason can start a row
    // with `$ `: the command begins only after the last of them.
    private static let codexHeaderKeys = [
        "Thread: ", "Environment: ", "Reason: ", "Permission rule: ",
    ]

    private static func codexCommand(_ rows: [String], full: (String) -> Bool) -> AgentRequest? {
        var index = 0
        var keys = codexHeaderKeys[...]
        while index < rows.count {
            if rows[index].isEmpty {
                index += 1
                continue
            }
            guard let key = keys.firstIndex(where: { rows[index].hasPrefix($0) }) else { break }
            keys = keys[(key + 1)...]
            while index < rows.count, !rows[index].isEmpty { index += 1 }
        }
        guard index < rows.count, rows[index].hasPrefix("$ ") else { return nil }
        let first = rows[index].dropFirst(2)
        guard !first.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var command = String(first)
        for (previous, row) in zip(rows[index...], rows[(index + 1)...]) {
            // Codex marks only the command's first line: another `$ ` row means a paragraph above
            // ended on a row of spaces rather than a blank one.
            guard !row.hasPrefix("$ ") else { return nil }
            command += (full(previous) ? "" : "\n") + row
        }
        let line = SessionDiscovery.trimmed(first.trimmingCharacters(in: .whitespaces), to: 60)
        // Unclipped (the screen bounds it): the answer compares it, and a command that differs
        // only past what the card shows is another prompt. The card clips it for display.
        return .permission(tool: "exec", summary: "run `\(line)`", detail: command)
    }

    // apply_patch_header.rs: an optional `Thread:` paragraph, the description, then a
    // `Destination: <path>` each; a path that does not fit after the label starts on its own row.
    private static func codexPatch(_ rows: [String], full: (String) -> Bool) -> AgentRequest? {
        let destination = { (text: String) in text.hasPrefix("Destination:") }
        var index = 0
        func skipBlanks() { while index < rows.count, rows[index].isEmpty { index += 1 } }
        skipBlanks()
        if index < rows.count, rows[index].hasPrefix("Thread: ") {
            while index < rows.count, !rows[index].isEmpty { index += 1 }
            skipBlanks()
        }
        guard index < rows.count, rows[index].hasPrefix("Description: ") else { return nil }
        while index < rows.count, !destination(rows[index]) {
            guard !rows[index].isEmpty else { return nil }
            index += 1
        }
        var paths: [String] = []
        while index < rows.count {
            var path = rows[index].dropFirst("Destination:".count)
                .trimmingCharacters(in: .whitespaces)
            var previous = rows[index]
            index += 1
            if path.isEmpty {
                guard index < rows.count, !rows[index].isEmpty, !destination(rows[index]) else {
                    return nil
                }
                path = rows[index]
                previous = rows[index]
                index += 1
            }
            while index < rows.count, !destination(rows[index]) {
                guard full(previous), !rows[index].isEmpty else { return nil }
                path += rows[index]
                previous = rows[index]
                index += 1
            }
            // Codex writes `unavailable` when it has no path to show.
            guard path.hasPrefix("/") else { return nil }
            paths.append(path)
        }
        guard !paths.isEmpty else { return nil }
        let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return .permission(tool: "apply_patch",
                           summary: "edit " + SessionDiscovery.trimmed(names, to: 60),
                           detail: paths.joined(separator: "\n"))
    }

    private static func text(_ row: String) -> Substring {
        row.drop { $0 == " " }
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
        guard let number = Int(digits), text.dropFirst(digits.count).hasPrefix(". ") else {
            return nil
        }
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
