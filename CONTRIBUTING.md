# Contributing to SlyTerm

Thanks for helping. Bug reports, game presets, fixes and features are all welcome. This guide
covers building the app, checking a change, and sending it. How the app behaves and how it is put
together is in [docs/TECHNICAL.md](docs/TECHNICAL.md); if you are an AI coding agent, read
[AGENTS.md](AGENTS.md) as well.

## Before you start

- **Read the [principles](docs/TECHNICAL.md#principles).** SlyTerm never interacts with the game,
  reads the screen only when asked, never takes the keyboard from the game unprompted and never
  types into a conversation on a guess. A change that bends one of these will not be merged,
  however useful it is otherwise.
- **Open an issue first for anything larger than a fix.** Describe what the player would see and
  do. Agreeing on the behaviour before the code saves both of us a rewrite.
- **Keep a pull request to one topic.** A fix and an unrelated clean-up are two pull requests.

## Reporting a bug

Open an issue with the **Bug report** form. It asks for:

- your macOS version, the SlyTerm version (**About SlyTerm** in the menu bar item) or the commit
  you built (`git rev-parse --short HEAD`), and the game and its display mode (borderless
  windowed, macOS fullscreen, exclusive fullscreen) if one is involved;
- what you did, what you expected and what happened instead;
- the relevant lines of the debug log. Turn it on with
  `defaults write com.charlesmelki.slyterm debug -bool true`, reproduce the problem, and look in
  `~/Library/Logs/SlyTerm.log`. Turn it off again with `-bool false`.

For a lookup that opens the wrong page, a screenshot of the game and the output of
`SlyTerm --ocr screenshot.png --at X Y --game <game>` (see
[Command-line modes](docs/TECHNICAL.md#command-line-modes)) usually show the problem straight away.

Before you post a log or a screenshot, read it. The log holds text read off your screen, folder
paths and what your agents were asked to do; a game screenshot can hold other players' names and
chat. Remove or blur anything that is not yours to share.

A security problem goes through private reporting instead, as [SECURITY.md](SECURITY.md) says, and
a question goes to [Discussions](https://github.com/MushkyQT/slyterm/discussions).

## Building

You need macOS 14 or later and the Xcode Command Line Tools (Swift 5.9 or later). The full Xcode
app is optional.

```sh
swift build            # debug build: .build/debug/SlyTerm, enough for the command-line modes
./build.sh             # release build, wrapped into dist/SlyTerm.app
./build.sh --install   # the same, then copied to /Applications
make run               # build, quit any running SlyTerm, and launch dist/SlyTerm.app
```

Note that `make run` quits every running copy of SlyTerm, including an installed one you may be
using.

`build.sh` signs the app ad hoc, and macOS ties the Screen Recording grant to that exact
signature, so every build asks for the grant again. To keep it across builds, create a self-signed
"Code Signing" certificate in Keychain Access (Certificate Assistant › Create a Certificate) and
build with `CODESIGN_IDENTITY="its name" ./build.sh`.

A copy you build does not update itself: only a release build has the update feed. That one is
made by `./build.sh --release`, which signs with the maintainer's Developer ID, has Apple notarize
the app and packages it as a DMG, so it needs the maintainer's credentials. Releases are built and
published by the Release workflow on GitHub;
[Building and releasing](docs/TECHNICAL.md#building-and-releasing) describes both.

The dependencies are [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) and
[Sparkle](https://sparkle-project.org), which installs updates. Please open an issue before adding
another.

## Where things are

All the app's code is in `Sources/SlyTerm`, with the agent activity feature in `Activity/` and
"Bring In a Session" in `Teleport/`. [The source map](docs/TECHNICAL.md#source-map) says what each
file holds. `Tools/` has scripts run by hand (the icon, lookup test images, agent session fixtures,
the startup animation preview and the README's GIF of it) and the two a release runs (its notes
and its update feed), and `Resources/` has `Info.plist`, the entitlements and the icons.

## Checking a change

There is no unit-test target. Instead, the binary has command-line modes that run each part of the
app offscreen or read-only, and a change is checked with the ones for the area it touches, then in
the running app when it involves windows, focus or hotkeys.

1. **It builds.** `swift build` succeeds without new warnings.
2. **The offline check for the area you touched.** Each mode is described in
   [Command-line modes](docs/TECHNICAL.md#command-line-modes).

   | Area | Check |
   | --- | --- |
   | Lookup matching and ranking | `swift Tools/make-lookup-fixtures.swift <dir>` draws test screenshots and prints the `--at` coordinates for each; then `.build/debug/SlyTerm --ocr <dir>/<file>.png --at X Y --game wow`. Also `--match`, `--search` and `--lookup` |
   | Sites and indices | `--probe <search url>`, `--index`, `--search "<name>" --preset <preset>` |
   | Web tab styling, a filled video | `--guide-snapshot <url> out.png`, with `--full`, `--fill`, `--eval` or `--find` as needed |
   | A floating web tab | `--float-snapshot out.png` |
   | Protected playback and the user agent | `--drm-check` |
   | Tab strip | `--strip-snapshot out.png` |
   | Activity card | `--card-snapshot out.png` |
   | Agent status and the session file readers | `--activity`, `--activity --transcript <file>`, `--activity --title <text>`, `--activity --screen <file>`; `swift Tools/make-agent-fixtures.swift <dir>` writes files to try them on |
   | Bring In a Session | `--sessions`, `--picker-snapshot out.png` |
   | Pick mode | `--pick-snapshot shot.png X Y out.png --scale 2` |
   | Setup assistant | `--setup-snapshot out.png`, or `--step 1`…`4` for one step |
   | Startup animation | `Tools/preview-startup-animation.swift` (its header says how to run it) |

   Look at the PNGs a snapshot writes: they are the review for any drawing change. Keep test
   screenshots and PNGs out of the repository. CI builds every pull request, runs the strip,
   float, card, picker and pick mode snapshots, and attaches their PNGs to the run as `snapshots`.
   It also builds the app bundle and checks its signature. A pull request that changes how the app
   is built or released also runs the Release workflow as a dry run, signed and notarized but not
   published; from a fork it is skipped, since forks get no signing secrets.
3. **A live run** for anything that involves focus, click-through, hotkeys, the card or a picker.
   A few things make this safer:
   - The app you build shares its preferences with any copy you have installed. Back them up
     first with `defaults export com.charlesmelki.slyterm ~/slyterm-prefs.plist`, and put them
     back afterwards with `defaults delete com.charlesmelki.slyterm` followed by
     `defaults import com.charlesmelki.slyterm ~/slyterm-prefs.plist`.
   - `open slyterm://…` goes to whichever copy macOS has registered, usually the one in
     `/Applications`. To reach the build you are testing, name it:
     `open -g -a dist/SlyTerm.app "slyterm://lookup?dry=1"`.
   - Allow and refuse type into real Claude Code and Codex sessions. Test them on a scratch
     session in a scratch folder, never on a conversation you care about.
     `claude --permission-mode default` makes Claude ask before it acts, so there is a prompt to
     answer.
   - With `debug` on, the log has a line for every mode change, lookup, activity transition and
     answer, which tells you what happened when nothing visible did.
4. **Say what you checked.** The pull request template asks for what you ran and saw offline, what
   you checked in the running app, and anything you could not verify, such as a game you do not
   have.

## Code style

Match the code around you. In particular:

- **Comments only where the code cannot speak for itself.** No doc comments, no `// MARK:`, no
  narration. A comment is for what a reader could not work out from the code and might break: a
  macOS or WebKit quirk, a threading or ordering constraint, the reason behind a safety check, an
  outside format or a number that comes from outside the code. One or two short `//` lines.
- **Layout.** Four-space indentation, lines usually within 100 columns.
- **Shapes.** Stateless groups of functions are an `enum`; app-wide objects are a `final class`
  with `static let shared`. When a feature has several parts, the types they share live in one file
  (`Activity/AgentActivity.swift`, `Teleport/TeleportModel.swift`).
- **Threads.** UI on the main thread only. Anything that reads the process table, files, the
  network or runs OCR goes off it, and only its result comes back. Never block the main thread on
  an Apple event: the first one can wait for a permission dialog.
- **Outside data is untrusted.** The agents' files (Claude Code's registry and transcripts, Codex's
  rollouts, omp's and pi's sessions) and titles, web responses and imported game JSON can be
  malformed or change format. No force unwraps when parsing them, bounded reads, and a line that
  does not parse is skipped.
- **Settings.** A new preference gets a default in `Settings`'s `register(defaults:)`, is written
  through `set(_:_:)` so `Settings.didChange` fires, and appears in the right Settings pane and in
  the [preferences table](docs/TECHNICAL.md#preferences-from-the-shell). Never rename an existing
  key: scripts and stored preferences depend on it.
- **Stored games must stay readable.** A new `LookupSource.Kind` or field changes what older builds
  can decode. A change to games already stored goes through `LookupStore.migrate()`, with a new
  `lookupGamesVersion` and a backup of the old list, as DofusDB's was.
- **New entry points.** A URL route goes in `RemoteControl.swift`; a command-line mode is
  dispatched from `main.swift`. Document both in docs/TECHNICAL.md.
- **Words in the UI** are plain, short statements of what happens. Menu items that open a window
  end in "…".

## Documentation

- **README.md** is the product page. It says what a feature does for a player in a few sentences.
  No setting keys, no internals, no edge cases.
- **docs/TECHNICAL.md** is the reference: behaviour in detail, every setting, the URL scheme, the
  command-line modes, troubleshooting and the architecture.
- **CHANGELOG.md** lists what changed in each version, with a link to the pull request for each
  line. Leave out changes nobody would notice, such as a comment or a rename inside one file.

Update all three in the same pull request as the behaviour they describe.

## Commits and pull requests

- Branch from `main`.
- Write the commit subject as a plain sentence in the imperative that says what the change does,
  without a prefix or a full stop. From the history: "Keep the Bring In picker on screen, and let
  it be dragged", "Check a pid against the start time the registry records". The body, wrapped at
  about 100 columns, says what changed and why.
- Pull requests are squash-merged, so `main` stays linear with one commit per change. Your branch
  can have as many commits as you like.
- The description says what changed, how you checked it and what is still unverified. For a visual
  change, attach the snapshot PNG or a screenshot, with other players' names and chat blurred.
- A pull request that changes the app adds its lines under `## [Unreleased]` at the top of
  CHANGELOG.md, and leaves the version alone.
- A release is a pull request of its own, made by a maintainer when enough has gathered. It raises
  the version in `Resources/Info.plist` (`CFBundleShortVersionString`, and `CFBundleVersion` up
  by one) and renames `[Unreleased]` to that version with the date. The version follows
  [semantic versioning](https://semver.org), counted over everything unreleased: the patch number
  if it is only fixes, the minor number for something new, the major number for a change that
  takes something away, such as a feature, a hotkey, a URL route or a command-line mode. Its
  Release dry run has to pass before it is merged. Once it is, the Tag workflow tags `main` with
  `vX.Y.Z`, publishes the signed DMG and the update feed on GitHub Releases, and updates the
  Homebrew cask in [MushkyQT/homebrew-tap](https://github.com/MushkyQT/homebrew-tap).
- AI-assisted changes are welcome. Credit the tool with a `Co-Authored-By:` trailer, and review
  the change yourself before you open the pull request: you are its author.

## Adding a game

The quickest way to share a game is a custom one: set it up in Settings › Lookup, use **Export…**,
and attach the `.slyterm-game.json` file to a **Share a game** issue.

To make it a preset that ships with the app:

1. Add a case to `LookupPresets.Preset` in `LookupModel.swift`, with its `title` and `siteName`,
   and build the game in `LookupPresets.make(_:)`: its app's bundle identifiers, its OCR languages
   and its sources.
2. Add the game's built-in strip patterns and tooltip lines in the `LookupPresets.Preset`
   extension. Tooltip lines must only appear in tooltips, never in the game's static interface
   (see [Advanced patterns](docs/TECHNICAL.md#advanced-patterns)).
3. If a site needs its own reader stylesheet or has ad slots of its own, add it to
   `GuideContent`'s built-in styles in `GuideTab.swift`.
4. If a site is a kind SlyTerm cannot handle yet, add a `LookupSource.Kind`, its resolver in
   `LookupResolvers.swift` and its detection in `LookupProbe`.
5. Check it with `--probe`, `--index`, `--search "<name>" --preset <preset>` and
   `--guide-snapshot`, then with screenshots of the game through `--ocr --at`. Keep the
   screenshots out of the repository.
6. Add the game to the presets in docs/TECHNICAL.md and to the list in the README.

Game and site names belong to their owners. A preset only opens public pages; it must never log
in, scrape behind a login or get around a site's rate limits.

## License

SlyTerm is under the [MIT License](LICENSE), and what you contribute is released under it too.
