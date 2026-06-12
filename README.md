# claude-tg-bridge

Telegram human-in-the-loop bridge for [Claude Code](https://claude.ai/code).

Lets autonomous Claude agents ask you questions, request permission confirmations,
and mirror their responses to your phone — all via a Telegram bot — while you're
away from the computer.

## What it does

- **`tg-ask.sh`** — agent calls this script; question flies to Telegram; script
  blocks until you reply (up to 24 h, runs as a background process). `--notify`
  mode for fire-and-forget notifications.

- **Permission confirmations** — `PermissionRequest` hook routes approval prompts
  to Telegram when per-project tg-mode is on. Reply "yes"/"+" to allow,
  "no"/"-" to deny. Silence for 4 min → falls back to the normal local dialog.

- **Session park** — when tg-mode is active, after each Claude turn the `Stop` hook
  mirrors the assistant's **final** reply to Telegram (it waits for the transcript
  to flush and skips intermediate status texts — a text is "final" only if no
  tool_use follows it) and parks, waiting for your message. Reply via Telegram to
  inject it into the session and continue; replying to the same anchor twice works,
  and you can address any session without a reply via a `#s<first 8 hex of id>` tag.

- **Background-agent wake** — if a background agent (Agent tool) finishes while its
  parent session is parked, the `SubagentStop` hook drops a wake marker and the park
  exits immediately, so the session processes the agent's result right away instead
  of waiting out the park window (up to 25 min). Stale markers from agents that
  finished mid-turn are discarded on the next `Stop`.

- **`/sessions`** — bot command listing all active Claude sessions with live status:
  🟢 working (turn in progress, by transcript mtime) · 😴 parked, waiting for your
  reply · ✅ finished its turn N min ago · 🟡 possibly interrupted (Esc fires no
  `Stop` event, so the state can go stale).

## Architecture

```
Telegram ──→ tg-daemon.sh (permanent long-poll, launchd KeepAlive)
                │
                ├─ routes replies to → answers/<qid>   (tg-ask.sh waits here)
                └─ routes messages to → inbox/<sid>    (tg-session.sh park picks up)

tg-ask.sh      blocks polling answers/<qid>; if the daemon is down it first tries a
               launchd kickstart, and only then self-polls (routing session replies
               too — advancing the shared getUpdates offset must never drop them)
tg-session.sh  SessionStart/Stop/End hooks; session state registry; park loop with
               mtime heartbeat; mirrors the FINAL reply to TG
tg-permission.sh  PermissionRequest hook; calls tg-ask with 240 s timeout
tg-mode.sh     per-project on/off toggle for tg-mode
```

The daemon is the **sole** `getUpdates` reader (Telegram only allows one per token).
Multiple concurrent agents are supported: each question gets a `#qXXXX` ID;
answer routing is via Telegram reply-to (message_id → msgmap/ lookup).

## Requirements

