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
            Settings.log("teleport move: \(session.agent.name) sessions cannot be resumed, "
                         + "nothing done")
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
                let failure = TeleportError.couldNotStop(pid: session.pid, agent: session.agent)
                self.finish(completion, .failure(failure))
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
            Settings.log("teleport copy: \(session.agent.name) sessions cannot be copied, "
                         + "nothing done")
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
        guard session.agent == .claude,
              let attachID = session.attachID.flatMap(Safe.attachID) else {
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
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            if Self.hasExited(pid) { timer.invalidate(); done(true); return }
            if Date() >= deadline { timer.invalidate(); done(false) }
        }
        timer.tolerance = 0.02
        // `.common`: while a quit waits on a send-back, the run loop is in a modal mode.
        RunLoop.main.add(timer, forMode: .common)
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

    private func confirmInterrupt(_ session: AgentSessionInfo, sendingBack: Bool = false) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let name = session.agent.name
        let alert = NSAlert()
        alert.messageText = session.status == .working ? "\(name) is working in that tab"
            : "\(name) is waiting for your answer in that tab"
        alert.informativeText = (sendingBack ? "Sending it back" : "Moving it")
            + " now interrupts the current turn; what \(name) has said so far is kept."
        if session.agent == .claude {
            alert.informativeText += sendingBack
                ? " To send it without interrupting, type /bg in that tab first."
                : " To move it without interrupting, type /bg in that tab first and attach it here instead."
        }
        alert.addButton(withTitle: sendingBack ? "Send Back" : "Move")
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

    private func run(appleScript source: String, what: String, host: TeleportHost,
                     then done: ((Bool) -> Void)? = nil) {
        appleScript.async { [weak self] in
            var error: NSDictionary?
            let script = NSAppleScript(source: source)
            _ = script?.executeAndReturnError(&error)
            guard script != nil, let error else {
                DispatchQueue.main.async { done?(script != nil) }
                return
            }
            let code = error[NSAppleScript.errorNumber] as? Int
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            DispatchQueue.main.async {
                Settings.log("teleport: \(what) failed (\(code.map(String.init) ?? "?")): \(message)")
                done?(false)
                guard code == Self.notPermitted, let self, !self.toldAboutAutomation else { return }
                self.toldAboutAutomation = true
                Toast.shared.show("Allow SlyTerm to control \(host.displayName) in " +
                                  "System Settings › Privacy & Security › Automation",
                                  near: NSEvent.mouseLocation, tint: .systemOrange)
            }
        }
    }

    // Main thread. `done` gets the tabs that stayed here, and why.
    func sendBack(_ tabs: [TerminalTab], copy: Bool, confirm: Bool,
                  done: @escaping ([(tab: TerminalTab, error: TeleportError)]) -> Void) {
        guard let controller else {
            Settings.log("send back: asked for before the overlay exists")
            done(tabs.map { ($0, .noController) })
            return
        }
        var stayed: [(tab: TerminalTab, error: TeleportError)] = []
        let tabs = tabs.filter { tab in
            guard controller.terminals.contains(where: { $0 === tab }) else { return false }
            guard inFlight.insert("tab:" + tab.id.uuidString).inserted else {
                stayed.append((tab, .alreadySending))
                return false
            }
            return true
        }
        // Always later, never from inside this call: a quit replies to AppKit from `done`, and a
        // reply before `.terminateLater` is returned is lost.
        let finish: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                tabs.forEach { self?.inFlight.remove("tab:" + $0.id.uuidString) }
                done(stayed)
            }
        }
        guard !tabs.isEmpty else { finish(); return }
        let terminal = SendBackTerminal.current
        // Main thread: ptsname returns a shared static buffer.
        let probes = Dictionary(tabs.compactMap { tab in
            tab.ttyName.map { (tab.id, TabProbe(tty: $0, foregroundGroup: tab.foregroundProcessGroup,
                                                titles: tab.titleStates, screen: nil)) }
        }, uniquingKeysWith: { first, _ in first })
        DispatchQueue.global(qos: .userInitiated).async {
            let hosted = SessionDiscovery.hostedSessions(tabs: probes)
            DispatchQueue.main.async {
                var plans: [(TerminalTab, SendBackPlan, pid_t?)] = []
                for tab in tabs {
                    let found = hosted[tab.id]
                    // Without its session the plan would be a folder, and the agent would be left
                    // running here, or killed by the quit.
                    if found == nil, Self.sendsBackAgent(tab) {
                        Settings.log("send back: tab \(tab.id.uuidString)'s agent was not found, stays")
                        stayed.append((tab, .notFound("That session")))
                        continue
                    }
                    var session = found?.session
                    if let status = tab.activity?.status { session?.status = status }
                    switch Self.sendBackPlan(session: session, folder: tab.currentDirectory,
                                             busy: tab.isRunningForegroundJob, copy: copy) {
                    case .success(let plan): plans.append((tab, plan, found?.processGroup))
                    case .failure(let error):
                        Settings.log("send back: tab \(tab.id.uuidString) stays: \(error.message)")
                        stayed.append((tab, error))
                    }
                }
                if confirm, Settings.shared.teleportConfirmBusy {
                    plans.removeAll { tab, plan, _ in
                        guard case .resume(let session, _, _) = plan, session.status.interrupts,
                              !session.turnsRunElsewhere,
                              !self.confirmInterrupt(session, sendingBack: true) else { return false }
                        stayed.append((tab, .declined))
                        return true
                    }
                }
                guard !plans.isEmpty else { finish(); return }
                // Asked before anything is stopped: this is also what brings up the Automation
                // prompt the first time.
                self.run(appleScript: "tell application \"\(terminal.name)\" to count windows",
                         what: "reaching \(terminal.name)", host: terminal.host) { reached in
                    guard reached else {
                        stayed += plans.map { ($0.0, .couldNotOpen(terminal.name)) }
                        finish()
                        return
                    }
                    let group = DispatchGroup()
                    for (tab, plan, processGroup) in plans {
                        group.enter()
                        self.carry(plan, from: tab, processGroup: processGroup, to: terminal,
                                   controller: controller) { error in
                            if let error { stayed.append((tab, error)) }
                            group.leave()
                        }
                    }
                    group.notify(queue: .main, execute: finish)
                }
            }
        }
    }

    func sendBack(_ tab: TerminalTab, copy: Bool = false) {
        let terminal = SendBackTerminal.current
        sendBack([tab], copy: copy, confirm: true) { stayed in
            MainActor.assumeIsolated {
                if let error = stayed.first?.error {
                    Toast.shared.show(error.message, near: NSEvent.mouseLocation, tint: .systemOrange)
                } else {
                    Toast.shared.show((copy ? "Copied to " : "Sent to ") + terminal.name,
                                      near: NSEvent.mouseLocation)
                }
            }
        }
    }

    // A tab counts when its agent can be resumed elsewhere; the quit alert offers it.
    static func sendsBackAgent(_ tab: TerminalTab) -> Bool {
        guard let activity = tab.activity else { return false }
        if activity.agent == .claude, activity.isBackground { return true }
        return Safe.sessionID(activity.sessionID)
            .flatMap { activity.agent.resumeCommand(id: $0) } != nil
    }

    static func sendBackPlan(session: AgentSessionInfo?, folder: String, busy: Bool,
                             copy: Bool) -> Result<SendBackPlan, TeleportError> {
        guard let session else {
            return .success(.folder(line: sendBackLine(nil, in: folder), closesTab: !copy && !busy))
        }
        let folder = TerminalTab.isUsableDirectory(session.cwd) ? session.cwd : folder
        if session.agent == .claude, session.isBackground {
            guard !copy else { return .failure(.cannotCopy(session.agent)) }
            guard let job = session.attachID.flatMap(Safe.attachID) else { return .failure(.noAttachID) }
            let command = "claude attach \(job)"
            return .success(.attach(line: sendBackLine(command, in: folder), command: command,
                                    folder: folder))
        }
        guard let id = Safe.sessionID(session.sessionID) else {
            return .failure(.cannotSendBack(session.agent))
        }
        if copy {
            guard let command = session.agent.copyCommand(id: id) else {
                return .failure(.cannotCopy(session.agent))
            }
            return .success(.fork(line: sendBackLine(command, in: folder)))
        }
        guard let command = session.agent.resumeCommand(id: id) else {
            return .failure(.cannotSendBack(session.agent))
        }
        return .success(.resume(session, line: sendBackLine(command, in: folder), command: command))
    }

    // The folder comes from another process's registry or cwd: quoted for the shell, and left
    // out if it holds anything that could end the line. `;`, not `&&`: the other terminal may not
    // be allowed into the folder, and every agent finds its session from anywhere.
    static func sendBackLine(_ command: String?, in folder: String) -> String {
        let cd = folder.hasPrefix("/") && printable(folder) == folder && !folder.contains("\t")
            ? "cd '" + folder.replacingOccurrences(of: "'", with: #"'\''"#) + "'" : nil
        return [cd, command].compactMap { $0 }.joined(separator: "; ")
    }

    static func openScript(typing line: String, in terminal: SendBackTerminal) -> String {
        let text = "\"" + line.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        switch terminal {
        case .iTerm2:
            return """
            tell application "iTerm2"
                set w to current window
                if w is missing value then
                    set s to current session of (create window with default profile)
                else
                    tell w to set s to current session of (create tab with default profile)
                end if
                tell s to write text \(text)
            end tell
            """
        case .terminal:
            return "tell application \"Terminal\" to do script \(text)"
        }
    }

    private func carry(_ plan: SendBackPlan, from tab: TerminalTab, processGroup: pid_t?,
                       to terminal: SendBackTerminal, controller: OverlayController,
                       done: @escaping (TeleportError?) -> Void) {
        func open(_ line: String, then opened: @escaping (Bool) -> Void) {
            run(appleScript: Self.openScript(typing: line, in: terminal),
                what: "opening a tab in \(terminal.name)", host: terminal.host, then: opened)
        }
        switch plan {
        case .resume(let session, let line, let command):
            DispatchQueue.global(qos: .userInitiated).async {
                let running = SessionDiscovery.isRunning(session)
                DispatchQueue.main.async {
                    guard running else {
                        Settings.log("send back: \(Self.name(of: session)) (pid \(session.pid)) is gone")
                        done(.notFound(Self.name(of: session)))
                        return
                    }
                    self.resume(session, line: line, command: command, from: tab,
                                processGroup: processGroup, to: terminal, controller: controller,
                                open: open, done: done)
                }
            }
        case .fork(let line):
            open(line) { opened in
                Settings.log("send back: " + (opened ? "copied tab \(tab.id.uuidString) to \(terminal.name)"
                                                     : "\(terminal.name) did not open the copy"))
                done(opened ? nil : .couldNotOpen(terminal.name))
            }
        case .attach(let line, let command, let folder):
            // Detached first, so the session never has two clients at once.
            controller.close(tab, replacementRunsStartup: false)
            open(line) { opened in
                guard opened else {
                    Settings.log("send back: \(terminal.name) did not open a tab, attaching here again")
                    controller.newTab(directory: self.directory(folder), typing: command, run: true)
                    done(.couldNotOpen(terminal.name))
                    return
                }
                Settings.log("send back: attached in \(terminal.name)")
                done(nil)
            }
        case .folder(let line, let closesTab):
            open(line) { opened in
                guard opened else { done(.couldNotOpen(terminal.name)); return }
                Settings.log("send back: opened \(tab.currentDirectory) in \(terminal.name)"
                             + (closesTab ? "" : ", tab kept for what it is running"))
                if closesTab { controller.close(tab, replacementRunsStartup: false) }
                done(nil)
            }
        }
    }

    private func resume(_ session: AgentSessionInfo, line: String, command: String, from tab: TerminalTab,
                        processGroup: pid_t?, to terminal: SendBackTerminal, controller: OverlayController,
                        open: @escaping (String, @escaping (Bool) -> Void) -> Void,
                        done: @escaping (TeleportError?) -> Void) {
        Settings.log("send back: stopping \(Self.name(of: session)) (pid \(session.pid)) "
                     + "in tab \(tab.id.uuidString)")
        stopHere(session, in: tab, processGroup: processGroup) { stopped in
            guard stopped else {
                Settings.log("send back: pid \(session.pid) would not stop, left here")
                done(.couldNotStopHere(pid: session.pid, agent: session.agent))
                return
            }
            open(line) { opened in
                guard opened else {
                    Settings.log("send back: \(terminal.name) did not open a tab, resuming here again")
                    // Only at the tab's own prompt: after `claude && …` something else is in front.
                    if controller.terminals.contains(where: { $0 === tab }), !tab.isRunningForegroundJob {
                        tab.type(command, enter: true)
                    } else {
                        controller.newTab(directory: self.directory(session.cwd), typing: command, run: true)
                    }
                    done(.couldNotOpen(terminal.name))
                    return
                }
                Settings.log("send back: \(Self.name(of: session)) resumed in \(terminal.name)")
                controller.close(tab, replacementRunsStartup: false)
                done(nil)
            }
        }
    }

    // Ctrl-C goes into SlyTerm's own pty, and only while the agent is still in front of it.
    private func stopHere(_ session: AgentSessionInfo, in tab: TerminalTab, processGroup: pid_t?,
                          then done: @escaping (Bool) -> Void) {
        kill(session.pid, SIGTERM)
        waitForExit(of: session.pid, upTo: Self.sigtermGrace) { [weak self, weak tab] gone in
            guard let self else { done(false); return }
            if gone { done(true); return }
            let inFront = { tab.map { $0.foregroundProcessGroup == processGroup } ?? false }
            guard session.agent == .claude, processGroup != nil, inFront(), let tab else {
                done(false)
                return
            }
            Settings.log("send back: pid \(session.pid) survived SIGTERM, sending Ctrl-C twice")
            tab.send(raw: "\u{3}")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if inFront() { tab.send(raw: "\u{3}") }
                self.waitForExit(of: session.pid, upTo: Self.interruptGrace, then: done)
            }
        }
    }

    func handleSendBack(_ url: URL) {
        guard let controller else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            let raw = items.first { $0.name.lowercased() == name }?.value?.trimmingCharacters(in: .whitespaces)
            return (raw?.isEmpty ?? true) ? nil : raw
        }
        let copy = value("mode")?.lowercased() == "copy"
        let tab: TerminalTab?
        if let named = value("tab") {
            tab = UUID(uuidString: named).flatMap { id in controller.terminals.first { $0.id == id } }
                ?? Int(named).flatMap { n in controller.terminals.indices.contains(n - 1) ? controller.terminals[n - 1] : nil }
        } else if let id = value("session").flatMap(Safe.sessionID) {
            tab = controller.terminals.first {
                $0.activity?.sessionID.caseInsensitiveCompare(id) == .orderedSame
            }
        } else {
            Settings.log("send back: no tab or session named, nothing done")
            toast("Name a tab or a session to send back")
            return
        }
        guard let tab else {
            Settings.log("send back: no tab of ours matches \(url.query ?? "")")
            toast("No SlyTerm tab matches that")
            return
        }
        sendBack(tab, copy: copy)
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
        case .session(let id):
            return SessionDiscovery.agentSession(id: id).map(TeleportCandidate.agent)
        case .pid(let pid):
            return SessionDiscovery.agentSession(pid: pid).map(TeleportCandidate.agent)
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
