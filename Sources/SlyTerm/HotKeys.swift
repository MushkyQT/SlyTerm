import AppKit
import Carbon

// Carbon, not an event monitor: needs no Accessibility permission and fires over fullscreen games.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if err == noErr {
                DispatchQueue.main.async { HotKeyCenter.shared.fire(id: hotKeyID.id) }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    @discardableResult
    func register(_ combo: String, handler: @escaping () -> Void) -> Bool {
        guard let parsed = KeyCombo.parse(combo) else {
            Settings.log("hotkey '\(combo)': cannot parse")
            return false
        }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: KeyCombo.fourCC("HVTM"), id: id)
        let status = RegisterEventHotKey(parsed.keyCode, parsed.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        Settings.log("hotkey '\(combo)': keyCode=\(parsed.keyCode) mods=\(parsed.carbonModifiers) status=\(status)")
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func fire(id: UInt32) { handlers[id]?() }
}

struct KeyCombo {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    static func pretty(_ combo: String) -> String {
        combo.lowercased().split(separator: "+").map { part -> String in
            switch part.trimmingCharacters(in: .whitespaces) {
            case "ctrl", "control": return "⌃"
            case "alt", "opt", "option": return "⌥"
            case "cmd", "command": return "⌘"
            case "shift": return "⇧"
            case "space": return "Space"
            case "return": return "↩"
            case "escape": return "⎋"
            case "tab": return "Tab"
            case "left": return "←"
            case "right": return "→"
            case "up": return "↑"
            case "down": return "↓"
            case "section": return "§"
            case "grave": return "`"
            case let k: return aliases[k].map { String($0) } ?? k.uppercased()
            }
        }.joined()
    }

    static func menuKeyEquivalent(_ combo: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.last, !name.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control", "^": modifiers.insert(.control)
            case "alt", "opt", "option", "⌥": modifiers.insert(.option)
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard let key = keyEquivalent(for: name) else { return nil }
        return (key, modifiers)
    }

    private static func keyEquivalent(for name: String) -> String? {
        switch name {
        case "space": return " "
        case "return", "enter": return "\r"
        case "tab": return "\t"
        case "escape", "esc": return "\u{1B}"
        case "delete", "backspace": return "\u{8}"
        case "left": return functionKey(NSLeftArrowFunctionKey)
        case "right": return functionKey(NSRightArrowFunctionKey)
        case "up": return functionKey(NSUpArrowFunctionKey)
        case "down": return functionKey(NSDownArrowFunctionKey)
        case "home": return functionKey(NSHomeFunctionKey)
        case "end": return functionKey(NSEndFunctionKey)
        case "pageup": return functionKey(NSPageUpFunctionKey)
        case "pagedown": return functionKey(NSPageDownFunctionKey)
        default:
            if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...15).contains(n) {
                return functionKey(NSF1FunctionKey + n - 1)
            }
            if let ch = aliases[name] { return String(ch) }
            // § and ` have no menu key equivalent AppKit can draw.
            if name.count == 1, let ch = name.first, ch.isLetter || ch.isNumber { return String(ch) }
            return nil
        }
    }

    private static func functionKey(_ code: Int) -> String? {
        UnicodeScalar(UInt32(code)).map { String(Character($0)) }
    }

    static func fourCC(_ s: String) -> OSType {
        s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    static func parse(_ text: String) -> KeyCombo? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var mods: UInt32 = 0
        for m in parts.dropLast() {
            switch m {
            case "ctrl", "control", "^": mods |= UInt32(controlKey)
            case "alt", "opt", "option", "⌥": mods |= UInt32(optionKey)
            case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            default: return nil
            }
        }
        guard let code = keyCode(for: keyName) else { return nil }
        return KeyCombo(keyCode: code, carbonModifiers: mods)
    }

    private static let namedKeys: [String: UInt32] = [
        "space": 49, "tab": 48, "return": 36, "enter": 36, "escape": 53, "esc": 53,
        "delete": 51, "backspace": 51, "grave": 50, "backtick": 50, "`": 50, "section": 10,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    ]

    private static let usKeys: [Character: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    ]

    private static let aliases: [String: Character] = [
        "plus": "+", "minus": "-", "equal": "=", "equals": "=", "comma": ",", "period": ".", "slash": "/",
        "semicolon": ";", "quote": "'", "backslash": "\\", "leftbracket": "[", "rightbracket": "]",
        "less": "<", "greater": ">",
    ]

    private static let codeNames: [UInt16: String] = [
        49: "space", 48: "tab", 36: "return", 76: "return", 53: "escape", 50: "grave", 10: "section",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
    ]

    static func keyName(for event: NSEvent) -> String? {
        if let name = codeNames[event.keyCode] { return name }
        guard let chars = event.charactersIgnoringModifiers, chars.count == 1, let ch = chars.first,
              !ch.isWhitespace, !(ch.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? true) else {
            return nil
        }
        if let alias = aliases.first(where: { $0.value == ch }) { return alias.key }
        return String(ch).lowercased()
    }

    // A registered combo is captured system-wide, so a bare letter would break typing everywhere.
    static func usableWithoutModifier(_ key: String) -> Bool {
        if key.hasPrefix("f"), Int(key.dropFirst()) != nil { return true }
        if ["section", "grave"].contains(key) { return true }
        // Virtual key codes 10 and 50 are the § and ` keys.
        if key.count == 1, let ch = key.first, let code = keyCodeFromCurrentLayout(for: ch), code == 10 || code == 50 { return true }
        return false
    }

    // Only macOS's own shortcuts can be found: one that another app registered still registers
    // here without an error.
    static func isMacOSShortcut(_ combo: String) -> Bool {
        guard let parsed = parse(combo) else { return false }
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let entries = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        // Carbon modifier bits; an entry that also needs fn is a different shortcut.
        let mask = UInt32(cmdKey | shiftKey | optionKey | controlKey) | UInt32(kEventKeyModifierFnMask)
        return entries.contains { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int else {
                return false
            }
            return code == Int(parsed.keyCode)
                && UInt32(truncatingIfNeeded: modifiers) & mask == parsed.carbonModifiers
        }
    }

    static func string(modifiers: NSEvent.ModifierFlags, key: String) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        if !key.isEmpty { parts.append(key) }
        return parts.joined(separator: "+")
    }

    static func keyCode(for name: String) -> UInt32? {
        if let code = namedKeys[name] { return code }
        if let ch = aliases[name] {
            return keyCodeFromCurrentLayout(for: ch) ?? usKeys[ch]
        }
        guard name.count == 1, let ch = name.first else { return nil }
        if let code = keyCodeFromCurrentLayout(for: ch) { return code }
        return usKeys[ch]
    }

    static func keyCodeFromCurrentLayout(for ch: Character) -> UInt32? {
        guard let layout = currentLayout() else { return nil }
        let target = String(ch).lowercased()
        return (0..<128).first { translate(UInt16($0), with: layout)?.lowercased() == target }.map(UInt32.init)
    }

    static func character(forKeyCode keyCode: UInt16) -> Character? {
        let typed = currentLayout().map { translate(keyCode, with: $0) }
            ?? usKeys.first { $0.value == UInt32(keyCode) }.map { String($0.key) }
        guard let typed, typed.count == 1 else { return nil }
        return typed.first
    }

    private static func currentLayout() -> CFData? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
    }

    private static func translate(_ keyCode: UInt16, with data: CFData) -> String? {
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout -> String? in
            var chars = [UniChar](repeating: 0, count: 4)
            var deadKeyState: UInt32 = 0
            var length = 0
            let err = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                     UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                     &deadKeyState, chars.count, &length, &chars)
            guard err == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
