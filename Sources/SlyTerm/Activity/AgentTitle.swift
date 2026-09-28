import Foundation

enum AgentTitle {
    static let kinds: [AgentKind] = [.codex, .omp, .gemini, .qwen]

    private typealias Parsed = (status: TeleportStatus, name: String, marked: Bool)

    // nil when `agent` has no title protocol or the title is not one of its own.
    static func parse(_ title: String, agent: AgentKind) -> (status: TeleportStatus, name: String, marked: Bool)? {
        // Gemini CLI and Qwen Code pad their titles to 80 columns.
        let title = title.trimmingCharacters(in: .whitespaces)
        switch agent {
        case .codex: return codex(title)
        case .omp: return omp(title)
        case .gemini: return gemini(title)
        case .qwen: return qwen(title)
        case .claude, .pi: return nil
        }
    }

    // Codex's default `terminal_title` is activity, thread name, project. The activity part is a
    // spinner frame while it works and nothing at all when idle, so an idle title has no mark.
    private static func codex(_ title: String) -> Parsed {
        var rest = Substring(title)
        // Its realtime voice mode puts a dot in front of everything else.
        if rest.hasPrefix("● ") { rest = rest.dropFirst(2) }
        for prefix in ["[ ! ] Action Required", "[ . ] Action Required"] where rest.hasPrefix(prefix) {
            return (.waiting, codexName(rest.dropFirst(prefix.count)), true)
        }
        if let first = rest.unicodeScalars.first, isBraille(first),
           rest.unicodeScalars.dropFirst().first.map({ $0 == " " }) ?? true {
            return (.working, codexName(rest), true)
        }
        return (.idle, codexName(rest), false)
    }

    // Also drops the frame Codex puts in place of a thread name it is still generating.
    private static func codexName(_ text: Substring) -> String {
        text.components(separatedBy: " | ").map { part in
            part.split(separator: " ").filter { !$0.unicodeScalars.allSatisfy(isBraille) }
                .joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    // `π > label` idle, `π ! label` waiting, `π <frame> label` working, where the frame comes from
    // omp's spinner styles or is `:` on hosts that cannot animate.
    private static func omp(_ title: String) -> Parsed? {
        guard title.hasPrefix("π ") else { return nil }
        let rest = title.dropFirst(2)
        let mark = rest.prefix { $0 != " " }
        let name = rest.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
        switch mark {
        case ">": return (.idle, name, true)
        case "!": return (.waiting, name, true)
        default:
            guard mark.unicodeScalars.count == 1, let scalar = mark.unicodeScalars.first,
                  isBraille(scalar) || "○◔◑◕●-\\|/:".unicodeScalars.contains(scalar) else { return nil }
            return (.working, name, true)
        }
    }

    // `✋  Action Required (folder)`, `⏲  Working… (folder)`, `◇  Ready (folder)`, and
    // `✦  <thought> (folder)` while it works, the folder dropped when the thought is long.
    private static func gemini(_ title: String) -> Parsed? {
        let forms: [(icon: String, word: String?, status: TeleportStatus)] = [
            ("✋", "Action Required", .waiting), ("⏲", "Working…", .working), ("◇", "Ready", .idle),
            ("✦", nil, .working),
        ]
        for form in forms where title.hasPrefix(form.icon + " ") {
            let rest = title.dropFirst(form.icon.count).trimmingCharacters(in: .whitespaces)
            guard let word = form.word else { return (form.status, folder(Substring(rest), last: true), true) }
            guard rest.hasPrefix(word) else { return nil }
            return (form.status, folder(rest.dropFirst(word.count), last: false), true)
        }
        return nil
    }

    // The 80-column cut can take the closing parenthesis.
    private static func folder(_ text: Substring, last: Bool) -> String {
        guard let open = text.range(of: " (", options: last ? .backwards : []) else { return "" }
        var name = text[open.upperBound...]
        if name.hasSuffix(")") { name = name.dropLast() }
        return name.trimmingCharacters(in: .whitespaces)
    }

    // Qwen Code marks working with ◐ and waiting with ✳, each followed by a text-style selector;
    // idle has no mark, as with Codex.
    private static func qwen(_ title: String) -> Parsed {
        var scalars = Substring(title).unicodeScalars
        guard let first = scalars.first, first == "◐" || first == "✳" else { return (.idle, title, false) }
        scalars = scalars.dropFirst()
        if let selector = scalars.first, selector == "\u{FE0E}" || selector == "\u{FE0F}" {
            scalars = scalars.dropFirst()
        }
        guard scalars.first == " " else { return (.idle, title, false) }
        let name = String(Substring(scalars.dropFirst())).trimmingCharacters(in: .whitespaces)
        return (first == "◐" ? .working : .waiting, name, true)
    }

    private static func isBraille(_ scalar: Unicode.Scalar) -> Bool {
        (0x2800...0x28FF).contains(scalar.value)
    }
}
