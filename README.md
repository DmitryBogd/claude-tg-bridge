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
  to Telegram in "away" or per-project tg-mode. Reply "так/yes/+" to allow,
  "ні/no/-" to deny. Silence for 4 min → falls back to the normal local dialog.

- **Session park** — when tg-mode is active, after each Claude turn the `Stop` hook
  mirrors the assistant's last reply to Telegram and parks, waiting for your
  message. Reply via Telegram to inject it into the session and continue.

- **`/sessions`** — bot command listing all active Claude sessions with their IDs.

## Architecture

```
Telegram ──→ tg-daemon.sh (permanent long-poll, launchd KeepAlive)
                │
                ├─ routes replies to → answers/<qid>   (tg-ask.sh waits here)
                └─ routes messages to → inbox/<sid>    (tg-session.sh park picks up)

tg-ask.sh      blocks polling answers/<qid>; fallback self-poll if daemon is down
tg-session.sh  SessionStart/Stop/End hooks; park loop; mirrors last reply to TG
tg-permission.sh  PermissionRequest hook; calls tg-ask with 240 s timeout
tg-mode.sh     per-project on/off toggle for tg-mode
```

The daemon is the **sole** `getUpdates` reader (Telegram only allows one per token).
Multiple concurrent agents are supported: each question gets a `#qXXXX` ID;
answer routing is via Telegram reply-to (message_id → msgmap/ lookup).

## Requirements

- macOS (uses launchd for auto-start; the scripts themselves run on any Linux/macOS with bash 4+, but the installer and daemon auto-restart are macOS-only)
- `bash`, `curl`, `jq`
- A Telegram bot token (`@BotFather`) + your personal chat ID

## Setup

### 1. Create a bot

1. Message `@BotFather` on Telegram → `/newbot` → get the token.
2. Get your chat ID: message `@userinfobot` or send a message to your bot then call
   `https://api.telegram.org/bot<TOKEN>/getUpdates`.

### 2. Install

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

### 3. Add hooks to Claude Code settings

Add the contents of `hooks-config.json` to the `"hooks"` key of your
`~/.claude/settings.json`. See [hooks-config.json](hooks-config.json) for the
full snippet.

### 4. Enable tg-mode for a project (optional)

```bash
cd /path/to/your-project
~/.claude/tg-hitl/tg-mode.sh on
```

Or enable globally (all projects) with away mode:
```bash
touch ~/.claude/tg-hitl/away          # enable
rm   ~/.claude/tg-hitl/away           # disable
```

## Usage

From a Claude agent:
```bash
# Block until the user replies (timeout 24 h)
~/.claude/tg-hitl/tg-ask.sh "Should I delete the old migration files? (yes/no)"

# Fire and forget
~/.claude/tg-hitl/tg-ask.sh --notify "Long task completed."
```

From Telegram (your phone):
- `/sessions` — list active Claude sessions
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
