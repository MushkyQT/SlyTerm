# SlyTerm technical details

This is the reference for how SlyTerm behaves, how to configure and script it, and how it is
built. For an overview of what the app does, see the [README](../README.md). To build it and send
a change, see [CONTRIBUTING.md](../CONTRIBUTING.md).

- [Principles](#principles)
- [The overlay](#the-overlay)
- [What each tab's agent is doing](#what-each-tabs-agent-is-doing)
- [Bringing a session in from another terminal](#bringing-a-session-in-from-another-terminal)
- [Lookup](#lookup)
- [Games and sources](#games-and-sources)
- [Web tabs](#web-tabs)
- [Settings](#settings)
- [Scripting](#scripting)
- [Troubleshooting](#troubleshooting)
- [Architecture](#architecture)
- [Migration notes](#migration-notes)

## Principles

These hold for every feature, and a change that breaks one of them is a bug:

- **No game interaction.** SlyTerm never reads a game's memory or network traffic and never sends
  it input. It is a window on top, nothing more.
- **The screen is read only on request.** The lookup takes one screenshot around the pointer when
  its hotkey (or its URL) fires, with SlyTerm's own windows excluded, and reads it on device.
  Nothing is captured at any other time.
- **The game keeps the keyboard.** A finished turn, a permission prompt, a bell, a terminal
  notification or a page arriving in a web tab never takes focus from the game, and a floating web
  tab never takes it on its own. A hidden overlay that has news comes back in click-through, so the
  next click and keystroke still reach the game.
- **Nothing is typed into a conversation on a guess.** Allow and refuse type one key, and only
  after a fresh check that the prompt up is the one the user read. Any doubt ends in a toast.
- **Agents' files are read, never written.** Claude Code's session registry and transcripts,
  Codex's rollouts and thread index, and omp's and pi's session files are the agents' own
  undocumented formats, read best effort and defensively, and so are the titles they set. Nothing
  connects to an agent's server or takes its locks.

## The overlay

### Window and modes

Set your game to **borderless windowed** for the most reliable overlay. Native macOS fullscreen
also works; exclusive fullscreen may not. If the overlay ends up behind the game, raise Settings ›
Window › Level to "Above everything, for games that cover the terminal".

- **Interact** (green dot). The terminal takes clicks, scrolling, text selection and typing, like
  any terminal. Typing goes to the terminal, not the game.
- **Click-through** (orange dot, dimmed). Every click and scroll passes through to the game
  underneath. Only the tab strip stays clickable, and clicking it (switching tabs, dragging the
  window) leaves you in click-through: the mode changes only by hotkey, eye button or trackpad
  tap, so a stray click on the strip never swallows your next click on the game. The keyboard goes
  back to the game. Click-through covers every SlyTerm window at once: a floating web tab lets
  clicks through too, all but its toolbar (see [Click-through and focus](#click-through-and-focus)).
- **Panic** (red dot) covers the whole screen, menu bar included, with a fully opaque terminal and
  puts the keyboard in it. Nothing of the game shows through. Press the hotkey again and the window
  goes back exactly where it was, with its previous opacity, mode and visibility. From a web tab it
  switches to the terminal you were reading it over, opening one if you have none, and comes back
  to the page when you leave. It also silences every web tab and hides the floating ones; leaving
  panic shows them again and lets the sound go on. Works from the hidden state too.
  While it lasts, the strip shows only the terminal tabs, and nothing brings a web tab in front:
  `⌘G`, `⌥⌘1`…`⌥⌘9`, `⌘L` and "New Web Tab" do nothing, and a guide that arrives loads out of sight
  (see [The lookup's tab](#the-lookups-tab)). Panic taken during Fullscreen covers it, and leaving
  panic goes back to Fullscreen; Fullscreen's keys do nothing during panic. `⌃⌥H` leaves panic and
  hides the window.
- **Fullscreen** (green dot) fills the screen, menu bar included, with the window that has the
  keyboard, opaque and in interact mode: a floating web tab when one has it, otherwise the SlyTerm
  window, shown if it was hidden, with the tab in front, terminal or web. Unlike panic it changes
  nothing else: no tab switches, nothing pauses, floating windows stay where they are and above it,
  and tabs and web tabs switch as usual. `⌃⌥M` (configurable), `⌘Return` in the SlyTerm window or a
  floating web tab, the strip's expand button (always the SlyTerm window), "Fullscreen" in the
  menu bar item and `slyterm://fullscreen` toggle it; while it is on, the expand button shows the
  collapse icon. One window is in Fullscreen at a time, and leaving puts it back at its exact
  frame and strip edge, with its previous opacity. Click-through, from the hotkey, the eye button, the tap or the
  keyboard going to another app, first leaves Fullscreen, so the window that ghosts is the one put
  back; `⌃⌥H` leaves it and hides. This is SlyTerm's own mode, not macOS fullscreen: it opens no
  Space and the game stays where it is. A page's own fullscreen button is something else again: it
  fills only its web tab (see
  [Streaming sites, DRM and fullscreen](#streaming-sites-drm-and-fullscreen)).

By default the overlay switches to click-through on its own as soon as the terminal loses keyboard
focus, that is, the moment you click into the game. So the loop is: hotkey or eye button, type your
prompt, click back into the game and keep playing, glance at the agent's output as it streams. The
keyboard moving between SlyTerm's own windows, from the terminal to a floating web tab or back,
does not count. Turn this off in Settings › Window ("Switch to click-through when the terminal
loses focus") if you would rather switch modes only by hand.

The first three automatic switches say why the terminal stopped typing: a toast by the strip's
corner, orange, for 4 seconds, "Click-through: clicks and keys go to the game. ⌃⌥Tab or the eye
button to type here." (the click-through shortcut as set, or "The eye button to type here." when
it has none). The hotkey, the eye button and the tap never show it, nor does panic, and with the
setting off nothing does; the count is kept in `ghostHintsShown`. The toast is a non-activating
panel that ignores the mouse, so the game keeps the keyboard. While the overlay is in
click-through and no agent hint is due, the strip's hint slot reads "click-through" in orange,
when there is room for it.

### Trackpad tap

A quick tap with three fingers roughly side by side, anywhere on the trackpad, toggles
click-through by default. Settings › Shortcuts › Trackpad sets how many fingers (2 to 5) and whether
the tap toggles click-through, shows or hides the terminal, fires panic mode, toggles Fullscreen,
or does nothing.

It relies on Apple's private MultitouchSupport framework, the same one BetterTouchTool uses, so a
future macOS update could stop it; that pane then says "Unavailable" and the hotkeys keep working.
macOS cannot be told to ignore the tap, so in System Settings › Trackpad › Point & Click set "Look
up & data detectors" to Force Click or off, otherwise every tap also opens a dictionary panel. One
tuning key has no control: `tapAlignment` (max vertical spread, default 0.50 of the trackpad
height, 1 disables the check). Enable `debug` and tap a few times to see in
`~/Library/Logs/SlyTerm.log` why a tap was or was not recognised.

### Tab bar

The bar goes where you put it. Drag it into the upper half of the screen and, the moment it
crosses the middle, the terminal flips to hang below it; drag it back down into the lower half and
the terminal goes back above it. The bar itself never leaves your pointer (the terminal is what
moves), so the bar is always the window's outer edge and the terminal is what reaches toward the
middle, where the game is. Settings › Window › Tab bar pins it to the top or the bottom of the
window instead.

On a narrow strip the tab names keep the room. Web tabs go behind a single `…` square before a
terminal's tab gets under 44 pt (see [Web tabs on the strip](#web-tabs-on-the-strip)); if tabs
would still be under 40 pt, the expand button goes (`⌘Return` and `⌃⌥M` still toggle
Fullscreen). The selected tab's `×`, which a tab only shows otherwise while the pointer is on
it, also waits for the pointer when it would leave less than three letters of the name;
middle-click and `⌘W` close a tab either way. A tab under 40 pt shows its mark and the first three letters of its name, with no
ellipsis ("sly", "cla", "Pro"). The eye, the minus and `+` always stay. A tab whose name is
shortened has it in its tooltip, above what its agent is doing.

### Tabs and folders

Every tab knows its own folder: SlyTerm reads it from the shell directly, with no shell
integration needed. New tabs open in the current tab's folder (turn that off in Settings ›
Terminal to always use the default folder). Tabs and their folders are restored at launch; only
the tab that comes back in front runs the startup command, so putting six folders back does not
start six `claude` sessions at once. Quitting with several tabs or a running command asks first
(tick "Don't ask again", untick it in Settings › General, or `defaults write
com.charlesmelki.slyterm confirmQuit -bool false`); logging out, restarting and shutting down are
never held up by that prompt. When the shell sets no title, the tab shows its folder name and
follows `cd`. Closing a tab hangs up its shell and what runs in it (`SIGHUP`), as closing a terminal
window does.

Every tab exports `SLYTERM_TAB_ID` to its shell, which the activity monitor, `slyterm://notify`
and "Bring In a Session" use to tell tabs apart.

### Font and keyboard

By default SlyTerm uses the font your iTerm2 default profile uses, so a prompt that renders there
(oh-my-posh, Powerlevel10k, Starship with Nerd Font icons) renders here. Without iTerm2 it picks the
first installed Nerd Font, and the system monospaced font otherwise, with installed Nerd Fonts as
glyph fallback. Change it under Settings › Terminal › Font, which lists the installed Nerd Fonts
first and then every other fixed-pitch family.

Option as Meta is **off** by default so that `{`, `[`, `|`, `~` keep working on French and other
international layouts. `⇧Return` or `⌥Return` gives you a newline in Claude Code, Codex, omp and
pi: SlyTerm sends ESC CR, or, to a program that turned on the kitty keyboard protocol as Codex does,
the key with its modifiers.

### Startup animation

At launch the icon plays itself over the first terminal: SF Symbols' `terminal` draws in, its
cursor blinks, the underscore bends into the smirk, the prompt shuts for a wink, and the whole
thing switches off like an old screen (a snap to a line, a dot, a flare) as the shell comes on
underneath. The shell is running the whole time and nothing it prints is lost; any hotkey, tab
switch or click-through cuts the animation short. Turn it off in Settings › General ("Play the
logo animation", key `startupAnimation`).

### Every action and its keys

| Action | How |
| --- | --- |
| Show / hide the overlay | `⌃⌥H` (configurable), or the `–` button; floating web tabs stay where they are |
| Toggle click-through | `⌃⌥Tab` (configurable), the eye button, or a three-finger tap on the trackpad; every SlyTerm window at once |
| Panic: cover the screen with an opaque terminal | `⌃⌥P` (configurable), or "Panic Mode" in the menu bar item |
| Fullscreen: the window with the keyboard fills the screen | `⌃⌥M` (configurable), `⌘Return` inside the SlyTerm window or a floating web tab, the expand button, or "Fullscreen" in the menu bar item |
| Look up what is under the pointer, in a web tab | `⌃⌥Q` (configurable), or "Look Up Under Pointer" in the menu bar item, which also has a "Lookup Game" submenu. Press it again without moving for the next guess |
| Pick which line near the pointer to look up | `⌃⌥⇧Q` (configurable), or "Pick Text Near Pointer…" in the menu bar item, then the key shown next to the line |
| What each tab's agent is doing | A spinner at the head of the tab while it works, an orange `?` while it waits for you; hover the tab for the detail |
| An agent finished or is waiting, or a program sent a notification | The tab turns yellow, the strip lights up and a card says what happened. Press `⌃⌥Tab`, or click the eye button |
| Allow or refuse what an agent asks, from the game | `⌃⌥Y` / `⌃⌥N` (configurable), while a Claude Code or Codex permission prompt is up in that tab |
| Pause what web tabs are playing, or play it again | `⌃⌥V` (configurable), or "Play / Pause" in the menu bar item |
| Move the window | Drag the tab strip |
| Resize | Drag the left or right edge, or the edge the tab strip is not on |
| New tab / close tab | `⌘T` (a terminal in the current tab's folder from a terminal, a web tab from a web tab) / `⌘W` (the tab in front, terminal or web), or `+` and `×` on the strip (on a narrow strip, the selected tab's `×` shows while the pointer is on it); middle-click closes a tab or a web tab's square |
| Switch tabs | `⌘1`…`⌘9` (terminals only); `⌃Tab` / `⌃⇧Tab`, `⌘⌥←` / `⌘⌥→` or `⌘⇧[` / `⌘⇧]` go through the terminals from a terminal, and through the web tabs in the SlyTerm window from a web tab |
| Go to a web tab | `⌥⌘1`…`⌥⌘9`, the web tabs in the order of their squares, from a terminal, a web tab or a floating window; hover a square to see its key |
| Web tab ↔ terminal | `⌘G` (the last web tab in front in the SlyTerm window; opens the active game's first source when there is none) |
| New web tab | `⌘L` in a terminal, `⌘T` in a web tab or a floating window, or "New Web Tab" in the menu bar item; in a web tab, `⌘L` goes to its address field |
| Open a link in a new web tab | `⌘`-click or middle-click opens it behind the one you are on |
| Reopen a closed web tab | `⌘⇧T` in a web tab or a floating window, up to the last ten, most recent first |
| Pop a web tab out / put it back | The pop-out button in its toolbar / the same button, or a click on its dimmed square in the strip |
| Move or resize a floating web tab | Drag its toolbar / drag its edges |
| Copy / paste / select all | `⌘C` (with a selection) / `⌘V` / `⌘A` |
| Font size, or page zoom in a web tab | `⌘+` / `⌘-` / `⌘0` |
| In a web tab: back / forward / reload | `⌘←` / `⌘→` / `⌘R` |
| In a web tab: find in page | `⌘F`, then `Return` / `⇧Return` or `⌘G` / `⌘⇧G` for the next / previous match, `Esc` to close; `⌘E` searches for the selection |
| Bring a session in from another terminal | `⌘⇧T` in a terminal, "Bring In a Session…" in the menu bar item, or a right-click on `+` |
| Send a tab's session back to its terminal | Right-click the tab, "Send Tab Back to …" in the menu bar item, or "Send Back and Quit" when quitting |
| Newline in Claude Code, Codex, omp and pi | `⇧Return` or `⌥Return` |
| Open Settings | `⌘,` in the SlyTerm window or a floating web tab, or "Settings…" in the menu bar item |
| Quit | `⌘Q` while the terminal or a web tab has focus, or the menu bar item |

## What each tab's agent is doing

A tab that runs a coding agent says so on the strip and on a card, with nothing to set up. SlyTerm
reads what each agent writes anyway, its session files and the title it gives the tab, and a poll
once a second, re-reading a file only when it has grown, costs about a millisecond. How much it
learns depends on the agent:

| Agent | Status from | Doing, asking and last answer from | Allow / refuse | Bring In |
| --- | --- | --- | --- | --- |
| Claude Code | its session registry | its transcript | Return / Escape | Move, Copy, Attach |
| Codex | its title, else its rollout | its rollout; a permission prompt from the tab's text | `y` / `n`, for a command or an edit | Move, Copy |
| omp | its title, else its session file | its session file | no: its questions wait in the terminal | Move |
| pi | its session file | its session file | no: pi does not ask | Move, Copy |
| Gemini CLI, Qwen Code | their titles | nothing | no | as a shell tab |
| Any other program | a mark, from a bell or a notification | the notification's text | no | as a shell tab |

### On the strip

A spinner at the head of the tab while the agent works, an orange question mark while it waits for
you (a permission prompt, a question) and the yellow dot below once it has finished and nobody
looked. Hover the tab and the tooltip says more, naming the agent: "Claude is working for 2m ·
editing GuideTab.swift", "Codex is waiting for you · run `npm test`", "omp finished 3m ago" and the
first line of what it said, or "Gemini is idle" when there is nothing more to say. The hint at the
right of the strip shows the selected tab's activity while it works, "running the tests · 2m", so in
click-through the strip alone says whether it is worth coming back yet.

Codex, omp, Gemini CLI and Qwen Code animate the tab's title while they work. While one of them is
the agent SlyTerm reads in a tab, the tab is named by the steady part of its title, so the name holds
still: `⠸ Fix the login test | demo` shows as "Fix the login test | demo", and Gemini CLI's
`✦  Working… (demo)` as "demo".

A tab and an agent are matched only while the agent is the job in front on the tab's own terminal:
Claude Code through the tab id the shell exports as well, the other agents by their process on that
terminal. So an agent started in the tab is found; one suspended with `⌃Z`, or running inside tmux,
screen or an editor's terminal started from the tab, is not, since the tab's screen is not where it
is. `SlyTerm --activity` (see [Command-line modes](#command-line-modes)) prints what the poll sees,
for every agent in any terminal.

### When an agent needs you

A turn finishing, or a prompt appearing, marks that tab yellow and lights the whole strip up to full
brightness even in click-through, so it stands out over the dimmed terminal. So does a terminal
bell, a [terminal notification](#terminal-notifications), or `open -g slyterm://notify` from a
script or a hook. It also plays the system alert sound; switch that off in Settings › General
("Play a sound when a tab needs attention", key `attentionSound`). It never takes the keyboard from
the game: if the overlay was hidden it comes back in click-through mode, so your next click and your
next keystroke still go to the game. Press `⌃⌥Tab`, or click the eye button, to read it and the mark
clears; clicking the yellow tab only brings it to the front, it does not take you out of
click-through. Nothing that happens in the tab you are typing in is news, so a turn finishing there
marks nothing and a shell completion beep stays quiet.

### The card

With the mark comes a card, hung off the strip and readable over the game: the tab's name, what
happened and, for a finished turn, how long it took and the last paragraph of the agent's answer;
for a permission prompt, the command it wants to run or the file it wants to edit; for a question,
the question and its options; for a notification, its title and its text. Its last line names the
keys that act on it, each combo in bold and taken from Settings › Shortcuts: `⌃⌥Y Allow · ⌃⌥N
Refuse · ⌃⌥Tab Look` for a permission prompt, on two lines when the card is too narrow for one.
The less SlyTerm can read of an agent, the less its card says: Gemini CLI's and Qwen Code's only
say that a turn finished or that something waits, and so does the card of a Codex whose rollout
cannot be found. A finished card fades after ten seconds, a waiting one stays until it is answered or closed with its ×. Clicking the
card brings its tab forward and, like a click on the strip, leaves you in click-through; `⌃⌥Tab`
with a card up opens the tab the card is about, whichever tab is selected.

The card sits on the side of the strip away from the terminal when the screen has room there, and
over the terminal's corner otherwise, never for the tab you are looking at. There is one card at a
time, but no request gets lost behind another: a finished turn never covers a request that still
stands, and a request pushed off the card by a newer one comes back once that one is answered or
closed (or, when you clicked the card, once that tab is answered or looked at, so the keys keep
meaning the tab you just turned to).

### Allow or refuse from the game

A permission prompt from Claude Code or Codex can be answered without leaving the game: `⌃⌥Y`
allows what the agent asks and `⌃⌥N` refuses it, both configurable in Settings › Shortcuts and named
on the card. They type the one key the prompt takes into the tab the card is about, or the selected
tab: for Claude Code, Return for the highlighted "Yes" and Escape for "No"; for Codex, `y` and `n`
(see [Codex](#codex)). They type it only when a fresh look confirms all of this:

- that tab's agent is waiting on the very prompt the card showed,
- the prompt has been up for at least a second and was not answered a moment ago,
- it is a prompt known to take a plain yes or no: for Claude Code, one for a tool known to put up
  such a prompt (a command, an edit, a read, a fetch or search, an MCP tool); for Codex, a command
  to run or an edit to make, as the tab shows it right before the key,
- and the agent is still the program running in the tab.

Otherwise a small toast says why and nothing is typed ("Claude is not the program running in
slyterm"). Every orange toast here stays 3.5 seconds, "Refused: …" included; the green
"Allowed: …" stays 1.6. So a prompt that changed while you reached
for the key wants another look at the card first, and some prompts always want the terminal: a
question, which is never answered blind (the card says to press `⌃⌥Tab`), a plan to approve, a
subagent asking for something, and several calls issued at once, where the transcript cannot say
which one the prompt on screen is about. omp and pi have nothing to answer this way, and the toast
says so ("omp is waiting, but not for a yes or no").

Refusing stops the agent's turn. That stop comes from the key you pressed, so for five seconds
after a refusal a turn ending in that tab brings no mark and no card.

### Turning it off

Turn the card off in Settings › General ("Show a card when an agent finishes or asks you
something", key `activityCards`) and an agent finishing or asking only marks its tab: the marks on
the strip and the yellow tab stay, but there is no card, no sound, and a hidden overlay stays
hidden. The same goes for a bell or a terminal notification from a tab whose agent SlyTerm reads,
such as Claude Code's terminal bell or omp's: it marks the tab and nothing more. From any other
tab, a bell or a notification still plays the sound and brings a hidden overlay back, with no card.
The allow and refuse shortcuts go with the card, `slyterm://allow` and `slyterm://refuse` included.

Those two URLs are off anyway until you turn them on, since any program of yours can open a URL,
and an agent that can run `open` could approve its own next request:
`defaults write com.charlesmelki.slyterm activityAnswerURLs -bool true`, with no control in
Settings. How long a finished card or a notification stays is "Keep a finished card for … s" in
Settings › General › Agents (`activityCardSeconds`, default 10; 0 keeps it until it is closed), off
while the card is off.

### Claude Code

SlyTerm reads Claude Code from the two files it writes anyway: its session registry, which says
whether each session is busy, waiting or idle, and the transcript, which says what the busy one is
running and what the waiting one is waiting for. Both formats are Claude Code's own and
undocumented, so everything read from them is best effort: when the transcript cannot be read the
status still shows, only the label does not.

The poll notices a change within a second; a Claude Code hook calling `slyterm://notify` (see
[Claude Code hooks](#claude-code-hooks)) makes it instant, and a terminal bell
(`preferredNotifChannel` set to `terminal_bell` in Claude Code's settings) marks the tab too. A
session brought in with Attach runs in Claude's daemon rather than in the tab, so its
status is read through the `claude attach` client in the tab and its registry entry, when both can
be seen.

### Codex

Codex (tried with 0.158) is read from three places: the title it gives the tab, its rollout file,
and, while it asks for something, the text on the tab.

- **The title.** Codex's default `terminal_title` is its activity, the thread's name and the
  project: `⠸ Fix the login test | demo` while it works, a braille spinner frame first;
  `[ ! ] Action Required | Fix the login test | demo`, blinking with `[ . ]`, while it waits for an
  approval, a question or a plan; and the same without a mark once it is idle. The title decides
  the status once it has shown a spinner or the Action Required mark since that Codex started. A
  title set up without the activity never shows one, and that Codex is read from its rollout alone,
  which cannot tell a call that waits for approval from one that runs: it shows as working. A change
  of status in the title starts a scan at once, so the strip follows Codex without waiting for the
  poll.
- **The rollout.** `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl` under `$CODEX_HOME` (`~/.codex`
  by default) records each turn's start and end, the call it is making (a command, the file an edit
  touches, a plan, an MCP tool), its final answer and how long it took; `session_index.jsonl` beside
  it holds the names threads were given. A Codex that runs its turns itself, as with `--no-daemon`,
  is read from the rollout it holds open. One started as `codex resume <id>` is read from that
  thread's rollout while its server still has it open: after `/new` or `/resume` inside it, the
  server lets go of the old thread within a minute or so, and the folder rule below takes over. Two
  Codex sessions started with the same id both go without.
- **The background server.** Since 0.157 Codex by default runs its turns in one machine-wide
  `codex app-server`, which writes the rollouts, while the Codex in the tab only shows them. SlyTerm
  finds the server the tab's Codex is connected to and the rollouts it has open, from the kernel's
  list of their open files and sockets, without connecting to anything. It takes the one in the
  same folder that began and was written since the tab's Codex started, with the thread name in the
  title deciding between several; two Codex sessions in one folder that were both open when a thread
  began cannot tell whose it is, and neither gets it, wherever the other one runs. A thread reopened
  from Codex's own resume picker is missed: its status still comes from the title, its card has no
  text, and Bring In lists its tab as a shell tab. The server also runs Codex's commands and hooks,
  with its own environment, so `SLYTERM_TAB_ID` never reaches them and a Codex hook cannot say which
  tab to mark. The title does that job.
- **The prompt on the tab.** Codex never writes an approval prompt to disk: in the rollout, a call
  that waits for approval looks like one that runs. So while its title says Action Required,
  SlyTerm reads the lines the tab shows (the text SlyTerm itself holds for that terminal, not a
  capture of the screen), from the bottom up. Only a prompt shaped exactly like Codex's approval to
  run a command or make an edit, with its default keys, counts: `Press enter to confirm or esc to
  cancel` on the last line; right above it the options, `1. Yes, proceed (y)` first, `No, and tell
  Codex what to do differently (esc)` last and between them only Codex's own `(p)` or `(a)` option,
  none of them taking `n`; above those, `Would you like to run the following command?` or `Would you
  like to make the following edits?`, the only such title on the tab. The paragraphs Codex puts
  before a command (`Environment:`, `Reason:` and the like, each ending at a blank line) are skipped
  whole, and the command is everything from the `$` line after them to the options, blank lines
  included; an edit shows its `Destination:` paths. A command too long for the card ends there
  with `…`, so the card never looks complete when it is not. Anything else is a Codex waiting for
  you, left to the terminal: a command Codex itself cut short (`[… 24 lines]`), network access,
  permissions, an MCP server's request, a question, a plan. With no prompt on the tab, the
  rollout's pending call is the card's text.

Allow types `y` and refuse types `n`, Codex's own keys for those two options. Refusing is "No, and
tell Codex what to do differently": the call is refused and the turn stops, waiting for what you
type next. Letters rather than Return and Escape, because if the prompt went away meanwhile a letter
lands in the input box, where Return would send a draft and Escape would interrupt the turn. Right
before the key, in the same turn of the main thread, SlyTerm reads the tab's lines again and types
only if they show the very prompt the card did. A prompt whose keys were changed in Codex's keymap
shows other hints and is left to the terminal. Codex's title stays on Action Required from one
approval to the next, so a different command or edit on the tab is a new prompt with a card of its
own, and a key pressed for the one before is not typed into it.

### omp and pi

omp (tried with 18.4.1) sets a title too, `π ⠹ Run the tests` while it works, `π ! Run the tests`
while it waits and `π > demo` when idle, and the status comes from it once omp has set one since it
started. The rest comes from its session file. omp notes, for each terminal, the session it last
opened there (`terminal-sessions/<tty>` under `~/.omp/agent`), a note it never removes, so SlyTerm
trusts it only while an omp is in front on that terminal and in the folder the note names. The
session file it points to has the title omp gave the session, the call it is making, with the intent
omp has the model give for each call, and the last reply. A question from omp's `ask` tool shows on
the card with its options, and waits for you in the terminal like a tool approval, which omp asks
for only when its `tools.approvalMode` is not the default. omp also rings the terminal bell when a
turn ends or it asks something, which marks the tab as well. Until omp has written the session's
first reply there is no file, and the card has no text.

pi sets a title that never changes, and does not ask for permission, so it is read from its session
file alone: under `~/.pi/agent/sessions/`, in a folder named after the working folder, the file
named by `--session` or `--session-id`, else the newest one written there since pi started, when no
other pi, in any terminal, runs in that folder. pi writes a message once it is finished, so while a
reply is being written the last line is the prompt or the tool results it answers, and the tab shows
it working.

### Gemini CLI and Qwen Code

Gemini CLI and Qwen Code are read from their titles alone. Gemini CLI's, with its dynamic window
title on, as it is by default, is `✦  Working…` or `⏲  Working…` while it works (`✦` followed by
what the model is thinking, when it is set to show that), `✋  Action Required` while it waits and
`◇  Ready` when idle, each followed by the folder. Qwen Code's starts with `◐` while it works and
`✳` while it waits, and has no mark when idle. That gives the strip its marks and a card that only
says a turn finished or something waits: SlyTerm reads no file of theirs, answers neither and does
not list them in Bring In, where their tab comes across as a shell tab.

### Terminal notifications

Any program can ask for your attention with one of the two escape sequences terminals commonly take
as a notification: `OSC 9` with a text (`ESC ] 9 ; text BEL`) or `OSC 777` with a title and a body
(`ESC ] 777 ; notify ; title ; body BEL`). SlyTerm marks the tab as a bell does and, with the card
on, shows one: yellow like a finished turn, with the tab's name, the notification's title (or
"notification") and its text, cut to its printable characters and about 300 of them. It fades like a
finished card. A tab whose agent SlyTerm already reads gets that agent's card instead, which says
more. An `OSC 9` whose text is a number, or a number and a `;` before the rest, is one of ConEmu's
numbered commands rather than a notification: `9 ; 4 ; …`, the progress report, is passed on to the
terminal view as before, and the others are dropped. A text that only begins with a digit, such as
`3 tests failed`, is a notification. Nothing in the tab you are typing in is news, so to try one,
run this and click into another app before it fires:

```sh
sleep 5; printf '\033]777;notify;Build;All 42 tests pass\a'
```

### Focus reports

A program that asks for focus reports (`ESC [ ? 1004 h`) is told whether its terminal has the
keyboard. SlyTerm says yes to the selected terminal tab only while the overlay is interactive and
its window has the keyboard, and no to every other tab, and to all of them while the game has the
keyboard: in click-through, with the overlay hidden, or with another app in front. So a program that
keeps its notifications for when nobody is looking at it sends them while you play.

## Bringing a session in from another terminal

You have an agent halfway through something in iTerm2, the game starts, and you would rather carry
on in the overlay than keep alt-tabbing out of it. macOS cannot move a running process from one
terminal app to another (a process is tied to the terminal it was started in, for good), so what
SlyTerm moves is the **state**: it opens a tab here that picks the work up where the other one left
it.

Three kinds of thing can come in, and each comes across differently:

- **A coding agent's conversation**, from Claude Code, Codex, omp or pi. SlyTerm stops it where it
  is, then runs the agent's own resume command here, in the session's folder: `claude --resume
  <id>`, `codex resume <id>`, `omp --resume=<id>` or `pi --session <id>`. Same session id, same
  transcript, so the conversation continues rather than starting over. It takes a few seconds, while
  the old one shuts down. A Codex whose turns run in its background server, as they do by default
  since Codex 0.157, keeps its turn running there while the one in the other terminal stops, and
  `codex resume` here picks it up where it is. One that runs its turns itself, as with
  `--no-daemon`, stops with its turn. A Claude conversation you have not typed anything
  into yet has no transcript, so bringing it in gives you a fresh one; a Codex, omp or pi that has
  not written its session file yet, or whose file SlyTerm cannot find, is listed as a plain shell
  tab.
- **A background Claude**, started with `claude --bg` or sent to the background by typing `/bg`
  in it. That one lives in Claude's own daemon rather than in a terminal, so nothing has to be
  stopped: SlyTerm runs `claude attach <id>` here and you are back in it, uninterrupted.
- **A plain shell tab.** You get a new tab in that shell's folder, with whatever it was running
  typed at the prompt but *not* run, so you can read it before pressing Return.

### The picker

Open the picker with `⌘⇧T` while the terminal has focus, with "Bring In a Session…" in the menu bar
item, or with a right-click on the `+` of the tab strip. It lists what is running in your other
terminals, in a group per agent (Claude Code, Codex, omp, pi) and then plain terminal tabs, each row
with its folder, which app it is in, how long it has been going and what it is doing right now:
Working (mid-turn), Waiting (the agent is waiting for your answer in that tab), Idle, Background, or
"Already here" for one of SlyTerm's own tabs, which it offers to switch to instead. A Codex, omp or
pi row takes its status from the session file, so a Codex waiting for an approval shows as Working.
A Claude conversation is listed under the title its own `/resume` picker gives it, a Codex one under
its thread's name or else its first prompt, an omp one under its title and a pi one under its name
or else its first prompt; a shell tab is listed under what it is running, or the name of the shell
when it is sitting at its prompt. Type to filter by name, folder or app, `↑` / `↓` to move, `Return`
to bring the selected one in, `Esc` to close. The panel stays within the screen however many rows it
gains, and it can be dragged by its title if it is covering something you want to see.

### Move, Copy, Attach

`Return` does the obvious thing for the row it is on: Move for an agent in a terminal, Attach for a
background Claude, "Open Folder Here" for a shell tab. `⌥Return` on a Claude Code, Codex or pi
conversation makes a **copy** instead: `claude --resume <id> --fork-session`, `codex fork <id>` or
`pi --fork <id>`, a new conversation with the same history behind it, and the one in iTerm2 left
running. That is the one for a side question about what it already knows while the first carries on
working. omp has no copy.

Moving an agent that is mid-turn interrupts it, and whatever it was in the middle of writing is
lost; the transcript on disk is not, which is why the resumed session still knows everything up to
that point. So SlyTerm asks before interrupting a session it can see is working, or waiting for an
answer to a permission prompt or a question, except a Codex whose turns run in its background
server, whose turn a move does not interrupt; a Codex that runs its turns itself is asked about
like the others. Turn the question off in Settings › General ("Ask
before interrupting an agent that is working or waiting for an answer"). To avoid it altogether with
Claude, type `/bg` in the source tab first: the session moves into Claude's daemon without being
interrupted, and the picker then offers Attach, which stops nothing at all.

To stop the session, SlyTerm sends it `SIGTERM` and waits up to 5 s. A Claude Code in iTerm2 that
is still running then gets two Ctrl-C typed into its iTerm2 session and 3 s more, since it quits
on a second Ctrl-C; no other agent or terminal gets them. If it is still running after that, nothing
is resumed and a toast says it could not be stopped.

By default the tab a session came from is closed once it is here, so you are not left with a dead
prompt in iTerm2 to go back and tidy up. Only iTerm2 and Terminal.app can be told to close a tab, so
the checkbox is off for every other terminal, and the first time you use it macOS asks once whether
SlyTerm may control that app. Terminal.app only knows how to close a whole window, so a tab there
is closed when it is alone in its window and left where it is otherwise. Untick "Close the tab a
session came from after moving it" in Settings › General to keep the source tab.

### From the source tab

You do not have to go and find the session in the picker: the tab it is in can hand itself over.
Inside a Claude Code conversation, a `!` command has the session id in its environment; from a
plain shell, the tty is enough.

```sh
! open -g "slyterm://teleport?session=$CLAUDE_CODE_SESSION_ID"   # inside a Claude Code conversation
open -g "slyterm://teleport?tty=$(tty)"                            # from a plain shell
```

`-g` keeps the terminal you typed it in at the front, so handing a session over never takes the
screen from the game. `session=` takes a Codex, omp or pi session id too, and `pid=` the pid of
any agent in the picker.

### Sending a session back

A session can go the other way, from a SlyTerm tab to iTerm2, Terminal, Ghostty or WezTerm:
right-click the tab in the strip (or Control-click it) and choose "Send Back to iTerm2", choose
"Send Tab Back to iTerm2" in the menu bar item for the tab in front, or quit with "Send Back and
Quit". The menus name the terminal that tab would go to.

A tab brought in from one of those four (moved, copied, attached or opened as a folder) remembers
it and goes back there. Any other tab goes to the one chosen in Settings › General › Agents
("Send sessions back to"), and when that one is not installed, to iTerm2, else Terminal.
The memory lasts as long as the tab: a tab restored at launch is a new shell and has none. Ghostty
counts only from 1.3, the first version with an AppleScript dictionary (`NSAppleScriptEnabled` in
its Info.plist); WezTerm counts when its bundle has the `wezterm` command line in `Contents/MacOS`.
Warp, kitty, Alacritty and VS Code cannot be told to open a tab and run a line in it.

- **An agent's conversation** is stopped here the way a move stops it (`SIGTERM`, 5 s, then for
  Claude Code two Ctrl-C into SlyTerm's own tab while Claude is still in front of it, 3 s more).
  Then a new tab opens in the other terminal's front window (WezTerm's first listed window; a new
  window when there is none, and always a new window in Terminal), and `cd '<folder>'; <resume
  command>` is typed and run there (`;`, so the session still resumes where that terminal is not
  allowed into the folder). SlyTerm's tab closes, and when it was the last one the tab that
  replaces it does not run the startup command. It asks before interrupting a session that is
  working or waiting, like a move, with the same setting.
- **A background Claude you attached** is not stopped: SlyTerm closes its tab, which detaches it,
  and runs `claude attach <id>` in the other terminal.
- **A plain shell** gets a new tab in its folder there. SlyTerm's tab closes, unless something is
  running in it.

"Copy to iTerm2", in the same menu for a Claude Code, Codex or pi conversation, runs the fork
command there instead (`claude --resume <id> --fork-session`, `codex fork <id>`, `pi --fork <id>`)
and leaves the SlyTerm tab running.

Nothing is stopped until the other terminal has answered: an Apple event for iTerm2, Terminal and
Ghostty, which is also when macOS asks, the first time, whether SlyTerm may control it, and
`wezterm cli --no-auto-start list` for WezTerm. A WezTerm that is not running is started without
being brought to the front, and SlyTerm waits up to 10 s for it to answer. A terminal started this
way (Ghostty is started by the Apple event) may open its own first window or tab as well, so the
session's tab can have an empty one next to it.

How each terminal gets its tab:

- **iTerm2**: `create tab with default profile` in the current window, then `write text`.
- **Terminal**: `do script`, which opens a window.
- **Ghostty**: `new tab in front window` (or `new window`) with a surface configuration whose
  `initial input` is the line and a newline, so the user's shell still starts and reads it.
  Ghostty 1.3 brings itself to the front for a new tab or window and has no option not to: when it
  takes the front within a second, SlyTerm gives the front back to the app that had it before the
  send-back (before the quit dialog, for "Send Back and Quit", which waits for it before quitting),
  through LaunchServices (`activate()` from a background app is refused since macOS 14). The game
  loses the keyboard for that moment, and a game in its own full-screen Space may see the Space
  switch and come back. LaunchServices also sends that app a reopen event, as a Dock click does,
  so an app with no window open may open one.
- **WezTerm**: its CLI, never through a shell: `spawn --window-id <id>` into the first window
  `list --format json` gives (or `--new-window`), then `send-text --no-paste --pane-id <pane> --
  <line>`. `--no-paste` because a bracketed paste would leave the line at the prompt, not run it;
  `--no-auto-start` because without it a WezTerm that is not running gets a windowless server and
  the tab opens where nobody sees it. Each call is given 5 s.

If the tab still does not open after the agent has stopped, the resume command is typed back into
SlyTerm's tab, or into a new one when something else is in front of that tab's shell, and a toast
says so; that tab keeps the origin. The other terminal is not brought to the front (Ghostty only
for a moment, see above), so the game keeps the screen. The folder is shell-quoted, and left out
if it contains a control character; the session id is checked as for a move.

"Send Back and Quit" is in the quit dialog, as its default button, whenever a tab runs an agent that
can be resumed elsewhere. It sends every such tab back at once, without asking about each agent
again (the dialog says a turn under way is interrupted), then quits; if one of them could not
be sent, SlyTerm stays open, the others are already gone, and a toast says why. The other tabs come
back at the next launch as usual. The dialog only appears while "Ask before quitting" is on.

### Attached sessions and hooks

A background Claude runs inside the daemon, not inside the tab, so its notify hook has no
`SLYTERM_TAB_ID` to report and cannot light up the tab you attached it to. The terminal bell still
can: set `preferredNotifChannel` to `terminal_bell` in Claude Code's settings and an attached
session marks its tab like any other. A session you moved rather than attached runs in the tab
itself and needs none of this, which is why Move is the default.

## Lookup

Point at something in your game (a quest in the journal, an item in your bags, the title of what
you have open), press `⌃⌥Q`, and the page your game's sources have for it opens in a **web tab**
next to your terminals, never in your browser: a browser would come to the front and take the
keyboard, which is the one thing you cannot afford mid-fight. A small message next to the pointer
says which page is opening and on which site (`Guide: Dragon scimitar · OSRS Wiki`), or what was
read and which game was asked when nothing matched (`No guide on Dofus for “Hogger”`). When the
game came from the fallback, with "Detect the game from the app in front" on and another game
naming an app, a second line says so for 4 seconds: `Dofus answered; no game claims World of
Warcraft. Set the game app in Settings › Lookup.` With one game and no game app set, there is no
second line. Typical time from key press to
the tab: 200 to 400 ms, plus about half a second for the page.

The overlay does not take focus when a guide arrives: if it was hidden it comes back in
click-through mode, so your next click and keystroke still go to the game. Press `⌃⌥Tab`, or click
the eye button, when you want to read and scroll it.

The pointer is what matters, not the keyboard focus, so it works in both interact and
click-through mode, and while the game is fullscreen.

### How it decides

Fastest path first:

1. **Which game is being played:** the one whose app owns the window under the pointer, else the
   one whose app is in front, else the game picked by hand in the menu bar's **Lookup Game**
   submenu. The app under the pointer and the app in front are both asked, in that order, because a
   pointer resting on a browser or the desktop does not mean you stopped playing. With no game
   configured at all it says so instead of guessing.
2. **The line under the pointer.** It screenshots a 900×48 pt band around the pointer and reads it
   with Apple's on-device text recognition, in the game's language. The line under the pointer is
   stripped of what a game draws around a name (progress counters like `(2/6)`, levels like `Niv.
   50` or `Lvl 50`, a leading `[15]`, stack counts like `x3`, list bullets, plus whatever strip
   patterns the game adds) and matched, accent- and case-insensitive, against the offline index of
   every indexed source of that game. Best score wins, ties go to the source you put first.
   Truncated names still match.
3. **Around the pointer.** Nothing convincing under the pointer: it looks around it, because the
   name of an item in your bags or your inventory is in a tooltip, not under the pointer. Every
   source that can be asked is asked about the line under the pointer at once, and if one names a
   page, that opens: a quest in the WoW quest log is no slower than it was. Meanwhile it
   screenshots the window under the pointer (the game's own when one of them is, the whole display
   when none is), reads it, and groups the lines the way they sit on screen: short stacked lines are
   a tooltip or a panel, lines side by side on one row (`One-Hand … Sword`) belong together, and
   lines on different fills never do. A tooltip has a fill of its own, so it stays apart from the
   quest log or the panel it is drawn over, however close their text.

   A group is taken for a **tooltip** when one of its lines under the first is a line only the
   game's tooltips have (`Sell Price:`, `Use:`, `Rank 1`, `30 sec cooldown`, `Niveau 56 • Poil`,
   `POIDS`, `2 more options`), or when its only line is one, as the mouseover text at the top left
   of Old School RuneScape is. Those are the game's [tooltip lines](#advanced-patterns). A group
   right above a tooltip, a text height or so over it, is its name set apart (RuneLite's `Use Pot`
   over its `Weight:`), and tooltip groups stacked on one another are one tooltip drawn in
   sections, the way Dofus draws an item's name, its weight and price, and its description on
   panels of their own. A tooltip line is never a candidate itself.

   The candidates are, in order: the line under the pointer (or, when the pointer rests past the
   end of a short line on its row, as it does on a quest log's row, that line); then the first line
   of every tooltip, nearest tooltip first, **wherever it is on screen** (WoW puts an action bar's
   tooltip in the bottom-right corner, fifty text heights from the button, and Dofus an item's to
   the left of the whole inventory window); then the first line of every other group, nearest the
   pointer first. A line set bigger than the rest of its group, as a tooltip's name is, counts for a
   little more and is a candidate even when it is not the first. The group the pointer is on a line
   of comes after the others: its heading, a zone or a category, is what you meant least.

   Beyond the tooltips, only the candidates within about ten text heights of the pointer are tried,
   and one opens only when something recognises it: an offline index or the sources' own searches,
   asked about the first few the index does not know, all at once, no more than three texts in a
   press, each asked of every source that can be asked. For a title next to the pointer, either has
   to name a page that is that text letter for letter, give or take one letter in ten: not a longer
   name the text is part of, nor a shorter one inside it, so "The Defia" left of a quest title by a
   tooltip does not open "The Defiant". The line under the pointer is held to the looser rule of a
   text you pointed at. The first recognised in that order wins.

   The window is read with the fast text recognition first. When nothing it read is recognised, it
   is read once more with the accurate one, which is three to four times slower but reads what the
   fast one garbles (a pixel font like Old School RuneScape's, where `Use Pot` comes out `USÈ
   Pot`), and the texts that reading adds are tried the same way, never one already asked. A tooltip
   typically takes under a second, most of it the site answering, and one the fast pass misread
   about a second more. A game with no index whose sources are all plain search URLs has nothing to
   recognise a guess with, and goes straight to step 5 when there is text under the pointer.
4. **The whole window.** Still nothing, in a game with an index: the best match anywhere in that
   window, under stricter rules. Among equal matches the biggest text wins, which is the title of
   the selected quest in the journal, so the hotkey also works with the pointer anywhere.
5. **The sources' own search.** Still nothing: the text under the pointer, else the first tooltip's
   name, else the title nearest the pointer, goes to **every** source that can be asked, each its
   own way (a MediaWiki's `opensearch`, Wowhead's suggestions, a Weebly site's search page,
   DofusDB's item API), and the page one of them names opens if the name that came back still reads
   as the text asked for. A text they already turned down in this press is not asked again, and
   neither is a title near the pointer the press had no room left to ask about: here it would only
   be held to the looser rule of the line under the pointer. Failing that, and for those two, the
   **first** source's search URL opens, which is the one thing every source can do. This is what
   finds a quest that lives as a section of a region page rather than on a page of its own.

Every source that can be asked is asked at once, wherever the lookup asks. When more than one names
a page, a page named exactly the text asked for wins over one that only comes close, and among
those the source you put first: a Weebly site's search, which matches any of the words, answers
`Wabbit en feu` for `Poils de Wo Wabbit`, and DofusDB's page of that very name opens instead. Once
one site has named a page, the others have one second more to answer, so a site that is slow or
down costs a second rather than a timeout. The message says which site answered.

### Press again for the next guess

Press `⌃⌥Q` again without moving the pointer (6 points of slack, within 10 seconds of the last
answer) and the next thing near it that is recognised opens instead of the same page: the next
candidate in the same order, further and further from the pointer, including what was too far for
the first press. When the press already knows what the next one will open, the message says so:
`Guide: Thunderfury  ·  ⌃⌥Q again: Bindings of the Windseeker`. Once nothing new is left it goes
back to the first page and round again, and if it only ever found one it says `Nothing else near
the pointer`.

Move the pointer, wait ten seconds, ask for another game or go from a dry run to a real press, and
the next press starts over. So does a press after the screen changed under a pointer that did not
move, as a list does when you scroll it with the wheel: each press again reads the line on the
pointer's row first, and starts over when it reads differently.

### Pick mode

When you would rather choose, press `⌃⌥⇧Q`. The screenshot it just took is frozen over the screen,
dimmed, with every line near the pointer lit and labelled with a key: press the key to look that
line up. The keys go by where they sit on the keyboard, the home row first, then the rows above and
below it, and each label shows the letter that key types on your layout, so on AZERTY you see `Q`
where QWERTY shows `A`. They go first to the group the pointer is in, nearest line first, then down
each tooltip, nearest tooltip first wherever it is, then down the other groups, nearest first, so a
tooltip's name gets one of the first keys.

The screenshot is read with the fast recognition, or the accurate one when the fast one found no
tooltip with a name in it, since the line you pick is the text looked up: that is about half a
second more before the frame freezes. The hint at the top names the game's first source ("Press a
key to look it up on Dofus Wiki"). `Return` takes the highlighted line, which starts on the one
`⌃⌥Q` alone would have gone for; `Tab`, `⇧Tab` and the arrows move the highlight; `Esc` cancels,
and so does `⌃⌥⇧Q` pressed again. `⌃⌥Q` while the picker is up takes the highlighted line.

It is keyboard first because moving the mouse closes the game's tooltip, but once the frame is
frozen you can also click a lit line, and a click anywhere else cancels. The picker shows the
screenshot its own key press took, and nothing else. When it closes, the keyboard goes back where it
was: to the game when the game had it, whether or not the terminal is in click-through.

### Permission and caches

The lookup needs the **Screen Recording** permission. The first press asks for it; grant SlyTerm in
System Settings › Privacy & Security › Screen Recording and relaunch the app. Nothing is captured
outside a hotkey press.

macOS applies a grant only to a process started after it, so SlyTerm notes at launch whether it
had one (`CGPreflightScreenCaptureAccess`, which captures nothing). Settings › Lookup › Permission
and the setup assistant's Games step then show one of three lines: "Screen Recording: not granted"
(orange), "Screen Recording: granted", or, when it was granted since launch, "Screen Recording:
granted, reopen SlyTerm to use it" (orange) with a **Reopen SlyTerm** button. The button quits as
⌘Q does, the quit confirmation included, and a short shell started as SlyTerm quits waits for it to
exit and opens the same bundle again. Run as `.build/debug/SlyTerm`, outside a bundle, there is
nothing to reopen: Settings keeps **Open System Settings…** and the assistant shows no button.

Each site's index is cached as one JSON file per host under
`~/Library/Application Support/SlyTerm/lookup/`, loaded and refreshed in the background at launch
and rebuilt when it is more than a week old. The first lookup on a site that has never been indexed
waits three seconds for the crawl and then goes on to the search rather than leaving the hotkey
silent; the crawl carries on and installs itself when it is done.

### Where guides open

The page arrives styled for its site: see [Reader mode and blocking](#reader-mode-and-blocking) for
what that means on a wiki, on Wowhead and on anything else. It goes to the web tab the lookup used
last, docked or floating, or to a new one when that one is playing something: see
[The lookup's tab](#the-lookups-tab).

Pick "In your browser" in Settings › Web › Open guides and guides go to your browser instead;
"Keep the game in front, load the page behind it" then leaves the game where it is and loads the
page behind it, for a second screen. Web tabs stay on the strip either way, for everything else.
Settings › Lookup says whether Screen Recording has been granted.
`open -g "slyterm://lookup?dry=1"` shows what would open without opening it, which is handy for
tuning.

## Games and sources

Settings › Lookup holds the games. A game is a name, the app it runs in, the language its text is
in, and an ordered list of **sources**. A source is a site: a name and a search URL with `{query}`
where the text goes, the way a browser's custom search engines work, as in
`https://oldschool.runescape.wiki/w/Special:Search?search={query}`. That is all you have to type.
SlyTerm then asks the address what sits behind it and says so under the table: "MediaWiki · 41 726
pages indexed", "Website · no index", or "Detecting…" while it looks, and "The URL needs {query}
where the text goes" when you left that out. What it finds (the kind of site, its home page, the
address its list of pages comes from) is the whole difference between a search box and an offline
index that lands on the exact page.

`+` under the games list offers the presets (World of Warcraft as a submenu, one row per version)
and **Custom Game…**; `−` removes the selected game. Under the sources table, `+` and `−` add and
remove a source and `▲` / `▼` reorder it. The order is worth getting right, and the caption says
why: "Sources with an index (a wiki or a sitemap) are matched offline first; then every source that
can be asked is: a page named exactly the text wins over a near one, and among equals the source
higher up. The first source's search page is the fallback."

**Text language** is what Apple's text recognition reads the screen in: Automatic, or one of its
languages. A game set to several (the Dofus 3 preset reads English and French) shows as an item of
its own. **Game app** is the app the game runs in, picked from what is running, or "Any (choose the
game by hand)". "Detect the game from the app in front" is what uses it, and "Otherwise use" names
the game that answers when nothing recognisable is in front. The menu bar's **Lookup Game** submenu
is those same two settings while you play: "Automatic (from the app in front)" toggles the
detection, and picking a game is picking the one "Otherwise use" holds.

### Advanced patterns

**Advanced**, under the sources table, holds two lists of the game, one regular expression per
line, where a pattern that does not compile is logged and ignored:

- **Strip patterns**, removed from what was read off the screen before matching.
- **Tooltip lines**: lines only the game's tooltips have. A group of lines with one of them is a
  tooltip, and its first line is tried before anything but the line under the pointer, wherever the
  game drew it (see [How it decides](#how-it-decides)). A line that also shows anywhere in the
  game's static interface does not belong here: the panel it is on would be taken for a tooltip.
  They are matched against the line as it was read, before the strip patterns. Prefix a pattern
  with `(?i)` to ignore case, and anchor it with `^` when you can.

The presets have both built in, on top of what you type here, and they come with the app: a game
made from a preset gets whatever a later version of SlyTerm knows, and the boxes show only what you
added.

- The World of Warcraft presets strip the `(Dungeon)` a quest log suffixes and know an item's and a
  spell's tooltip lines in English and in French (`Sell Price`, `Prix de vente`, `Use:`, `Equip:`,
  `Binds when`, `Lié quand`, `Requires`, `Item Level`, `Durability`, `Unique`, `Rank 1`, `15 Mana`,
  `Instant`, `30 sec cooldown`, `Tools:`, `Reagents:` and so on).
- Dofus 3 knows the line under an item's name (`Level 56 • Hair`, `Niveau 56 • Poil`), `WEIGHT`
  and `POIDS`, `AVERAGE PRICE` and `PRIX MOYEN`, and the tooltip's pin hint. Dofus Retro has none
  yet.
- Old School RuneScape and RuneScape know the mouseover text's `2 more options` and RuneLite's
  `Weight:`, and strip what the mouseover text and RuneLite's box by the pointer write around a
  name: the action in front of it (`Use`, `Take`, `Wield`, `Attack`, `Talk-to`, `Chop down`,
  `Climb-up` and the rest, case-sensitive and only before a capital, so "Enter the Abyss" keeps its
  first word), `/ 2 more options`, a monster's `(level-2)` and the `-> Bucket` of an item used on
  another. `Use Pot / 2 more options` is looked up as `Pot`.

Under them are the reader CSS and hidden selectors of the selected source, which are appended to
what web tabs already know about that host.

### Import and export

**Import…** and **Export…** pass one game around as JSON, saved as `Dofus.slyterm-game.json`: a
game somebody worked out for a site is worth passing on. An import is always an addition, never an
overwrite: it comes in with fresh identifiers and sits next to what you already have.

### The presets

A fresh install starts with the first of them, Dofus, configured.

- **Dofus**, two presets in a submenu of their own, both in English and reading English then
  French text:
  - **Dofus 3** (the Dofus Wiki, then DofusDB), the current game. The
    [Dofus Wiki](https://dofuswiki.fandom.com) is an English Fandom wiki of some 31 000 articles,
    about 2 000 of them quests with their steps, and items and monsters besides: its titles are
    matched offline like any MediaWiki's. [DofusDB](https://dofusdb.fr/en), the encyclopedia, is
    asked about items: the name in an item's tooltip opens its page, as
    `dofusdb.fr/en/database/object/336` for `Gwandpa Wabbit's Staff`. DofusDB has no index (some
    22 000 items, 50 to a request), but its API finds an item by name, with the accents the
    recognition dropped and an `i` it read as `l` forgiven (`Gwandpa Wabblt's Staff` still finds
    it), and by the name's longest word when a slip elsewhere keeps the whole name from matching.
    It is detected from its address, and the address's first part is the language it is asked in:
    `https://dofusdb.fr/fr/database/items?q={query}` for French, and `es`, `de` and `pt` the same.
  - **Dofus Retro** (the 129Dofus Wiki), the 1.29 game Ankama runs next to Dofus 3, sometimes
    called Dofus Classic. The [129Dofus Wiki](https://129dofus.fandom.com) has some 5 000
    articles: items, monsters and areas, and about half the quests. DofusDB has no Retro data. Its
    app is not known to the preset, so pick the game by hand or set its app in Settings, and it has
    no tooltip patterns yet.

  For French guides, [Dofus pour les Noobs](https://www.dofuspourlesnoobs.com) works as a source
  from `https://www.dofuspourlesnoobs.com/apps/search?q={query}`: a Weebly site, whose sitemap gives
  every page name away in its slugs, so a quest is matched offline against ~2 500 pages, with a
  reader stylesheet of its own.
- **World of Warcraft** (Wowhead), one preset per version because Wowhead keeps one database per
  version: Retail at `wowhead.com`, Classic (the Anniversary, Era and Hardcore realms) at
  `wowhead.com/classic`, Burning Crusade Classic at `/tbc`, Mists of Pandaria Classic at
  `/mop-classic` and WoW: Forever at `/forever`. They sit in a submenu of their own under `+`. No
  sitemap, so no index (Wowhead's addresses are numeric ids), but the endpoint behind each
  database's search box names the exact page, so a quest opens as `wowhead.com/classic/quest=…` and
  an item as `wowhead.com/item=…`. When several pages share a name it prefers the quest, then the
  item, the NPC, the zone, the achievement and the spell. Every version is the same app to macOS, so
  with several of them configured the one picked by hand answers when World of Warcraft is in
  front.
- **RuneScape**, two presets in a submenu of their own:
  - **Old School RuneScape** (OSRS Wiki). A MediaWiki: every article title is listed through its
    API and matched offline, and `opensearch` catches what the recognition misspelled. Point at an
    item and the mouseover text names it at the top left of the game, which is a tooltip wherever
    the pointer is.
  - **RuneScape** (RuneScape Wiki), the modern game, RS3 to its players. The OSRS wiki's sibling,
    read the same way; at some 92 000 articles it is the largest index the app builds.

### Any other site

Any MediaWiki-based wiki works from one URL, Fandom and wiki.gg included. Paste the wiki's own
search address with `{query}` in it and the detection finds its `api.php` at the root or under
`/w/`, lists its articles from there, and reads the wiki's `server` and `articlepath` so a title
becomes the address that wiki really serves it at, subdirectory and all. Anything else is indexed
from `sitemap.xml` when it has one, and a site with neither is still a search URL, which is all the
fallback needs.

### Where games are stored

All of it lives in the same preferences as everything else: `lookupGames` is the games as a JSON
array, `lookupActiveGame` the identifier of the one picked by hand, and `lookupAutoDetect` whether
the app in front gets to pick instead. The JSON is what Export… writes, one game at a time; in it,
`stripPatterns` and `tooltipPatterns` are the two Advanced lists as you typed them, and `preset` is
what brings the built-in ones along:

```sh
defaults write com.charlesmelki.slyterm lookupAutoDetect -bool false
defaults read com.charlesmelki.slyterm lookupGames
```

## Web tabs

A web tab is a page inside SlyTerm: a guide the lookup opened, or anything typed into an address
field, video included. It sits in the SlyTerm window next to your terminals, and it can be popped
out into a floating window of its own over the game and put back later. Web tabs are not numbered
like your terminals: `⌘1`…`⌘9` count terminals only, so your tab numbers never move because a page
is open.

### Web tabs on the strip

Each web tab is a square at the right end of the strip, next to `+`, in the order they were opened,
with no title, so the terminals keep the room for theirs. A square shows its site's icon or, until
it has one, a book for a page the lookup opened, a play symbol for a page with a video and a globe
for anything else. Hover it and a label shows at once beside the squares, over the terminals' tabs:
the page title, followed by " · click to put it back" for a floating one, and its key, `⌥⌘1` for
the first square up to `⌥⌘9` for the ninth. The selected square is highlighted, a page that is playing puts a
small speaker on its square (sound, or a video in view; a muted loop in a corner does not count),
and a floating one is drawn dimmed with a dashed outline: clicking it puts the page back into the
SlyTerm window and selects it. A middle-click on a square closes that web tab.

The squares never squeeze the terminals below 44 pt each. The web tabs that do not fit go behind a
last `…` square ("N more web tabs"), which is highlighted when the tab in front is one of them and
carries the speaker when one of them plays; clicking it lists them by title, with their `⌥⌘` key
up to the ninth, and picking one does what clicking its square would.

With no web tab open, one dimmed globe holds the place, so nothing in the strip shifts when a page
comes or goes; clicking it, like `⌘G`, opens the active game's first source. The squares stay
when Settings › Web sends guides to your browser.

### The toolbar and the address field

Along the top of a web tab, from left to right: back and forward, the address field, find, reader
mode, pop out ("Pop out into a floating window", or "Put back into the SlyTerm window" while it
floats), open in your browser and, on a floating window only, `×` to close it.

- **The address field** shows the page title, or its host when it has none, with the address as its
  tooltip. Click it in interact mode, or press `⌘L`, and it shows the address, selected, ready to be
  typed over. `Return` opens what you typed in this tab and `⌘Return` in a new web tab, in front;
  `Esc` cancels and gives the page the keyboard back. A web address opens as typed and a bare host
  such as `wowhead.com` as `https://` (`http://` for `localhost` and an IPv4 address); anything
  else, `https://` with no host included, is a search, sent to the address in Settings › Web ›
  "Search with", DuckDuckGo by default. Nothing but an `http` or `https` address ever
  comes out of the field. `⌘C`, `⌘V`, `⌘X` and `⌘A` work in it.
- **Reader mode**: the button switches between reader mode and the full page, and names the mode a
  click takes you to. On a streaming site, where the reader never applies (see
  [Reader mode and blocking](#reader-mode-and-blocking)), it is disabled, with the tooltip "Reader
  mode is off on streaming sites".
- **Open in browser**, the compass, hands the current page to your real browser, honouring "Keep
  the game in front, load the page behind it".

### Keys in a web tab

While a web tab is in front in the SlyTerm window:

- `⌘←` / `⌘→` back and forward, `⌘R` reload, `⌘+` / `⌘-` / `⌘0` zoom (kept in `guideZoom`, one for
  every web tab, and the "Page zoom" slider in Settings › Web, 50% to 200%, which changes open
  pages as it moves), `⌘C` copy, `⌘V` paste and `⌘X` cut, into the page's own fields too (a site's
  search box, a sign-in form), `⌘A` select all. The terminal font is not touched.
- `⌘F` find, `⌘E` find the selection, and `⌘G` / `⌘⇧G` the next and previous match while the find
  bar is open.
- `⌘L` the address field. In a terminal, `⌘L` opens a new, blank web tab with its address field
  ready.
- `⌘G`, outside find, switches between the terminal and the last web tab you had in front in the
  SlyTerm window, and opens the active game's first source when there is none.
- `⌃Tab` / `⌃⇧Tab`, `⌘⌥←` / `⌘⌥→` and `⌘⇧[` / `⌘⇧]` go through the web tabs in the SlyTerm window;
  from a terminal they go through the terminals.
- `⌥⌘1`…`⌥⌘9` go to the web tab of that square, as a click on it would, putting a floating one back.
- `⌘W` closes the web tab and shows the terminal again. `⌘T` opens a new, blank web tab with its
  address field ready; a new terminal is `+` on the strip, or `⌘T` from a terminal.
- `⌘⇧T` reopens the web tab closed last, as browsers do, in the SlyTerm window; again for the one
  before, up to ten. With none left it beeps. From a terminal, `⌘⇧T` opens
  [Bring In a Session](#bringing-a-session-in-from-another-terminal) instead.
- Space, Page Down and the arrows scroll the page once the overlay has the keyboard.

A floating window takes the same page keys (`⌘←` / `⌘→`, `⌘R`, `⌘F`, `⌘E`, `⌘G` / `⌘⇧G` while
finding, `⌘C`, `⌘V`, `⌘X`, `⌘A`, `⌘+` / `⌘-` / `⌘0`), plus `⌘L`, `⌘T` for a new web tab in the
SlyTerm window, `⌘⇧T` to reopen a closed one there, `⌥⌘1`…`⌥⌘9`, `⌘W` to close it, `⌘Return` for
Fullscreen, `⌘,` for Settings and `⌘Q`.

### Links

- A link that asks for a new window (`target="_blank"`, `window.open`) opens a new web tab, in
  front. A page opens one only in answer to a click or a key, and at most three in five seconds: a
  pop-up it tries on a timer, or a burst of them, is dropped. The new tab does not keep a link back
  to the page that opened it (see [Troubleshooting](#troubleshooting)).
- `⌘`-click or middle-click on a link opens it in a new web tab behind the one you are on.
- Every other link stays in the tab, whatever site it goes to.

### Floating windows

The pop-out button moves the page, as it is, into a window of its own over the game, and the SlyTerm
window goes back to the terminal it showed before. When the page is playing a video, the window
opens filled with it, as the site's own fullscreen would fill it (see
[Streaming sites, DRM and fullscreen](#streaming-sites-drm-and-fullscreen)). Put it back with the
same button or a click on its dimmed square in the strip; putting it back undoes the fill if popping
out made it and it is still on, and brings the SlyTerm window back if it was hidden. `×` on its
toolbar, or `⌘W`, closes it. Several web tabs can float at once.

- **The window** is the page on the terminal's translucent background, with rounded corners,
  resizable from its sides and its bottom down to 240 × 160 pt, and its toolbar across the top,
  which covers the top edge as the strip does the SlyTerm window's. The toolbar is the handle: drag
  its empty space to move the window. Since the strip may be hidden, the toolbar shows the mode
  itself, left of its back button: the strip's green dot in interact mode, and in click-through an
  orange dot on the strip's click-through brown. The docked toolbar has neither.
- **Where it opens.** A page opens where the last floating page was, and a video that is playing,
  or filling the page, where the last floating video was; each is saved when you finish moving or
  resizing a window of its kind. A page with a paused video opens as a page. The first page opens at
  440 × 560 pt next to the SlyTerm window, the first video 420 pt wide at its own shape, plus the
  toolbar, in the top-right corner of the SlyTerm window's screen, 16 pt in. A window that would
  land exactly on another floating one is moved 24 pt, and every one is kept on its screen.
- **A filled video keeps its shape.** While the page is filled with a video whose shape is known,
  resizing keeps the page at that shape, with the toolbar on top.
- **Hiding.** `⌃⌥H` and the strip's `–` hide the SlyTerm window only: floating windows stay until
  they are put back or closed. Panic hides them (see
  [Pausing from the game](#pausing-from-the-game)). The card that says what an agent did stays
  above them.
- **Fullscreen.** `⌃⌥M` or `⌘Return` in a floating window fills its screen with it, opaque, with
  the kept shape set aside and the other floating windows above it. Leaving puts it back where it
  was, and that frame, not the filled one, stays its remembered place. Closing it, putting it back
  or hiding it ends Fullscreen; panic hides it and fills it again when panic ends.

### Click-through and focus

Click-through follows the rest of SlyTerm: `⌃⌥Tab`, the eye button, the trackpad tap and the switch
when the terminal loses focus change every SlyTerm window at once. In click-through a floating page
lets every click through to the game and dims to the click-through level, except a video that is
playing, which has a level of its own: Settings › Web › Opacity › "Playing video", 85% by
default, in click-through and in interact mode alike, so the game shows through the picture. The
same holds in the SlyTerm window: with a web tab in front that is playing a video, the whole window,
the tab's toolbar included, takes the video level; the strip keeps its usual level. A paused
video goes back to the usual rule, opaque in interact mode.

A floating window's toolbar stays clickable in click-through, like the strip, dimmed with the rest:
its buttons work and dragging it moves the window. Its address field needs interact mode, since the
toolbar cannot take the keyboard in click-through: a click on it there shows "Click-through:
⌃⌥Tab to type here" for 2.5 seconds, with the combo from Settings › Shortcuts.

Clicking a floating page in interact mode gives it the keyboard, and clicking into the game from
there switches everything to click-through, as leaving the terminal does; so does hiding the
SlyTerm window while a floating one is up, which gives the keyboard back to the game. Putting back
a floating window that has the keyboard hands it to the SlyTerm window, and so does closing one
while the SlyTerm window is on screen and interactive; otherwise the keyboard goes back to the
game. A floating window never takes the keyboard on its own, and
neither does a page arriving.

### Pausing from the game

`⌃⌥V` pauses every web tab that is playing, docked or floating. Pressed when nothing plays, it plays
again what it paused, or else the tab that played last. A toast says what it did: "Paused" or
"Playing" followed by the page title (and how many more when there are several), or "Nothing is
playing" in orange. It is "Play / pause" in Settings › Shortcuts and "Play / Pause" in the menu bar
item, and `slyterm://playpause` does the same. It works by telling SlyTerm's own page to pause or
play, never with a keystroke.

Some players, often on music sites, keep their sound outside the page, where SlyTerm's script
cannot reach it. WebKit still hears the sound, so the tab counts as playing, and `⌃⌥V` holds
it by suspending all of that tab's media, then lets it go on again. A held page cannot play
anything, so the first click or key in it turns the hold into a plain pause, and the site's own
controls work as usual; loading another page lets go of it too.

Panic silences every web tab, suspending all of its media, sound kept outside the page included, and
hides the floating windows; leaving panic shows them again and lets each tab go on as it was. A web
tab in front in the SlyTerm window switches to the terminal, as described in
[Window and modes](#window-and-modes). Until panic ends the web tabs are gone from the strip and no
key brings one in front; a guide that arrives meanwhile stays out of sight (see
[The lookup's tab](#the-lookups-tab)), and `⌃⌥V` only says "Panic mode is on". Fullscreen pauses
and suspends nothing.

### Pausing on its own

With Settings › Web › Videos › "Pause videos when a guide opens or they go out of view" on,
as it is by default, videos pause at the moments you stop watching them. Sound with no video in
view, a podcast or music, is left playing.

- **A guide opens.** The lookup, press again and `slyterm://guide?url=` pause every video that is
  playing, in the SlyTerm window or floating, before the guide loads. `⌃⌥V` then plays them again,
  as long as nothing else is playing. A guide that arrives during panic leaves the videos panic
  silenced paused when it ends. A guide sent to your browser pauses nothing.
- **A video in the SlyTerm window goes out of view:** another tab comes in front of it (a terminal,
  another web tab, a new or a lookup's one), or the window hides. It plays again when it is back in
  front: its square clicked, `⌥⌘N`, `⌃Tab` or `⌘G` to it, or `⌃⌥H` showing the window. A window
  that comes back on its own, for an agent that needs you, leaves it paused; `⌃⌥V` plays it.
  Popping a video out is not leaving the view, and floating videos never pause for this.

Panic keeps its own suspension, whatever this setting says; leaving it with `⌃⌥H`, which hides the
window, leaves the video panic covered paused, to play again when the window comes back. Off, a
video plays on until you pause it.

### The lookup's tab

The lookup never replaces a show. A guide loads into the lookup's own web tab, the one it used last,
in the SlyTerm window or floating, unless that tab was closed, is playing something, or holds what
`⌃⌥V`, panic or [pausing on its own](#pausing-on-its-own) paused: then the guide opens in a new
web tab in the SlyTerm window, which becomes the lookup's tab. A web tab that `⌘G` or the empty
globe opened on the game's first source is the lookup's too when it has none. A tab in the SlyTerm window is brought to the front, a hidden overlay
coming back in click-through so the game keeps the keyboard; a floating one loads the page where it
is. `slyterm://guide?url=` goes the same way, and `slyterm://web?url=` always opens a new web tab,
in front, with the same rule for a hidden overlay.
During panic the page still loads, in the lookup's tab or a new one, suspended like the others, but
it does not come in front and no floating window shows. When panic ends, that tab is the one in
front in the SlyTerm window, or, if it floats, its window shows with the others.

### Reader mode and blocking

- **Reader mode** is what you get, on every site but the streaming ones: the article and its
  screenshots on the terminal's own dark, translucent background, no header, no sidebar, no footer.
  The toolbar button switches between reader mode and the full page, the site as its author made it.
- **The reader is per site.** SlyTerm carries a stylesheet for each of the two sites it was tuned
  on, Dofus pour les Noobs and Wowhead; one for MediaWiki, which serves the OSRS and RuneScape
  wikis, warcraft.wiki.gg and any Fandom wiki, with chrome and rails gone and the article at the
  full width of the tab (on Fandom also its navigation, cover image and featured video, and a dark
  Fandom theme is left as it is); and a generic one for everything else, which hides the header, the nav,
  the footer, the sidebar and the cookie banner and reads the rest in the system font. A light page
  is inverted rather than recoloured, so the guides keep their own colours and the screenshots are
  inverted back; a page that was already dark, Wowhead or a wiki in night mode, is left as it is.
  Whatever you typed into a source's Advanced reader CSS and hidden selectors is appended after all
  of that, so it wins.
- **Screenshots stay small** on a site whose layout SlyTerm knows (Dofus pour les Noobs today), so
  the text stays readable and the page short: a lone one is capped at a fraction of the tab, a run
  of them becomes a row of thumbnails. Click any screenshot to expand it in place, click again or
  press `Esc` to shrink it. The full page shows them at the site's size. Anywhere else images are
  simply held to the width of the tab.
- **Ads, the consent banner and the trackers are blocked in both modes**, always, from one list of
  hosts that holds for every site but the streaming ones. The page loads in about half a second
  instead of three seconds, and nothing pops up over the game. The slots a site serves from its own
  address are hidden by the same per-site entry the reader uses, in both modes too: a blocked ad
  leaves the same hole in the full page either way.
- **Streaming sites are left as they are**, with no reader and no blocking, and so is their player
  embedded in another page, such as a YouTube video in a guide: their players break under the
  reader's styling, and YouTube stops playing when its ad requests are blocked. They are
  YouTube, Netflix, Twitch, Kick, Prime Video, Disney+, Max, Hulu, Paramount+, Peacock,
  Crunchyroll, Apple TV and Apple Music, Spotify, Deezer, SoundCloud, Vimeo, Dailymotion, Plex,
  Canal+, france.tv, Arte and Molotov, subdomains included.
- **Find in page** with `⌘F`, or the magnifier in the toolbar: a bar opens under the toolbar and the
  page jumps to the first match as you type, every match highlighted and the current one in orange
  with its rank in the count. Halfway through a long quest, type a few words of the step you are at
  and you are there. `Return` / `⇧Return`, the arrow keys or `⌘G` / `⌘⇧G` step through the matches
  and wrap around; `Esc` closes the bar and leaves the match selected, so `⌘C` copies it. `⌘E`
  searches for whatever is selected in the page. Case and accents are ignored, so `dechet` finds
  *Déchet*. Following a link keeps the bar and its query on the new page, with the matches marked
  but no jump.

### Streaming sites, DRM and fullscreen

Services such as Netflix only offer their DRM, Apple's FairPlay, to Safari, so web tabs identify as
Safari: their user agent ends in `Version/… Safari/605.1.15`, with the version of the Safari
installed on the Mac. It is the same engine as Safari. Autoplay is allowed, so a video can start
without a click. `SlyTerm --drm-check` prints the user agent and whether a page is offered FairPlay
(see [Command-line modes](#command-line-modes)).

Real fullscreen would open a new Space and take the screen from the game, so it stays off. A site's
fullscreen button fills the web tab, or the floating window, instead: the video covers the page on
black, and the site believes it is fullscreen, so its own controls and subtitles stay on screen.
`Esc`, or the site's button again, goes back. Popping out a tab that is playing a video fills it
the same way. As in a browser, a player embedded in another page fills it only when that page lets
its frame go fullscreen.

### Memory

WebKit costs about 300 MB of helper processes while a web tab is open, and each web tab adds a page
of its own to that. Closing the web tabs you do not use gives their memory back, which
is why none is kept warm. Web tabs are not restored at launch.

## Settings

### The Settings window

The menu bar item is for doing: show / hide, a new tab, click-through, panic mode, Fullscreen, the
lookup and which game it asks, a new web tab, play / pause, opacity (terminal, click-through, playing video),
**Shortcuts…** (Settings on its Shortcuts tab), **Help** (the README's
[shortcut list](https://github.com/MushkyQT/slyterm#shortcuts) in your browser), resetting the
window position, **About SlyTerm** (the standard panel, with the version from `Info.plist`; the app
is in the Dock and ⌘Tab while it is open, as for Settings), quitting.
Everything that configures the app is behind **Settings…** in it, in six tabs:

- **General**: under Launch, restoring the last session's tabs, the logo animation and **Run Setup
  Assistant…** (see [The setup assistant](#the-setup-assistant)); under Agents, the card that says
  what an agent finished or asks, the sound a tab plays when it needs you, how long a finished card
  stays, asking before interrupting an agent mid-turn, closing the tab a session was brought in
  from, and which terminal sessions are sent back to; under Quitting, the quit confirmation.
- **Terminal**: font family and size, the default folder for new tabs and whether new tabs inherit
  the current one's, the startup command, the scrollback (lines kept per tab, for tabs opened after
  the change), Option as Meta.
- **Window**: background opacity, the dim level in click-through, switching to click-through on
  focus loss, the window level ("Above other windows", "Above the menu bar", the default, or "Above
  everything, for games that cover the terminal"), where the tab bar sits.
- **Shortcuts**: the nine global hotkeys and the trackpad tap.
- **Lookup**: the games and their sources, the language each game's text is read in, how the game
  is picked, whether Screen Recording has been granted (see
  [Permission and caches](#permission-and-caches)), and importing or exporting a game.
- **Web**: "Search with", the address that words typed into a web tab's address field go to, with
  `{query}` where they go (an address without `{query}` shows in orange and is not saved; emptying
  the field puts DuckDuckGo back); pausing videos when a guide opens or they go out of view (see
  [Pausing on its own](#pausing-on-its-own)); the opacity of a playing video; the page zoom of
  every web tab; and where guides open ("In a web tab inside SlyTerm" or "In your browser", see
  [Where guides open](#where-guides-open)).

Nothing there is modal: the terminal stays where it is and every change applies as you make it.

### The setup assistant

A fresh install opens a four-step window, and the terminal first appears when it closes:

1. **Welcome**: what SlyTerm does. **Use Defaults** closes it and changes nothing.
2. **Games**: "No, skip game lookup", or a list of the [presets](#the-presets): one row per game,
   Dofus, World of Warcraft and RuneScape, with a segment per version (its full name in the
   segment's tooltip). **Add Another Game…** opens a short form, which **Cancel** (or `Esc`)
   closes without adding anything: a name, one or more site addresses, and optionally the app the game runs
   in, from the ones running. Each address is probed as in Settings › Lookup. A MediaWiki gets its
   own `Special:Search` address, Wowhead, DofusDB and a Weebly site their usual one, and any other
   site `https://duckduckgo.com/?q=site%3A<host>+{query}`, with its sitemap as its index when it
   has one. Under the list, whether Screen Recording is granted, and a button that asks macOS for
   it (nothing is captured), or, when it was granted since SlyTerm opened, **Reopen SlyTerm** (see
   [Permission and caches](#permission-and-caches)). Reopening from here brings the assistant back
   at the next launch, since it was not finished.
3. **Shortcuts**: show / hide, click-through and panic, plus the lookup and pick keys when games are
   on and Allow / Refuse when the card is on, with the Shortcuts pane's recorder and warnings.
4. **Done**: the main shortcuts as chosen (the click-through one as "takes you back to the
   terminal"), a caption saying that clicking into the game switches to click-through by itself
   (only while that setting is on), **Open Settings** and **Start**.

Nothing is saved until **Start** or **Open Settings** on the last step; closing the window keeps
everything as it was. A new game list starts with the Dofus preset: on the first run it stays only
if Dofus is checked, so "No" leaves no game at all. The games already there show as checked and
stay, and a preset or a name that is already in the list is not added twice. Run again from
Settings › General, it only adds. Closing it sets `setupDone`, and it does not open by itself
again; quitting SlyTerm while it is open brings it back at the next launch. The first launch of a
version that has it stores `setupDone` as false on a fresh install and as true on one that already
ran an earlier version (it has `frameEdge`, `sessionDirectories` or `lookupGamesVersion` stored), so
existing installs never see it.

### Shortcuts

**Settings › Shortcuts** has all nine actions: show / hide the terminal, toggle click-through,
panic mode, Fullscreen, "Look up what's under the pointer", "Pick text near the pointer", "Allow
what the agent asks", "Refuse it" and "Play / pause". Allow and refuse are off, and say so, while the card
is off in General. Click a field, press the new shortcut, done. A shortcut needs ⌃, ⌥ or ⌘, except
function keys and the top-left `§` / `` ` `` key, which work on their own; while SlyTerm runs, a key
used alone is taken from every app, the game included. Esc cancels, ⌫ or Clear removes a shortcut.
A global hotkey is only paused while its field is listening, so the others keep working while the
window is open.

The pane warns when two actions share a shortcut, when macOS uses it for one of its own (the list
in System Settings › Keyboard › Keyboard Shortcuts, which `CopySymbolicHotKeys` returns), and when
macOS did not accept it. It cannot see another app's shortcut: macOS registers the same combo for
both apps without an error, and only one of them then gets the key. Under the list, a caption
names the main keys inside SlyTerm (`⌘L`, `⌘G`, `⌘⇧T`, `⌘Return`, `⌘F`, `⌘,`) and points to Help.

The defaults are all ⌃⌥ with a key. Games rarely bind Control and Option together, and if a finger
slips off one of them the game gets ⌃ or ⌥ with a key, where a ⌘ chord would become ⌘Q, or ⌃⌘Q,
which locks the screen. They stay off the ⌃⌥ keys that Magnet and Rectangle's recommended layout
use (C, D, E, F, G, I, J, K, R, T, U, the arrows, Return, − and =), off macOS's ⌃⌥Space (next input
source), and off W, A, S and D, which are held down while moving. What you press with a hand on
the mouse (look up, pick, click-through, play / pause) is on the left of the keyboard; allow and
refuse take both hands, which makes an accidental allow unlikely. One clash is known: Moonlight
leaves a stream with ⌃⌥⇧Q, SlyTerm's pick mode.

In `defaults`, a combo is written as modifiers `ctrl`, `alt`, `cmd`, `shift` joined with `+`, then a
key: a letter or digit (resolved on your current keyboard layout, so `t` is the physical T on
AZERTY too), `f1`–`f12`, `space`, `tab`, `escape`, `grave`, arrows, or `plus`, `minus`, `comma`… for
punctuation.

### Preferences from the shell

Every setting is a key in the `com.charlesmelki.slyterm` defaults domain, so it can also be set from
a shell:

```sh
defaults write com.charlesmelki.slyterm startupCommand "claude"
defaults write com.charlesmelki.slyterm workingDirectory "$HOME/Projects/my-project"
defaults write com.charlesmelki.slyterm hotkeyToggle "ctrl+alt+x"
defaults write com.charlesmelki.slyterm fontName "JetBrains Mono"
defaults write com.charlesmelki.slyterm debug -bool true   # trace to ~/Library/Logs/SlyTerm.log
```

| Key | Default | What it does |
| --- | --- | --- |
| `opacity` | `0.9` | Terminal background opacity while interactive, 0.2–1 (text stays opaque) |
| `ghostOpacity` | `0.7` | Whole-window alpha in click-through, 0.2–1 |
| `videoOpacity` | `0.85` | Whole-window alpha of a web tab playing a video, docked in front or floating, in both modes, 0.2–1 |
| `autoGhost` | `true` | Switch to click-through when the terminal loses keyboard focus |
| `fontSize` | `13` | 8–40 |
| `fontName` | iTerm2's font | Empty for the system monospaced font |
| `workingDirectory` | home | The folder the first tab starts in, and new tabs when inheriting is off |
| `newTabInheritsDirectory` | `true` | A new tab starts in the current tab's folder |
| `startupCommand` | empty | Typed into every new tab, such as `claude` or `codex` |
| `shell` | `$SHELL` | Run as a login shell in each tab |
| `optionAsMeta` | `false` | Off keeps Option for accents and brackets on international layouts |
| `scrollback` | `10000` | Lines kept per tab; a change applies to tabs opened after it |
| `restoreSession` | `true` | Bring the last run's tabs and folders back at launch |
| `confirmQuit` | `true` | Ask before quitting with several tabs or a running command |
| `attentionSound` | `true` | Play the system alert when a tab needs you |
| `startupAnimation` | `true` | Play the logo over the first terminal at launch |
| `windowLevel` | `statusBar` | `floating`, `statusBar` or `popUpMenu` ("Above other windows", "Above the menu bar", "Above everything" in Settings) |
| `stripPosition` | `auto` | `auto` (follows the window), `top` or `bottom` |
| `hotkeyToggle` | `ctrl+alt+h` | Show / hide |
| `hotkeyGhost` | `ctrl+alt+tab` | Toggle click-through |
| `hotkeyPanic` | `ctrl+alt+p` | Panic mode |
| `hotkeyFullscreen` | `ctrl+alt+m` | Fullscreen |
| `hotkeyQuest` | `ctrl+alt+q` | The lookup (named from when it only knew Dofus quests) |
| `hotkeyPick` | `ctrl+alt+shift+q` | Pick mode |
| `hotkeyAllow` | `ctrl+alt+y` | Allow a Claude Code or Codex permission prompt |
| `hotkeyRefuse` | `ctrl+alt+n` | Refuse it |
| `hotkeyPlayPause` | `ctrl+alt+v` | Pause what web tabs are playing, or play it again |
| `tapGesture` | `true` | The trackpad tap |
| `tapGestureAction` | `ghost` | `ghost`, `toggle`, `panic` or `fullscreen` |
| `tapFingers` | `3` | 2–5 |
| `tapAlignment` | `0.5` | Max vertical spread between fingers, as a fraction of the trackpad height; 1 disables the check |
| `questOpenInApp` | `true` | Open the lookup's pages in a web tab rather than the browser |
| `questOpenInBackground` | `false` | In the browser, load the page behind the game |
| `guideZoom` | `1` | Web tab page zoom, 0.5–2 |
| `webSearchURL` | `https://duckduckgo.com/?q={query}` | Where words typed into a web tab's address field go, `{query}` where they go; an address without `{query}` is ignored |
| `autoPauseVideo` | `true` | Pause videos when a guide opens, and a docked video when it goes out of view, playing it again on its return |
| `lookupGames` | Dofus | The games, as a JSON array |
| `lookupActiveGame` | | The identifier of the game picked by hand |
| `lookupAutoDetect` | `true` | Let the app in front pick the game |
| `teleportClosesSource` | `true` | Close the tab a session came from after moving it (iTerm2 and Terminal only) |
| `teleportConfirmBusy` | `true` | Ask before interrupting an agent that is working or waiting for an answer |
| `sendBackTerminal` | `iterm2` | Where a tab's session is sent back to when it was not brought in from one of these: `iterm2`, `terminal`, `ghostty` or `wezterm` (iTerm2, else Terminal, when the one chosen is not installed) |
| `activityCards` | `true` | The card when an agent finishes or asks, or a program sends a notification, and with it the allow and refuse shortcuts, the sound and bringing a hidden overlay back for an agent |
| `activityAnswerURLs` | `false` | Let `slyterm://allow` and `slyterm://refuse` answer (no control in Settings) |
| `activityCardSeconds` | `10` | How long a finished card or a notification stays; 0 keeps it until closed |
| `debug` | `false` | Trace to `~/Library/Logs/SlyTerm.log` and the unified log |
| `setupDone` | set at first launch | The setup assistant has run; `false` opens it at the next launch as on a fresh install (Settings › General › Run Setup Assistant… opens it any time) |

The app also keeps state of its own in the same domain, which is not worth editing: `frame` and
`frameEdge` (the window and the edge its strip was on), `floatFrame` and `floatVideoFrame` (where
the last floating page and the last floating video were), `sessionDirectories` and
`sessionSelected` (the tabs to restore), `ghostHintsShown` (how many times the automatic switch to
click-through has said so, up to 3), `lookupGamesVersion` and `lookupGames.v0` (see
[Migration notes](#migration-notes)), and `migratedFormerDefaults`.

`hotkeyQuest`, `questOpenInApp` and `questOpenInBackground` keep the names they were given when the
feature only knew Dofus quests, and `guideZoom` the one from when there was a single Guide tab, so
nothing already scripted has to change.

## Scripting

### URL scheme

The app answers `slyterm://` URLs, so anything that can run a shell command can drive it:

```sh
open -g slyterm://toggle   # show / hide
open -g slyterm://show     # show and focus
open -g slyterm://hide
open -g slyterm://ghost    # toggle click-through
open -g slyterm://panic    # toggle panic: an opaque terminal over the whole screen
open -g slyterm://fullscreen   # toggle Fullscreen for the window with the keyboard
open -g slyterm://notify   # mark the current tab as needing attention, never steals focus
open -g slyterm://allow    # answer the permission prompt an agent has up with Yes (off until activityAnswerURLs)
open -g slyterm://refuse   # or with No; both take ?tab= like notify, and do nothing unless a prompt is up
open -g slyterm://lookup   # look up whatever is under the pointer
open -g "slyterm://lookup?dry=1"   # same, but only show what would open
open -g "slyterm://lookup?q=Abyssal%20whip"   # look that text up, without reading the screen
open -g "slyterm://lookup?game=Old%20School%20RuneScape"   # ask that game's sources, whatever is in front
open -g "slyterm://lookup?pick=1"   # pick mode: freeze the screen and choose the line; takes dry and game too
open -g slyterm://pick     # the same, shorter
open -g slyterm://quest    # what lookup used to be called, kept for scripts that use it
open -g "slyterm://guide?url=https%3A%2F%2Fwww.dofuspourlesnoobs.com%2Fbestiaire.html"   # open a page in the lookup's web tab, or a new one when it is playing
open -g slyterm://guide    # what ⌘G does: the last web tab, or the active game's first source
open -g "slyterm://web?url=https%3A%2F%2Fwww.twitch.tv"   # open a page in a new web tab, in front
open -g slyterm://playpause   # pause what web tabs are playing, or play it again, as ⌃⌥V does
open -g slyterm://settings # open the Settings window
open -g slyterm://hotkeys  # open it on the Shortcuts tab
open -g slyterm://teleport # open "Bring In a Session"
open -g "slyterm://teleport?session=<uuid>"   # move that conversation here, from any agent
open -g "slyterm://teleport?session=<uuid>&mode=copy"   # a forked copy, the source untouched (not omp)
open -g "slyterm://teleport?pid=<pid>"        # the agent with that pid
open -g "slyterm://teleport?tty=ttys003"      # the shell on that tty: its folder, its command typed
open -g "slyterm://teleport?cwd=/some/folder" # a new tab in that folder
open -g "slyterm://send-back?session=<uuid>"  # send the SlyTerm tab running that session back
open -g "slyterm://send-back?tab=2&mode=copy" # a forked copy of tab 2's session there, the tab untouched
```

Inside a Claude Code conversation in SlyTerm, `! open -g
"slyterm://send-back?session=$CLAUDE_CODE_SESSION_ID"` sends it back. `tab=` takes a tab's
`SLYTERM_TAB_ID` or its number; with neither `tab=` nor `session=` nothing happens.

`-g` keeps the current app in front.

### Claude Code hooks

Every tab exports `SLYTERM_TAB_ID`, so a Claude Code hook lights up the tab it runs in rather than
whichever one you left selected. In `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "[ -n \"$SLYTERM_TAB_ID\" ] && open -g \"slyterm://notify?tab=$SLYTERM_TAB_ID\"" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "[ -n \"$SLYTERM_TAB_ID\" ] && open -g \"slyterm://notify?tab=$SLYTERM_TAB_ID\"" }] }]
  }
}
```

`Stop` fires when Claude finishes a task, `Notification` when it asks for input or permission. The
hooks are optional since the strip reads Claude's status on its own; what they add is the instant
mark and card, where the poll takes up to a second. The `$SLYTERM_TAB_ID` test matters because
`~/.claude/settings.json` is global: without it, the same hook running in iTerm2 or VS Code would
have LaunchServices start SlyTerm just to light up a tab you are not looking at.

A Codex hook cannot do the same in Codex's default mode: Codex runs its hooks in its background
server, whose environment has no `SLYTERM_TAB_ID`. Its title marks the tab instead (see
[Codex](#codex)).

### Command-line modes

The SlyTerm binary also has command-line modes that check each stage of a feature from a terminal,
without the hotkey and without putting a window over the game. There is no `--help`: an argument
that is not one of these modes launches the full app.

The lookup modes (everything before `--guide-snapshot` below) take `--game <name>`, either a game
you have configured or one of the presets `dofus`, `wow` or `osrs`, made up on the spot so a site
can be tried out before it is added to Settings; without it they use the game the hotkey would.
`--preset <name>` is always the preset as this build ships it, even when a game you configured has
that name, so `--preset dofus` tries the English sources next to a Dofus game stored with the
French ones, without reading the games you configured at all.

```sh
B=dist/SlyTerm.app/Contents/MacOS/SlyTerm
$B --match "La Geste de Ratagnan (2/6)"   # best index matches for a line of text
$B --ocr screenshot.png                   # read an image and match every line, `--fast` for the fast pass
$B --ocr screenshot.png --at 1204 880     # the image read around a pointer at that pixel (see below)
$B --pick-snapshot screenshot.png 1204 880 pick.png --scale 2
                                          # draw pick mode offscreen over that image, the pointer at
                                          # that pixel, and write a PNG; `--scale 2` for a Retina
                                          # screenshot; takes `--game`
$B --lookup                               # the whole pipeline at the pointer, opens nothing
$B --lookup 360 531                       # same at a screen point (origin bottom-left)
$B --search "Abyssal whip" --game osrs    # what each source that can be asked resolves it to,
                                          # and the answer the lookup would take
$B --search "Gwandpa Wabbit's Staff" --preset dofus
                                          # the same with both of the Dofus preset's sites, as
                                          # this build ships it
$B --index                                # every game's sources, their kind and their index size
$B --index --refresh                      # rebuild those indices now instead of waiting a week
$B --probe "https://warcraft.wiki.gg/wiki/Special:Search?search={query}"
                                          # what kind of site is behind a URL, and what it can index
$B --guide-snapshot https://www.dofuspourlesnoobs.com/la-geste-de-ratagnan.html out.png
                                          # render a guide page offscreen and write a PNG (see below)
$B --guide-snapshot "https://www.youtube.com/watch?v=…" out.png --fill
                                          # the same with the page's video filling it, as popping
                                          # out a playing video does
$B --drm-check                            # whether web tabs are offered FairPlay, and the user agent
                                          # they send; loads nothing from the network
$B --strip-snapshot strip.png             # draw the tab strip offscreen, every state in one PNG,
                                          # web tabs overflowing into `…` included, and print what
                                          # each `…` menu would list
$B --float-snapshot float.png             # draw a floating web tab offscreen, a page and a video, in
                                          # interact and click-through, and print where it opens
                                          # and how its frame keeps a video's shape
$B --card-snapshot card.png               # draw the kinds of card offscreen, stacked, truncation included
$B --sessions                             # what "Bring In a Session" would offer, as a table
$B --sessions --json                      # the same, for scripts
$B --sessions --session <uuid> --send-back   # what sending it back would do, the AppleScript
                                          # included; `--copy` for the fork. Stops and opens nothing
$B --picker-snapshot picker.png           # draw the picker offscreen with sample rows, plus a
                                          # second PNG with an `-empty` suffix for the empty state
$B --setup-snapshot setup.png             # draw every step of the setup assistant offscreen, in one
                                          # PNG; `--step 1`…`4` draws one. Saves nothing, no network
$B --activity                             # every running agent, in any terminal: agent, status, how
                                          # long, what it is doing, what it asks, the last thing it said
$B --activity --json                      # the same, for scripts
$B --activity --transcript s.jsonl        # what the parser reads from one transcript, rollout or
                                          # session file
$B --activity --title "⠸ Fix it | demo"   # what each agent's title rules make of a title
$B --activity --screen tab.txt --agent codex
                                          # the prompt the answer would find in a tab's lines
$B --activity --poll --times 4            # scan repeatedly and time it; a quiet pass opens no file
```

- `--ocr screenshot.png --at X Y` takes the pointer in pixels with the origin at the top left, as
  Preview's inspector shows it. It prints the image's blocks, the fill each line is on, which
  blocks are tooltips and the lines that make them one (`*`), the candidates the hotkey would try,
  and what the nearby stage alone answers, asking the site and reading accurately when the fast
  reading comes to nothing, as the hotkey does. The band under the pointer, the whole-window match
  and the search page are not run. `--pick` adds the pick list, `--fast` keeps to the fast pass.
- `--guide-snapshot` renders with the real configuration, rules and stylesheet, without showing a
  window, so the reader mode can be worked on without putting anything over the game. `--full`
  renders the full page, `--width` / `--height` set the size, `--scroll` reaches the rest of the
  page, `--eval <js>` clicks or switches mode before the picture, and `--find <text>` opens the find
  bar, which puts the whole tab in the PNG. It also prints a `media:` line: the media the page's
  controller takes for the main one (a video or an embedded player, and its size, or `none`), what
  a fill would cover, the state the main frame reports, and after `tab:` the tab's own state,
  merged over every frame with what WebKit says is playing, so sound the script cannot see shows
  there. `--fill` fills the page before the picture and prints the filled element's rect against
  the viewport.
- `--drm-check` loads a small page with the web tabs' real configuration in an offscreen web view,
  under an `https://` address so the page counts as secure but without going to the network, and
  prints the user agent, whether `navigator.requestMediaKeySystemAccess('com.apple.fps', …)`
  succeeds and then `createMediaKeys()`, and what
  `WebKitMediaKeys.isTypeSupported('com.apple.fps.1_0', 'video/mp4')` answers. It gives up after
  20 seconds.
- `--sessions` columns are kind (`claude`, `bg` for a background Claude, `codex`, `omp`, `pi` or
  `shell`), host, status, pid, tty, folder, session or attach id, the action Return would take, and
  the label. `--session <uuid>`, `--pid <pid>` and `--tty ttys003` narrow it to the one a
  `slyterm://teleport` URL would pick, so a URL can be checked before it is fired at a live session;
  `--tty` lists that terminal's agent, then its shell. With `--send-back` it prints, for each one,
  what "Send Back" would do with it and the script (for WezTerm, the commands) it would send to
  the terminal chosen in Settings, since a SlyTerm tab's own origin is not visible from outside the
  app; for a session outside SlyTerm it says the app would not offer it.
- `--activity --transcript` tells the file's kind from its first line (a Codex rollout starts with
  `session_meta`, an omp session with its title, a pi session with its header, anything else is
  taken for Claude Code's), and `--agent <name>` forces it: `claude`, `codex`, `omp`, `pi`,
  `gemini` or `qwen`. For an agent other than Claude it also prints the file's head (id, folder,
  start, title or thread name, first prompt) and the status, its time and whether the session ended.
  `--status waiting` (or `busy`) says what the tab would show in that state.
- `--activity --title <text>` runs the title through every agent's rules, or only `--agent`'s, and
  prints the status, whether the title carried the agent's own mark, and the name the strip would
  show. `--activity --screen <file>` reads a file of a tab's lines, top to bottom, and prints the
  request Codex's and omp's prompts give, or `--agent`'s alone; a first line `# title: '…'` is read
  as the tab's title. `swift Tools/make-agent-fixtures.swift <dir>` writes synthetic rollouts,
  session files, titles and screens for these modes and prints what each should give.

None of the command-line modes signals a process, types into a session or puts a window on screen.
What they write is the PNG you name and, for the index modes, the index cache. Run from the app
bundle, they share the app's preferences; run as `.build/debug/SlyTerm`, outside a bundle, they use
a separate `SlyTerm` defaults domain.

## Troubleshooting

- **Overlay hidden behind the game.** Settings › Window › Level → "Above everything, for games that
  cover the terminal", and make sure the game is not in exclusive fullscreen.
- **Hotkey does nothing, or moves a window instead.** Another app has the same combination, often
  a window manager. macOS does not report it to either app, so change the shortcut in one of them.
  When macOS itself refuses a combo, or uses it, Settings › Shortcuts says so next to the field and
  the menu bar item shows "Shortcut unavailable" under the refused row.
- **No spinner on a tab that runs an agent.** An agent is matched to a tab only while it is the job
  in front on the tab's own terminal, and a Claude through the tab id the shell exports as well. So
  an agent started in the tab is found; one suspended with `⌃Z`, or running inside tmux, screen or
  an editor's terminal started from the tab, is not, since the tab's screen is not where it is. A
  session brought in with Attach is read through its `claude attach` client and its daemon's
  registry entry, and shows nothing when either is missing. `SlyTerm --activity` prints what the
  poll sees, and `debug` logs every transition as `activity:` lines.
- **A Codex shows as working while it waits, or its card has no text.** Codex says it waits only in
  its title, with the activity part its default `terminal_title` has: a title set up without it
  leaves SlyTerm the rollout, which cannot tell waiting from working. A card with no text means
  SlyTerm found no rollout for that Codex, as with a thread reopened from Codex's own resume picker
  (see [Codex](#codex)). `SlyTerm --sessions --json` names the file each agent is read from, as
  `transcript`, and lists an agent without one as a shell tab.
- **`⌃⌥Y` does nothing.** The card is off in Settings › General, which turns the shortcut off with
  it; or nothing is waiting in that tab; or the prompt is not a plain yes or no (a question, a
  plan, a subagent's request, several calls at once, or for Codex anything but a command or an
  edit, or a prompt whose keys were remapped); or the agent is omp or pi, which have nothing to
  answer this way; or it changed since the card showed it, the card came up less than a second ago,
  or it was just answered. A toast by the strip says which.
- **Typing goes to the game instead of the terminal.** You are in click-through mode (orange dot).
  Press `⌃⌥Tab`, click the eye button, or three-finger tap. Clicking the tab strip does not do it on
  purpose: it would fire every time you switched tabs or moved the window.
- **Typing goes to the terminal instead of the game.** The terminal has focus (green dot). Click
  into the game once, or press `⌃⌥Tab`.
- **The lookup says Screen Recording is needed, again.** The app is ad-hoc signed by default, and
  macOS ties the grant to that exact build: every `./build.sh` produces a "new" app and the grant
  has to be redone (toggle SlyTerm off and on in System Settings › Privacy & Security › Screen
  Recording, then relaunch, or use **Reopen SlyTerm** in Settings › Lookup). To keep it across builds, create a self-signed "Code Signing"
  certificate in Keychain Access (Certificate Assistant › Create a Certificate) and build with
  `CODESIGN_IDENTITY="its name" ./build.sh`.
- **The lookup opens the wrong page or nothing.** Press `⌃⌥Q` again for the next guess, or `⌃⌥⇧Q`
  to pick the line yourself. To see why, run `defaults write com.charlesmelki.slyterm debug -bool
  true`, press the hotkey, and read `~/Library/Logs/SlyTerm.log`: it lists which game answered,
  what was read under and around the pointer, what was asked and every match score. A screenshot of
  the same screen goes through `--ocr screenshot.png --at X Y` for the ranking in full. A tooltip
  the game draws far from the pointer that is not marked as one there wants a line only its
  tooltips have in the game's **Tooltip lines**.
- **The lookup opens a search page instead of the guide.** Either that source has no offline index
  to match against (Wowhead and DofusDB have none by design, and a site with neither a sitemap nor a
  wiki API gets none), or the index is still being built, which is what the first lookup on a newly
  added site runs into: it waits three seconds for the crawl and then goes to the search rather
  than leaving you with nothing. `--index` says which of the two it is, source by source, with the
  size and the age of every index; `--index --refresh` rebuilds them on the spot.
- **The wrong game was picked.** The lookup asks the app under the pointer, then the app in front,
  then the game chosen by hand, and the message names the game or the site that answered. When
  the game chosen by hand answered for an app no game claims, the message's second line names that
  app. Set each game's **Game app** in Settings › Lookup so it can be
  recognised, or turn "Detect the game from the app in front" off and pick the game yourself, in
  that pane or in the menu bar's "Lookup Game" submenu.
- **The lookup opened a new web tab instead of its own.** Its own was playing something, and the
  lookup never replaces a show: the new tab is the lookup's from then on (see
  [The lookup's tab](#the-lookups-tab)).
- **A floating web tab's address field does not take typing.** The toolbar's dot is orange:
  SlyTerm is in click-through. Press `⌃⌥Tab`, then click the field.
- **Ads play on YouTube.** Nothing is blocked on streaming sites, since YouTube stops playing when
  its ad requests are blocked (see [Reader mode and blocking](#reader-mode-and-blocking)).
- **Signing in through a pop-up does not finish.** A pop-up opens as a new web tab, without the
  link back to the page that opened it, so a site that signs you in through a pop-up window never
  hears back from it. Sign in on the site's own page instead.
- **A streaming site will not play.** Web tabs identify as the Safari installed on the Mac, since
  services only offer their DRM to Safari. `SlyTerm --drm-check` prints the user agent they send and
  whether a page is offered FairPlay; the toolbar's browser button hands the page to your browser.
- **`claude` not found.** Tabs run your shell as a login shell so the `~/.zprofile` PATH applies.
  If `claude` only lives in `~/.zshrc`, either move the PATH line to `~/.zprofile` or use the full
  path `~/.local/bin/claude` as the startup command. The same goes for `codex` and the others.

## Architecture

SlyTerm is one Swift package: an executable target, `SlyTerm`, with
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) as its only dependency, and a tiny C
target, `CMultitouch`, that declares the layout of the touch frames Apple's private
MultitouchSupport framework hands the trackpad tap. It
links AppKit, Carbon, ScreenCaptureKit, Vision and WebKit. `build.sh` wraps the release binary,
`Resources/Info.plist` and the icons into `dist/SlyTerm.app`; the app is `LSUIElement`, so it has no
Dock icon except while Settings or the setup assistant is open (see
[Windows and focus](#windows-and-focus)), and it registers the `slyterm` URL scheme.

### Source map

| File | What it holds |
| --- | --- |
| `main.swift` | Entry point: runs a command-line mode and exits if one matches, otherwise starts the app as a menu bar accessory |
| `AppDelegate.swift` | Launch order, the menu bar item and its menu, hotkey and trackpad registration, URL events; `AppSwitcher`, the Dock icon and app menu while Settings, the assistant or About is open; `ScreenRecording`, the permission line and Reopen SlyTerm; `NSAlert.runModal(level:)` |
| `OverlayController.swift` | Owns the two panels, the tabs, the floating web windows and the modes (interact, click-through, panic, Fullscreen), the strip edge, focus, the attention mark, the lookup's web tab and what play / pause and panic paused |
| `Panels.swift` | `OverlayPanel`, the non-activating terminal window, and `StripPanel`, the child window that stays clickable |
| `Tab.swift` | The `Tab` protocol a terminal and a web tab both satisfy |
| `TerminalTab.swift` | One terminal tab: a SwiftTerm view, its pty and login shell, its folder read from the kernel, its title read by each agent's rules, its visible lines, notifications and focus reports |
| `TabStripView.swift` | The strip: tabs, the web tabs' squares, activity marks, tooltips, the hint; `--strip-snapshot` |
| `HotKeys.swift` | `HotKeyCenter` over Carbon `RegisterEventHotKey`, and `KeyCombo` parsing on the current layout and checking against macOS's own shortcuts |
| `HotkeyRecorder.swift` | The list of global actions and the shortcut recorder field |
| `Settings.swift` | Every preference over `UserDefaults`, the `didChange` notification, the debug log, the HoverTerm carry-over |
| `SettingsWindow.swift` | The six Settings panes |
| `RemoteControl.swift` | The `slyterm://` routes |
| `TrackpadGestures.swift` | The N-finger tap, over `Sources/CMultitouch` |
| `Fonts.swift` | Nerd Font detection and iTerm2's profile font |
| `StartupAnimation.swift` | The logo animation, a pure function of time |
| `Lookup.swift` | The lookup pipeline, press again, screen capture, OCR, the toast; `LookupCLI` |
| `LookupNearby.swift` | Lines into blocks, tooltips and the ranking of candidates around the pointer |
| `LookupPicker.swift` | Pick mode's frozen-frame panel; `--pick-snapshot` |
| `LookupModel.swift` | Games and sources, `LookupStore` (storage and migrations), `LookupPresets`, the index cache location |
| `LookupIndex.swift` | `LookupText` (cleaning, folding, scoring) and the offline indices |
| `LookupResolvers.swift` | HTTP, one resolver per kind of site, and `LookupProbe`, which detects the kind from a URL |
| `WebModel.swift` | The types web tabs, floating windows, the strip and the controller share, and `WebSites`: the streaming sites, the Safari user agent, what an address field's text opens |
| `GuideTab.swift` | `GuideContent` (blocking rules, per-site stylesheets, the web view's configuration), `GuideTab` (one web tab: its toolbar and address field, its icon, its media state), `--guide-snapshot` |
| `GuideFindBar.swift` | A web tab's find bar |
| `WebMedia.swift` | The fullscreen shim and the media controller every page gets, as scripts; `WebMediaFrames`, the frames' reports merged into a tab's media state; `WebIcons`, the favicons; `--drm-check` |
| `FloatingWebPanel.swift` | `FloatingWeb`, a web tab's floating window: the page panel, the toolbar panel over it, its frames, dragging, the kept aspect and filling its screen for Fullscreen |
| `Activity/AgentActivity.swift` | The types the monitor, strip, card and answer share, and `AgentKind`: each agent's name, resume and copy commands and answer keys |
| `Activity/ActivityMonitor.swift` | The poll: which agent runs in each tab, and its status from Claude Code's registry, the tab's title or the agent's session file |
| `Activity/TranscriptTail.swift` | Claude Code's transcript parser, pure over lines of bytes, and the tail reads the other readers share |
| `Activity/AgentTitle.swift` | The title rules of Codex, omp, Gemini CLI and Qwen Code |
| `Activity/AgentScreen.swift` | The prompt Codex or omp shows on a tab's visible lines |
| `Activity/CodexRollout.swift` | Codex's rollout reader and its thread index |
| `Activity/PiSession.swift` | pi's and omp's session file reader |
| `Activity/ActivityCard.swift` | The card; `--card-snapshot` |
| `Activity/ActivityAnswer.swift` | Allow and refuse, and every check before the keystroke |
| `Activity/ActivityCLI.swift` | `--activity` |
| `Teleport/TeleportModel.swift` | The types discovery, engine and picker share |
| `Teleport/SessionDiscovery.swift` | What is running in other terminals, from Claude Code's registry, the process table and the agents' session files; which session each tab hosts |
| `Teleport/AgentDiscovery.swift` | The Codex, omp, pi, Gemini CLI and Qwen Code processes in front on a terminal, and the session file each one writes |
| `Teleport/TeleportEngine.swift` | Bringing a candidate in: stop, open a tab, type the command, close the source; sending a tab back to iTerm2, Terminal, Ghostty or WezTerm |
| `Teleport/TeleportPicker.swift` | The "Bring In a Session" panel; `--picker-snapshot` |
| `Teleport/SessionsCLI.swift` | `--sessions` |
| `SetupAssistant.swift` | The first-launch setup window: its steps, the short game form, applying the choices; `--setup-snapshot` |

`Tools/` holds scripts run by hand: `make-icon.swift` rebuilds `Resources/AppIcon.icns` from
`Resources/StatusItemIcon.pdf`, `make-lookup-fixtures.swift` draws synthetic game screenshots for
tuning the lookup, `make-agent-fixtures.swift` writes synthetic agent files, titles and screens for
the `--activity` modes, `preview-startup-animation.swift` renders instants of the logo animation to
a contact sheet, and `make-readme-animation.swift` renders the whole of it to
`docs/startup-animation.gif`, the loop at the top of the README.

```sh
swift Tools/make-icon.swift
swift Tools/make-lookup-fixtures.swift <out dir>   # prints each file's --at X Y and expected first candidate
swift Tools/make-agent-fixtures.swift <out dir>    # prints the mode to run on each file and what it should give
```

The two animation scripts use top-level code, which only compiles from a file named `main.swift`,
so they are linked to one first:

```sh
ln -sf "$PWD/Tools/preview-startup-animation.swift" /tmp/main.swift
swiftc -O /tmp/main.swift Sources/SlyTerm/StartupAnimation.swift -o /tmp/preview
/tmp/preview out.png                 # a sheet of the whole timeline
/tmp/preview out.png 1.9 2.1 2.3     # chosen instants, in seconds

ln -sf "$PWD/Tools/make-readme-animation.swift" /tmp/main.swift
swiftc -O /tmp/main.swift Sources/SlyTerm/StartupAnimation.swift -o /tmp/make-readme-animation
/tmp/make-readme-animation docs/startup-animation.gif
```

### Windows and focus

- `OverlayPanel` is a borderless, resizable `NSPanel` with `.nonactivatingPanel`, so it can take
  keyboard input without activating the app: the game keeps its menu bar and its Space.
  `collectionBehavior` includes `fullScreenAuxiliary` and `canJoinAllSpaces` so it also floats over
  fullscreen apps. Its `constrainFrameRect` is overridden so panic and Fullscreen can cover the
  menu bar.
- Click-through is `ignoresMouseEvents`, which is all-or-nothing per window, so the tab strip is a
  separate child panel that stays clickable and doubles as the drag handle.
- A floating web tab is two panels built the same way (`FloatingWeb`): the page panel, a resizable
  `OverlayPanel` that can become key, and over its top band a child `FloatingBarPanel` holding the
  tab's toolbar, which is the drag handle. Both are borderless and non-activating, with the main
  window's `collectionBehavior` (`canJoinAllSpaces`, `fullScreenAuxiliary`, `stationary`,
  `ignoresCycle`) and no animation. In click-through the page panel ignores the mouse and the
  toolbar panel never does, as with the strip, but the toolbar panel can only become key in
  interact mode. Showing one orders both front without making either key. Handing the keyboard back
  to the game (click-through, hiding, closing a window that has it) first asks the app that was in
  front back when SlyTerm is active, then orders the key panels out and back in while every SlyTerm
  panel refuses key, so AppKit cannot pass the keyboard from one of them to another. The card is
  ordered back above a floating window each time one comes to the front.
- The card, the toast and the two pickers are panels of their own. The card and the toast never
  become key and never activate the app. The pickers take the keyboard without activating the app
  where macOS allows it (the session picker activates only when that is refused), and give it back
  when they close: the lookup picker to whichever app had it, the session picker to the terminal
  when the overlay is interactive.
- Global hotkeys use Carbon `RegisterEventHotKey`: no Accessibility permission, and they fire even
  while a fullscreen game has the keyboard.
- Settings and the setup assistant are ordinary windows one level above the overlay while SlyTerm is
  active, and at the normal level when it is not, so they go behind the app you switch to. While
  either is open, `AppSwitcher` makes SlyTerm a regular app, with a Dock icon, a place in `⌘Tab` and
  an app menu (Quit, an Edit menu, Close); when the last one closes it is an accessory again and the
  menu is removed. The menu sees `⌘C`, `⌘V`, `⌘W` and the rest before the overlay's key handler,
  so its Edit items and Close are enabled only while Settings, the assistant or a sheet on them is
  key; a disabled item lets the key through to the terminal. An app that is already active when it
  turns regular keeps the previous app's menu bar, so in that case activation goes to the Dock and
  comes back 0.2 s later.
- The quit confirmation and the confirmation before interrupting an agent run through
  `NSAlert.runModal(level:)`, two levels above the overlay. `runModal` puts an alert at the modal
  panel level, below the overlay and Settings, and does it again each time the app activates, so
  the level is set once the modal session runs (on the run loop in `.modalPanel` mode; the main
  queue is not served during it) and after each activation change.

### Tabs

A tab is anything that satisfies the `Tab` protocol: `TerminalTab` (a pty and a SwiftTerm view) or
`GuideTab`, a web tab (a `WKWebView` under a small toolbar). Showing a tab and the attention signal
go through the protocol; folders, pasting and the font are terminal business. The controller keeps
the terminals in one ordered list and the web tabs in another, in strip order, docked and floating
alike, which is why the numbered shortcuts and the saved session see only terminals. A web tab's
toolbar and page can be lifted out of its own view into a `FloatingWeb` and put back: the same web
view moves, so the page is not reloaded. Terminal emulation is SwiftTerm's
`LocalProcessTerminalView`, one per tab, with its own pty and login shell; a tab's folder is read
from the kernel, so it follows `cd` without shell integration.

### Threads

The UI is main-thread only. Work that costs anything happens off it and only the answer crosses
back:

- the activity monitor's scan (the process table, `sysctl` per process, the open files of Codex
  processes, transcript and session file tails) on a serial background queue;
- the session discovery scan, off the main thread whenever the picker refreshes;
- Apple events to iTerm2 and Terminal on a queue of their own, because the first one raises the
  Automation permission dialog and does not return until the user answers it;
- screen capture, OCR and every network request of the lookup;
- a web tab's icon, fetched with an ephemeral `URLSession` whose delegate runs on one serial
  queue; the cache it goes into is only touched on the main thread;
- the installed Safari's version for the web tabs' user agent, read from its `Info.plist` once,
  off the main thread at launch;
- the debug log, which has one writer queue.

Waits in the teleport engine are 100 ms timers, never sleeps, since the overlay may be sitting over
a game while an agent shuts down.

### Agent activity

`ActivityMonitor` scans once a second, three times slower while the overlay is hidden, and at once
when a tab's title changes an agent's status. A scan starts on the main thread with a `TabProbe`
per terminal tab: its tty, its foreground process group, the state each agent's title rules give
its title and, only while the title says the agent the last scan found in the tab is waiting,
the tab's visible lines. Everything
else runs on the monitor's serial queue.

Claude Code comes first. The monitor reads its session registry (`~/.claude/sessions/<pid>.json`)
and matches each live session to a tab by the `SLYTERM_TAB_ID` in its environment (read once per
pid and start time, since it never changes) when it is also the foreground job on that tab's pty. A
tab with no Claude is matched to the Codex, omp, pi, Gemini CLI or Qwen Code process of this user
that is in its tty's foreground group, recognised by its kernel name or, for a node or bun launch,
by the script it runs; npm's Codex is a `node` whose native `codex` child is the one reported, once
per group. `AgentDiscovery` then finds that process's session file, as [Codex](#codex) and
[omp and pi](#omp-and-pi) describe, keeping what it read in a cache pruned every scan. Which Codex
began a thread, and whether a pi is alone in its folder, is settled over every Codex and pi of this
user in front on any terminal, not only SlyTerm's, before the tabs' own results are kept.

`TranscriptTail` reads a Claude transcript, `CodexRollout` a Codex rollout and `PiSession` a pi or
omp session file. Each reads the last 64 KB, only when the file's size or mtime moved, and goes
back 512 KB once when that tail holds no last answer, as a turn full of big tool results does (for
a rollout, also when it holds no turn record). A file's head, a rollout's `session_meta` or a
session's header and title, is read once. Nothing is decoded into a struct, nothing is
force-unwrapped, and a line that does not parse is skipped, because these formats change between
releases. A scan with nothing new opens no file, which `--activity --poll` counts.

Claude's status is its registry's. For the other agents, a title's state counts when the title
carried the agent's own mark at or after the agent's process started, with 2 s of slack, and the
session file's reading otherwise; pi has only the reading, Gemini CLI and Qwen Code only the title.
How long it has been in that state comes from whichever decided. When a title says a turn ended,
the monitor rescans for up to 2 s for the session file's record of that end, so the finished card
carries this turn's answer and not the one before. While a Codex waits, its request is what
`AgentScreen` finds on the visible lines, else the rollout's pending call; an omp's is the `ask` in
its session file, else the screen's. Transitions become `ActivityEvent`s on the main thread, which
the controller turns into the attention mark and the card, and the strip draws
`TerminalTab.activity`.

`TerminalTab` keeps the title the program set and, for each agent with title rules, a `TitleState`:
the status, since when (stamped only when the status changes, so a spinner frame or Codex's blinking
mark does not restamp it), the name without the mark, and when the title last carried a mark. It
registers handlers for OSC 9 and OSC 777 on SwiftTerm's terminal, which take precedence over
SwiftTerm's own handling; SwiftTerm's `notify` delegate method is a protocol extension default,
which a subclass override would never receive. Focus reports are sent with `setTerminalFocus`, on
each change, because SwiftTerm sends them only when its view gains or loses first responder, which
never happens when the game takes the keyboard from a non-activating panel.

Allow and refuse type a single key into the pty, the agent's `answerKeys`, after a fresh scan has
confirmed that the prompt the card showed is still up and not yet answered, and `tcgetpgrp` on the
tab's pty that the agent is still in front. For Codex the tab's visible lines are read and parsed
again in the same main-thread turn as the keystroke, and must give the very request the card
showed.

### Web tabs

A web tab blocks with one `WKContentRuleList`, compiled once at launch and cached by WebKit under a
versioned identifier (`slyterm-guide-v5`), and restyles with a `WKUserScript` injected at document
start, so the first paint is already dark. Every rule's trigger carries an `unless-domain` list
built from `WebSites.streamingHosts` (`*youtube.com` and so on), which is what leaves streaming
sites unblocked. `unless-domain` only looks at the page in the tab, so a last rule,
`ignore-previous-rules` with an `if-frame-url` list of the same hosts
(`^https?://([^/]+\.)?youtube\.com[:/]` and so on), lifts the blocking inside a streaming site's
player embedded in another page. Reader mode is one class on `<html>`: the stylesheet hides the
site's chrome and inverts the whole page rather than forcing a text colour, which would flatten the
guides' own colours; screenshots are inverted back so they look normal.

The script carries a map of host suffix to stylesheet, built from the table of sites SlyTerm was
tuned on plus every source of every configured game, and picks the longest suffix matching
`location.host`: a user script cannot ask the app anything, and the tab follows links wherever they
go. It is given the streaming hosts too, and never applies the reader on one of them. Editing a game
in Settings throws the scripts away and makes them again, so the next page loaded is styled with
it.

Every web tab's `WKWebViewConfiguration` comes from one factory, which `--drm-check` uses too:
Safari's user agent suffix as `applicationNameForUserAgent` (`Version/… Safari/605.1.15`, with the
installed Safari's version, or 18.0 when it cannot be read), no user action required for media
playback, `javaScriptCanOpenWindowsAutomatically` off (it is on by default on macOS, which lets a
page's timer open window after window), the reader script, the fullscreen shim and the media
controller. The media controller's message handler is added by `GuideTab` when it is created, not
by the factory, so `--drm-check`'s web view has none; it goes through a weak proxy so the
configuration does not keep the tab alive, and is removed when the tab closes. WebKit's own element
fullscreen stays off (`isElementFullscreenEnabled`, off by default): it opens a new Space, which
would pull the screen away from the game.

`createWebViewWith` never returns a web view: it opens the page in a new web tab and forgets the
opener, which is why a pop-up sign-in cannot report back. A tab opens at most three of these in
five seconds; the rest are dropped with a `guide: pop-up ignored` log line.

The fullscreen shim runs in the page's own world, in every frame, at document start. It redefines
`requestFullscreen` and its `webkit` spellings on `Element.prototype`; `exitFullscreen` and its
spellings, and the `fullscreenElement`, `fullscreenEnabled` and `fullscreen` getters and theirs, on
`Document.prototype`; and `webkitEnterFullscreen`, `webkitExitFullscreen` and the
`webkitSupportsFullscreen` and `webkitDisplayingFullscreen` getters on `HTMLVideoElement.prototype`.
A request dispatches `slyterm-fullscreen-enter` at the element, or `slyterm-fullscreen-exit` at the
document, and resolves its promise; real fullscreen is never touched, and the element reported as
fullscreen is the one carrying `data-slyterm-fill`.

The media controller, `window.__slytermMedia`, runs in an isolated world
(`WKContentWorld.defaultClient`) in every frame, out of the page's reach. Its main media is the
largest visible `<video>`, a playing one first, else, in the main frame only, the largest visible
`<iframe>` of at least 200 × 112 px. A site's request fills the element it named (a video climbs to
its player container); SlyTerm's own fill, when a playing video is popped out, takes the main
media's container, found by climbing while the parent's rect stays within 4 px of the element's,
below `body`. Filling marks the element the page asked for with `data-slyterm-fill`, the target
with `data-slyterm-filled`, what lies between it and its video with `data-slyterm-fill-path`, and
each ancestor with `data-slyterm-fill-ancestor`, which neutralises `transform`, `translate`,
`rotate`, `scale`, `filter`, `perspective`, `contain`, `content-visibility`, `will-change`,
`backdrop-filter`, `clip-path`, `mask`, `opacity`, `mix-blend-mode`, `isolation` and `z-index`,
so that `position: fixed` is the viewport, nothing clips or fades the player and nothing paints
over it; `data-slyterm-fill-root` on `<html>` hides the page's scrollbars. They are attributes
rather than classes because some players' frameworks rewrite `className` as they render. One
stylesheet sets the target `position: fixed; inset: 0` at `100vw` × `100vh` on black at the top
`z-index`, and its videos to `object-fit: contain`. Then `fullscreenchange` and
`webkitfullscreenchange` fire at the element and `resize` at the window, so the site lays out its
fullscreen controls. `Esc` while filled unfills, and so does the target shrinking to 0 × 0 (a
`ResizeObserver` watches it), which is what YouTube does to its player on an in-page navigation
without leaving fullscreen. Unfilling undoes all of it and fires the same events. A frame that asks
to fill has its frame element filled by the parent page only when that element allows fullscreen
(`allowfullscreen`, `webkitallowfullscreen` or `allow="fullscreen"`); otherwise the parent tells
the frame to leave its own fill, as a refused request would.

The controller posts `{token, playing, busy, video, aspect, filled, gone}` on media events (`play`,
`playing`, `pause`, `ended`, `emptied`, `loadedmetadata`, `volumechange`, `resize`, captured on
the document), on fill changes, on a scroll or a resize while a silent video runs, and on
`pagehide` as gone; the token is random per frame. `busy` means some media element is neither
paused nor ended; `playing` that one of those is also audible (not muted, volume above 0) or is a
video showing at least 200 × 112 px of itself in the viewport, so a muted loop in a corner does not
count; `video` that the main media is a video whose `videoWidth` is above 0, `aspect` its
`videoWidth / videoHeight`. All of it is the page's word, so `GuideTab` checks every field (a token
of at most 64 characters, booleans, an aspect that is a finite number, clamped to 0.5–4) and drops
a message that does not parse. It keeps at most 16 frames, keyed by token with their latest
`WKFrameInfo`, forgets them when a main-frame navigation commits, and merges them into the tab's
media state: playing when any frame plays, the video and its aspect from the playing frame or else
the main frame, filled when any frame is. Commands go back with `evaluateJavaScript(_:in:in:)` into
that frame's isolated world, and an error from a frame that has gone away is ignored. Pausing
remembers which frames it paused, so playing resumes those, or else the frame that played last.

The script cannot see media outside the document, such as a `new Audio()` never added to it, or
inside a shadow root. So every web tab also reads WebKit's private `_isPlayingAudio`, the flag
Safari's speaker icon shows, every 2 s and whenever a frame reports (only where this WebKit has
it), and counts as playing when WebKit hears sound that no frame reports.
`requestMediaPlaybackState` would not do: it answers `.playing` for any page that merely holds a
media element, such as a wiki page with sound samples. When `⌃⌥V` pauses a tab whose frames report
nothing playing and WebKit hears sound, it calls `setAllMediaPlaybackSuspended(true)`
and remembers it, and playing again resumes it: suspending is the only public way to pause media
the script cannot reach and resume it later. A suspended page cannot start anything itself, so a
mouse or key down in the web view first sends `pauseAllMediaPlayback`, then lifts the suspension,
before the event reaches the page, which leaves the media paused but playable; a main-frame
navigation lifts it too. `setMediaSuspended(_:)`, the suspension for panic, is a second reason kept
apart from `⌃⌥V`'s: WebKit's suspension is one switch, on while either reason holds, so lifting
panic's leaves a tab `⌃⌥V` held still held.

The first time a host is seen in a launch, once a main-frame load finishes, the page is asked for
its icons (`link[rel~=icon]`, `shortcut icon`, `apple-touch-icon`, preferring 32 px and up and PNG
or ICO, else the origin's `/favicon.ico`). The one chosen is fetched off the main thread with an
ephemeral `URLSession`, `http` and `https` only, with a 5 s timeout and at most 256 KB, and must
decode to an image of non-zero size. Icons are cached in memory per host, one fetch per host per
launch; a later page on the same host gets the cached one, or none, without being asked.

### Lookup

`SCScreenshotManager` (ScreenCaptureKit) takes the screenshot, with SlyTerm's own windows excluded
so the terminal text is never read by mistake; `VNRecognizeTextRequest` (Vision, in the game's
languages or detecting them itself, fast level first, accurate as a fallback) reads it.

Each kind of source has a builder and a resolver: a sitemap, with Weebly's slugs spelling accents as
bare entity names (`au-delagrave-du-mur`) decoded back; a MediaWiki's `allpages` and `opensearch`,
its titles turned into addresses through `siteinfo`; Wowhead's suggestions, which name a page no
index could have; DofusDB's item API. Names are matched with a Levenshtein ratio plus containment
bonuses over an inverted index of their words.

Around the pointer, lines are grouped into blocks by a union-find over pairs that stack or share a
row, and ranked by their distance in text heights, so a Retina capture, a scaled UI and a
screenshot file rank alike.

All the matching runs on device. The only network calls are the weekly index refresh and the
sources' own search for what no index placed: the line under the pointer and at most the three
titles nearest it, plus a few more each time you press again.

### Icons and the startup animation

Both icons come from one piece of art, `Resources/StatusItemIcon.pdf`. The menu bar uses it
directly as a template image, and `swift Tools/make-icon.swift` sets it on a dark tile to rebuild
`Resources/AppIcon.icns`, the icon Finder, Spotlight and the Screen Recording list show. Run that
only when the art changes; `build.sh` just copies the result.

The startup animation (`StartupAnimation.swift`) is drawn with Core Animation from the icon's own
paths, stroked rather than filled so the underscore and the smirk can be the same curve with its
control points moved. Every frame is a pure function of time, driven by a `CADisplayLink`, which is
what lets `Tools/preview-startup-animation.swift` render any instant of it to a PNG for tuning,
and `Tools/make-readme-animation.swift` turn it into the README's GIF. Rerun that one after changing
the animation. The shell starts underneath right away; only the terminal view's alpha is held at 0
while the logo is up.

### Files on disk

| Path | What |
| --- | --- |
| `~/Library/Preferences/com.charlesmelki.slyterm.plist` | Every setting and the app's own state |
| `~/Library/Application Support/SlyTerm/lookup/` | One index per host, as JSON, rebuilt weekly |
| `~/Library/Logs/SlyTerm.log` | The debug trace, written only while `debug` is on |
| WebKit's usual places under `~/Library` | The web tabs' cookies and cache, shared by all of them, and the compiled blocking rules |
| `~/.claude/sessions/*.json` and Claude Code's transcripts | Read, never written |
| `~/.codex/sessions/` rollouts and `~/.codex/session_index.jsonl`, under `$CODEX_HOME` when the Codex process has it set | Read, never written |
| `~/.omp/agent/terminal-sessions/` and `~/.omp/agent/sessions/`, where omp's `PI_CONFIG_DIR`, `OMP_PROFILE`, `PI_CODING_AGENT_DIR` or `XDG_STATE_HOME` put them | Read, never written |
| `~/.pi/agent/sessions/`, where pi's `PI_CODING_AGENT_DIR`, `PI_CODING_AGENT_SESSION_DIR` or `--session-dir` put it | Read, never written |

## Migration notes

### Coming from HoverTerm

SlyTerm is the same app under a new name, with a new bundle identifier
(`com.charlesmelki.slyterm`), URL scheme (`slyterm://`) and tab variable (`SLYTERM_TAB_ID`).
Settings, hotkeys, the window frame and the last session are copied over from the old name on the
first launch. Screen Recording has to be granted again, and any hook or script that used
`hoverterm://` or `$HOVERTERM_TAB_ID` needs the new spelling. The old
`~/Library/Application Support/HoverTerm` cache, `~/Library/Logs/HoverTerm.log` and the
`com.charlesmelki.hoverterm` preferences can be deleted once the old app is gone.

### Dofus in English

The Dofus preset was French (Dofus pour les Noobs and DofusDB in French) before it became Dofus 3
in English. A Dofus game already stored keeps the sources it has; to switch, remove it and add
Dofus 3 from `+`, or add the Dofus Wiki to it. A new list, and a game added from the preset, get
the English ones.

### DofusDB in stored Dofus games

A Dofus game made before DofusDB was part of the preset gets it once, after its other sources, the
first time a version of SlyTerm that has it launches (`lookupGamesVersion` 1); remove it and it
stays removed. A version of SlyTerm from before DofusDB cannot read a game that has it: it leaves
that game out, and loses it for good the next time it saves the list. The list as it was before
DofusDB was added is kept under `lookupGames.v0`, so to go back to such a version, quit SlyTerm and
put that copy back first:

```sh
defaults write com.charlesmelki.slyterm lookupGames -string "$(defaults read com.charlesmelki.slyterm lookupGames.v0)"
```
