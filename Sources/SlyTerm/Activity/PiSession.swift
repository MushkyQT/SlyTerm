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

    static func head(_ url: URL) -> Head? {
        nil
    }

    static func read(_ url: URL) -> TranscriptTail.Reading {
        TranscriptTail.Reading()
    }
}
