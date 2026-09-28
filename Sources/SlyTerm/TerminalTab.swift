import AppKit
import Darwin
import SwiftTerm

final class SlyTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // No super: SwiftTerm's default would beep regardless of the overlay's state.
    override func bell(source: Terminal) {
        // Always async: BEL arrives mid-`feed()` inside the parser, and the handler moves windows.
        DispatchQueue.main.async { [weak self] in self?.onBell?() }
    }
}

final class TerminalTab: NSObject, Tab, LocalProcessTerminalViewDelegate {
    static let backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    static let insets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 2)
    let id = UUID()
    let view: SlyTerminalView
    var contentView: NSView { view }
    var focusView: NSView { view }
    private(set) var startDirectory: String
    private(set) var title: String { didSet { if title != oldValue { onTitleChange?() } } }
    var needsAttention = false { didSet { if needsAttention != oldValue { onAttentionChange?() } } }
    var onTitleChange: (() -> Void)?
    var onDirectoryChange: (() -> Void)?
    var onAttentionChange: (() -> Void)?
    var onBell: (() -> Void)?
    var onExit: (() -> Void)?
    var activity: AgentActivity? {
        didSet {
            guard activity != oldValue else { return }
            updateTitle()
            onActivityChange?()
        }
    }
    var onActivityChange: (() -> Void)?
    var onNotification: ((_ title: String?, _ body: String) -> Void)?
    private(set) var titleStates: [AgentKind: TitleState] = [:]

    private var shellTitle: String?
    private var reportedDirectory: String?
    private var lastKnownDirectory: String
    // What the program was last told about the keyboard. SwiftTerm starts at focused and reports
    // on its own whenever the view becomes or stops being first responder.
    private var focusReported = true
    private var isFirstResponder = false

    init(frame: NSRect, directory: String) {
        let s = Settings.shared
        startDirectory = directory
        lastKnownDirectory = directory
        view = SlyTerminalView(frame: frame, font: s.font, options: TerminalOptions(scrollback: s.scrollback))
        title = TerminalTab.folderTitle(directory)
        super.init()
        view.processDelegate = self
        view.onBell = { [weak self] in self?.onBell?() }
        view.bellStyle = .none
        view.autoresizingMask = [.width, .height]
        view.optionAsMetaKey = s.optionAsMeta
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        view.nativeBackgroundColor = TerminalTab.backgroundColor
        view.backgroundOpacity = 0
        view.caretColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        view.caretTextColor = TerminalTab.backgroundColor
        view.selectedTextBackgroundColor = NSColor.systemBlue.withAlphaComponent(0.45)
        // Registered handlers replace SwiftTerm's own parsing of these two codes.
        let terminal = view.getTerminal()
        for code in [9, 777] {
            terminal.registerOscHandler(code: code) { [weak self] data in
                self?.notification(code: code, data)
            }
        }
        Settings.log("font: \(view.font.fontName) family=\(view.font.familyName ?? "?") size=\(view.font.pointSize)")
    }

    func start(runStartupCommand: Bool = true) {
        let s = Settings.shared
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("TERM_PROGRAM=SlyTerm")
        env.append("TERM_PROGRAM_VERSION=0.1.0")
        env.append("SLYTERM_TAB_ID=\(id.uuidString)")
        env.append("SHELL=\(s.shell)")
        env.append("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        let inherited = ProcessInfo.processInfo.environment
        for key in ["TMPDIR", "XDG_CONFIG_HOME", "SSH_AUTH_SOCK"] {
            if let v = inherited[key] { env.append("\(key)=\(v)") }
        }
        var cwd = startDirectory
        if !TerminalTab.isUsableDirectory(cwd) { cwd = NSHomeDirectory() }
        view.startProcess(executable: s.shell, args: ["-l"], environment: env, currentDirectory: cwd)
        startDirectory = cwd
        lastKnownDirectory = cwd
        updateTitle()
        Settings.log("tab start: dir=\(cwd) pid=\(view.process?.shellPid ?? 0)")

        if runStartupCommand { sendStartupCommand() }
    }

    func sendStartupCommand() {
        let command = Settings.shared.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.view.send(txt: command + "\r")
        }
    }

    func type(_ text: String, enter: Bool) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.view.send(txt: enter ? text + "\r" : text)
        }
    }

    func send(raw text: String) {
        guard !text.isEmpty else { return }
        view.send(txt: text)
    }

    func paintNote(_ line: String) {
        view.feed(text: "\u{1b}[2m\(line)\u{1b}[0m\r\n")
    }

    func terminate() { view.terminate() }

    var currentDirectory: String {
        if let live = liveWorkingDirectory(), TerminalTab.isUsableDirectory(live) { return live }
        if let reported = reportedDirectory, TerminalTab.isUsableDirectory(reported) { return reported }
        return lastKnownDirectory
    }

    var knownDirectory: String { lastKnownDirectory }

    // SwiftTerm ignores a failed chdir in the child and execs anyway (in `/` from Finder), so
    // check +x and +r here, not just existence.
    static func isUsableDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return access(path, X_OK | R_OK) == 0
    }

    // `running` is required: shellPid is never cleared on exit, and a reused pid would report
    // another process's cwd into the saved session.
    private func liveWorkingDirectory() -> String? {
        guard let process = view.process, process.running, process.shellPid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(process.shellPid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    var isRunningForegroundJob: Bool {
        // `running` is required: childfd stays set after exit, and a recycled fd can be another
        // tab's pty. Same for the two properties below.
        guard let process = view.process, process.running, process.childfd >= 0 else { return false }
        let pgid = tcgetpgrp(process.childfd)
        return pgid > 0 && pgid != process.shellPid
    }

    var foregroundProcessGroup: pid_t? {
        guard let process = view.process, process.running, process.childfd >= 0 else { return nil }
        let pgid = tcgetpgrp(process.childfd)
        return pgid > 0 ? pgid : nil
    }

    // Main thread only: ptsname returns a shared static buffer.
    var ttyName: String? {
        guard let process = view.process, process.running, process.childfd >= 0,
              let name = ptsname(process.childfd) else { return nil }
        return SessionDiscovery.ttyName(fromArgument: String(cString: name))
    }

    private static func folderTitle(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? (Settings.shared.shell as NSString).lastPathComponent : name
    }

    func refresh() {
        let dir = currentDirectory
        if dir != lastKnownDirectory {
            lastKnownDirectory = dir
            onDirectoryChange?()
        }
        updateTitle()
    }

    // An agent that animates its title is shown by the name in it, so the tab's name holds still.
    private func updateTitle() {
        let name = activity.flatMap { titleStates[$0.agent]?.name } ?? ""
        title = name.isEmpty ? shellTitle ?? TerminalTab.folderTitle(lastKnownDirectory) : name
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shellTitle = title.isEmpty ? nil : title
            let moved = self.readTitleStates(title)
            self.refresh()
            // Claude Code's title starts with Qwen's waiting mark: only the tab's own agent counts.
            if moved.contains(where: { kind in self.activity.map { $0.agent == kind } ?? true }) {
                Activity.monitor?.refreshNow(completion: nil)
            }
        }
    }

    // Spinner frames and Codex's blinking mark keep the stamp: `since` moves with the status only.
    // Returns the kinds whose status moved.
    private func readTitleStates(_ text: String) -> [AgentKind] {
        let now = Date()
        var moved: [AgentKind] = []
        for agent in AgentTitle.kinds {
            guard let parsed = AgentTitle.parse(text, agent: agent) else {
                if titleStates.removeValue(forKey: agent) != nil { moved.append(agent) }
                continue
            }
            let old = titleStates[agent]
            var state = old ?? TitleState(status: parsed.status, since: now, name: "", markedAt: nil)
            if state.status != parsed.status { (state.status, state.since) = (parsed.status, now) }
            state.name = parsed.name
            if parsed.marked { state.markedAt = now }
            if old.map({ $0.status != state.status }) ?? parsed.marked { moved.append(agent) }
            titleStates[agent] = state
        }
        return moved
    }

    // The rows the program drew, even with the view scrolled back: only the bounds of
    // `getScrollInvariantLine(row:)` say where the buffer ends. Main thread only.
    func visibleLines() -> [String] {
        let terminal = view.getTerminal()
        let top = terminal.buffer.totalLinesTrimmed
        var low = top + terminal.getTopVisibleRow() + terminal.rows
        var high = low
        var step = max(1, terminal.rows)
        while terminal.getScrollInvariantLine(row: high) != nil {
            low = high + 1
            high += step
            step *= 2
        }
        while low < high {
            let middle = (low + high) / 2
            if terminal.getScrollInvariantLine(row: middle) == nil { high = middle } else { low = middle + 1 }
        }
        return (max(top, low - terminal.rows)..<low).map { row in
            // Cells never written hold NUL.
            var text = terminal.getScrollInvariantLine(row: row)?.translateToString(
                trimRight: true, skipNullCellsFollowingWide: true,
                characterProvider: { cell in
                    let character = terminal.getCharacter(for: cell)
                    return character == "\0" ? " " : character
                }) ?? ""
            while text.last == " " { text.removeLast() }
            return text
        }
    }

    func firstResponderChanged(_ first: Bool) {
        guard first != isFirstResponder else { return }
        isFirstResponder = first
        focusReported = first
    }

    // Reaches the program only once it has asked for focus reports (DECSET 1004).
    func reportFocus(_ focused: Bool) {
        guard focused != focusReported else { return }
        focusReported = focused
        view.getTerminal().setTerminalFocus(focused)
    }

    // OSC 777 `notify;title;body` and OSC 9 `body`. OSC 9 `4;state;progress` is a progress report,
    // passed on to SwiftTerm's progress bar; ConEmu's other numbered OSC 9 commands are dropped.
    private func notification(code: Int, _ data: ArraySlice<UInt8>) {
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        var title: String?
        let body: String
        if code == 777 {
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "notify" else { return }
            (title, body) = (String(parts[1]), String(parts[2]))
        } else {
            if let report = TerminalTab.progressReport(text) {
                view.progressReport(source: view.getTerminal(), report: report)
                return
            }
            let conEmu = text.range(of: #"\A[0-9]+(;|\z)"#, options: .regularExpression) != nil
            guard !conEmu else { return }
            body = text
        }
        guard let clean = TerminalTab.printable(body) else { return }
        let heading = title.flatMap { TerminalTab.printable($0) }
        DispatchQueue.main.async { [weak self] in self?.onNotification?(heading, clean) }
    }

    // SwiftTerm's own reading of `4;<state>[;<progress>]`, which it keeps private.
    private static func progressReport(_ text: String) -> Terminal.ProgressReport? {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "4", parts[1].count == 1, let raw = Int(parts[1]),
              let state = Terminal.ProgressReportState(rawValue: raw) else { return nil }
        var progress: UInt8?
        if parts.count >= 3, !parts[2].isEmpty {
            guard let value = Int(parts[2]) else { return nil }
            progress = UInt8(max(0, min(value, 100)))
        } else if state == .set {
            progress = 0
        }
        return Terminal.ProgressReport(state: state, progress: state == .remove ? nil : progress)
    }

    // Any program in the tab can send these: controls and invisible format characters go.
    private static func printable(_ text: String, limit: Int = 300) -> String? {
        let scalars = text.unicodeScalars.lazy
            .map { CharacterSet.whitespacesAndNewlines.contains($0) ? " " : $0 }
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let flat = String(String.UnicodeScalarView(scalars)).split(separator: " ")
            .joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        let path: String
        if directory.hasPrefix("file://") {
            guard let url = URL(string: directory), TerminalTab.isLocalHost(url.host ?? ""),
                  !url.path.isEmpty else { return }
            path = url.path
        } else if directory.hasPrefix("/") {
            path = directory
        } else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reportedDirectory = path
            self.refresh()
        }
    }

    // Shells report `mymac` in OSC 7 where hostName gives `mymac.local`.
    private static func isLocalHost(_ host: String) -> Bool {
        guard !host.isEmpty, host != "localhost" else { return true }
        let short = { (name: String) in name.split(separator: ".").first.map(String.init) ?? name }
        return short(host).caseInsensitiveCompare(short(ProcessInfo.processInfo.hostName)) == .orderedSame
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in self?.onExit?() }
    }
}
