import AppKit

class OverlayPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    // Set while SlyTerm gives the keyboard away, so AppKit cannot hand it on to this panel.
    var refusesKey = false

    override var canBecomeKey: Bool { !refusesKey }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let handler = keyHandler, handler(event) { return }
        super.sendEvent(event)
    }

    // No clamping: AppKit would keep the panel below the menu bar, and panic mode covers it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// A separate child window so the strip stays clickable in click-through mode:
// ignoresMouseEvents is per window.
final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
