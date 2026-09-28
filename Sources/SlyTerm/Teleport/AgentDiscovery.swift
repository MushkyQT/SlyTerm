import Foundation

// Codex, omp, pi, Gemini CLI and Qwen Code TUIs in front on a terminal, and the session file each
// one writes. Blocking syscalls and file reads: call off the main thread.
enum AgentDiscovery {
    typealias Entry = SessionDiscovery.ProcessTable.Entry
    typealias Arguments = SessionDiscovery.ProcessArguments

    struct TUI {
        var process: Entry
        var agent: AgentKind
        var arguments: Arguments?
        // After the executable, or after the script for a node or bun launch.
        var words: [String]
        var tty: String

        var environment: [String: String] { arguments?.environment ?? [:] }
    }

    struct SessionFile: Equatable {
        var url: URL
        var runsElsewhere: Bool
    }

    struct Head: Equatable {
        var id: String
        var cwd: String
        var startedAt: Date?
        var title: String?
        var firstPrompt: String?
    }

    // One per poller, so a quiet poll opens no file: heads never change, and the rest is kept
    // until its size or mtime moves.
    final class Cache {
        fileprivate var heads: [String: (stamp: Stamp?, head: Head?)] = [:]
        fileprivate var resumed: [String: URL?] = [:]
        fileprivate var texts: [String: (stamp: Stamp, lines: [String])] = [:]
        fileprivate var listings: [String: (stamp: Stamp, names: [String])] = [:]
        fileprivate var threadNames: [String: (stamp: Stamp, names: [String: String])] = [:]
        private var used: Set<String> = []

        fileprivate func touch(_ key: String) { used.insert(key) }

        func prune() {
            heads = heads.filter { used.contains($0.key) }
            resumed = resumed.filter { used.contains($0.key) }
            texts = texts.filter { used.contains($0.key) }
            listings = listings.filter { used.contains($0.key) }
            threadNames = threadNames.filter { used.contains($0.key) }
            used = []
        }
    }

    private static let natives: [String: AgentKind] = [
        "codex": .codex, "omp": .omp, "pi": .pi, "gemini": .gemini, "qwen": .qwen,
    ]

    private static let interpreters: Set<String> = ["node", "bun"]

    // npm installs, by the package in the script's path when the bin link's name is not there.
    // omp's package name contains pi's, so it comes first.
    private static let packages: [(marker: String, agent: AgentKind)] = [
        ("/@openai/codex/", .codex), ("/@oh-my-pi/pi-coding-agent/", .omp), ("/pi-coding-agent/", .pi),
        ("/@google/gemini-cli/", .gemini), ("/@qwen-code/qwen-code/", .qwen),
    ]

    private static let interpreterValueFlags: Set<String> = ["-r", "--require", "--import", "--loader",
                                                             "--experimental-loader"]

    // Codex 0.158's subcommands that are not a conversation's TUI (`resume` and `fork` are).
    private static let codexCommands: Set<String> = [
        "exec", "e", "review", "login", "logout", "mcp", "mcp-server", "plugin", "app-server",
        "remote-control", "app", "completion", "update", "doctor", "sandbox", "debug", "execpolicy",
        "apply", "a", "agents", "queue", "archive", "delete", "unarchive", "migrate-rollouts", "cloud",
        "cloud-tasks", "responses-api-proxy", "stdio-to-uds", "exec-server", "tcp-tunnel", "features",
        "help",
    ]

    private static let codexValueFlags: Set<String> = [
        "-c", "--config", "-i", "--image", "-m", "--model", "--local-provider", "-p", "--profile",
        "-s", "--sandbox", "-a", "--ask-for-approval", "-C", "--cd", "--add-dir", "--enable",
        "--disable", "--remote", "--remote-auth-token-env",
    ]

    static func kind(of process: Entry, arguments: Arguments?) -> AgentKind? {
        identify(process, arguments: arguments)?.agent
    }

