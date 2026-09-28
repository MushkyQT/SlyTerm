import Foundation

enum CodexRollout {
    struct Head: Equatable {
        var id: String
        var cwd: String
        var startedAt: Date?
        var originator: String?
        var firstPrompt: String?
    }

    static func head(_ url: URL) -> Head? {
        nil
    }

    static func read(_ url: URL) -> TranscriptTail.Reading {
        TranscriptTail.Reading()
    }

    // Thread id → name, from `session_index.jsonl` under a Codex home (`~/.codex` by default).
    static func threadNames(in home: URL) -> [String: String] {
        [:]
    }
}
