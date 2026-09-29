<p align="center">
  <img src="docs/startup-animation.gif" width="480"
       alt="The SlyTerm logo, a terminal window with a smirk, draws itself in, winks and switches off like an old screen">
</p>

<h1 align="center">SlyTerm</h1>

<p align="center">
  <b>A macOS terminal that floats over your game.</b><br>
  Keep Claude Code or Codex running on top of the game, click straight through the terminal to
  play, and answer your agent with a hotkey when it needs you.
</p>

<p align="center">
  <a href="https://github.com/MushkyQT/SlyTerm/releases/latest/download/SlyTerm.dmg"><img
    src="https://img.shields.io/github/v/release/MushkyQT/SlyTerm?style=for-the-badge&logo=apple&logoColor=white&label=Download%20for%20macOS&labelColor=238636&color=2ea44f"
    height="44" alt="Download SlyTerm for macOS"></a>
</p>

<p align="center">
  or with Homebrew: <code>brew install --cask mushkyqt/tap/slyterm</code><br>
  <sub>macOS 14 or later · Apple silicon and Intel · Signed and notarized · Free and open source</sub>
</p>

<p align="center">
  <a href="https://github.com/MushkyQT/SlyTerm/releases"><img
    src="https://img.shields.io/github/downloads/MushkyQT/SlyTerm/total?label=downloads"
    alt="Downloads"></a>
  <a href="https://github.com/MushkyQT/homebrew-tap"><img
    src="https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2FMushkyQT%2Fhomebrew-tap%2Fmain%2FCasks%2Fslyterm.rb&search=version%20%22(%5B%5E%22%5D%2B)%22&replace=%241&label=homebrew%20tap"
    alt="Homebrew tap version"></a>
  <a href="https://github.com/MushkyQT/SlyTerm/actions/workflows/ci.yml"><img
    src="https://img.shields.io/github/actions/workflow/status/MushkyQT/SlyTerm/ci.yml?branch=main&label=CI"
    alt="CI status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/MushkyQT/SlyTerm" alt="MIT License"></a>
</p>

https://github.com/user-attachments/assets/b203d4ae-e3b4-426d-8685-bfc97ce9af88

SlyTerm is an always-on-top terminal overlay for macOS, made for playing while a coding agent works.
Type a prompt, click back into the game, and your clicks pass through the terminal to the game while
the output keeps coming. When the agent finishes or asks for permission, a card tells you, and
`⌃⌥Y` or `⌃⌥N` answers it without leaving the game. It also looks up whatever is under your pointer
on the game's wiki, and plays guides and videos in tabs you can float over the game.

## Features

### Stays on top, lets your clicks through

