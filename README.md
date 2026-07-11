# Claudius — Claude Code usage limits in your macOS menu bar

**See how much of your Claude Code plan is left — the 5-hour session window and the weekly limit — at a glance, without opening a dashboard or running `/usage`.**

Claudius is a lightweight, open-source **macOS menu bar app** for [Claude Code](https://claude.com/claude-code) power users on **Pro and Max plans**. It shows your remaining **session and weekly usage** as two colour-coded gauges, warns you when you're burning through your **rate limit** too fast, and breaks down which of your sessions consumed the most — all read locally from the OAuth token Claude Code already stores and your local session transcripts. No login, no account, no telemetry.

> ⚠️ Unofficial and not affiliated with Anthropic. It reads an **undocumented** usage endpoint via the token Claude Code keeps in your Keychain, so it can break without notice. Personal tool, shared as-is.

---

## Why Claudius?

- **Never get surprised by a rate limit again.** Two menu-bar gauges show remaining % for your **5-hour session** and **weekly** windows, each with a live reset countdown.
- **Know if you're on pace.** A subtle arrow flags when your weekly burn is running ahead of — or behind — a healthy rate, so you can ease off *before* you hit the wall, not after.
- **See what's eating your quota.** A per-session consumption breakdown over the **last 5h / day / week / all-time** ranks which Claude Code sessions used the most, **model-weighted** so Opus, Sonnet, Haiku and Fable compare fairly.
- **Optional cache keep-alive.** Keep a long conversation's prompt cache warm so resuming stays fast — and it *refuses to warm a dead cache*, so it never wastes usage on a session that's already cold.
- **100% local & private.** Reads the token from your macOS **Keychain** and transcripts from `~/.claude`. Nothing leaves your machine except the call to Anthropic's own usage endpoint.

## Features

| | |
|---|---|
| **Session + weekly gauges** | Remaining %, colour-coded, in the menu bar |
| **Pace arrow** | Weekly burn rate: ↑ too fast, ↓ behind, hidden when on-track |
| **Reset countdowns** | Exact time until each window resets |
| **Per-session consumption** | Model-weighted usage share, filterable by 5h / 1d / 1w / all |
| **Cache warmth + keep-alive** | Optional, per session; never warms a cold cache |
| **Limit / reset notifications** | Optional background watcher (launchd) |
| **CLI included** | `claude-usage` works standalone in scripts and CI |

## What everything means

**In the menu bar** — two coloured badges, and sometimes a small arrow:

- **Left badge (circle) = your 5-hour limit, right badge (rounded square) = your weekly limit.** The number is how much you have **left**; the colour runs green → yellow → orange → red as it gets low.
- **The arrow** shows only when your weekly pace is off: **↑** you're burning through it fast, **↓** you're well under. No arrow means you're on track.

**Click the icon** to open the panel:

- **Session / Weekly / Fable bars** — how much of each limit is left, and when it resets.
- **Sessions** — your recent Claude Code chats. The green bar is *cache warmth*: how much longer that chat will resume quickly (e.g. "~59m left", or "expired"). The **🔥 flame** keeps a chat warm automatically; the **↻** refreshes one right now (uses a little quota).
- **Show consumption** — which chats have used the most of your allowance, over the last **5h / day / week / all time**.
- **Auto-refresh 5h limit** — when on, it starts a fresh 5-hour limit the moment your current one resets, so you're not left waiting on it.

## Install

Requires macOS 13+, the Xcode command-line tools (`swiftc`), `python3`, and an authenticated Claude Code CLI (that's where the Keychain token comes from).

```sh
# 1. Backend CLI
mkdir -p ~/.local/bin
install -m 0755 claude-usage ~/.local/bin/claude-usage

# 2. The app  → /Applications/Claudius.app
./build.sh
open /Applications/Claudius.app

# 3. (optional) notifications on limit reached / reset
sed "s|__HOME__|$HOME|g" com.ark.claude-usage.plist > ~/Library/LaunchAgents/com.ark.claude-usage.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ark.claude-usage.plist
```

## How it works

The macOS app (SwiftUI, `MenuBarExtra`) shells out to a small Python backend, `claude-usage`, which:

1. reads the `Claude Code-credentials` OAuth token from your login **Keychain**,
2. calls Anthropic's usage endpoint (the one behind `/usage`) for session/weekly/model limits, and
3. parses your local `~/.claude` transcripts for per-session cache warmth and consumption — deduped by message id, so streaming rewrites and resumed sessions aren't double-counted.

Because the token lives only in the Keychain and the app runs the `claude` CLI for keep-alive, it **can't be sandboxed** for the Mac App Store — distribute a notarized build instead.

<details>
<summary><strong>How do I check my Claude Code usage without opening a dashboard?</strong></summary>

Claudius surfaces the same numbers as the in-app `/usage` command, but always-on in your menu bar. Two badges show **% left** for the session (5h) and weekly windows; click for full bars, reset times, and a one-tap refresh. If you prefer the terminal, the bundled `claude-usage` CLI prints the same data:

```sh
claude-usage            # live view of session / weekly / model limits
claude-usage check      # prints true/false — are you rate-limited right now?
claude-usage sessions   # recent sessions + cache warmth
claude-usage cost --since 1d   # which sessions consumed the most today
```

</details>

## Keywords

Claude Code usage tracker · Claude rate limit menu bar · Claude Max weekly limit macOS · Claude Pro 5-hour session window · Anthropic usage monitor · claude-usage CLI · token quota tracker for macOS · CodexBar alternative · ccusage alternative · Claude-Code-Usage-Monitor alternative.
