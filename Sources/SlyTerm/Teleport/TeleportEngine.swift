import AppKit
import Darwin

final class TeleportEngine {
    static let shared = TeleportEngine()
    weak var controller: OverlayController?
    // A move takes seconds while the source stops; a second request meanwhile would open two
    // tabs resuming one session. Main thread only.
    private var inFlight: Set<String> = []

    // Apple events go on this queue, not the main thread: the first one to an app blocks until
    // the user answers the Automation permission dialog.
    private let appleScript = DispatchQueue(label: "com.charlesmelki.slyterm.applescript")

    // errAEEventNotPermitted: Automation for that app has not been granted.
    private static let notPermitted = -1743
    private var toldAboutAutomation = false

    // Measured: an idle session exits about 1.5 s after SIGTERM, transcript written and registry
    // entry removed.
    private static let sigtermGrace: TimeInterval = 5
    private static let interruptGrace: TimeInterval = 3

    func perform(_ action: TeleportAction, on candidate: TeleportCandidate, closeSource: Bool,
                 completion: @escaping (Result<Void, TeleportError>) -> Void) {
        guard let controller else {
            Settings.log("teleport: \(action.title) asked for before the overlay exists")
            finish(completion, .failure(.noController))
            return
        }
        let key = candidate.id
        guard inFlight.insert(key).inserted else {
            Settings.log("teleport: \(action.title) on \(key) asked for while it is already under way, dropped")
            finish(completion, .failure(.inProgress))
            return
        }
        let completion: (Result<Void, TeleportError>) -> Void = { [weak self] result in
            self?.inFlight.remove(key)
            completion(result)
        }

        var action = action
        if candidate.isAlreadyHere { action = .switchTo }
        if action == .move, case .agent(let session) = candidate, session.agent == .claude,
           session.isBackground { action = .attach }

        switch action {
        case .switchTo:
            switchTo(candidate, controller: controller, completion: completion)
        case .openFolder:
            openFolder(candidate, closeSource: closeSource, controller: controller, completion: completion)
        case .move:
            guard case .agent(let session) = candidate else {
                openFolder(candidate, closeSource: closeSource, controller: controller, completion: completion)
                return
            }
            move(session, closeSource: closeSource, controller: controller, completion: completion)
        case .copy:
            guard case .agent(let session) = candidate else {
                openFolder(candidate, closeSource: false, controller: controller, completion: completion)
                return
            }
            copy(session, controller: controller, completion: completion)
        case .attach:
            guard case .agent(let session) = candidate else {
                openFolder(candidate, closeSource: false, controller: controller, completion: completion)
                return
            }
            attach(session, controller: controller, completion: completion)
        }
    }

    // Stop first: two clients on one session interleave writes into one unlocked transcript.
    private func move(_ session: AgentSessionInfo, closeSource: Bool, controller: OverlayController,
                      completion: @escaping (Result<Void, TeleportError>) -> Void) {
        guard let id = Safe.sessionID(session.sessionID) else {
            Settings.log("teleport move: \"\(session.sessionID)\" is not a session id, nothing done")
            finish(completion, .failure(.notFound(Self.name(of: session))))
            return
        }
        guard let command = session.agent.resumeCommand(id: id) else {
            Settings.log("teleport move: \(session.agent.name) sessions cannot be resumed, nothing done")
            finish(completion, .failure(.notFound(Self.name(of: session))))
            return
        }
        guard SessionDiscovery.isRunning(session) else {
            Settings.log("teleport move: \(Self.name(of: session)) (\(id), pid \(session.pid)) is gone")
            finish(completion, .failure(.notFound(Self.name(of: session))))
            return
        }
        // A Codex whose turns run in its background server keeps working when its window goes.
        guard !session.status.interrupts || !Settings.shared.teleportConfirmBusy
                || session.turnsRunElsewhere || confirmInterrupt(session) else {
            Settings.log("teleport move: \(Self.name(of: session)) is mid-turn and the user chose not to interrupt")
            finish(completion, .failure(.declined))
            return
        }

        Settings.log("teleport move: stopping \(Self.name(of: session)) (\(id), pid \(session.pid)) " +
                     "in \(session.host.displayName)")
        stop(session) { [weak self] stopped in
            guard let self else { return }
            guard stopped else {
                Settings.log("teleport move: \(Self.name(of: session)) (pid \(session.pid)) would not stop, nothing was resumed")
                self.finish(completion, .failure(.couldNotStop(pid: session.pid, agent: session.agent)))
                return
            }
            controller.newTab(directory: self.directory(session.cwd), typing: command, run: true)
            self.reveal(controller)
            Settings.log("teleport move: resumed \(Self.name(of: session)) (\(id)) here, from \(session.host.displayName)")
            if closeSource { self.closeSourceTab(host: session.host, tty: session.tty) }
            self.finish(completion, .success(()))
        }
    }