    private static func identify(_ process: Entry,
                                 arguments: Arguments?) -> (agent: AgentKind, words: [String])? {
        let words = arguments?.arguments ?? []
        let agent: AgentKind
        let own: ArraySlice<String>
        if let native = natives[process.command] {
            agent = native
            own = words.dropFirst()
        } else if interpreters.contains(process.command), let found = launched(words) {
            agent = found.agent
            own = words.dropFirst(found.index + 1)
        } else {
            return nil
        }
        return isTUI(agent, own) ? (agent, Array(own)) : nil
    }

    // `node [flags] <script>` or `bun [run] <script>`. pi sets `process.title`, which on macOS
    // overwrites argv in place: argv[0] becomes "pi" and the rest is blanked.
    private static func launched(_ words: [String]) -> (agent: AgentKind, index: Int)? {
        if let first = words.first, let agent = natives[first] { return (agent, 0) }
        var index = 1
        while index < words.count {
            let word = words[index]
            if word == "run", index == 1 {
                index += 1
                continue
            }
            guard word.hasPrefix("-") else { return script(word).map { ($0, index) } }
            index += interpreterValueFlags.contains(word) ? 2 : 1
        }
        return nil
    }

    private static func script(_ path: String) -> AgentKind? {
        if let package = packages.first(where: { path.contains($0.marker) }) { return package.agent }
        let name = (path as NSString).lastPathComponent
        return natives[name] ?? natives[(name as NSString).deletingPathExtension]
    }

    private static func isTUI(_ agent: AgentKind, _ words: ArraySlice<String>) -> Bool {
        guard agent == .codex, let command = codexPositionals(words).first else { return true }
        return !codexCommands.contains(command)
    }

    private static func codexPositionals(_ words: ArraySlice<String>) -> [String] {
        var found: [String] = []
        var skip = false
        for word in words {
            if skip {
                skip = false
            } else if word.hasPrefix("-") {
                skip = codexValueFlags.contains(word)
            } else {
                found.append(word)
            }
        }
        return found
    }

    // A TUI is the job in front on its tty. One per process group: the outermost agent in it,
    // except npm's Codex, a `node codex.js` whose native child is the one holding the files.
    static func tuis(in table: SessionDiscovery.ProcessTable, on ttys: Set<String>? = nil,
                     inspect: (pid_t) -> Arguments?) -> [TUI] {
        let user = getuid()
        var groups: [pid_t: [TUI]] = [:]
        for process in table.entries where process.uid == user && process.pgid > 0 && process.pgid == process.tpgid {
            guard natives[process.command] != nil || interpreters.contains(process.command),
                  let tty = SessionDiscovery.ttyName(process.tdev), ttys?.contains(tty) ?? true else { continue }
            let arguments = inspect(process.pid)
            guard let found = identify(process, arguments: arguments) else { continue }
            let tui = TUI(process: process, agent: found.agent, arguments: arguments, words: found.words, tty: tty)
            groups[process.pgid, default: []].append(tui)
        }
        return groups.values.compactMap { members in
            let pids = Set(members.map(\.process.pid))
            guard let outer = members.filter({ !pids.contains($0.process.ppid) })
                .min(by: { $0.process.pid < $1.process.pid }) else { return nil }
            guard outer.agent == .codex, outer.process.command != "codex" else { return outer }
            return members.first {
                $0.process.command == "codex" && $0.agent == .codex && $0.process.ppid == outer.process.pid
            } ?? outer
        }
    }

