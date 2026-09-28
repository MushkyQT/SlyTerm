import AppKit

enum AgentKind: String, CaseIterable, Equatable {
    case claude, codex, omp, pi, gemini, qwen

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .omp: return "omp"
        case .pi: return "pi"
        case .gemini: return "Gemini"
        case .qwen: return "Qwen"
        }
    }

    var productName: String {
        switch self {
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .qwen: return "Qwen Code"
        default: return name
        }
    }

    // Only ever given an id `Safe.sessionID` has validated: this text reaches a shell.
    func resumeCommand(id: String) -> String? {
        switch self {
        case .claude: return "claude --resume \(id)"
        case .codex: return "codex resume \(id)"
        case .omp: return "omp --resume=\(id)"
        case .pi: return "pi --session \(id)"
        case .gemini, .qwen: return nil
        }
    }

    func copyCommand(id: String) -> String? {
        switch self {
        case .claude: return "claude --resume \(id) --fork-session"
        case .codex: return "codex fork \(id)"
        case .pi: return "pi --fork \(id)"
        case .omp, .gemini, .qwen: return nil
        }
    }

    // Claude Code's prompt has "Yes" first and highlighted. Codex's own letters: if its prompt
    // went away meanwhile, a letter lands in the input box where Return would submit a draft.
    var answerKeys: (allow: String, refuse: String)? {
        switch self {
        case .claude: return ("\r", "\u{1b}")
        case .codex: return ("y", "n")
        default: return nil
        }
    }
}

struct AgentActivity: Equatable {
    var agent: AgentKind
    var status: TeleportStatus
    var since: Date?
    var sessionID: String
    // For a background session: the daemon-hosted process, not the `claude attach` in the tab.
    var pid: pid_t
    var isBackground: Bool
    // The pty's foreground group when matched (the attach client for a background session); the
    // answer checks it is still in front before typing.
    var processGroup: pid_t?
    var doing: AgentDoing?
    var request: AgentRequest?
    var lastMessage: String?
    var lastTurnDuration: TimeInterval?

    var isWorking: Bool { status == .working }
    var isWaiting: Bool { status == .waiting }

    var prompt: AgentPrompt? {
        isWaiting ? AgentPrompt(sessionID: sessionID, since: since, request: request) : nil
    }
}

// Claude Code's status goes back to busy between two prompts, so each prompt gets a new `since`.
struct AgentPrompt: Equatable {
    var sessionID: String
    var since: Date?
    var request: AgentRequest?

    // The stamp decides; the request only for a Claude too old to stamp its status.
    // `==` is stricter on purpose: it compares what the user saw.
    func isSame(as other: AgentPrompt) -> Bool {
        guard sessionID == other.sessionID else { return false }
        if let since, let then = other.since { return since == then }
        return request == other.request
    }
}

struct AgentDoing: Equatable {
    var tool: String
    var label: String
    var startedAt: Date?
}

enum AgentRequest: Equatable {
    case permission(tool: String, summary: String, detail: String?)
    case question(text: String, options: [String])
    case unknown

    var isAnswerableByKey: Bool {
        if case .permission = self { return true }
        return false
    }
}

enum ActivityEvent: Equatable {
    case finished(tab: UUID, activity: AgentActivity)
    case asks(tab: UUID, activity: AgentActivity)
    case answered(tab: UUID)
    case gone(tab: UUID)
    case changed(tab: UUID)
    // An OSC 9 or OSC 777 notification from whatever runs in the tab.
    case notified(tab: UUID, title: String?, body: String)

    var tab: UUID {
        switch self {
        case .finished(let tab, _), .asks(let tab, _), .answered(let tab), .gone(let tab), .changed(let tab),
             .notified(let tab, _, _): return tab
        }
    }
}

// A tab as the main thread sees it when a scan starts. The title and the screen live in
// SwiftTerm and `ptsname` uses a shared buffer, so all of it is read there.
struct TabProbe: Equatable {
    var tty: String
    var foregroundGroup: pid_t?
    var titles: [AgentKind: TitleState]
    // The visible lines, read only while some title says its agent is waiting.
    var screen: [String]?
}

// What one agent's title protocol makes of the tab's title, stamped when the status changed.
struct TitleState: Equatable {
    var status: TeleportStatus
    var since: Date
    var name: String
    // Last time the title carried one of the agent's own state marks. Codex's idle title has
    // none, so its title is only trusted after a mark since the agent started.
    var markedAt: Date?
}

protocol ActivityMonitoring: AnyObject {
    var onEvent: ((ActivityEvent) -> Void)? { get set }
    func start(tabs: @escaping () -> [TerminalTab], visible: @escaping () -> Bool)
    func stop()
    // `completion` runs on the main thread after the scan is applied to the tabs; the answer
    // relies on that before it types.
    func refreshNow(completion: (() -> Void)?)
}

protocol ActivityCardPresenting: AnyObject {
    func present(_ event: ActivityEvent, tab: TerminalTab)
    func refresh(_ tab: TerminalTab)
    func dismiss(tab: UUID?)
    var presentedTab: UUID? { get }
    var presentedPrompt: AgentPrompt? { get }
    var presentedAt: Date? { get }
    func layout()
}

protocol ActivityHost: AnyObject {
    var terminals: [TerminalTab] { get }
    var selectedTerminal: TerminalTab? { get }
    var stripScreenFrame: NSRect { get }
    var stripEdge: StripEdge { get }
    var isGhost: Bool { get }
    var isOverlayVisible: Bool { get }
    func isBeingViewed(_ tab: Tab) -> Bool
    @discardableResult
    func select(tabID: UUID) -> Bool
    func requestAttention(_ tab: Tab)
    func clearAttention(_ tab: Tab)
}

enum Activity {
    static var monitor: ActivityMonitoring?
    static var card: ActivityCardPresenting?
    static weak var host: ActivityHost?
}

enum TabStripMark: Equatable {
    case none
    case attention
    case working
    case waiting
}

func activityElapsed(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    return String(format: "%dh %02dm", minutes / 60, minutes % 60)
}

func activityDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return seconds % 60 == 0 ? "\(minutes)m" : "\(minutes)m \(seconds % 60)s" }
    return String(format: "%dh %02dm", minutes / 60, minutes % 60)
}
