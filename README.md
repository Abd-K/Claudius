# Claudius

*Claude Code usage at a glance.*

A macOS menu bar app that shows how much of your Claude Code subscription limits
you have left — the 5-hour session window and the weekly window — plus per-session
cache warmth and consumption. No dashboards, no logins: it reads the same data
`/usage` shows and your local session transcripts.

> Personal tool. It talks to an **undocumented** Anthropic usage endpoint using the
> OAuth token Claude Code already stores in your Keychain, so it can break without
> notice. Not affiliated with Anthropic.

## What it shows

- **Two menu-bar circles** — session (5h) and weekly — coloured by how much is left,
  with a pace arrow on the weekly (↑ burning fast, ↓ behind, hidden when on-track).
- **Popover** — full bars with reset countdowns, an available/limited badge, and a
  one-tap refresh.
- **Sessions** — recent Claude Code sessions with cache warmth (measured from the
  last real reply, not a file touch), an optional keep-alive that only ever extends
  a *live* cache, and a collapsible **consumption** view ranking sessions by share
  of usage over 5h / 1d / 1w / all-time.

## Parts

| File | What it is |
|---|---|
| `ClaudiusApp.swift`, `SessionsFeature.swift` | the SwiftUI menu-bar app |
| `claude-usage` | Python backend: reads the Keychain token, calls the usage endpoint, parses transcripts. The app shells out to it. |
| `build.sh` | compiles + ad-hoc-signs the app into `/Applications/Claudius.app` |
| `make_icon.sh` / `make_icon.swift` | regenerate `AppIcon.icns` |
| `com.ark.claude-usage.plist` | optional launchd watcher for reset/limit notifications |

## Install

Requires macOS 13+, the Xcode command-line tools (`swiftc`), `python3`, and an
authenticated Claude Code CLI (that's where the Keychain token comes from).

```sh
# 1. Backend CLI
install -m 0755 claude-usage ~/.local/bin/claude-usage

# 2. The app  → /Applications/Claudius.app
./build.sh
open /Applications/Claudius.app

# 3. (optional) background notifications on limit reached / reset
cp com.ark.claude-usage.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ark.claude-usage.plist
```

The CLI is usable on its own: `claude-usage` (live view), `claude-usage check`
(true/false), `claude-usage sessions`, `claude-usage cost --since 1d`.

## Notes

- The token lives only in the login Keychain, and the app shells out to the `claude`
  CLI for keep-alive — so this can't be sandboxed for the Mac App Store. Distribute
  notarized instead.
- Keep-alive costs real quota (each refresh re-reads the session's context), so it's
  off by default and refuses cold sessions.