    // `titleNames`: tty → the Codex thread name its title shows.
    static func sessionFiles(for tuis: [TUI],
                             titleNames: [String: String] = [:],
                             in table: SessionDiscovery.ProcessTable,
                             inspect: (pid_t) -> Arguments?,
                             cache: Cache) -> [pid_t: SessionFile] {
        var files: [pid_t: SessionFile] = [:]
        var guessed: [pid_t: SessionFile] = [:]
        let servers = tuis.contains { $0.agent == .codex } ? codexServers(in: table, inspect: inspect) : []
        let piFolders = tuis.filter { $0.agent == .pi }
            .map { SessionDiscovery.workingDirectory(of: $0.process.pid).map(realPath) }
        for tui in tuis {
            let cwd = SessionDiscovery.workingDirectory(of: tui.process.pid)
            switch tui.agent {
            case .codex:
                guard let found = codexRollout(for: tui, cwd: cwd, titleName: titleNames[tui.tty],
                                               servers: servers, cache: cache) else { continue }
                if found.guessed {
                    guessed[tui.process.pid] = found.file
                } else {
                    files[tui.process.pid] = found.file
                }
            case .omp:
                files[tui.process.pid] = ompSession(for: tui, cwd: cwd, cache: cache)
                    .map { SessionFile(url: $0, runsElsewhere: false) }
            case .pi:
                let alone = cwd.map { folder in piFolders.filter { $0 == realPath(folder) }.count == 1 } ?? false
                files[tui.process.pid] = piSession(for: tui, cwd: cwd, alone: alone, cache: cache)
                    .map { SessionFile(url: $0, runsElsewhere: false) }
            case .claude, .gemini, .qwen:
                continue
            }
        }
        // Two TUIs in one folder that were both open when a thread began cannot tell whose it is.
        let certain = Set(files.values.map(\.url))
        for (url, claims) in Dictionary(grouping: guessed, by: { $0.value.url }) where !certain.contains(url) {
            if claims.count == 1, let claim = claims.first { files[claim.key] = claim.value }
        }
        return files
    }

    static func head(of url: URL, agent: AgentKind, cache: Cache) -> Head? {
        let path = url.path
        cache.touch(path)
        if let known = cache.heads[path]?.head { return known }
        let now = stamp(path)
        if let known = cache.heads[path], known.stamp == now { return nil }
        let head: Head?
        switch agent {
        case .codex:
            head = CodexRollout.head(url).map {
                Head(id: $0.id, cwd: $0.cwd, startedAt: $0.startedAt, title: nil, firstPrompt: $0.firstPrompt)
            }
        case .omp, .pi:
            head = PiSession.head(url).map {
                Head(id: $0.id, cwd: $0.cwd, startedAt: $0.startedAt, title: $0.title, firstPrompt: $0.firstPrompt)
            }
        case .claude, .gemini, .qwen:
            head = nil
        }
        cache.heads[path] = (now, head)
        return head
    }

