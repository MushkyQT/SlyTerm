# AGENTS.md

Guidance for AI coding agents working on SlyTerm. Human contributors: the same rules are explained
in [CONTRIBUTING.md](CONTRIBUTING.md).

SlyTerm is a macOS menu bar app, one Swift package (`Package.swift`, Swift 5.9, macOS 14): a
terminal that floats over games, with click-through, global hotkeys, coding agent session status and
answers (Claude Code, Codex, omp, pi, and Gemini CLI and Qwen Code from their titles), web tabs that show guides and video and can float over the game, an OCR lookup that opens a
game's wiki in one, and bringing sessions in from other terminals. Its only dependency is SwiftTerm.
Behaviour and architecture are in [docs/TECHNICAL.md](docs/TECHNICAL.md); the
[source map](docs/TECHNICAL.md#source-map) says which file holds what.

## Commands

```sh
swift build                          # the build check; binary at .build/debug/SlyTerm
./build.sh                           # release app bundle at dist/SlyTerm.app
.build/debug/SlyTerm --strip-snapshot /tmp/strip.png   # an offline check (full list below)
```

There is no test target. A change is verified with the binary's command-line modes, which run
offscreen and never type into anything:

| Area | Modes |
| --- | --- |
| Lookup | `--match <text>`, `--ocr <png> [--at X Y] [--pick] [--fast]`, `--lookup [x y]`, `--search <text>`, `--index [--refresh]`, `--probe <url>`, all with `--game <name>` or `--preset <name>` |
| Pick mode | `--pick-snapshot <png> X Y <out.png> [--scale 2]` |
| Web tabs | `--guide-snapshot <url> <out.png> [--full] [--fill] [--width N] [--height N] [--scroll N] [--eval <js>] [--find <text>]`, `--float-snapshot <out.png>`, `--drm-check` |
| Tab strip | `--strip-snapshot <out.png>` |
| Activity | `--activity [--json]`, `--activity --transcript <file.jsonl> [--status waiting]`, `--activity --title <text>`, `--activity --screen <file>`, the last three with `[--agent <name>]`, `--activity --poll [--times N]`, `--card-snapshot <out.png>`; fixtures from `swift Tools/make-agent-fixtures.swift <dir>` |
| Bring In a Session | `--sessions [--json] [--session <uuid> \| --pid <pid> \| --tty <tty>]`, `--picker-snapshot <out.png>` |

`swift Tools/make-lookup-fixtures.swift <dir>` draws synthetic game screenshots and prints the
`--at` coordinates and the expected first candidate for each. When a mode writes a PNG, open it
and look at it: for drawing changes that is the test.

CI (`.github/workflows/ci.yml`) runs `swift build`, the strip, float, card and picker snapshots,
and pick mode over every lookup fixture on each pull request, and attaches the PNGs to the run as
`snapshots`. It checks that they were written, not what they show.

## Hazards

Read these before running anything.

- **Any argument that is not one of the modes above launches the full GUI app.** There is no
  `--help`. A stray launch puts a window on the user's screen, writes preferences and
  `~/Library/Application Support/SlyTerm/`, starts a shell for every restored tab and may run the
  user's `startupCommand`, which is often `claude`. Pass only the flags listed.
- **The user's real app may be running.** Check `pgrep -xl SlyTerm` before a live launch, and do
  not quit it without asking. `make run` quits every running SlyTerm, and `./build.sh --install`
  overwrites `/Applications/SlyTerm.app`: run neither unless asked.
- **Preferences are shared.** `dist/SlyTerm.app` and its binary use the installed app's
  `com.charlesmelki.slyterm` domain; `.build/debug/SlyTerm` uses its own `SlyTerm` domain. Before a
  live run of the bundle, `defaults export` the domain to a backup, and afterwards `defaults
  delete` it and `defaults import` the backup.
- **`open slyterm://…` reaches the registered copy,** usually the installed one. Target the build
  under test with `open -g -a dist/SlyTerm.app "slyterm://…"`.
- **Agent sessions and terminal tabs you did not create are off limits.** The activity and
  teleport features read `~/.claude/sessions`, `~/.codex`, `~/.omp` and `~/.pi` and the user's
  transcripts, and allow, refuse and teleport act on real sessions. Never answer, signal, resume,
  attach to or close a session or tab that was not created for the test, and never connect to
  Codex's background server or take its locks. `--activity` and `--sessions` are read-only ways to
  look. For a live test, start a scratch `claude --permission-mode default` or `codex -s read-only`
  in a scratch folder, in a window you opened.
- **Guard anything that types.** Before an automated keystroke, confirm SlyTerm is the frontmost
  app, or the text lands in whatever the user has in front.
- **Nothing generated goes in the repository:** screenshots, fixture images, snapshot PNGs, logs.
  Game screenshots can also hold other players' names and chat. Write them to a temporary folder.
- **Network modes hit real sites** (`--search`, `--probe`, `--index --refresh`, `--guide-snapshot`).
  Keep it to a handful of requests.

## Invariants

A change that breaks one of these is wrong, whatever it fixes.

1. **No game interaction.** Never read a game's memory or network traffic, and never send it
   input: no synthetic events posted to it and no Accessibility automation of it.
2. **Screen capture only on request.** Capture happens only for the lookup hotkey or URL, through
   ScreenCaptureKit with SlyTerm's own windows excluded.
3. **The game keeps the keyboard.** Panels are non-activating. A card, an attention mark or a
   guide arriving never takes focus; a hidden overlay with news comes back in click-through.
4. **No keystroke on a guess.** `Activity/ActivityAnswer.swift` types one key (Return or Escape
   for Claude Code, `y` or `n` for Codex), only after every check passes; any doubt ends in a toast and an `answer: … ignored` log line.
   `activityCards` off disables the card, both hotkeys and both URLs. `activityAnswerURLs` stays
   off by default, since any local process, an agent included, can open a URL.
5. **Main thread for UI only.** Process-table reads, file reads, OCR and network run off it.
   Apple events go through the teleport engine's own queue, because the first one can block on a
   permission dialog.
6. **Outside data is untrusted.** The agents' registries, transcripts, titles and screens are
   undocumented formats that change between releases: bounded reads, no force unwraps, and a line that does not parse is
   skipped. The same goes for web responses and imported game JSON.
7. **Stored data stays compatible.** Never rename a preference key (`hotkeyQuest` and
   `questOpenInApp` keep their old names on purpose). A change to stored games goes through
   `LookupStore.migrate()` with a new `lookupGamesVersion` and a backup of the old list.

## Conventions

- **Match the surrounding code.** Four-space indentation, lines usually within 100 columns.
  Stateless groups are an `enum`, app-wide objects a `final class` with `static let shared`, and a
  multi-part feature declares its shared types in one contract file
  (`Activity/AgentActivity.swift`, `Teleport/TeleportModel.swift`).
- **Comments only where the code cannot speak for itself.** No doc comments, no `// MARK:`, no
  narration, nothing aimed at users. Write a comment only for what a reader could not work out from
  the code and might break: a macOS or WebKit quirk, a threading or ordering constraint, the reason
  behind a safety check, an outside format, a number that comes from outside the code. One or two
  short `//` lines.
- **Keep diffs small.** Do not reformat or rename code you are not changing, and do not add a
  dependency.
- **New entry points are wired in three places.** A setting: a default in `Settings`'s
  `register(defaults:)`, a control in `SettingsWindow.swift` if it has one, and a row in the
  [preferences table](docs/TECHNICAL.md#preferences-from-the-shell). A URL route:
  `RemoteControl.swift` and [the URL list](docs/TECHNICAL.md#url-scheme). A command-line mode:
  `main.swift` and [the modes list](docs/TECHNICAL.md#command-line-modes).
- **Two kinds of documentation.** README.md is the product page: what a feature does for a player,
  in a few plain sentences, with no setting keys or internals. docs/TECHNICAL.md holds everything
  else. Update both in the same change as the behaviour.
- **Versions.** A pull request that changes the app adds its lines under `## [Unreleased]` in
  [CHANGELOG.md](CHANGELOG.md) and leaves the version alone. A release is its own change: it
  raises the semantic version in `Resources/Info.plist` (patch if only fixes are unreleased, minor
  for something new, major for something taken away; `CFBundleVersion` up by one) and renames
  `[Unreleased]` to that version with the date. The Tag workflow tags `main` with `vX.Y.Z` once
  the release is merged. Release only when asked.
- **Plain words.** UI strings and docs are short statements of what happens, with no marketing
  tone, rhetorical questions or punchlines.
- **Commits.** The subject is a plain imperative sentence saying what the change does, with no
  prefix and no full stop ("Look an app's icon up once"). The body says what and why. End it with a
  `Co-Authored-By:` trailer naming the agent. Pull requests are squash-merged; `main` stays linear.
  Commit, push or open a pull request only when asked.

## Done means

- `swift build` passes.
- The modes for the area you touched have been run and their output read, PNGs included.
- README.md and docs/TECHNICAL.md describe the new behaviour, and CHANGELOG.md has its lines
  under `[Unreleased]`.
- Your summary or pull request lists what was verified offline, what was verified in the running
  app, and what was not verified at all. Hotkeys, focus, click-through and window placement can
  only be verified in the running app; if you could not run it, say so.
