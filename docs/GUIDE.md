# SlyTerm guide

Everything SlyTerm does, feature by feature, for players. The [README](../README.md) is the short
tour. [TECHNICAL.md](TECHNICAL.md) has every setting, the URL scheme, the command-line modes and
how the app is built.

- [Install and update](#install-and-update)
- [First run](#first-run)
- [The overlay](#the-overlay)
- [Click-through](#click-through)
- [Coding agents](#coding-agents)
- [Lookup](#lookup)
- [Web tabs](#web-tabs)
- [Bringing a session in](#bringing-a-session-in)
- [Panic button and fullscreen](#panic-button-and-fullscreen)
- [The terminal](#the-terminal)
- [Scripting](#scripting)
- [Privacy](#privacy)
- [When a shortcut does nothing](#when-a-shortcut-does-nothing)

## Install and update

[Download SlyTerm](https://github.com/MushkyQT/SlyTerm/releases/latest/download/SlyTerm.dmg), open
the DMG and drag SlyTerm to Applications, then open it from there. It needs macOS 14 Sonoma or later
and runs on Apple silicon and Intel Macs. Every version from 1.3.0 on, with what changed in it, is
on the [Releases](https://github.com/MushkyQT/SlyTerm/releases) page. With
[Homebrew](https://brew.sh), `brew install --cask mushkyqt/tap/slyterm` does the same.

Look for the icon in the menu bar: a terminal window with a smirk.

The lookup needs the Screen Recording permission. macOS asks for it the first time you press
`⌃⌥Q`: turn SlyTerm on in System Settings › Privacy & Security › Screen Recording, then relaunch
it. Settings › Lookup and the first setup say when that is still needed, with a button that
reopens SlyTerm. If you used a copy you built yourself before, macOS asks once more when the
downloaded app replaces it.

SlyTerm checks for a new version once a day. When there is one, an item such as "Update to SlyTerm
1.4.0…" waits at the top of the menu bar item and nothing opens over your game; choose it when you
are ready. In Settings › General › Updates you can turn the checks off, or have updates download
on their own and install when SlyTerm quits.

### Build from source

You need the Xcode Command Line Tools (`xcode-select --install`); the full Xcode app is not needed.

```sh
git clone https://github.com/MushkyQT/slyterm.git
cd slyterm
./build.sh --install
open /Applications/SlyTerm.app
```

A copy built from source does not update itself. [CONTRIBUTING.md](../CONTRIBUTING.md) has more on
building.

## First run

The first time SlyTerm opens, a short setup asks whether you play games with it open and which
ones, so the lookup knows where to search, and shows the main shortcuts so you can change them.
On a Mac with a trackpad it also sets what a tap with several fingers does and lets you try it
there, and says when macOS opens Look up on the same tap. Add your own game with its name and a
wiki or site address. Everything it sets is in Settings, which can run the setup again.

1. Set your game to **borderless windowed**, or use macOS fullscreen. Exclusive fullscreen can hide
   the overlay.
2. Press `⌃⌥H` to show the terminal and run `claude` or `codex`. To start your agent in every new
   tab, set Settings › Terminal › Startup command to it.
3. Type your prompt, then click back into the game. The terminal lets your clicks through while
   the agent works.
4. When a card says the agent is done or needs you, answer with `⌃⌥Y` or `⌃⌥N`, or press `⌃⌥Tab`
   to go back to the terminal.
5. Point at something in the game and press `⌃⌥Q` to look it up.
6. Press `⌘L` in the terminal for a web tab, type an address, and pop it out with the button in its
   toolbar to watch it in a window of its own over the game.

## The overlay

SlyTerm stays above your game, in borderless windowed mode or in macOS fullscreen. Drag it by its
tab strip, resize it from its edges and choose how see-through it is. It has no Dock icon and lives
in the menu bar. While Settings or the setup assistant is open it shows in the Dock and in `⌘Tab`, so
you can switch away and come back to it. `⌃⌥H` shows or hides it from anywhere, even while the game
has the keyboard.

In a narrow window the tab names stay readable: the expand button goes, and a tab too narrow for its
`×` shows none; close it with `⌘W`, a middle click or its right-click menu.

If a game still covers the terminal, set Settings › Window › Level to "Above everything".

## Click-through

Two modes, one key (`⌃⌥Tab`):

- **Interact**: the terminal takes your typing, clicks and scrolling, like any terminal.
- **Click-through**: the terminal dims, and every click, scroll and keystroke goes to the game
  underneath.

Click into your game and SlyTerm switches to click-through by itself. You show the terminal, type
a prompt, click back into the game and keep playing while the output streams in. A three-finger tap
on the trackpad switches modes too. The first three times it switches by itself, a note by the tab
strip says so, and the strip reads "click-through" when it has room and nothing else to say.

## Coding agents

### What each agent gets

| Agent | State on the tab | Card when it finishes or asks | Answer from the game |
| --- | :---: | :---: | :---: |
| Claude Code | ✓ | ✓ | ✓ |
| Codex | ✓ | ✓ | ✓ |
| omp, pi | ✓ | ✓ | |
| Gemini CLI, Qwen Code | ✓ | | |
| Any program that sends terminal notifications | ✓ | ✓ | |

There is nothing to set up: SlyTerm reads the session files and the terminal titles the agents
already write.

### On the tab strip

Each tab running a coding agent shows its state: a spinner while it works, an orange question mark
while it waits for you, a yellow dot once it has finished and you have not looked. Hover a tab for
the details, such as "Codex is working for 2m · editing GuideTab.swift" or "Claude is waiting for
you · run `npm test`". Any other program that sends terminal notifications gets a mark and a card
with its text.

### Answering from the game

When an agent finishes a turn or asks for permission, a card appears by the tab strip with the end
of its answer or the command it wants to run. For Claude Code and Codex, `⌃⌥Y` allows the request
and `⌃⌥N` refuses it, and the game keeps the keyboard throughout. SlyTerm types the answer only
after it has checked that the prompt on screen is the one the card showed; for Codex, only its usual
prompt to run a command or edit files, with its default keys, is answered. Anything it cannot answer
safely, such as a question with several options, waits for you in the terminal.

## Lookup

Point at a quest, an item or a spell and press `⌃⌥Q`. SlyTerm reads the text around the pointer,
finds the matching page on your game's wiki or guide site, and opens it in a web tab next to your
terminals. It also finds the name at the top of an item's tooltip, wherever the game draws it.

Press `⌃⌥Q` again for the next guess, or `⌃⌥⇧Q` to choose from every line near the pointer with one
key each. The message by the pointer names the site that answered, or the game it asked when
nothing matched, so a lookup that went to the wrong game shows it.

### Games with presets

- **Dofus**: Dofus 3 with the Dofus Wiki and DofusDB, and Dofus Retro with the 129Dofus Wiki, in
  English
- **World of Warcraft**, every version Wowhead covers: Retail, Classic, Burning Crusade Classic,
  Mists of Pandaria Classic and WoW: Forever
- **RuneScape**: Old School with the OSRS Wiki, and RuneScape 3 with the RuneScape Wiki

### Any other game

Add a site by pasting its search URL. SlyTerm indexes MediaWiki sites, including Fandom and wiki.gg
wikis, and any site with a sitemap, so a name opens its exact page. A game you set up can be
exported from Settings › Lookup and
[sent in as a preset](../CONTRIBUTING.md#adding-a-game).

## Web tabs

Guides and video, from YouTube, Twitch and the like, open in web tabs: small squares at the end of
the tab strip, each with its site's icon. Streaming sites such as Netflix get the same protected
playback Safari has. Type an address or a search into a web tab's address bar, or open a new one
with `⌘L` in a terminal or `⌘T` in a web tab, and `⌘⇧T` brings back the one you just closed. Hover a
square to see its page and its key: `⌥⌘1`…`⌥⌘9` go to the web tabs in order. `⌘G` switches between
the page and your terminal, and the game keeps focus when a page opens.

### Floating over the game

Pop a web tab out and it floats over the game in a window of its own, filled with its video if one
is playing, while the SlyTerm window goes back to your terminal. It switches to click-through with
the rest of SlyTerm, and a dot on its toolbar shows which mode it is in: green when it takes clicks
and typing, orange in click-through. A playing video has an opacity of its own, 85% by default, so
the game shows through it in either mode. Put it back and it returns to the SlyTerm window.

### Pausing

`⌃⌥V` pauses what is playing without leaving the game, and plays it again; the panic button
silences it too. Looking something up pauses your videos while you read the guide. A video in the
SlyTerm window also pauses when another tab covers it or the window hides, and plays again when you
come back to it. One setting turns this off.

### Reader mode

Guides show in reader mode on the terminal's dark, translucent background, with ads, cookie banners
and trackers blocked; streaming sites are left as they are, so their players work. `⌘F` finds text
in the page, so you can jump straight to the quest step you are on. If you prefer your browser, one
setting sends the lookup's pages there instead. Settings › Web holds these settings, with the page
zoom and the search address.

## Bringing a session in

If you started Claude Code, Codex, omp or pi in iTerm2, Terminal or another terminal app before
launching the game, press `⌘⇧T` in a terminal tab to bring it into SlyTerm. The conversation carries
on from the same session. A background Claude (`claude --bg`) is attached without being
interrupted, and Codex keeps working through the move when it runs in its background server, as
it does by default. Otherwise moving an agent in the middle of a turn interrupts it, so SlyTerm asks
first. Claude Code, Codex and pi can also be copied, with the original left running, and a plain
shell tab comes across with its folder and its command.

### Sending it back

Right-click its tab and choose Send Back, or quit with Send Back and Quit: the conversation opens
where it left off, in a new tab of the terminal it came from. That works for iTerm2, Terminal,
Ghostty and WezTerm; a session from anywhere else, or started in SlyTerm, goes to the one chosen in
Settings.

## Panic button and fullscreen

### Panic button

`⌃⌥P` fills the screen with an opaque terminal, menu bar included, and puts the keyboard in it.
Web tabs go silent and leave the tab strip, and floating web tabs hide. A guide you look up in the
meantime loads out of sight and is in front when you leave. Press it again and the window goes back
exactly where it was, with the floating tabs and what was playing.

### Fullscreen

`⌃⌥M` or `⌘Return` inside SlyTerm fills the screen with the window you are in: the SlyTerm window
with the tab in front, or a floating web tab. The expand button on the tab strip fills it with the
SlyTerm window. It is opaque and keeps the keyboard. Nothing pauses or hides, and tabs switch as
usual. Press it again, or switch to click-through, and the window goes back where it was.

## The terminal

- Tabs like iTerm2, each in its own folder, restored at the next launch
- Uses your iTerm2 font, so Powerlevel10k, Starship and oh-my-posh prompts render correctly; Nerd
  Fonts are picked up automatically
- Option is left alone by default, so `{`, `[`, `|` and `~` keep working on French and other
  international keyboards
- `⇧Return` for a newline in Claude Code and Codex
- A startup command, such as `claude` or `codex`, typed into each new tab

## Scripting

Every action is also a `slyterm://` URL, so shell scripts, Shortcuts, a Stream Deck or a Claude
Code hook can drive the app: `open -g slyterm://toggle`. Each tab exports `SLYTERM_TAB_ID`, so a
hook can mark the tab it ran in. The routes are listed in
[TECHNICAL.md](TECHNICAL.md#url-scheme), with [hook examples](TECHNICAL.md#claude-code-hooks).

## Privacy

SlyTerm is a separate window on top of your game, like any other app's. It never reads the game's
memory or network traffic, and it never sends the game any input. The lookup takes one screenshot
around the pointer when you press its hotkey, reads it on your Mac with Apple's text recognition,
and does not save it.

Apart from the pages you open, its only network requests go to the guide sites you have set up, for
an index refresh once a week and a search when a name is not in the index, and to GitHub, where it
looks for a new version of SlyTerm once a day unless you turn that off in Settings.

## When a shortcut does nothing

The full list of shortcuts is in the [README](../README.md#shortcuts), and **Help** in the menu bar
item opens it. The keys that start with `⌃⌥` work from anywhere, including while the game has the
keyboard, and stay clear of the keys games use. If one does nothing, or moves a window instead,
another app, often a window manager, has the same shortcut: change one of the two in Settings ›
Shortcuts.

If you use the three-finger tap, set System Settings › Trackpad › Point & Click › "Look up & data
detectors" to Force Click or off, or each tap also opens a dictionary panel.

More fixes, for an overlay hidden behind the game or a lookup that opens the wrong page, are in
[Troubleshooting](TECHNICAL.md#troubleshooting).