    private func copy(_ session: AgentSessionInfo, controller: OverlayController,
                      completion: @escaping (Result<Void, TeleportError>) -> Void) {
        guard let id = Safe.sessionID(session.sessionID) else {
            Settings.log("teleport copy: \"\(session.sessionID)\" is not a session id, nothing done")
            finish(completion, .failure(.notFound(Self.name(of: session))))
            return
        }
        guard let command = session.agent.copyCommand(id: id) else {
            Settings.log("teleport copy: \(session.agent.name) sessions cannot be copied, nothing done")
            finish(completion, .failure(.cannotCopy(session.agent)))
            return
        }
        controller.newTab(directory: directory(session.cwd), typing: command, run: true)
        reveal(controller)
        Settings.log("teleport copy: forked \(Self.name(of: session)) (\(id)) into a new tab, source untouched")
        finish(completion, .success(()))
    }

    private func attach(_ session: AgentSessionInfo, controller: OverlayController,
                        completion: @escaping (Result<Void, TeleportError>) -> Void) {
        guard session.agent == .claude, let attachID = session.attachID.flatMap(Safe.attachID) else {
            Settings.log("teleport attach: \(Self.name(of: session)) has no usable attach id")
            finish(completion, .failure(.noAttachID))
            return
        }
        controller.newTab(directory: directory(session.cwd), typing: "claude attach \(attachID)", run: true)
        reveal(controller)
        Settings.log("teleport attach: attached to \(Self.name(of: session)) (\(attachID)) here")
        finish(completion, .success(()))
    }

    private func openFolder(_ candidate: TeleportCandidate, closeSource: Bool, controller: OverlayController,
                            completion: @escaping (Result<Void, TeleportError>) -> Void) {
        guard case .shell(let tab) = candidate else {
            controller.newTab(directory: directory(candidate.cwd), typing: nil)
            reveal(controller)
            Settings.log("teleport open folder: new tab in \(candidate.cwd)")
            finish(completion, .success(()))
            return
        }
        // The command and the host name come from another process and reach a real pty: strip
        // anything that could move the cursor or end a line.
        let command = tab.foregroundCommand.map(Self.printable)
        let note = command.map { Self.printable("Was running in \(tab.host.displayName): \($0)") }
        controller.newTab(directory: directory(tab.cwd), typing: command, run: false, note: note)
        reveal(controller)
        Settings.log("teleport open folder: \(tab.cwd) from \(tab.host.displayName)" +
                     (command.map { ", \"\($0)\" typed but not run" } ?? ""))
        if closeSource, tab.foregroundCommand == nil { closeSourceTab(host: tab.host, tty: tab.tty) }
        finish(completion, .success(()))
    }

    private func switchTo(_ candidate: TeleportCandidate, controller: OverlayController,
                          completion: @escaping (Result<Void, TeleportError>) -> Void) {
        guard case .slyTerm(let tabID) = candidate.host, let tabID, controller.select(tabID: tabID) else {
            Settings.log("teleport switch: no tab of ours answers to that session any more")
            finish(completion, .failure(.notFound("That tab")))
            return
        }
        reveal(controller)
        Settings.log("teleport switch: brought tab \(tabID.uuidString) forward")
        finish(completion, .success(()))
    }

