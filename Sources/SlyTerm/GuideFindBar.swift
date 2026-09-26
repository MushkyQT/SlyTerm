import AppKit

final class GuideFindBar: GuideToolbarView, NSSearchFieldDelegate {
    static let height: CGFloat = 28

    let field = NSSearchField(frame: .zero)
    private let countLabel = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var lastQuery = ""

    var onChange: ((String) -> Void)?
    var onStep: ((Int) -> Void)?
    var onClose: (() -> Void)?

    var isEditing: Bool { field.currentEditor() != nil }

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue; lastQuery = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        build()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let fieldHeight: CGFloat = 19
        field.frame = NSRect(x: 8, y: (GuideFindBar.height - fieldHeight) / 2, width: 210, height: fieldHeight)
        field.controlSize = .small
        field.font = NSFont.systemFont(ofSize: 11.5)
        field.placeholderString = "Find in page"
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = self
        field.target = self
        field.action = #selector(changed)

        countLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.55)
        countLabel.lineBreakMode = .byTruncatingTail

        let previous = GuideToolbarView.button("chevron.up", tooltip: "Previous match (⇧Return)", target: self, action: #selector(stepBack))
        let next = GuideToolbarView.button("chevron.down", tooltip: "Next match (Return)", target: self, action: #selector(stepForward))
        let close = GuideToolbarView.button("xmark", tooltip: "Done (Esc)", target: self, action: #selector(closeBar))
        buttons = [previous, next, close]
        [field, countLabel, previous, next, close].forEach { addSubview($0) }
        place()
    }

    // Laid out by hand: the bar is created with no size and sized later, which autoresizing
    // masks get wrong.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    private func place() {
        let width = bounds.width
        let size: CGFloat = 20, y = (GuideFindBar.height - size) / 2
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: width - 70 + CGFloat(i) * 22, y: y, width: size, height: size)
        }
        let left = field.frame.maxX + 8
        countLabel.frame = NSRect(x: left, y: (GuideFindBar.height - 16) / 2, width: max(0, width - 76 - left), height: 16)
    }

    func show(count: Int, index: Int) {
        if field.stringValue.isEmpty {
            countLabel.stringValue = ""
        } else if count == 0 {
            countLabel.stringValue = "Not found"
            countLabel.textColor = NSColor(calibratedRed: 1, green: 0.55, blue: 0.5, alpha: 0.9)
        } else {
            countLabel.stringValue = "\(index) of \(count)"
            countLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.55)
        }
    }

    // Also wired as the field's action: NSSearchField reports its cancel button only there.
    func controlTextDidChange(_ notification: Notification) { changed() }

    @objc private func changed() {
        let query = field.stringValue
        guard query != lastQuery else { return }
        lastQuery = query
        onChange?(query)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onStep?(shift ? -1 : 1)
        case #selector(NSResponder.cancelOperation(_:)): onClose?()
        case #selector(NSResponder.moveUp(_:)): onStep?(-1)
        case #selector(NSResponder.moveDown(_:)): onStep?(1)
        default: return false
        }
        return true
    }

    @objc private func stepBack() { onStep?(-1) }
    @objc private func stepForward() { onStep?(1) }
    @objc private func closeBar() { onClose?() }
}
