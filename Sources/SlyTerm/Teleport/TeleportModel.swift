import AppKit

enum TeleportHost: Equatable {
    case iTerm2(sessionID: String?)
    case appleTerminal(sessionID: String?)
    case slyTerm(tabID: UUID?)
    case other(program: String)
    case unknown

    init(program: String?, itermSessionID: String?, termSessionID: String?, slyTermTabID: String?) {
        if let tab = slyTermTabID, !tab.isEmpty { self = .slyTerm(tabID: UUID(uuidString: tab)); return }
        switch program ?? "" {
        case "iTerm.app":
            // ITERM_SESSION_ID is `w0t1p0:<UUID>`; AppleScript's `session id` is the UUID alone.
            let uuid = itermSessionID?.split(separator: ":", maxSplits: 1).last.map(String.init)
            self = .iTerm2(sessionID: uuid?.isEmpty == false ? uuid : nil)
        case "Apple_Terminal": self = .appleTerminal(sessionID: termSessionID?.isEmpty == false ? termSessionID : nil)
        case "SlyTerm": self = .slyTerm(tabID: nil)
        case "": self = .unknown
        case let name: self = .other(program: name)
        }
    }

    var displayName: String {
        switch self {
        case .iTerm2: return "iTerm2"
        case .appleTerminal: return "Terminal"
        case .slyTerm: return "SlyTerm"
        case .other(let program):
            switch program {
            case "WarpTerminal": return "Warp"
            case "ghostty": return "Ghostty"
            case "vscode": return "VS Code"
            case "WezTerm": return "WezTerm"
            case "Hyper": return "Hyper"
            default: return program
            }
        case .unknown: return "Unknown"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .iTerm2: return "com.googlecode.iterm2"
        case .appleTerminal: return "com.apple.Terminal"
        case .slyTerm: return Bundle.main.bundleIdentifier ?? "com.charlesmelki.slyterm"
        case .other(let program):
            switch program {
            case "WarpTerminal": return "dev.warp.Warp-Stable"
            case "ghostty": return "com.mitchellh.ghostty"
            case "vscode": return "com.microsoft.VSCode"
            case "WezTerm": return "com.github.wez.wezterm"
            case "kitty": return "net.kovidgoyal.kitty"
            case "Alacritty": return "org.alacritty"
            case "Hyper": return "co.zeit.hyper"
            default: return nil
            }
        case .unknown: return nil
        }
    }

    var icon: NSImage? {
        guard let id = bundleIdentifier else { return nil }
        if let cached = TeleportHost.iconCache[id] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        TeleportHost.iconCache[id] = icon
        return icon
    }

    // Main thread only. A nil value caches a miss, so an uninstalled app is looked up once.
    private static var iconCache: [String: NSImage?] = [:]

    var canCloseSource: Bool {
        switch self {
        case .iTerm2, .appleTerminal: return true
        default: return false
        }
    }

    var isSlyTerm: Bool { if case .slyTerm = self { return true } else { return false } }
}

enum TeleportStatus: Equatable { case working, waiting, idle, unknown }

struct AgentSessionInfo: Equatable {
    var pid: pid_t
    var sessionID: String
    var cwd: String
    var name: String
    var label: String
    var isBackground: Bool
    var attachID: String?
    var status: TeleportStatus
    var startedAt: Date
    var procStart: Date? = nil
    var host: TeleportHost
    var tty: String?
    var version: String?
    var statusUpdatedAt: Date?
    var agent: AgentKind = .claude
    var transcript: URL? = nil
    // Codex in server mode: stopping this process leaves the turn running in `codex app-server`.
    var turnsRunElsewhere: Bool = false
}

struct ShellTabInfo: Equatable {
    var shellPid: pid_t
    var tty: String
    var cwd: String
    var shellName: String
    var foregroundCommand: String?
    var host: TeleportHost
    var startedAt: Date
}

enum TeleportCandidate: Equatable {
    case agent(AgentSessionInfo)
    case shell(ShellTabInfo)

    var id: String {
        switch self {
        case .agent(let s): return s.sessionID
        case .shell(let t): return "tty:" + t.tty
        }
    }
    var host: TeleportHost {
        switch self {
        case .agent(let s): return s.host
        case .shell(let t): return t.host
        }
    }
    var cwd: String {
        switch self {
        case .agent(let s): return s.cwd
        case .shell(let t): return t.cwd
        }
    }
    var title: String {
        switch self {
        case .agent(let s): return s.label
        case .shell(let t): return t.foregroundCommand ?? t.shellName
        }
    }
    var startedAt: Date {
        switch self {
        case .agent(let s): return s.startedAt
        case .shell(let t): return t.startedAt
        }
    }
    var isAlreadyHere: Bool { host.isSlyTerm }
}

enum TeleportAction: Equatable {
    case move
    case copy
    case attach
    case openFolder
    case switchTo

    static func primary(for candidate: TeleportCandidate) -> TeleportAction {
        if candidate.isAlreadyHere { return .switchTo }
        switch candidate {
        case .agent(let s): return s.agent == .claude && s.isBackground ? .attach : .move
        case .shell: return .openFolder
        }
    }

    static func secondary(for candidate: TeleportCandidate) -> TeleportAction? {
        guard case .agent(let s) = candidate, !s.isBackground, s.agent.copyCommand(id: s.sessionID) != nil else {
            return nil
        }
        return .copy
    }

    var title: String {
        switch self {
        case .move: return "Move Here"
        case .copy: return "Copy Here"
        case .attach: return "Attach Here"
        case .openFolder: return "Open Folder Here"
        case .switchTo: return "Switch to It"
        }
    }
}

enum TeleportError: Error, Equatable {
    case notFound(String)
    case couldNotStop(pid: pid_t, agent: AgentKind)
    case cannotCopy(AgentKind)
    case declined
    case noAttachID
    case noController
    case inProgress

    var message: String {
        switch self {
        case .notFound(let what): return "\(what) is not running any more"
        case .couldNotStop(let pid, let agent):
            return "Couldn't stop \(agent.name) (pid \(pid)). Close it there and try again"
        case .cannotCopy(let agent): return "\(agent.name) sessions can only be moved"
        case .declined: return "Left where it was"
        case .noAttachID: return "That background session has no id to attach to"
        case .noController: return "SlyTerm is not ready yet"
        case .inProgress: return "Already bringing that one in"
        }
    }
}