    private func stop(_ session: AgentSessionInfo, then done: @escaping (Bool) -> Void) {
        kill(session.pid, SIGTERM)
        waitForExit(of: session.pid, upTo: Self.sigtermGrace) { [weak self] gone in
            guard let self else { done(false); return }
            if gone { done(true); return }
            // Only Claude Code is known to quit on a double Ctrl-C; SIGTERM always ends Codex.
            guard session.agent == .claude, case .iTerm2(let raw) = session.host,
                  let itermID = raw.flatMap(Safe.appleScriptID) else {
                Settings.log("teleport: pid \(session.pid) survived SIGTERM and its tab cannot be typed into")
                done(false)
                return
            }
            Settings.log("teleport: pid \(session.pid) survived SIGTERM, sending Ctrl-C twice to iTerm2 session \(itermID)")
            self.interrupt(itermSession: itermID)
            // Claude Code exits on a second Ctrl-C only when it follows the first closely,
            // so both are sent before the wait.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.interrupt(itermSession: itermID)
                self.waitForExit(of: session.pid, upTo: Self.interruptGrace, then: done)
            }
        }
    }

    private func interrupt(itermSession id: String) {
        run(appleScript: Self.itermScript(matching: "(id of s) is \"\(id)\"",
                                          doing: "write text (character id 3) newline no"),
            what: "Ctrl-C into iTerm2 session \(id)", host: .iTerm2(sessionID: id))
    }

    // Not `tell session id "…"`: iTerm2 3.7.1 fails it with -1728, as sessions are elements
    // of tabs, not of the application.
    private static func itermScript(matching test: String, doing clause: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if \(test) then
                            tell s to \(clause)
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    private func waitForExit(of pid: pid_t, upTo timeout: TimeInterval, then done: @escaping (Bool) -> Void) {
        if Self.hasExited(pid) { done(true); return }
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if Self.hasExited(pid) { timer.invalidate(); done(true); return }
            if Date() >= deadline { timer.invalidate(); done(false) }
        }
        timer.tolerance = 0.02
    }

    // A zombie counts as gone: its transcript is complete, and its shell may not reap it until
    // its prompt returns.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return true }
        return info.kp_proc.p_stat == SZOMB
    }

    private func confirmInterrupt(_ session: AgentSessionInfo) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let name = session.agent.name
        let alert = NSAlert()
        alert.messageText = session.status == .working ? "\(name) is working in that tab"
            : "\(name) is waiting for your answer in that tab"
        alert.informativeText = "Moving it now interrupts the current turn; what \(name) has said so far is kept."
            + (session.agent == .claude ? " To move it without interrupting, type /bg in that tab first and "
                + "attach it here instead." : "")
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = Settings.shared.dialogLevel
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Closes a second after the new tab opens: an Apple event arriving before the source shell's
    // prompt is back can be lost.
    private func closeSourceTab(host: TeleportHost, tty: String?) {
        // A plain shell's iTerm2 tab has no session id (SIP withholds /bin/zsh's environment),
        // so fall back to matching its tty.
        let device = tty.flatMap(Safe.tty)
        let script: String
        switch host {
        case .iTerm2(let sessionID):
            if let id = sessionID.flatMap(Safe.appleScriptID) {
                script = Self.itermScript(matching: "(id of s) is \"\(id)\"", doing: "close")
            } else if let device {
                script = Self.itermScript(matching: "(tty of s) is \"/dev/\(device)\"", doing: "close")
            } else {
                Settings.log("teleport: the iTerm2 tab has neither a session id nor a tty, left open")
                return
            }
        case .appleTerminal:
            guard let device else {
                Settings.log("teleport: no tty for the Terminal tab to close, left open")
                return
            }
            // Matched by tty. Terminal's tab does not understand `close` (-1708), only its
            // window does, so a window is closed only when this is its sole tab.
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "/dev/\(device)" then
                            if (count of tabs of w) is 1 then close w
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        default:
            Settings.log("teleport: \(host.displayName) cannot be asked to close a tab, left open")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.run(appleScript: script, what: "closing the \(host.displayName) tab", host: host)
        }
    }

    private func run(appleScript source: String, what: String, host: TeleportHost) {
        appleScript.async { [weak self] in
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return }
            let code = error[NSAppleScript.errorNumber] as? Int
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            DispatchQueue.main.async {
                Settings.log("teleport: \(what) failed (\(code.map(String.init) ?? "?")): \(message)")
                guard code == Self.notPermitted, let self, !self.toldAboutAutomation else { return }
                self.toldAboutAutomation = true
                Toast.shared.show("Allow SlyTerm to control \(host.displayName) in " +
                                  "System Settings › Privacy & Security › Automation",
                                  near: NSEvent.mouseLocation, tint: .systemOrange)
            }
        }
    }

    enum RemoteRequest: Equatable {
        case picker
        case malformed(String)
        case subject(Subject, mode: TeleportAction?, closeSource: Bool?)

        enum Subject: Equatable {
            case session(String)
            case pid(pid_t)
            case tty(String)
            case folder(String)
        }
    }

    // A web page can open this URL: nothing may reach a shell but an agent's resume, fork or attach
    // command, with an id validated character by character.
    func handleRemote(_ url: URL) {
        switch Self.request(from: url) {
        case .picker:
            Settings.log("teleport: nothing named, opening the picker")
            TeleportPicker.shared.show()
        case .malformed(let named):
            Settings.log("teleport: \"\(named)\" is not something that can be brought in")
            toast("No session \(Self.short(named)) is running")
        case .subject(let subject, let mode, let close):
            let closeSource = close ?? Settings.shared.teleportClosesSource
            DispatchQueue.global(qos: .userInitiated).async {
                let found = Self.resolve(subject)
                DispatchQueue.main.async { self.act(on: found, subject: subject, mode: mode, closeSource: closeSource) }
            }
        }
    }

    static func request(from url: URL) -> RemoteRequest {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            let raw = items.first { $0.name.lowercased() == name }?.value?.trimmingCharacters(in: .whitespaces)
            return (raw?.isEmpty ?? true) ? nil : raw
        }

        var mode: TeleportAction?
        switch value("mode")?.lowercased() {
        case "move": mode = .move
        case "copy": mode = .copy
        default: mode = nil
        }
        var closeSource: Bool?
        switch value("close")?.lowercased() {
        case "1", "true", "yes": closeSource = true
        case "0", "false", "no": closeSource = false
        default: closeSource = nil
        }
        func subject(_ s: RemoteRequest.Subject) -> RemoteRequest { .subject(s, mode: mode, closeSource: closeSource) }

        if let session = value("session") {
            guard let id = Safe.sessionID(session) else { return .malformed(session) }
            return subject(.session(id))
        }
        if let pid = value("pid") {
            guard let number = Int32(pid), number > 0 else { return .malformed(pid) }
            return subject(.pid(number))
        }
        if let tty = value("tty") {
            guard let device = Safe.tty(tty) else { return .malformed(tty) }
            return subject(.tty(device))
        }
        if let cwd = value("cwd") {
            guard cwd.hasPrefix("/") else { return .malformed(cwd) }
            return subject(.folder(cwd))
        }
        return .picker
    }

    private static func resolve(_ subject: RemoteRequest.Subject) -> TeleportCandidate? {
        switch subject {
        case .session(let id): return SessionDiscovery.agentSession(id: id).map(TeleportCandidate.agent)
        case .pid(let pid): return SessionDiscovery.agentSession(pid: pid).map(TeleportCandidate.agent)
        case .tty(let tty): return SessionDiscovery.shellTab(tty: tty).map(TeleportCandidate.shell)
        case .folder: return nil
        }
    }

    private func act(on candidate: TeleportCandidate?, subject: RemoteRequest.Subject,
                     mode: TeleportAction?, closeSource: Bool) {
        if case .folder(let path) = subject {
            guard let controller, TerminalTab.isUsableDirectory(path) else {
                Settings.log("teleport: no tab can be opened in \(path)")
                toast("No folder to open at \(Self.short(path))")
                return
            }
            controller.newTab(directory: path)
            reveal(controller)
            Settings.log("teleport: opened a tab in \(path)")
            return
        }
        guard let candidate else {
            Settings.log("teleport: \(Self.describe(subject)) is not running")
            toast("No session \(Self.describe(subject)) is running")
            return
        }
        let action: TeleportAction
        if case .shell = candidate {
            action = TeleportAction.primary(for: candidate)
        } else {
            action = mode ?? TeleportAction.primary(for: candidate)
        }
        perform(action, on: candidate, closeSource: closeSource) { result in
            guard case .failure(let error) = result else { return }
            Settings.log("teleport: \(action.title) failed: \(error.message)")
            MainActor.assumeIsolated {
                Toast.shared.show(error.message, near: NSEvent.mouseLocation, tint: .systemOrange)
            }
        }
    }

    private static func describe(_ subject: RemoteRequest.Subject) -> String {
        switch subject {
        case .session(let id): return String(id.prefix(8))
        case .pid(let pid): return "pid \(pid)"
        case .tty(let tty): return tty
        case .folder(let path): return short(path)
        }
    }

    private static func name(of session: AgentSessionInfo) -> String {
        let label = session.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "That conversation" : "“\(short(label))”"
    }

    private static func short(_ text: String) -> String {
        let clean = printable(text)
        return clean.count <= 48 ? clean : clean.prefix(45) + "…"
    }

    private func toast(_ line: String) {
        MainActor.assumeIsolated {
            Toast.shared.show(line, near: NSEvent.mouseLocation, tint: .systemOrange)
        }
    }

    // Every agent finds the id from any folder, so the default folder is a safe fallback; Codex
    // then asks which folder to use, and pi whether to fork.
    private func directory(_ path: String) -> String {
        TerminalTab.isUsableDirectory(path) ? path : Settings.shared.workingDirectory
    }

    private func reveal(_ controller: OverlayController) {
        controller.showKeepingGhost()
    }

    private func finish(_ completion: @escaping (Result<Void, TeleportError>) -> Void,
                        _ result: Result<Void, TeleportError>) {
        if Thread.isMainThread { completion(result) } else { DispatchQueue.main.async { completion(result) } }
    }

    private static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.value == 0x09 || ($0.value >= 0x20 && $0.value != 0x7f)
        }))
    }
}

private enum Safe {
    static func sessionID(_ raw: String) -> String? {
        matches(raw, #"\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z"#) ? raw : nil
    }

    // No leading `-`: it would read as an option.
    static func attachID(_ raw: String) -> String? {
        matches(raw, #"\A[A-Za-z0-9][A-Za-z0-9_-]{3,63}\z"#) ? raw : nil
    }

    static func tty(_ raw: String) -> String? {
        guard matches(raw, #"\A(/dev/)?ttys?[0-9]+\z"#) else { return nil }
        return raw.hasPrefix("/dev/") ? String(raw.dropFirst("/dev/".count)) : raw
    }

    static func appleScriptID(_ raw: String) -> String? {
        let id = raw.split(separator: ":", maxSplits: 1).last.map(String.init) ?? raw
        return matches(id, #"\A[0-9A-Fa-f-]{8,64}\z"#) ? id : nil
    }

    // `\A` and `\z`, not `^` and `$`: `$` also matches before a trailing newline.
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

private extension TeleportStatus {
    var interrupts: Bool { self == .working || self == .waiting }
}
