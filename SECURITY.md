# Security

## Reporting a vulnerability

Please do not report a security problem in a public issue, a discussion or a pull request. Use
GitHub's private reporting instead: on the repository's **Security** tab, choose **Report a
vulnerability**, or open [the form](https://github.com/MushkyQT/slyterm/security/advisories/new)
directly. Only the maintainer sees the report, and the fix is worked out in the advisory it opens.

Please include:

- what an attacker needs (a page open in a web tab, a URL opened on the Mac, a game file imported,
  a transcript Claude wrote) and what they get;
- the steps to reproduce it, the version in About SlyTerm (or, for a copy you built, the commit:
  `git rev-parse --short HEAD`) and your macOS version;
- the relevant lines of `~/Library/Logs/SlyTerm.log` with `debug` on, if they help. The log holds
  text read off your screen, folder paths and what Claude was asked to do, so remove anything that
  is not yours to share.

When a fix is on `main`, the advisory is published, with credit to you unless you would rather not.

## Supported versions

Only the latest release on [GitHub Releases](https://github.com/MushkyQT/SlyTerm/releases) and the
latest commit on `main` are supported. Fixes land on `main` and ship in the next release, which the
app offers as an update.

## What counts

SlyTerm types into terminals, signals the processes in them, reads the screen and answers a URL
scheme, so these matter most:

- **A keystroke or a signal nobody asked for.** Allow or refuse reaching a prompt other than the
  one the card showed, or getting through while one of its checks fails. Bringing a session in
  typing a command other than the one it shows, or stopping or closing a process or tab other than
  the one picked.
- **A `slyterm://` URL that does more than [the URL list](docs/TECHNICAL.md#url-scheme) says**,
  such as answering a prompt while `activityAnswerURLs` is off. Any local process can open a URL,
  so every route has to be safe to call from one.
- **The screen captured at any other time than a lookup**, or what a lookup read sent anywhere but
  the game's own sources.
- **A page in a web tab getting out of it**: reading files, reaching a terminal, typing, or
  capturing the screen.
- **A crafted file or response doing harm**: a `.slyterm-game.json`, a Claude Code transcript or
  registry entry, or a site's answer that makes the app crash or do something the user did not
  ask for.
- **An update installed without passing its checks**: a feed or DMG not signed with SlyTerm's
  update key, or an app not signed with its Developer ID, being accepted, or the updater opening a
  window over the game on its own.
- **Anything that makes SlyTerm send input to a game** or read its memory or traffic, which can get
  a player banned. See the [principles](docs/TECHNICAL.md#principles).

Not in scope:

- Problems in SwiftTerm, Sparkle, WebKit or macOS themselves. Report those to
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm),
  [Sparkle](https://github.com/sparkle-project/Sparkle/security) or
  [Apple](https://security.apple.com).
- What a site shows or does inside its own web tab, within WebKit's sandbox.
- Changing SlyTerm's preferences or its files on disk: a process that can do that already runs as
  the user.