SlyTerm sits above the game, in borderless windowed mode or macOS fullscreen, as see-through as you
like. Click into the game and it dims and switches to click-through by itself: every click, scroll
and key goes to the game underneath. `⌃⌥H` shows or hides it from anywhere, and `⌃⌥Tab` switches
modes. [More](docs/GUIDE.md#the-overlay)

<img src="docs/features/overlay.gif" width="600"
     alt="The terminal appears over Dofus with ⌃⌥H, a prompt is typed, and a click on a monster dims it into click-through while Claude keeps working">

### Tells you when your agent needs you

Every tab shows what its agent is doing: a spinner while it works, an orange question mark when it
waits for you, a yellow dot when it finished while you were busy. When Claude Code or Codex asks to
run a command, a card shows the command, and `⌃⌥Y` allows it or `⌃⌥N` refuses it while the game
keeps the keyboard. SlyTerm only types the answer after checking that the prompt on screen is the one
on the card. [More](docs/GUIDE.md#coding-agents)

<img src="docs/features/claude.gif" width="600"
     alt="Over World of Warcraft, a tab's spinner turns into a question mark and a card asks to run npm test; ⌃⌥Y allows it, and a second card says Claude finished">

| Works with | State on the tab | Card | Answer from the game |
| --- | :---: | :---: | :---: |
| Claude Code, Codex | ✓ | ✓ | ✓ |
| omp, pi | ✓ | ✓ | |
| Gemini CLI, Qwen Code | ✓ | | |

There is nothing to install in the agents: SlyTerm reads the session files and terminal titles they
already write.

### Looks up what's under your pointer

Hover a quest, an item or a spell and press `⌃⌥Q`. SlyTerm reads the text near the pointer with the
Mac's own text recognition and opens the matching wiki page in a tab. If it picked the wrong line,
press `⌃⌥Q` again for the next guess. [More](docs/GUIDE.md#lookup)

<img src="docs/features/lookup.gif" width="600"
     alt="Pointing at a Minor Healing Potion in the World of Warcraft bag and pressing ⌃⌥Q opens its Wowhead page in a web tab">

It comes set up for **Dofus** (Dofus 3 and Retro), **World of Warcraft** (Retail and the Classic
versions on Wowhead) and **RuneScape** (Old School and RS3). For any other game, paste its wiki's
search URL: Fandom, wiki.gg and other MediaWiki sites work, and so does any site with a sitemap.

### Plays guides and video over the game

Web tabs sit next to your terminals, with guides in reader mode and ads and cookie banners blocked.
Pop one out and it floats over the game in its own window, with the video slightly see-through so
the game shows behind it. `⌃⌥V` pauses it from the game, and a lookup pauses it while you read.
YouTube, Twitch and streaming sites like Netflix all play. [More](docs/GUIDE.md#web-tabs)

<img src="docs/features/web.gif" width="600"
     alt="Over Cyberpunk 2077, a YouTube guide playing in a web tab pops out into a floating window, keeps playing with the game showing through after a click in the game, and ⌃⌥V pauses it">

### Brings sessions in from iTerm2 and Terminal

If you started Claude Code, Codex, omp or pi in another terminal before the game, press `⌘⇧T` and
pick it: the same conversation carries on in a SlyTerm tab. When you are done, send it back to a
new tab of iTerm2, Terminal, Ghostty or WezTerm, where it left off.
[More](docs/GUIDE.md#bringing-a-session-in)

<img src="docs/features/bring-in.gif" width="600"
     alt="⌘⇧T opens Bring In a Session over Old School RuneScape, and Return resumes an iTerm2 Claude session in a new tab">

### Has a panic button

`⌃⌥P` covers the whole screen with an opaque terminal and silences every video. Press it again and
everything goes back where it was, videos included. [More](docs/GUIDE.md#panic-button-and-fullscreen)

<img src="docs/features/fullscreen.gif" width="600"
     alt="Over World of Warcraft, ⌃⌥P fills the screen with an opaque terminal while Claude keeps working, and pressing it again puts the window and a floating Wowhead page back where they were">

### And behaves like a real terminal

- Tabs like iTerm2, each in its own folder, reopened at the next launch
- Your iTerm2 font, so Powerlevel10k, Starship and Nerd Font prompts look right
- Option left alone, so `{`, `[`, `|` and `~` still work on French and other keyboards
- `⇧Return` for a newline in Claude Code and Codex, and a startup command such as `claude` in each
  new tab
- Every action is a `slyterm://` URL, for scripts, Shortcuts, a Stream Deck or a Claude Code hook
- Lives in the menu bar, with no Dock icon

## It leaves your game alone

SlyTerm is an ordinary window on top of the game. It never reads the game's memory or network
traffic, and never sends the game any input. The lookup takes one screenshot around the pointer when
you press its key, reads it on your Mac and does not keep it.
[What it sends over the network](docs/GUIDE.md#privacy)

## Install

[Download the DMG](https://github.com/MushkyQT/SlyTerm/releases/latest/download/SlyTerm.dmg), drag
SlyTerm to Applications and open it, or run `brew install --cask mushkyqt/tap/slyterm`. Then look for
the smirking terminal in the menu bar. A short setup asks which games you play and shows you the
shortcuts.

The lookup needs the Screen Recording permission, and macOS asks for it the first time you press
`⌃⌥Q`. SlyTerm checks for updates once a day and waits in the menu bar for you to install them, so
nothing pops up mid-game.
[Permissions, updates and building from source](docs/GUIDE.md#install-and-update)

## Getting started

1. Set your game to **borderless windowed**. Exclusive fullscreen can hide the overlay.
2. Press `⌃⌥H` to show the terminal, and run `claude` or `codex`.
3. Type your prompt and click back into the game.
4. When a card appears, answer it with `⌃⌥Y` or `⌃⌥N`, or press `⌃⌥Tab` to go back to the terminal.
5. Point at something in the game and press `⌃⌥Q` to look it up.

## Shortcuts

These are the defaults, and the global ones can be changed in Settings › Shortcuts. ⌃ is Control,
⌥ is Option, ⌘ is Command and ⇧ is Shift. **Help** in the menu bar item opens this list.

| Action | Keys |
| --- | --- |
| Show or hide the terminal | `⌃⌥H` |
| Switch between interact and click-through | `⌃⌥Tab`, or a three-finger tap |
| Panic: cover the screen with an opaque terminal | `⌃⌥P` |
| Fullscreen: fill the screen with the window you are in | `⌃⌥M`, or `⌘Return` inside SlyTerm |
| Look up what is under the pointer | `⌃⌥Q`, again for the next guess |
| Pick a line near the pointer to look up | `⌃⌥⇧Q` |
| Allow or refuse an agent's permission prompt | `⌃⌥Y` / `⌃⌥N` |
| Pause the web tabs that are playing, or play them again | `⌃⌥V` |
| Bring in a session from another terminal | `⌘⇧T` in a terminal |
| Send a session back to its terminal | Right-click its tab |
| Web tab ↔ terminal | `⌘G` |
| New web tab from a terminal, or the address bar of the web tab in front | `⌘L` |
| New tab (a web tab from a web tab), close tab, switch tabs | `⌘T`, `⌘W`, `⌘1`…`⌘9` |
| Go to a web tab | `⌥⌘1`…`⌥⌘9` |
| Reopen the web tab you just closed | `⌘⇧T` in a web tab |
| Settings | `⌘,` |

The `⌃⌥` keys work from anywhere, even while the game has the keyboard. If one does nothing, another
app has it too: see [When a shortcut does nothing](docs/GUIDE.md#when-a-shortcut-does-nothing).

## Documentation

- [Guide](docs/GUIDE.md): every feature in full, for players.
- [Technical details](docs/TECHNICAL.md): every setting, the URL scheme, the command-line modes and
  how the app is built.
- [Troubleshooting](docs/TECHNICAL.md#troubleshooting): the overlay hidden behind the game, a hotkey
  that does nothing, a lookup that opens the wrong page.
- [Changelog](CHANGELOG.md): what changed in each release.
- [Contributing](CONTRIBUTING.md), [AGENTS.md](AGENTS.md) for AI coding agents, and
  [Security](SECURITY.md) for reporting a vulnerability privately.

## Credits

Terminal emulation is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza.
Updates are installed by [Sparkle](https://sparkle-project.org). The licences of SlyTerm, SwiftTerm
and Sparkle are inside the app, in `Contents/Resources/Licenses`.
The lookup presets open pages from the [Dofus Wiki](https://dofuswiki.fandom.com), the
[129Dofus Wiki](https://129dofus.fandom.com), [DofusDB](https://dofusdb.fr),
[Wowhead](https://www.wowhead.com), the
[OSRS Wiki](https://oldschool.runescape.wiki) and the [RuneScape Wiki](https://runescape.wiki).
SlyTerm is not affiliated with any of these sites, or with Ankama, Blizzard Entertainment or Jagex.

## License

SlyTerm is released under the [MIT License](LICENSE).
