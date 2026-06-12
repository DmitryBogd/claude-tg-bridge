#!/bin/bash
# tg-ask.sh — human-in-the-loop via Telegram.
#
#   tg-ask.sh --notify "text"            send a notification, don't wait for a reply
#   tg-ask.sh "question" [timeout_sec]   send a question and wait for the answer
#                                        (default 86400 s = 24 h; exit 124 on no answer)
#
# Every question gets an ID like #q3f2a. Answer routing:
#   - a Telegram reply to a specific question → goes to whoever asked it;
#   - plain text while exactly one question is active → goes to that question;
#   - otherwise the bot asks you to answer with a reply.
#
# How answers are received:
#   - PRIMARY: getUpdates is read by the permanent tg-daemon.sh (one reader per
#     token), which files answers into answers/<qid>. tg-ask only waits for its file.
#   - Daemon dead → FIRST kickstart it via launchd (it's KeepAlive anyway) and
#     keep waiting for the file. Self-polling is the last resort, and it ALSO
#     routes session replies (msgmap/#s → inbox/<sid>): advancing the offset
#     confirms the WHOLE batch to Telegram, so everything read must be filed,
#     or it is lost forever (an older version silently "ate" session replies).
# State: pending/, answers/, offset.fallback, daemon.beat, poll.lock. Config: .env.
set -uo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

DIR="${TG_HITL_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=/dev/null
[ -f "$DIR/.env" ] && source "$DIR/.env"
# No config → honest exit 124 (same as "no answer"): callers fall back to their
# normal dialog instead of crashing with "unbound variable" under set -u.
if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
  echo "NO_RESPONSE: TG_TOKEN/TG_CHAT_ID not set in $DIR/.env" >&2
  exit 124
fi
API="${TG_API_BASE:-https://api.telegram.org}/bot${TG_TOKEN}"
PENDING="$DIR/pending"
ANSWERS="$DIR/answers"
MSGMAP="$DIR/msgmap"
SESSIONS="$DIR/sessions"
INBOX="$DIR/inbox"
OFFSET_FILE="$DIR/offset.fallback"   # the fallback poller's own cursor (never touches the daemon's offset)
PIDFILE="$DIR/daemon.pid"
BEAT="$DIR/daemon.beat"
LOCK="$DIR/poll.lock"
DAEMON_LABEL="com.$(id -un).tg-hitl-daemon"
mkdir -p "$PENDING" "$ANSWERS" "$MSGMAP" "$SESSIONS" "$INBOX"

send() {
  curl -s --max-time 15 -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1
}

if [ "${1:-}" = "--notify" ]; then
  send "🔔 ${2:?usage: tg-ask.sh --notify <text>}"
  exit 0
fi

QUESTION="${1:?usage: tg-ask.sh [--notify] <text> [timeout_sec]}"
TIMEOUT="${2:-86400}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
QID=$(hexdump -n2 -e '/2 "%04x"' /dev/urandom)

cleanup() { rm -f "$PENDING/$QID" "$ANSWERS/$QID"; }
trap cleanup EXIT