    // The id the file name carries, for a head that cannot be read: Codex's `rollout-<time>-<uuid>`,
    // pi's and omp's `<time>_<uuid>`.
    static func fileID(of url: URL, agent: AgentKind) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        switch agent {
        case .codex:
            guard stem.count > 36, UUID(uuidString: String(stem.suffix(36))) != nil else { return nil }
            return String(stem.suffix(36))
        case .omp, .pi:
            guard let bar = stem.lastIndex(of: "_") else { return nil }
            let id = stem[stem.index(after: bar)...]
            return id.isEmpty ? nil : String(id)
        case .claude, .gemini, .qwen:
            return nil
        }
    }

    static func codexHome(_ environment: [String: String]) -> URL {
        if let custom = nonEmpty(environment["CODEX_HOME"]) {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static func threadNames(in home: URL, cache: Cache) -> [String: String] {
        let path = home.appendingPathComponent("session_index.jsonl").path
        cache.touch(path)
        guard let now = stamp(path) else { return [:] }
        if let known = cache.threadNames[path], known.stamp == now { return known.names }
        let names = CodexRollout.threadNames(in: home)
        cache.threadNames[path] = (now, names)
        return names
    }

    // Codex's title is "<activity> <thread> | <project>" by default: the thread is before the last bar.
    static func threadName(inTitle name: String?) -> String? {
        guard let name, let bar = name.range(of: " | ", options: .backwards) else { return nil }
        let thread = name[..<bar.lowerBound].trimmingCharacters(in: .whitespaces)
        return thread.isEmpty ? nil : thread
    }

    // Codex since 0.157 runs turns in a machine-wide `codex app-server`: the TUI is then a client
    // holding no rollout, and the server holds every loaded thread's. `guessed`: matched by folder.
    private static func codexRollout(for tui: TUI, cwd: String?, titleName: String?, servers: [Server],
                                     cache: Cache) -> (file: SessionFile, guessed: Bool)? {
        let home = codexHome(tui.environment)
        let sessions = realPath(home.appendingPathComponent("sessions").path) + "/"
        let own = openFiles(of: tui.process.pid)
        let held = own.paths.filter { isRollout($0, under: sessions) }
        if let path = newest(held) {
            return (SessionFile(url: URL(fileURLWithPath: path), runsElsewhere: false), false)
        }
        let connected = servers.filter { !$0.listening.isDisjoint(with: own.peers) }
        let positionals = codexPositionals(tui.words[...])
        if positionals.first == "resume", positionals.count > 1, UUID(uuidString: positionals[1]) != nil,
           let url = rollout(id: positionals[1].lowercased(), under: sessions, cache: cache) {
            return (SessionFile(url: url, runsElsewhere: !connected.isEmpty), false)
        }
        guard !connected.isEmpty, let cwd, let started = SessionDiscovery.startTime(of: tui.process.pid) else {
            return nil
        }
        let folder = realPath(codexFolder(tui.words, cwd: cwd) ?? cwd)
        // Only a thread begun since the TUI started: the server also holds other TUIs' threads, and
        // keeps a thread loaded for a minute after its TUI quits. One resumed from a picker is missed.
        var candidates: [String] = []
        for server in connected {
            for path in server.paths where isRollout(path, under: server.sessions) && !candidates.contains(path) {
                guard (stamp(path)?.modified ?? .distantPast) >= started,
                      let head = head(of: URL(fileURLWithPath: path), agent: .codex, cache: cache),
                      (head.startedAt ?? .distantPast) >= started, realPath(head.cwd) == folder else { continue }
                candidates.append(path)
            }
        }
        if candidates.count > 1, let titleName {
            let names = threadNames(in: home, cache: cache)
            let named = candidates.filter { path in
                let url = URL(fileURLWithPath: path)
                let id = head(of: url, agent: .codex, cache: cache)?.id ?? fileID(of: url, agent: .codex)
                return id.flatMap { names[$0] } == titleName
            }
            if !named.isEmpty { candidates = named }
        }
        guard candidates.count == 1, let path = candidates.first else { return nil }
        return (SessionFile(url: URL(fileURLWithPath: path), runsElsewhere: true), true)
    }

    private static func isRollout(_ path: String, under sessions: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.hasPrefix(sessions) && name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    private static func newest(_ paths: [String]) -> String? {
        guard paths.count > 1 else { return paths.first }
        return paths.max { (stamp($0)?.modified ?? .distantPast) < (stamp($1)?.modified ?? .distantPast) }
    }

    private static func codexFolder(_ words: [String], cwd: String) -> String? {
        var folder: String?
        for (index, word) in words.enumerated() {
            if (word == "-C" || word == "--cd"), index + 1 < words.count {
                folder = words[index + 1]
            } else if word.hasPrefix("--cd=") {
                folder = String(word.dropFirst("--cd=".count))
            }
        }
        guard let folder else { return nil }
        let expanded = (folder as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
    }

    // Rollouts sit in sessions/YYYY/MM/DD: newest days first, a bounded walk, kept per id.
    private static func rollout(id: String, under sessions: String, cache: Cache) -> URL? {
        let key = sessions + id
        cache.touch(key)
        if let known = cache.resumed[key] { return known }
        let manager = FileManager.default
        func children(_ path: String) -> [String] {
            ((try? manager.contentsOfDirectory(atPath: path)) ?? []).sorted(by: >).map { path + "/" + $0 }
        }
        var found: URL?
        var days = 0
        search: for year in children(String(sessions.dropLast())) {
            for month in children(year) {
                for day in children(month) {
                    days += 1
                    guard days <= rolloutDaysSearched else { break search }
                    let names = (try? manager.contentsOfDirectory(atPath: day)) ?? []
                    let suffix = "-\(id).jsonl"
                    if let name = names.first(where: { $0.hasPrefix("rollout-") && $0.hasSuffix(suffix) }) {
                        found = URL(fileURLWithPath: day + "/" + name)
                        break search
                    }
                }
            }
        }
        cache.resumed[key] = .some(found)
        return found
    }

    private static let rolloutDaysSearched = 730

    private struct Server {
        var sessions: String
        var paths: [String]
        var listening: Set<String>
    }

    // The TUI talks to its server over a unix socket: a server is this TUI's when one of the
    // TUI's sockets is connected to a path the server has bound.
    private static func codexServers(in table: SessionDiscovery.ProcessTable,
                                     inspect: (pid_t) -> Arguments?) -> [Server] {
        let user = getuid()
        var servers: [Server] = []
        for process in table.entries where process.uid == user && process.command == "codex" {
            guard let arguments = inspect(process.pid),
                  codexPositionals(arguments.arguments.dropFirst()).first == "app-server" else { continue }
            let open = openFiles(of: process.pid)
            guard !open.bound.isEmpty else { continue }
            let home = codexHome(arguments.environment)
            servers.append(Server(sessions: realPath(home.appendingPathComponent("sessions").path) + "/",
                                  paths: open.paths,
                                  listening: open.bound))
        }
        return servers
    }

    private static func ompSession(for tui: TUI, cwd: String?, cache: Cache) -> URL? {
        guard let cwd else { return nil }
        let crumb = ompStateDirectory(tui.environment, cwd: cwd)
            .appendingPathComponent("terminal-sessions/\(tui.tty)").path
        // Written at start, resume and switch, never removed: only the omp in front makes it current.
        guard let lines = lines(of: crumb, cache: cache), lines.count >= 2, !lines[1].isEmpty,
              !lines.dropFirst(2).contains("fresh"), realPath(lines[0]) == realPath(cwd) else { return nil }
        let file = lines[1].hasPrefix("/") ? lines[1] : (lines[0] as NSString).appendingPathComponent(lines[1])
        return stamp(file) == nil ? nil : URL(fileURLWithPath: file)
    }

    // omp's utils/src/dirs.ts: PI_CONFIG_DIR, OMP_PROFILE (else PI_PROFILE), PI_CODING_AGENT_DIR
    // for the default profile, then $XDG_STATE_HOME/omp when that folder exists.
    private static func ompStateDirectory(_ environment: [String: String], cwd: String) -> URL {
        let profile = nonEmpty(environment["OMP_PROFILE"] ?? environment["PI_PROFILE"])
        var root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(nonEmpty(environment["PI_CONFIG_DIR"]) ?? ".omp")
        if let profile { root = root.appendingPathComponent("profiles/\(profile)") }
        if profile == nil, let custom = nonEmpty(environment["PI_CODING_AGENT_DIR"]) {
            let expanded = (custom as NSString).expandingTildeInPath
            let agent = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
            if agent != root.appendingPathComponent("agent").path { return URL(fileURLWithPath: agent) }
        }
        if let state = nonEmpty(environment["XDG_STATE_HOME"]) {
            var app = URL(fileURLWithPath: state).appendingPathComponent("omp")
            if let profile { app = app.appendingPathComponent("profiles/\(profile)") }
            if stamp(app.path)?.isDirectory == true { return app }
        }
        return root.appendingPathComponent("agent")
    }

    // Under node, pi's `process.title` blanks these flags: the folder's newest file is the fallback.
    private static func piSession(for tui: TUI, cwd: String?, alone: Bool, cache: Cache) -> URL? {
        guard let cwd else { return nil }
        let environment = tui.environment
        let words = tui.words
        func value(_ flag: String) -> String? {
            guard let index = words.firstIndex(of: flag), index + 1 < words.count else { return nil }
            return nonEmpty(words[index + 1])
        }
        if words.contains("--no-session") { return nil }
        let folder = piFolder(environment, sessionDir: value("--session-dir"), cwd: cwd)
        if let session = value("--session") {
            if session.contains("/") || session.hasSuffix(".jsonl") {
                let expanded = (session as NSString).expandingTildeInPath
                let path = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
                if stamp(path) != nil { return URL(fileURLWithPath: path) }
            } else if let path = piFile(in: folder, id: session, cache: cache) {
                return URL(fileURLWithPath: path)
            }
        }
        if let id = value("--session-id"), let path = piFile(in: folder, id: id, cache: cache) {
            return URL(fileURLWithPath: path)
        }
        guard alone, let started = SessionDiscovery.startTime(of: tui.process.pid) else { return nil }
        let recent = listing(of: folder, cache: cache).filter { $0.hasSuffix(".jsonl") }.prefix(piFilesChecked)
        let written = recent.compactMap { name -> (path: String, modified: Date)? in
            let path = folder + "/" + name
            guard let modified = stamp(path)?.modified, modified >= started else { return nil }
            return (path, modified)
        }
        return written.max { $0.modified < $1.modified }.map { URL(fileURLWithPath: $0.path) }
    }

    // Names start with the creation time, so the newest sort first; `--continue` picks one of those.
    private static let piFilesChecked = 64

    // pi's session-manager.ts: `--<cwd without its leading slash, / \ : as ->--`.
    private static func piFolder(_ environment: [String: String], sessionDir: String?, cwd: String) -> String {
        if let custom = sessionDir ?? nonEmpty(environment["PI_CODING_AGENT_SESSION_DIR"]) {
            let expanded = (custom as NSString).expandingTildeInPath
            return expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        }
        let agent = nonEmpty(environment["PI_CODING_AGENT_DIR"]).map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent").path
        let trimmed = cwd.hasPrefix("/") ? String(cwd.dropFirst()) : cwd
        let slug = String(trimmed.map { "/\\:".contains($0) ? "-" : $0 })
        return agent + "/sessions/--\(slug)--"
    }

    // pi takes an id prefix; only an unambiguous match counts.
    private static func piFile(in folder: String, id: String, cache: Cache) -> String? {
        let matches = listing(of: folder, cache: cache).filter { name in
            guard name.hasSuffix(".jsonl"), let bar = name.lastIndex(of: "_") else { return false }
            return name[name.index(after: bar)...].hasPrefix(id)
        }
        guard matches.count == 1, let name = matches.first else { return nil }
        return folder + "/" + name
    }

    private static func lines(of path: String, cache: Cache) -> [String]? {
        cache.touch(path)
        guard let now = stamp(path) else { return nil }
        if let known = cache.texts[path], known.stamp == now { return known.lines }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: textLimit)) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        cache.texts[path] = (now, lines)
        return lines
    }

    private static let textLimit = 16 * 1024

    private static func listing(of folder: String, cache: Cache) -> [String] {
        cache.touch(folder)
        guard let now = stamp(folder) else { return [] }
        if let known = cache.listings[folder], known.stamp == now { return known.names }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted(by: >)
        cache.listings[folder] = (now, names)
        return names
    }

    fileprivate struct Stamp: Equatable {
        var size: Int64
        var modified: Date
        var isDirectory: Bool
    }

    fileprivate static func stamp(_ path: String) -> Stamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return Stamp(size: Int64(info.st_size), modified: modified, isDirectory: info.st_mode & S_IFMT == S_IFDIR)
    }

    private struct OpenFiles {
        var paths: [String] = []
        var bound: Set<String> = []
        var peers: Set<String> = []
    }

    private static let descriptorLimit = 8192

    // What `lsof -p` shows, from the kernel: nothing is opened or connected to.
    private static func openFiles(of pid: pid_t) -> OpenFiles {
        var open = OpenFiles()
        let stride = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return open }
        let count = min(Int(bytes) / stride + 32, descriptorLimit)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let filled = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return open }
        for descriptor in descriptors.prefix(Int(filled) / stride) {
            if descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                    continue
                }
                let path = withUnsafePointer(to: &info.pvip.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                if !path.isEmpty { open.paths.append(path) }
            } else if descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                      info.psi.soi_family == AF_UNIX else { continue }
                var local = info.psi.soi_proto.pri_un.unsi_addr.ua_sun
                var peer = info.psi.soi_proto.pri_un.unsi_caddr.ua_sun
                if let path = socketPath(&local) { open.bound.insert(path) }
                if let path = socketPath(&peer) { open.peers.insert(path) }
            }
        }
        return open
    }

    // `sun_path` need not end in a NUL when the path fills it.
    private static func socketPath(_ address: inout sockaddr_un) -> String? {
        let bytes = withUnsafeBytes(of: &address.sun_path) { Array($0) }
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return end == 0 ? nil : String(decoding: bytes[..<end], as: UTF8.self)
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
