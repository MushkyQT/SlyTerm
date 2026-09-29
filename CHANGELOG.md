# Changelog

What changes in SlyTerm from one version to the next. Changes merged since the last release are
under Unreleased. Versions follow [semantic versioning](https://semver.org), and each one is tagged
`vX.Y.Z` on `main`; from 1.3.0 on, each is also a DMG on
[GitHub Releases](https://github.com/MushkyQT/SlyTerm/releases). The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
How each feature behaves in detail is in [docs/TECHNICAL.md](docs/TECHNICAL.md).

## [Unreleased]

### Added

- SlyTerm can be installed with Homebrew: `brew install --cask mushkyqt/tap/slyterm`. The cask
  follows each release.
  ([#11](https://github.com/MushkyQT/slyterm/pull/11))

## [1.3.0] - 2026-09-29

### Added

- SlyTerm can be downloaded from GitHub Releases as a DMG: open it and drag SlyTerm to
  Applications. The app is signed with a Developer ID and notarized by Apple, and runs on Apple
  silicon and Intel Macs with macOS 14 or later.
  ([#10](https://github.com/MushkyQT/slyterm/pull/10))
- The downloaded app checks for a new version once a day. One it finds waits as "Update to SlyTerm
  X…" at the top of the menu bar item, and nothing opens over the game until you choose it; Check
  for Updates…, next to About SlyTerm, checks at once. In Settings › General › Updates the daily
  check can be turned off, and updates can be downloaded on their own and installed when SlyTerm
  quits. A copy built from source does not update itself, and Settings says so.
  ([#10](https://github.com/MushkyQT/slyterm/pull/10))
- When Screen Recording was granted after SlyTerm opened, Settings › Lookup and the setup assistant
  say it needs a reopen and offer a Reopen SlyTerm button.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- The first three times the overlay switches to click-through by itself because another app took
  the keyboard, an orange note by the tab strip says that click-through is on and which shortcut
  brings the focus back to SlyTerm. In click-through with nothing else to report, the
  strip reads "click-through".
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- The menu bar item has Shortcuts…, which opens Settings on its Shortcuts tab, Help, which opens
  the README's shortcut list, and About SlyTerm, which shows the version.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- Settings has a Web tab: the search address, pausing videos, the opacity of a playing video, a
  page zoom slider for every web tab and where guides open.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- Settings › General sets how long a finished card stays, up to 300 seconds, and Settings ›
  Terminal how many lines of scrollback a new tab keeps, from 1,000 to 100,000.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- A tab's right-click menu has Close Tab.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- On a Mac with a trackpad, the setup assistant's Shortcuts step sets what the trackpad tap does
  and with how many fingers, says when a tap is recognised and what it will do, and warns when
  macOS opens Look up on the same three-finger tap, with a button to Trackpad Settings. While the
  assistant is open a tap does nothing else. Its last step lists the tap next to the hotkey with
  the same action.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))

### Changed

- The first time the downloaded app replaces a copy you built, macOS asks again for Screen
  Recording, and for control of iTerm2, Terminal or Ghostty the next time a session is brought in
  from one or sent back to it, since the app is signed differently. Updates keep both.
  ([#10](https://github.com/MushkyQT/slyterm/pull/10))
- The setup assistant calls the permission Screen Recording, as System Settings does, and says
  that SlyTerm needs to be reopened after it is allowed.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- The setup assistant's last step says that clicking into the game switches to click-through by
  itself, and names the click-through shortcut as the way back to the terminal.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- A floating web window's toolbar shows the mode, as the strip does: a green dot in interact mode,
  an orange dot on the strip's click-through colour in click-through. A click on its address field
  in click-through says which shortcut to press to type there.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- The lookup's message names the site that answered ("Guide: Dragon scimitar · OSRS Wiki") and,
  when nothing matched, the game it asked, in its own colour so a wrong game stands out. Pick
  mode's hint names the site it looks things up on.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- Tab names stay readable on a narrow strip: the expand button makes way when tabs would be under
  40 pt, a tab too narrow for its × plus three letters of its name has no ×, and a tab where an
  ellipsis would leave one or two letters shows the first three letters of its name. The tooltip
  has the full name.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- The activity card's title is larger, and the toasts that say why an answer key did nothing stay
  3.5 seconds.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- Settings › General is grouped as Launch, Agents and Quitting, and Settings › Shortcuts lists the
  main keys inside SlyTerm. The window levels in Settings › Window read "Above other windows",
  "Above the menu bar" and "Above everything, for games that cover the terminal"; the stored
  values are unchanged.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))

### Fixed

- Quitting during the first-run setup assistant, as macOS offers to after Screen Recording is
  allowed, no longer skips it: SlyTerm reopens it at the next launch on the same step, with the
  games already chosen.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- In Settings › Shortcuts, each shortcut's name and Clear button sit level with its field.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))
- macOS's Screen Recording prompt, asked for from the setup assistant, is no longer hidden behind
  the assistant.
  ([#9](https://github.com/MushkyQT/slyterm/pull/9))

## [1.2.0] - 2026-09-28

### Added

- Send Back returns a session to the terminal it was brought in from, and Ghostty (1.3 or later)
  and WezTerm can now take sessions back, as iTerm2 and Terminal do. A tab started in SlyTerm goes
  to the terminal chosen in Settings, which can now also be Ghostty or WezTerm.
  ([#8](https://github.com/MushkyQT/slyterm/pull/8))
- While Settings or the setup assistant is open, SlyTerm shows in the Dock and in `⌘Tab`, with an
  app menu, so switching to another app no longer leaves the window out of reach behind it.
  ([#7](https://github.com/MushkyQT/slyterm/pull/7))
- Send a session back: right-click a tab and choose "Send Back to iTerm2" to stop its agent here
  and resume it in a new iTerm2 tab, or "Copy to iTerm2" for a fork. The menu bar item has "Send Tab
  Back to iTerm2", the quit dialog has "Send Back and Quit" whenever a tab runs an agent, and
  `slyterm://send-back?session=<id>` does it from a script. Settings › General › Other terminals
  chooses iTerm2 or Terminal. `--sessions … --send-back` prints what it would do.
  ([#5](https://github.com/MushkyQT/slyterm/pull/5))
- A setup assistant on the first launch of a fresh install: whether you play games with SlyTerm
  open and which presets to add, a short form for another game (a name and a wiki or site
  address, probed for its search and index), and the main shortcuts. Settings › General › Run Setup
  Assistant… opens it again. Existing installs do not see it.
  ([#4](https://github.com/MushkyQT/slyterm/pull/4))
- A Dofus Retro lookup preset, with the English 129Dofus Wiki. It sits next to Dofus 3 in a Dofus
  submenu under `+` in Settings › Lookup.
  ([#4](https://github.com/MushkyQT/slyterm/pull/4))
- Fullscreen: `⌃⌥M` fills the screen with the window that has the keyboard, the SlyTerm window with
  the tab in front or a floating web tab, opaque and in interact mode. Nothing pauses, hides or
  switches. `⌘Return` in the SlyTerm window or a floating web tab, the strip's expand button,
  "Fullscreen" in the menu bar item, `slyterm://fullscreen` and the trackpad tap toggle it too;
  click-through and hiding leave it first. The shortcut is set in Settings › Shortcuts.
  ([#2](https://github.com/MushkyQT/slyterm/pull/2))

### Changed

- The Dofus preset is now Dofus 3 in English: the Dofus Wiki for quests, items and monsters, then
  DofusDB in English for items, reading English then French text. Dofus games already stored keep
  their sources.
  ([#4](https://github.com/MushkyQT/slyterm/pull/4))
- Web tabs hide a Fandom wiki's navigation, cover image, featured video, ads and consent banner, and
  leave a dark Fandom theme as it is.
  ([#4](https://github.com/MushkyQT/slyterm/pull/4))
- Panic hides the web tabs from the tab strip, and `⌘G`, `⌥⌘1`…`⌥⌘9`, `⌘L` and "New Web Tab" do
  nothing until it ends. A guide that arrives during panic loads out of sight and is in front when
  panic ends.
  ([#2](https://github.com/MushkyQT/slyterm/pull/2))
- `⌘Return` and the strip's expand button toggle Fullscreen instead of panic. Panic stays on
  `⌃⌥P`, "Panic Mode" in the menu bar item, `slyterm://panic` and the trackpad tap.
  ([#2](https://github.com/MushkyQT/slyterm/pull/2))

### Fixed

- The quit confirmation could open behind the Settings window or the terminal and stay out of
  sight; the same went for the confirmation before interrupting an agent. Both now open in front.
  ([#7](https://github.com/MushkyQT/slyterm/pull/7))
- `⌘C`, `⌘V`, `⌘X`, `⌘A` and `⌘Z` work in the text fields of Settings and the setup assistant, and
  `⌘W` closes them.
  ([#7](https://github.com/MushkyQT/slyterm/pull/7))
- Closing a terminal tab ends its shell and whatever is running in it, as closing a terminal window
  does. They used to keep running, out of sight, until SlyTerm quit.
  ([#5](https://github.com/MushkyQT/slyterm/pull/5))
- Clicking a shortcut field in Settings › Shortcuts started recording and stopped it at once on
  macOS 26, so no new shortcut could be typed.
  ([#4](https://github.com/MushkyQT/slyterm/pull/4))

## [1.1.0] - 2026-09-28

### Added

- Coding agents other than Claude Code on the tab strip and the card. Codex, omp and pi show their
  state and a card with their text, and Gemini CLI and Qwen Code show their state from their
  terminal titles. The words name the agent, as in "Codex is working for 2m · …". There is no new
  hotkey or setting.
  ([#1](https://github.com/MushkyQT/slyterm/pull/1))
- `⌃⌥Y` and `⌃⌥N` answer Codex's prompt to run a command or edit files, with Codex's own `y` and
  `n`. Only that prompt, with its default keys, is answered; anything else waits in the terminal.
  ([#1](https://github.com/MushkyQT/slyterm/pull/1))
- Bring In a Session moves Codex, omp and pi sessions in from other terminals, and copies Codex and
  pi sessions with the original left running. A Codex running in its background server, as it
  does by default, keeps working through the move; moving another agent in the middle of a turn
  asks first. ([#1](https://github.com/MushkyQT/slyterm/pull/1))
- A program that sends a terminal notification (OSC 9 or OSC 777) marks its tab, and the card shows
  the notification's text. ([#1](https://github.com/MushkyQT/slyterm/pull/1))
- Terminals are told when they lose the keyboard, so agents that only notify an unfocused terminal
  do so while the game has the keyboard. ([#1](https://github.com/MushkyQT/slyterm/pull/1))
- For contributors: the `--activity --title` and `--activity --screen` modes, `--agent <name>`, and
  `Tools/make-agent-fixtures.swift` to check the agent readers offline.
  ([#1](https://github.com/MushkyQT/slyterm/pull/1))

### Changed

- For contributors: the activity and session types are named after agents instead of Claude
  (`ClaudeActivity` is now `AgentActivity`), and their shared file is
  `Activity/AgentActivity.swift`. ([#1](https://github.com/MushkyQT/slyterm/pull/1))

### Fixed

- `TERM_PROGRAM_VERSION` in a tab gives SlyTerm's version instead of 0.1.0.
  ([#1](https://github.com/MushkyQT/slyterm/pull/1))

## [1.0.0] - 2026-09-26

The first public release: the terminal that floats over a game with click-through and global
hotkeys, Claude Code's state on the tab strip with cards answered by `⌃⌥Y` and `⌃⌥N`, the lookup
that opens a game's wiki page for what is under the pointer, web tabs that float over the game, and
Bring In a Session for Claude Code and plain shell tabs.

[Unreleased]: https://github.com/MushkyQT/slyterm/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/MushkyQT/slyterm/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/MushkyQT/slyterm/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/MushkyQT/slyterm/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/MushkyQT/slyterm/releases/tag/v1.0.0