# Daemon liveness — heartbeat file (touched every iteration, iteration ≤ ~60 s);
# kill -0 on the pid is only a transition-period fallback (pid reuse lies).
daemon_alive() {
  local p
  if [ -f "$BEAT" ]; then
    [ $(( $(date +%s) - $(stat -f %m "$BEAT" 2>/dev/null || echo 0) )) -le 120 ]
    return
  fi
  [ -f "$PIDFILE" ] || return 1
  p=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# Wait for our answer to appear in answers/<QID> (placed there either by the
# daemon or, in fallback mode, by another waiter). Shared by both modes.
finish_if_answered() {
  if [ -f "$ANSWERS/$QID" ]; then
    local ANSWER; ANSWER=$(cat "$ANSWERS/$QID")
    send "✅ #q$QID — received, continuing."
    echo "$ANSWER"
    exit 0
  fi
}

echo "$QUESTION" > "$PENDING/$QID"
# Send the question and capture its message_id → reply binding by id (more
# reliable than the #q tag). Up to 3 attempts: without a message_id, reply
# routing only works via the text tag.
QMID=""
for _try in 1 2 3; do
  QMID=$(curl -s --max-time 15 -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=❓ #q$QID
$QUESTION

↩️ Answer by replying to this exact message." 2>/dev/null | jq -r '.result.message_id // empty' 2>/dev/null)
  [ -n "$QMID" ] && break
  sleep 2
done
[ -n "$QMID" ] && echo "q:$QID" > "$MSGMAP/$QMID"

# ── DAEMON mode: just wait for the answer file, never touch getUpdates. ──
if daemon_alive; then
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    finish_if_answered
    sleep 2
    daemon_alive || break   # daemon died while we waited → kickstart/fallback
  done
  finish_if_answered
fi

# ── FALLBACK: no daemon — route updates ourselves (no need for a full copy of
# the daemon's rules: questions + session replies via msgmap/#s; rest — a hint). ──
match_session() {
  local pref="$1" f sid hit="" n=0
  shopt -s nullglob
  for f in "$SESSIONS"/*; do
    sid=$(basename "$f")
    case "$sid" in "$pref"*) hit="$sid"; n=$((n + 1)) ;; esac
  done
  shopt -u nullglob
  [ "$n" = 1 ] && echo "$hit"
}

route_updates() {
  local resp="$1" n i text reply reply_mid spec qid sid8 tsid full target
  n=$(jq '.result | length' <<<"$resp") || return
  for ((i = 0; i < n; i++)); do
    text=$(jq -r --arg cid "$TG_CHAT_ID" \
      ".result[$i].message | select((.chat.id|tostring) == \$cid) | .text // .caption // empty" \
      <<<"$resp")
    [ -n "$text" ] || continue
    reply=$(jq -r ".result[$i].message.reply_to_message.text // empty" <<<"$resp")
    reply_mid=$(jq -r ".result[$i].message.reply_to_message.message_id // empty" <<<"$resp")
    # 0) msgmap by message_id — both questions and sessions.
    if [ -n "$reply_mid" ] && [[ "$reply_mid" =~ ^[0-9]+$ ]] && [ -f "$MSGMAP/$reply_mid" ]; then
      spec=$(cat "$MSGMAP/$reply_mid")
      case "$spec" in
        q:*) qid=${spec#q:}
             if [ -f "$PENDING/$qid" ]; then
               printf '%s' "$text" > "$ANSWERS/$qid.tmp" && mv "$ANSWERS/$qid.tmp" "$ANSWERS/$qid"
               rm -f "$PENDING/$qid"
             fi; continue ;;
        s:*) tsid=${spec#s:}
             if [ -f "$SESSIONS/$tsid" ]; then
               printf '%s\n' "$text" >> "$INBOX/$tsid"
               send "✉️ received — will deliver to the session on its next turn."
             fi; continue ;;
      esac
    fi
    # 1) #q tag in the replied-to message.
    qid=$(sed -nE 's/.*#q([0-9a-f]{4}).*/\1/p' <<<"$reply" | head -1)
    if [ -n "$qid" ] && [ -f "$PENDING/$qid" ]; then
      printf '%s' "$text" > "$ANSWERS/$qid.tmp" && mv "$ANSWERS/$qid.tmp" "$ANSWERS/$qid"
      rm -f "$PENDING/$qid"
      continue
    fi
    # 2) #s tag in the replied-to message or in the text itself → session.
    sid8=$(sed -nE 's/.*#s([0-9a-f]{8}).*/\1/p' <<<"$reply" | head -1)
    [ -n "$sid8" ] || sid8=$(sed -nE 's/.*#s([0-9a-f]{8}).*/\1/p' <<<"$text" | head -1)
    if [ -n "$sid8" ]; then
      full=$(match_session "$sid8")
      if [ -n "$full" ]; then
        printf '%s\n' "$(sed -E 's/#s[0-9a-f]{8}[[:space:]]*//' <<<"$text")" >> "$INBOX/$full"
        send "✉️ received — will deliver to the session on its next turn."
        continue
      fi
    fi
    # 3) Exactly one active question → it gets the text.
    if [ "$(ls "$PENDING" | wc -l | tr -d ' ')" = "1" ]; then
      target=$(ls "$PENDING")
      printf '%s' "$text" > "$ANSWERS/$target.tmp" && mv "$ANSWERS/$target.tmp" "$ANSWERS/$target"
      rm -f "$PENDING/$target"
      continue
    fi
    send "⚠️ The TG daemon is down, I'm in fallback mode. Reply to the specific message (#q…/#s…)."
  done
}

# Skipping the old backlog is allowed ONLY if nothing belongs to anyone: we are
# the only question AND there are no registered sessions (an offset jump
# confirms everything skipped to Telegram — for session replies that would be
# a silent loss).
if [ "$(ls -1 "$PENDING" 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
   && [ -z "$(ls -A "$SESSIONS" 2>/dev/null)" ]; then
  LAST=$(curl -s --max-time 15 "$API/getUpdates?offset=-1&timeout=0" 2>/dev/null \
    | jq -r '.result[-1].update_id // empty')
  [ -n "$LAST" ] && echo $((LAST + 1)) > "$OFFSET_FILE"
fi

LAST_KICK=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  finish_if_answered
  # The daemon may have come back (launchd) — hand polling back to it.
  if daemon_alive; then sleep 2; continue; fi
  # Try to revive the daemon (KeepAlive; at most once per 60 s).
  if [ $(( $(date +%s) - LAST_KICK )) -gt 60 ]; then
    launchctl kickstart -k "gui/$(id -u)/$DAEMON_LABEL" >/dev/null 2>&1 || true
    LAST_KICK=$(date +%s)
    sleep 5
    continue
  fi
  if ! mkdir "$LOCK" 2>/dev/null; then
    HOLDER=$(cat "$LOCK/pid" 2>/dev/null || echo "")
    if [ -n "$HOLDER" ] && ! kill -0 "$HOLDER" 2>/dev/null; then
      rm -f "$LOCK/pid" && rmdir "$LOCK" 2>/dev/null
    fi
    sleep 2
    continue
  fi
  echo $$ > "$LOCK/pid"
  trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; cleanup' EXIT
  OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo "")
  RESP=$(curl -s --max-time 35 \
    "$API/getUpdates?timeout=25${OFFSET:+&offset=$OFFSET}" 2>/dev/null || echo '{}')
  route_updates "$RESP"
  # Advance the offset AFTER filing (at-least-once, same as the daemon): a crash
  # mid-routing → the batch is re-read, not "confirmed and lost".
  MAXID=$(jq -r '.result[-1].update_id // empty' <<<"$RESP" 2>/dev/null)
  [ -n "$MAXID" ] && echo $((MAXID + 1)) > "$OFFSET_FILE"
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null
  trap cleanup EXIT
done

echo "NO_RESPONSE: the user did not reply within ${TIMEOUT}s" >&2
exit 124
