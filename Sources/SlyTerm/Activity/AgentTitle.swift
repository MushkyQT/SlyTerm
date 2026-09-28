import Foundation

enum AgentTitle {
    static let kinds: [AgentKind] = [.codex, .omp, .gemini, .qwen]

    // nil when `agent` has no title protocol or the title is not one of its own.
    static func parse(_ title: String, agent: AgentKind) -> (status: TeleportStatus, name: String, marked: Bool)? {
        nil
    }
}