- macOS (see [Platform support](#platform-support) for Linux/Windows)
- `bash` (3.2+ — the stock macOS bash works), `curl`, `jq`
- A Telegram bot token (`@BotFather`) + your personal chat ID

## Platform support

| Platform | Status |
|---|---|
| **macOS** | ✅ Fully supported: installer, launchd auto-start/auto-restart. |
| **Linux** | ⚠️ The scripts are plain bash + curl + jq, but two macOS-isms must be patched: `stat -f %m` (BSD) → `stat -c %Y`, and the `launchctl kickstart` daemon-revival calls. Run `tg-daemon.sh` under a systemd user service instead of launchd. Untested — patches welcome. |
| **Windows (WSL2)** | ⚠️ The realistic path: run Claude Code *inside* WSL, apply the Linux notes above (WSL2 supports systemd user services). The hooks fire inside WSL, so the whole chain stays POSIX. Untested — reports welcome. |
| **Windows (native)** | ❌ Not supported. These are bash scripts wired into Claude Code hooks assuming a POSIX shell, a BSD/GNU userland, and a service manager for the always-on daemon — none of which exist natively. Use WSL2. |

## Setup

### Option A — let an AI agent set it up

Paste this into Claude Code (or any AI assistant with shell access) and answer
its questions:

```text
Set up claude-tg-bridge — a Telegram human-in-the-loop bridge for Claude Code
(https://github.com/DmitryBogd/claude-tg-bridge). Steps:

1. Verify prerequisites: macOS, bash, curl, jq (offer `brew install jq` if missing).
2. Clone https://github.com/DmitryBogd/claude-tg-bridge.git and run ./install.sh.
3. Walk me through creating a Telegram bot: I message @BotFather → /newbot →
   I get a token. Then help me find my numeric chat ID (e.g. via @userinfobot,
   or by messaging my new bot and calling getUpdates). Ask me for both values
   and write them into ~/.claude/tg-hitl/.env, keeping it chmod 600.
   NEVER print, log, or commit the token.
4. Restart the daemon: launchctl kickstart -k gui/$(id -u)/com.$(id -un).tg-hitl-daemon
   Verify it is alive: ~/.claude/tg-hitl/daemon.beat is fresh and
   ~/.claude/tg-hitl/daemon.log has no errors.
5. Merge the hooks from hooks-config.json into the "hooks" key of my
   ~/.claude/settings.json. Preserve my existing hooks; show me the diff before
   saving.
6. Send a test notification: ~/.claude/tg-hitl/tg-ask.sh --notify "claude-tg-bridge is up"
   and ask me to confirm it arrived in Telegram.
7. Tell me how to enable tg-mode for a project (~/.claude/tg-hitl/tg-mode.sh on)
   and remind me that hooks only apply to Claude Code sessions started AFTER this
   setup — running sessions must be restarted.
```

### Option B — manual

#### 1. Create a bot

1. Message `@BotFather` on Telegram → `/newbot` → get the token.
2. Get your chat ID: message `@userinfobot` or send a message to your bot then call
   `https://api.telegram.org/bot<TOKEN>/getUpdates`.

#### 2. Install

```bash
git clone https://github.com/DmitryBogd/claude-tg-bridge.git
cd claude-tg-bridge
./install.sh
```

`install.sh` will:
- Copy scripts to `~/.claude/tg-hitl/`
- Create `~/.claude/tg-hitl/.env` from `.env.example`
- Generate and load the launchd plist

Then edit `~/.claude/tg-hitl/.env`:
```
TG_TOKEN=1234567890:AAAA...
TG_CHAT_ID=123456789
```

Restart the daemon after editing `.env`:
```bash
launchctl kickstart -k gui/$(id -u)/com.$(id -un).tg-hitl-daemon
```

#### 3. Add hooks to Claude Code settings

Add the contents of `hooks-config.json` to the `"hooks"` key of your
`~/.claude/settings.json`. See [hooks-config.json](hooks-config.json) for the
full snippet. Hooks apply only to sessions started after the change.

#### 4. Enable tg-mode for a project

```bash
cd /path/to/your-project
~/.claude/tg-hitl/tg-mode.sh on
```

The per-project flag is the **only** switch. (Earlier versions also had a global
"away" file; it was removed — two switches with OR logic made disabling
confusing.)

## Usage

From a Claude agent:
```bash
# Block until the user replies (timeout 24 h)
~/.claude/tg-hitl/tg-ask.sh "Should I delete the old migration files? (yes/no)"

# Fire and forget
~/.claude/tg-hitl/tg-ask.sh --notify "Long task completed."
```

From Telegram (your phone):
- `/sessions` — list active Claude sessions with live statuses
- `/help` — quick reference
- Reply to a bot message to route your text to the right session/question

## Operations

```bash
# Daemon status
launchctl list com.$(id -un).tg-hitl-daemon

# Restart daemon
launchctl kickstart -k gui/$(id -u)/com.$(id -un).tg-hitl-daemon

# Tail daemon log
tail -f ~/.claude/tg-hitl/daemon.log

# tg-mode status for current project
~/.claude/tg-hitl/tg-mode.sh status
```

## Known limitations

- **Two-reader `getUpdates` window.** While the daemon is being restarted and a
  `tg-ask` fallback poller is active, both may briefly call `getUpdates`; Telegram
  confirms updates by the highest offset seen, so one reader can in principle
  confirm a batch the other never processed. Mitigated (daemon-dead gate,
  kickstart-first, offset advanced only after routing) but not hard-interlocked.
- Sessions opened **before** the hooks were installed are not in the registry
  (Claude Code snapshots hook config at session start) — restart them or re-apply
  via `/hooks`.
- A fully idle session outside the park window cannot be "woken up" from Telegram —
  there is no API to append to a live session; your message is queued in `inbox/`
  and delivered at the end of the session's next turn.
- macOS-only out of the box (launchd, BSD `stat`) — see
  [Platform support](#platform-support).

## Security notes

- `.env` contains the bot token — keep it `chmod 600`, never commit it.
- The token is passed as part of the Telegram API URL (`/bot<TOKEN>/...`) and will
  be visible in `ps` output during the ~50 s long-poll curl. On a personal machine
  this is acceptable; if concerned, use a dedicated low-privilege bot account.
- Only messages from `TG_CHAT_ID` are processed — all other senders are silently
  ignored.
- QIDs are 16-bit random hex (65 536 values), sufficient for personal use with few
  concurrent questions.

## License

MIT
