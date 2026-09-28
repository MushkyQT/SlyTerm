import AppKit

enum HotkeyAction: String, CaseIterable {
    case toggle, ghost, panic, fullscreen, quest, pick, allow, refuse, playPause

    var title: String {
        switch self {
        case .toggle: return "Show / hide terminal"
        case .ghost: return "Toggle click-through"
        case .panic: return "Panic mode"
        case .fullscreen: return "Fullscreen"
        case .quest: return "Look up what's under the pointer"
        case .pick: return "Pick text near the pointer"
        case .allow: return "Allow what the agent asks"
        case .refuse: return "Refuse it"
        case .playPause: return "Play / pause"
        }
    }

    var settingsKey: String {
        switch self {
        case .toggle: return "hotkeyToggle"
        case .ghost: return "hotkeyGhost"
        case .panic: return "hotkeyPanic"
        case .fullscreen: return "hotkeyFullscreen"
        case .quest: return "hotkeyQuest"
        case .pick: return "hotkeyPick"
        case .allow: return "hotkeyAllow"
        case .refuse: return "hotkeyRefuse"
        case .playPause: return "hotkeyPlayPause"
        }
    }

    var defaultCombo: String {
        switch self {
        case .toggle: return "ctrl+alt+h"
        case .ghost: return "ctrl+alt+tab"
        case .panic: return "ctrl+alt+p"
        case .fullscreen: return "ctrl+alt+m"
        case .quest: return "ctrl+alt+q"
        case .pick: return "ctrl+alt+shift+q"
        case .allow: return "ctrl+alt+y"
        case .refuse: return "ctrl+alt+n"
        case .playPause: return "ctrl+alt+v"
        }
    }

    var needsActivityCards: Bool { self == .allow || self == .refuse }
}

final class HotkeyRecorderView: NSView {
    var combo: String { didSet { needsDisplay = true } }
    var onChange: ((String) -> Void)?
    // Carbon swallows a registered combo system-wide, so hotkeys unregister while recording.
    var onBeginRecording: (() -> Void)?
    var onEndRecording: (() -> Void)?
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled, recording { window?.makeFirstResponder(nil) }
            needsDisplay = true
        }
    }

    private var recording = false { didSet { needsDisplay = true } }
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var warning: String? { didSet { needsDisplay = true } }
    private var warningTimer: Timer?

    init(combo: String) {
        self.combo = combo
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 26))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 180).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override func becomeFirstResponder() -> Bool {
        recording = true
        heldModifiers = []
        onBeginRecording?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        onEndRecording?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if recording {
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { return super.flagsChanged(with: event) }
        heldModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        needsDisplay = true
    }

    // Cmd combos arrive as key equivalents before keyDown; grab them while recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        switch event.keyCode {
        case 53:                                   // Escape
            window?.makeFirstResponder(nil)
        case 51, 117:                              // Delete, forward delete
            combo = ""
            window?.makeFirstResponder(nil)
            onChange?(combo)
        default:
            guard let key = KeyCombo.keyName(for: event) else {
                flash("Key not supported")
                return
            }
            let hasModifier = mods.contains(.control) || mods.contains(.option) || mods.contains(.command)
            guard hasModifier || KeyCombo.usableWithoutModifier(key) else {
                flash("Add ⌃, ⌥ or ⌘")
                return
            }
            combo = KeyCombo.string(modifiers: mods, key: key)
            window?.makeFirstResponder(nil)
            onChange?(combo)
        }
    }

    private func flash(_ text: String) {
        warning = text
        warningTimer?.invalidate()
        warningTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.warning = nil }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.45) }

        let text: String
        let color: NSColor
        if let warning {
            text = warning
            color = .systemOrange
        } else if recording {
            let held = KeyCombo.pretty(KeyCombo.string(modifiers: heldModifiers, key: "")).replacingOccurrences(of: "+", with: "")
            text = held.isEmpty ? "Type shortcut…" : held
            color = held.isEmpty ? .secondaryLabelColor : .labelColor
        } else if combo.isEmpty {
            text = "none"
            color = .secondaryLabelColor
        } else {
            text = KeyCombo.pretty(combo)
            color = .labelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
