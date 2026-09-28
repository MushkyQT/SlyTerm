# Changelog

What changes in SlyTerm from one version to the next. Versions follow
[semantic versioning](https://semver.org), and each one is tagged `vX.Y.Z` on `main`. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). How each feature behaves in
detail is in [docs/TECHNICAL.md](docs/TECHNICAL.md).

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

[1.1.0]: https://github.com/MushkyQT/slyterm/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/MushkyQT/slyterm/releases/tag/v1.0.0
