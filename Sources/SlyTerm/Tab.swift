import AppKit

protocol Tab: AnyObject {
    var id: UUID { get }
    var contentView: NSView { get }
    // For a guide, the web view inside the container: the container refuses first responder.
    var focusView: NSView { get }
    var title: String { get }
    var onTitleChange: (() -> Void)? { get set }
    var needsAttention: Bool { get set }
    var onAttentionChange: (() -> Void)? { get set }
    var isRunningForegroundJob: Bool { get }
    func terminate()
    func refresh()
}

extension Tab {
    var isRunningForegroundJob: Bool { false }
    func refresh() {}
}
