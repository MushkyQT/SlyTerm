import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift Tools/make-agent-fixtures.swift <out dir>\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let cwd = "/Users/you/Projects/demo"

struct Fixture {
    let file: String
    let mode: String
    let expected: [String]
}

var made: [Fixture] = []

func json(_ value: Any) -> String {
    let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
    let data = (try? JSONSerialization.data(withJSONObject: value, options: options)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

// Keys in the order the agents write them: readers look for `"type":…` near the start of a line.
func record(_ pairs: [(String, Any)]) -> String {
    "{" + pairs.map { "\(json($0.0)):\(json($0.1))" }.joined(separator: ",") + "}"
}

func write(_ name: String, _ lines: [String], mode: String, expected: [String]) {
    let text = lines.joined(separator: "\n") + "\n"
    try? text.write(to: outDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    made.append(Fixture(file: name, mode: mode, expected: expected))
}

// Codex rollouts: `{"timestamp","type","payload"}` per line, `session_meta` first.

func time(_ minute: Int, _ second: Double) -> String {
    String(format: "2026-09-28T10:%02d:%06.3fZ", minute, second)
}

func codex(_ at: String, _ type: String, _ payload: [(String, Any)]) -> String {
    "{\"timestamp\":\(json(at)),\"type\":\(json(type)),\"payload\":\(record(payload))}"
}

func meta(_ id: String, history: String = "paginated") -> String {
    let instructions = String(repeating: "You are Codex, a coding agent. Follow the instructions. ", count: 300)
    return codex(time(0, 0), "session_meta", [
        ("session_id", id), ("id", id), ("timestamp", time(0, 0)), ("cwd", cwd), ("originator", "codex-tui"),
        ("cli_version", "0.158.0"), ("source", "cli"), ("thread_source", "user"), ("model_provider", "openai"),
        ("base_instructions", ["text": instructions]), ("history_mode", history),
    ])
}

func started(_ at: String, _ turn: String) -> String {
    codex(at, "event_msg", [("type", "task_started"), ("turn_id", turn), ("started_at", 1_790_589_600)])
}

func complete(_ at: String, _ turn: String, _ message: String?, ms: Int) -> String {
    codex(at, "event_msg", [("type", "task_complete"), ("turn_id", turn), ("last_agent_message", message ?? NSNull()),
                            ("duration_ms", ms)])
}

func developer(_ at: String) -> String {
    codex(at, "response_item", [("type", "message"), ("role", "developer"),
                                ("content", [["type": "input_text", "text": "<permissions instructions>"]])])
}

func userItem(_ at: String, _ text: String) -> [String] {
    let environment = "<environment_context>\n  <cwd>\(cwd)</cwd>\n</environment_context>"
    let item: [String: Any] = ["type": "UserMessage", "id": "item-user", "content": [["type": "text", "text": text]]]
    return [codex(at, "response_item", [("type", "message"), ("role", "user"),
                                        ("content", [["type": "input_text", "text": environment]])]),
            codex(at, "response_item", [("type", "message"), ("role", "user"),
                                        ("content", [["type": "input_text", "text": text]])]),
            codex(at, "event_msg", [("type", "item_completed"), ("item", item)])]
}

func agentItem(_ at: String, _ text: String, phase: String) -> [String] {
    [codex(at, "event_msg", [("type", "item_completed"),
                             ("item", ["type": "AgentMessage", "id": "item-agent", "phase": phase,
                                       "content": [["type": "Text", "text": text]]])]),
     codex(at, "response_item", [("type", "message"), ("role", "assistant"), ("phase", phase),
                                 ("content", [["type": "output_text", "text": text]])])]
}

func exec(_ at: String, _ call: String, _ js: String) -> String {
    codex(at, "response_item", [("type", "custom_tool_call"), ("status", "completed"), ("call_id", call),
                                ("name", "exec"), ("input", js)])
}

func output(_ at: String, _ call: String, _ text: String) -> String {
    codex(at, "response_item", [("type", "custom_tool_call_output"), ("call_id", call), ("output", text)])
}

let turnOne = "00000000-0000-7000-8000-0000000000a1"
let turnTwo = "00000000-0000-7000-8000-0000000000a2"

let doneID = "00000000-0000-7000-8000-00000000c0d1"
write("codex-done.jsonl", [meta(doneID), started(time(1, 0), turnOne), developer(time(1, 0.1))]
    + userItem(time(1, 0.2), "Run the unit tests and tell me if they pass.")
    + agentItem(time(1, 2), "Running the unit tests.", phase: "commentary")
    + [exec(time(1, 3), "call_a1", #"const r = await tools.exec_command({cmd:"npm test",yield_time_ms:10000});"#),
       output(time(1, 40), "call_a1", "Script completed\nOutput:\n42 passing")]
    + agentItem(time(1, 41), "All **42** tests pass.", phase: "final_answer")
    + [complete(time(1, 41.5), turnOne, "All **42** tests pass.", ms: 41_500)],
    mode: "--activity --transcript", expected: [
        "status idle since 10:01:41, pending -, request -, turn 42s",
        "message \"All 42 tests pass.\"; thread \"Run unit tests\" (renamed in session_index.jsonl)",
    ])

// The earlier turn's reply is more than 64 KB from the end, so the reader looks deeper for it.
let pendingID = "00000000-0000-7000-8000-00000000c0d2"
write("codex-pending-exec.jsonl", [meta(pendingID), started(time(2, 0), turnOne)]
    + userItem(time(2, 0.2), "Find the TODOs.")
    + [exec(time(2, 1), "call_b1", #"const r = await tools.exec_command({cmd:"ls src"});"#),
       output(time(2, 2), "call_b1", String(repeating: "src/file.swift\n", count: 6000))]
    + agentItem(time(2, 3), "There are 12 TODOs.", phase: "final_answer")
    + [complete(time(2, 3.5), turnOne, "There are 12 TODOs.", ms: 3500), started(time(3, 0), turnTwo)]
    + userItem(time(3, 0.2), "Search for FIXME too, outside the sandbox.")
    + [exec(time(3, 1), "call_b2", #"const r = await tools.exec_command({cmd:"cat notes.txt"});"#),
       output(time(3, 1.5), "call_b2", String(repeating: "note line\n", count: 7000)),
       exec(time(3, 2), "call_b3", #"const r = await tools.exec_command({cmd:"grep -rn \"TODO\\|FIXME\" src","#
            + #"sandbox_permissions:"require_escalated",justification:"Search every file"}); text(r.output);"#)],
    mode: "--activity --transcript", expected: [
        "status working since 10:03:00, pending exec_command, label grep -rn \"TODO\\|FIXME\" src",
        "request permission(exec) run `grep -rn \"TODO\\|FIXME\" src`, detail the same command",
        "message \"There are 12 TODOs.\" (from the deep read), turn 4s",
    ])

let abortedID = "00000000-0000-7000-8000-00000000c0d3"
write("codex-aborted.jsonl", [meta(abortedID), started(time(4, 0), turnOne)]
    + userItem(time(4, 0.2), "Say hi.")
    + agentItem(time(4, 1), "hi", phase: "final_answer")
    + [complete(time(4, 1.2), turnOne, "hi", ms: 1200), started(time(5, 0), turnTwo)]
    + userItem(time(5, 0.2), "Delete the build folder.")
    + [exec(time(5, 1), "call_c1",
            #"const r = await tools.exec_command({cmd:"rm -rf build",sandbox_permissions:"require_escalated"});"#),
       output(time(5, 4), "call_c1", "aborted by user after 2.7s"),
       codex(time(5, 4.1), "event_msg", [("type", "turn_aborted"), ("turn_id", turnTwo), ("reason", "interrupted"),
                                         ("duration_ms", 4100)])],
    mode: "--activity --transcript", expected: [
        "status idle since 10:05:04, pending -, request -",
        "message \"hi\", turn 1s (the aborted turn has no reply of its own)",
    ])

// Legacy threads: `user_message` / `agent_message` events and JSON `function_call` arguments.
let legacyID = "00000000-0000-7000-8000-00000000c0d4"
write("codex-legacy.jsonl", [meta(legacyID, history: "legacy"), started(time(6, 0), turnOne),
    codex(time(6, 0.2), "event_msg", [("type", "user_message"), ("message", "List the files.")]),
    codex(time(6, 1), "response_item", [("type", "function_call"), ("name", "shell"), ("call_id", "call_d1"),
                                        ("arguments", json(["command": ["bash", "-lc", "ls"]]))]),
    codex(time(6, 2), "response_item", [("type", "function_call_output"), ("call_id", "call_d1"),
                                        ("output", "README.md\nsrc")]),
    codex(time(6, 3), "event_msg", [("type", "agent_message"), ("message", "Two entries: README.md and src.")]),
    complete(time(6, 3.2), turnOne, nil, ms: 3200), started(time(7, 0), turnTwo),
    codex(time(7, 0.2), "event_msg", [("type", "user_message"), ("message", "Update the plan, then build.")]),
    codex(time(7, 1), "response_item", [("type", "function_call"), ("name", "update_plan"), ("call_id", "call_d2"),
                                        ("arguments", json(["plan": [["step": "build", "status": "pending"]]]))]),
    codex(time(7, 2), "response_item", [("type", "function_call"), ("name", "shell_command"), ("call_id", "call_d3"),
                                        ("arguments", json(["command": "swift build -c release"]))])],
    mode: "--activity --transcript", expected: [
        "status working since 10:07:00, pending exec_command, label swift build -c release",
        "request unknown (two calls pending), message \"Two entries: README.md and src.\", turn 3s",
        "prompt \"List the files.\"",
    ])

let patchID = "00000000-0000-7000-8000-00000000c0d5"
write("codex-pending-patch.jsonl", [meta(patchID), started(time(8, 0), turnOne)]
    + userItem(time(8, 0.2), "Fix the typo in the README.")
    + [exec(time(8, 1), "call_e1", #"const r = await tools.apply_patch("*** Begin Patch\n"#
            + #"*** Update File: docs/README.md\n@@\n-teh\n+the\n*** End Patch"); text(r);"#)],
    mode: "--activity --transcript", expected: [
        "status working since 10:08:00, pending apply_patch, label editing README.md, request unknown",
        "message -, turn -",
    ])

let index = [
    record([("id", doneID), ("thread_name", "Run tests"), ("updated_at", time(1, 1))]),
    record([("id", pendingID), ("thread_name", "Find TODOs"), ("updated_at", time(2, 1))]),
    record([("id", doneID), ("thread_name", "Run unit tests"), ("updated_at", time(1, 2))]),
]
try? (index.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("session_index.jsonl"),
                                                  atomically: true, encoding: .utf8)

// pi and omp sessions: a header, then entries with `id`, `parentId` and `timestamp`; omp puts a
// 256-byte title slot before the header.

func titleSlot(_ title: String) -> String {
    let bare = record([("type", "title"), ("v", 1), ("title", title), ("source", "auto"), ("updatedAt", time(0, 0)),
                       ("pad", "")])
    let pad = max(0, 255 - bare.utf8.count)
    return record([("type", "title"), ("v", 1), ("title", title), ("source", "auto"), ("updatedAt", time(0, 0)),
                   ("pad", String(repeating: " ", count: pad))])
}

func header(_ id: String, _ at: String) -> String {
    record([("type", "session"), ("version", 3), ("id", id), ("timestamp", at), ("cwd", cwd)])
}

var entry = 0
func message(_ at: String, _ message: [String: Any]) -> String {
    entry += 1
    return record([("type", "message"), ("id", String(format: "e%07d", entry)),
                   ("parentId", String(format: "e%07d", entry - 1)), ("timestamp", at), ("message", message)])
}

func user(_ at: String, _ text: String, synthetic: Bool = false) -> String {
    var body: [String: Any] = ["role": "user", "content": [["type": "text", "text": text]]]
    if synthetic { body["synthetic"] = true }
    return message(at, body)
}

func assistant(_ at: String, text: String? = nil, calls: [[String: Any]] = [], stop: String) -> String {
    var blocks: [[String: Any]] = []
    if let text { blocks.append(["type": "text", "text": text]) }
    blocks += calls.map { ["type": "toolCall"].merging($0) { $1 } }
    return message(at, ["role": "assistant", "content": blocks, "stopReason": stop])
}

func result(_ at: String, _ call: String, _ tool: String, _ text: String) -> String {
    message(at, ["role": "toolResult", "toolCallId": call, "toolName": tool,
                 "content": [["type": "text", "text": text]]])
}

func info(_ at: String, _ name: String) -> String {
    record([("type", "session_info"), ("id", "i-\(name.count)"), ("parentId", NSNull()), ("timestamp", at),
            ("name", name)])
}

let piDone = "00000000-0000-7000-8000-0000000000e1"
let countFiles = ["command": "find . -name '*.swift' | wc -l"]
write("pi-done.jsonl", [header(piDone, time(10, 0)), info(time(10, 0.1), "Old name"),
    user(time(10, 1), "How many Swift files are there?"),
    assistant(time(10, 3), calls: [["id": "tc1", "name": "bash", "arguments": countFiles]], stop: "toolUse"),
    result(time(10, 4), "tc1", "bash", "37"),
    assistant(time(10, 6), text: "There are **37** Swift files.", stop: "stop"),
    info(time(10, 7), "Count Swift files")],
    mode: "--activity --transcript", expected: [
        "status idle since 10:10:06, pending -, request -, ended no",
        "message \"There are 37 Swift files.\", turn 5s, title \"Count Swift files\"",
    ])

let piWorking = "00000000-0000-7000-8000-0000000000e2"
write("pi-working-bash.jsonl", [header(piWorking, time(11, 0)),
    user(time(11, 1), "Build it."),
    assistant(time(11, 2), text: "Building.",
              calls: [["id": "tc2", "name": "read", "arguments": ["path": "Package.swift"]]], stop: "toolUse"),
    result(time(11, 3), "tc2", "read", "// swift-tools-version:5.9"),
    assistant(time(11, 5), calls: [["id": "tc3", "name": "bash", "arguments": ["command": "swift build\n  -c release"]]],
              stop: "toolUse")],
    mode: "--activity --transcript", expected: [
        "status working since 10:11:01 (the prompt), pending bash, label swift build -c release",
        "request -, message -, turn -",
    ])

let ompAsk = "00000000-0000-7000-8000-0000000000e3"
write("omp-waiting-ask.jsonl", [titleSlot("Pick a database"), header(ompAsk, time(12, 0)),
    user(time(12, 1), "Set up the database. Ask me which one first."),
    assistant(time(12, 3), calls: [["id": "tc4", "name": "ask", "intent": "Asking which database",
                                    "arguments": ["questions": [[
                                        "id": "db", "question": "Which database?",
                                        "options": [["label": "SQLite"], ["label": "Postgres"]],
                                    ]]]]],
              stop: "toolUse")],
    mode: "--activity --transcript", expected: [
        "status waiting since 10:12:03, pending ask, label Asking which database",
        "request question Which database? options SQLite | Postgres, title \"Pick a database\"",
    ])

let ompEnded = "00000000-0000-7000-8000-0000000000e4"
write("omp-ended.jsonl", [titleSlot("Say hello"), header(ompEnded, time(13, 0)),
    user(time(13, 0.5), "Plan mode is on.", synthetic: true),
    user(time(13, 1), "Say hello."),
    assistant(time(13, 2.5), text: "Hello!", stop: "stop"),
    record([("type", "custom"), ("customType", "session_exit"), ("data", ["reason": "dispose", "kind": "normal"]),
            ("id", "x1"), ("parentId", NSNull()), ("timestamp", time(13, 9))])],
    mode: "--activity --transcript", expected: [
        "status idle since 10:13:02, ended yes, message \"Hello!\", turn 2s (1.5 s)",
        "prompt \"Say hello.\" (the synthetic one is skipped)",
    ])

// Titles, one per line, as the agents set them.

func titles(_ name: String, _ rows: [(String, String)]) {
    try? (rows.map(\.0).joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent(name),
                                                             atomically: true, encoding: .utf8)
    made.append(Fixture(file: name, mode: "--activity --title <line> --agent " + name.dropFirst(7).dropLast(4),
                        expected: rows.map { "\"\($0.0.trimmingCharacters(in: .whitespaces))\" → \($0.1)" }))
}

func padded(_ title: String) -> String {
    title.padding(toLength: 80, withPad: " ", startingAt: 0)
}

titles("titles-codex.txt", [
    ("⠹ Fix the login test | demo", "working marked \"Fix the login test | demo\""),
    ("⠧ ⠧ | demo", "working marked \"demo\""),
    ("⠋ demo", "working marked \"demo\""),
    ("[ ! ] Action Required | Fix the login test | demo", "waiting marked \"Fix the login test | demo\""),
    ("[ . ] Action Required | Fix the login test | demo", "waiting marked \"Fix the login test | demo\""),
    ("Fix the login test | demo", "idle unmarked \"Fix the login test | demo\""),
    ("", "idle unmarked \"\""),
])
titles("titles-omp.txt", [
    ("π ⠹ Fix the login test", "working marked \"Fix the login test\""),
    ("π ◑ Fix the login test", "working marked \"Fix the login test\""),
    ("π ! Fix the login test", "waiting marked \"Fix the login test\""),
    ("π > demo", "idle marked \"demo\""),
    ("π >", "idle marked \"\""),
    ("π: demo", "- (titles turned off)"),
])
titles("titles-gemini.txt", [
    (padded("✦  Working… (demo)"), "working marked \"demo\""),
    (padded("✦  Reading the login handler (demo)"), "working marked \"demo\""),
    (padded("⏲  Working… (demo)"), "working marked \"demo\""),
    (padded("✋  Action Required (demo)"), "waiting marked \"demo\""),
    (padded("◇  Ready (demo)"), "idle marked \"demo\""),
    (padded("Gemini CLI (demo)"), "- (dynamic title off)"),
])
titles("titles-qwen.txt", [
    (padded("◐\u{FE0E} Fix the login test"), "working marked \"Fix the login test\""),
    (padded("✳\u{FE0E} Fix the login test"), "waiting marked \"Fix the login test\""),
    (padded("Qwen - demo"), "idle unmarked \"Qwen - demo\""),
])

// Screens, 100 columns: Codex's overlay is inset two columns each side and wraps like ratatui,
// breaking a word that does not fit the pane at its edge.

func wrap(_ text: String, width: Int) -> [String] {
    var rows: [String] = []
    var current = ""
    for var word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
        let candidate = current.isEmpty ? word : current + " " + word
        if candidate.count <= width {
            current = candidate
            continue
        }
        if !current.isEmpty { rows.append(current) }
        while word.count > width {
            rows.append(String(word.prefix(width)))
            word = String(word.dropFirst(width))
        }
        current = word
    }
    if !current.isEmpty { rows.append(current) }
    return rows
}

func pane(_ text: String) -> [String] {
    text.isEmpty ? [""] : wrap(text, width: 96).map { "  " + $0 }
}

let asked = "Run the end-to-end tests for the checkout flow, then summarise the failures and suggest the "
    + "smallest fix that would make them pass again."
let history = wrap(asked, width: 98).enumerated().map { ($0.offset == 0 ? "› " : "  ") + $0.element }
    + ["", "• Running the Playwright suite for the checkout flow.", ""]

func screen(_ name: String, title: String, _ rows: [String], expected: String) {
    let text = (["# title: '\(title)'"] + rows).joined(separator: "\n") + "\n"
    try? text.write(to: outDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    let agent = name.hasPrefix("screen-omp") ? "omp" : "codex"
    made.append(Fixture(file: name, mode: "--activity --screen --agent \(agent)", expected: [expected]))
}

let execOptions = [
    "", "",
    "› 1. Yes, proceed (y)",
    "  2. Yes, and don't ask again for commands that start with `npm run test:e2e` (p)",
    "  3. No, and tell Codex what to do differently (esc)",
    "",
    "  Press enter to confirm or esc to cancel",
]
let command = "npm run test:e2e -- --project=chromium --grep checkout-flow --reporter=line --retries=2 --workers=4 "
    + "--output=\(cwd)/test-results/checkout"

screen("screen-codex-exec-wrapped.txt", title: "[ ! ] Action Required | Run e2e tests | demo",
       history + pane("Would you like to run the following command?") + [""] + pane("Environment: local") + [""]
       + pane("Reason: Playwright needs to start a browser, which the sandbox blocks, so run the suite "
              + "outside of it this once.")
       + [""] + pane("$ " + command) + execOptions,
       expected: "permission(exec) run `npm run test:e2e -- --project=chromium --grep checkout-flow…`, detail the "
           + "command with a line break after --retries=2 (a word wrap, not joined)")

var remapped = execOptions
remapped[2] = "› 1. Yes, proceed (ctrl-y)"
screen("screen-codex-exec-remapped.txt", title: "[ ! ] Action Required | Run e2e tests | demo",
       history + pane("Would you like to run the following command?") + [""] + pane("$ npm test") + remapped,
       expected: "unknown (the approve key is not y)")

let longPath = "\(cwd)/packages/checkout/src/components/payment/providers/stripe/StripePaymentElementWrapper.tsx"
screen("screen-codex-patch-wrapped.txt", title: "[ ! ] Action Required | Fix payment form | demo",
       history + pane("Would you like to make the following edits?") + [""]
       + pane("Description: Apply proposed file edits") + pane("Destination: " + longPath)
       + pane("Destination: \(cwd)/packages/checkout/src/index.ts") + [
           "", "",
           "› 1. Yes, proceed (y)",
           "  2. Yes, and don't ask again for these files (a)",
           "  3. No, and tell Codex what to do differently (esc)",
           "",
           "  Press enter to confirm or esc to cancel",
       ],
       expected: "permission(apply_patch) edit StripePaymentElementWrapper.tsx, index.ts, detail the two full paths")

screen("screen-codex-network.txt", title: "[ ! ] Action Required | Install deps | demo",
       history + pane("Do you want to approve network access to \"registry.npmjs.org\"?") + [""]
       + pane("Reason: npm install needs the registry") + [
           "", "",
           "› 1. Yes, just this once (y)",
           "  2. Yes, and allow this host for this conversation (a)",
           "  3. Yes, and allow this host in the future (p)",
           "  4. No, and tell Codex what to do differently (esc)",
           "",
           "  Press enter to confirm or esc to cancel",
       ],
       expected: "unknown")

screen("screen-codex-question.txt", title: "[ ! ] Action Required | Set up database | demo",
       history + [
           "",
           "  Question 1/2 (2 unanswered)",
           "  Which database should the demo use?",
           "",
           "  › 1. SQLite    Simple local file.",
           "    2. Postgres  Matches production.",
           "",
           "  tab to add notes | enter to submit answer | ←/→ to navigate questions | esc to interrupt",
       ],
       expected: "unknown")

screen("screen-codex-idle.txt", title: "Run e2e tests | demo",
       history + [
           "• Would you like to run the following command? was the question; the suite passed.",
           "",
           "› Ask Codex to do anything",
           "",
           "  gpt-5 default · \(cwd)",
           "  ← for agents · ? for shortcuts",
       ],
       expected: "- (no prompt)")

screen("screen-omp-approval.txt", title: "π ! Clean the build",
       [" Remove the build output.", "",
        "╭─ Allow tool: bash " + String(repeating: "─", count: 79) + "╮",
        "│ Command: rm -rf dist" + String(repeating: " ", count: 77) + "│",
        "├" + String(repeating: "─", count: 98) + "┤",
        "│ → Approve" + String(repeating: " ", count: 88) + "│",
        "│   Deny" + String(repeating: " ", count: 91) + "│",
        "╰" + String(repeating: "─", count: 98) + "╯"],
       expected: "unknown")

for fixture in made {
    print(outDir.appendingPathComponent(fixture.file).path)
    print("    \(fixture.mode)")
    for line in fixture.expected { print("        expected: \(line)") }
}
