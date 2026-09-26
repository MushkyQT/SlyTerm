import AppKit

struct ClaudeActivity: Equatable {
    var status: TeleportStatus
    var since: Date?
    var sessionID: String
    // For a background session: the daemon-hosted process, not the `claude attach` in the tab.
    var pid: pid_t
    var isBackground: Bool
    // The pty's foreground group when matched (the attach client for a background session); the
    // answer checks it is still in front before typing.
    var processGroup: pid_t?
    var doing: ClaudeDoing?
    var request: ClaudeRequest?
    var lastMessage: String?
    var lastTurnDuration: TimeInterval?

    var isWorking: Bool { status == .working }
    var isWaiting: Bool { status == .waiting }

    var prompt: ClaudePrompt? {
        isWaiting ? ClaudePrompt(sessionID: sessionID, since: since, request: request) : nil
    }
}

// Claude Code's status goes back to busy between two prompts, so each prompt gets a new `since`.
struct ClaudePrompt: Equatable {
    var sessionID: String
    var since: Date?
    var request: ClaudeRequest?

    // The stamp decides; the request only for a Claude too old to stamp its status.
    // `==` is stricter on purpose: it compares what the user saw.
    func isSame(as other: ClaudePrompt) -> Bool {
        guard sessionID == other.sessionID else { return false }
        if let since, let then = other.since { return since == then }
        return request == other.request
    }
}

struct ClaudeDoing: Equatable {
    var tool: String
    var label: String
    var startedAt: Date?
}

enum ClaudeRequest: Equatable {
    case permission(tool: String, summary: String, detail: String?)
    case question(text: String, options: [String])
    case unknown

    var isAnswerableByKey: Bool {
        if case .permission = self { return true }
        return false
    }
}

enum ActivityEvent: Equatable {
    case finished(tab: UUID, activity: ClaudeActivity)
    case asks(tab: UUID, activity: ClaudeActivity)
    case answered(tab: UUID)
    case gone(tab: UUID)
    case changed(tab: UUID)

    var tab: UUID {
        switch self {
        case .finished(let tab, _), .asks(let tab, _), .answered(let tab), .gone(let tab), .changed(let tab): return tab
        }
    }
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
    var presentedPrompt: ClaudePrompt? { get }
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
