#!/bin/bash
# tg-daemon.sh — the SOLE owner of Telegram getUpdates for the whole HITL channel.
#
# One permanent process reads updates and:
#   - routes answers: a reply to a message present in msgmap → its target
#     (q:<qid> → answers/<qid>, s:<sid> → inbox/<sid>); fallback — #q…/#s… tags
#     in the replied-to text OR in the message's own text; plain text while
#     EXACTLY ONE target is active (one question with NO live parks, or one live
#     park with NO questions) → that target; otherwise asks to answer with a reply;
#   - commands: /sessions (with 🟢/😴/✅/🟡 statuses), /help.
# Daemon liveness — the daemon.beat heartbeat file (touched every iteration;
# an iteration is ≤ ~60 s due to long-poll). kill -0 on a pid is unreliable
# (pid reuse). SESSION PARK liveness — mtime of parked/<sid> (the Stop hook
# touches it every ~3 s).
# Started via launchd (KeepAlive). If the daemon is dead, tg-ask has a self-poll
# fallback. Offline-resilient: backoff on network errors; Telegram keeps
# undelivered updates for 24 h.
# Testing: TG_DAEMON_TEST=1 source tg-daemon.sh — defines functions without
# starting the loop.
set -uo pipefail
# launchd often provides the C locale → bash mis-tokenizes a $variable adjacent
# to multibyte characters (non-ASCII text, «»). UTF-8 fixes that.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

DIR="${TG_HITL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
[ -f "$DIR/.env" ] && source "$DIR/.env"
# No config → a loud exit into the log (launchd restarts after ThrottleInterval),
# not an "unbound variable" crash under set -u at the first curl.
if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
  echo "tg-daemon: TG_TOKEN/TG_CHAT_ID not set in $DIR/.env — exiting" >&2
  return 1 2>/dev/null || exit 1
fi
API="${TG_API_BASE:-https://api.telegram.org}/bot${TG_TOKEN}"
PENDING="$DIR/pending"
ANSWERS="$DIR/answers"
SESSIONS="$DIR/sessions"
INBOX="$DIR/inbox"
PARKED="$DIR/parked"
MSGMAP="$DIR/msgmap"      # message_id → target (s:<sid> / q:<qid>); written by the sender
OFFSET_FILE="$DIR/offset"
PIDFILE="$DIR/daemon.pid"
BEAT="$DIR/daemon.beat"   # daemon liveness heartbeat
mkdir -p "$PENDING" "$ANSWERS" "$SESSIONS" "$INBOX" "$PARKED" "$MSGMAP"

say() {
  curl -s --max-time 15 -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
# <code>…</code> in Telegram is copied on tap. Escape dynamic parts via esc().
say_html() {
  curl -s --max-time 15 -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

fmtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# A park is alive = the marker exists AND its mtime is fresh (the Stop hook
# touches it every ~3 s). Self-heals after a SIGKILLed hook: the mtime goes
# stale within seconds.
park_alive() {
  local pf="$PARKED/$1"
  [ -f "$pf" ] && [ $(( $(date +%s) - $(fmtime "$pf") )) -le 15 ]
}

# "<number of live parks> <sid of the last one>" — for plain-text routing.
live_parks() {
  local pf sid n=0 hit=""
  shopt -s nullglob
  for pf in "$PARKED"/*; do
    sid=$(basename "$pf")
    park_alive "$sid" && { n=$((n + 1)); hit="$sid"; }
  done
  shopt -u nullglob
  echo "$n $hit"
}

# Remove stale sessions (>12 h without activity) TOGETHER with their leftovers;
# a queue nobody will ever take is honestly bounced back to TG.
prune_sessions() {
  local now f sid last pend
  now=$(date +%s)
  shopt -s nullglob
  for f in "$SESSIONS"/*; do
    [ -f "$f" ] || continue
    last=$(field "$f" last)
    [ -n "$last" ] && [ $(( now - last )) -gt 43200 ] || continue
    sid=$(basename "$f")
    pend=$( { cat "$INBOX/$sid.taken" 2>/dev/null; cat "$INBOX/$sid" 2>/dev/null; } )
    [ -n "$pend" ] && say "⚠️ [$(field "$f" name)] session went stale and was removed — NOT delivered: ${pend:0:500}"
    rm -f "$f" "$INBOX/$sid" "$INBOX/$sid.taken" "$DIR/lastmirror/$sid" "$PARKED/$sid"
  done
  shopt -u nullglob
}

# Build the /sessions text (pure echo, no sending — testable separately).
# Status: live park → 😴; state=running + fresh transcript → 🟢, stale →
# 🟡 (Esc fires no Stop event — the state may be stuck); state=idle → ✅ with time.
# The sid in <code> is deliberately WITHOUT "#s": several #s tags in one message
# would break fallback reply routing to this list (the regex takes the first match).
build_sessions_list() {
  local now f name cwd last sid state stopped tpath ago age act out="" n=0 status
  now=$(date +%s)
  shopt -s nullglob
  for f in "$SESSIONS"/*; do
    [ -f "$f" ] || continue
    name=$(esc "$(field "$f" name)")
    cwd=$(esc "$(field "$f" cwd)")
    last=$(field "$f" last); [ -n "$last" ] || last=$now
    state=$(field "$f" state)
    stopped=$(field "$f" stopped)
    tpath=$(field "$f" tpath)
    sid=$(basename "$f")
    if park_alive "$sid"; then
      status="😴 parked — waiting for your reply in TG"
    elif [ "$state" = "running" ]; then
      act="$last"
      [ -n "$tpath" ] && [ -f "$tpath" ] && act=$(fmtime "$tpath")
      age=$(( now - act ))
      if [ "$age" -le 180 ]; then
        if [ "$age" -lt 60 ]; then status="🟢 working (active ${age}s ago)"
        else status="🟢 working (active $(( age / 60 )) min ago)"; fi
      else
        status="🟡 possibly interrupted (Esc?) — no activity for $(( age / 60 )) min"
      fi
    elif [ "$state" = "idle" ]; then
      [ -n "$stopped" ] || stopped=$last
      status="✅ finished its turn $(( (now - stopped) / 60 )) min ago"
    else
      status="active $(( (now - last) / 60 )) min ago"   # old-format record
    fi
    out="$out

• <b>${name:-?}</b> — $status
<code>${sid}</code>
${cwd}"
    n=$((n + 1))
  done
  shopt -u nullglob
  [ "$n" -gt 0 ] && printf '%s' "$out"
}

list_sessions() {
  prune_sessions
  local body
  body=$(build_sessions_list)
  if [ -z "$body" ]; then
    say "No registered active sessions."
  else
    say_html "🖥 <b>Active Claude sessions</b>
(reply to a session's message, or use a #s&lt;first 8 chars of id&gt; tag in your text)$body"
  fi
}

# Full session_id by prefix — ONLY if the match is unique (otherwise nothing,
# to avoid delivering to the wrong session on an 8-hex prefix collision).
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

deliver_answer() {  # an answer to a tg-ask question
  printf '%s' "$2" > "$ANSWERS/$1.tmp" && mv "$ANSWERS/$1.tmp" "$ANSWERS/$1"
  rm -f "$PENDING/$1"
}
deliver_to_session() {  # a message to a session (the park loop or the next Stop picks it up)
  printf '%s\n' "$2" >> "$INBOX/$1"
}

# Confirm delivery to a session — ALWAYS with the project name. If the session is
# in a live park — stay silent: the injection itself sends "✅ [name] received";
# otherwise say "queued".
confirm_session() {
  local sid="$1" nm
  nm=$(field "$SESSIONS/$sid" name)
  if park_alive "$sid"; then
    :   # parked — the session itself will confirm on injection
  else
    say "✉️ [${nm:-?}] received — will deliver on that session's next turn."
  fi
}

# Route one text message.
# msgmap s:* records are NOT deleted after use (a repeat reply to the same anchor
# must keep working); cleanup is periodic, by age.
handle() {
  local text="$1" reply="$2" reply_mid="$3" spec qid sid8 tsid full nq parks np phit cleaned
  case "$text" in
    /sessions*) list_sessions; return ;;
    /help*)
      say "Commands:
/sessions — active Claude sessions (🟢 working · 😴 waiting for your reply · ✅ finished its turn · 🟡 possibly interrupted)
/help — this reference

To message a session — REPLY to one of its messages, or add a #s<first 8 chars of id> tag to your text (ids are in /sessions). If exactly one target is active, you can write without a reply. The bot confirms WHICH project received it."
      return ;;
  esac

  # 0) Most reliable: reply by message_id (works for ANY message of a session).
  # Validate reply_mid as an integer (a Telegram message_id is always an integer).
  if [ -n "$reply_mid" ] && [[ "$reply_mid" =~ ^[0-9]+$ ]] && [ -f "$MSGMAP/$reply_mid" ]; then
    spec=$(cat "$MSGMAP/$reply_mid")
    case "$spec" in
      q:*) qid=${spec#q:}
           if [ -f "$PENDING/$qid" ]; then deliver_answer "$qid" "$text"
           else say "That question is no longer active."; fi; return ;;
      s:*) tsid=${spec#s:}   # full sid from msgmap
           if [ -f "$SESSIONS/$tsid" ]; then deliver_to_session "$tsid" "$text"; confirm_session "$tsid"
           else say "That session is already closed — nowhere to deliver."; fi; return ;;
    esac
  fi
  # 1) Fallback: a #q text tag in the replied-to message (a tg-ask question).
  qid=$(sed -nE 's/.*#q([0-9a-f]{4}).*/\1/p' <<<"$reply" | head -1)
  if [ -n "$qid" ] && [ -f "$PENDING/$qid" ]; then deliver_answer "$qid" "$text"; return; fi
  # 2) Fallback: a #s text tag in the replied-to message (a session).
  sid8=$(sed -nE 's/.*#s([0-9a-f]{8}).*/\1/p' <<<"$reply" | head -1)
  if [ -n "$sid8" ]; then
    full=$(match_session "$sid8")
    [ -n "$full" ] && { deliver_to_session "$full" "$text"; confirm_session "$full"; return; }
  fi
  # 2.5) Tags in the message's OWN text — addressing without a reply
  # ("#sa1980da9 do X").
  qid=$(sed -nE 's/.*#q([0-9a-f]{4}).*/\1/p' <<<"$text" | head -1)
  if [ -n "$qid" ] && [ -f "$PENDING/$qid" ]; then
    cleaned=$(sed -E 's/#q[0-9a-f]{4}[[:space:]]*//' <<<"$text")
    deliver_answer "$qid" "$cleaned"; return
  fi
  sid8=$(sed -nE 's/.*#s([0-9a-f]{8}).*/\1/p' <<<"$text" | head -1)
  if [ -n "$sid8" ]; then
    full=$(match_session "$sid8")
    if [ -n "$full" ]; then
      cleaned=$(sed -E 's/#s[0-9a-f]{8}[[:space:]]*//' <<<"$text")
      deliver_to_session "$full" "$cleaned"; confirm_session "$full"; return
    fi
  fi
  # 3) Plain text without a reply → only when the target is UNAMBIGUOUS: exactly
  # one question and zero live parks (as before), OR exactly one live park and
  # zero questions. NEVER to a non-parked session without a reply ("guessing"
  # once delivered to the wrong session).
  nq=$(ls "$PENDING" 2>/dev/null | wc -l | tr -d ' ')
  parks=$(live_parks); np=${parks%% *}; phit=${parks#* }
  if [ "$nq" = "1" ] && [ "$np" = "0" ]; then deliver_answer "$(ls "$PENDING")" "$text"; return; fi
  if [ "$np" = "1" ] && [ "$nq" = "0" ] && [ -f "$SESSIONS/$phit" ]; then
    deliver_to_session "$phit" "$text"; confirm_session "$phit"; return
  fi
  say "↩️ REPLY to the specific message you mean (or add a #s<id> tag to your text) — otherwise I don't know who this is for. /sessions — the list."
}

# ── For unit tests: define the functions and skip the runtime. ──
[ "${TG_DAEMON_TEST:-0}" = "1" ] && return 0 2>/dev/null

# Single instance. "Already running" = a fresh heartbeat AND a live pid from
# PIDFILE. A fresh beat alone is NOT proof of life: after kickstart -k (SIGKILL,
# no trap) the beat stays fresh for ≤120 s and would block the replacement —
# real downtime on every restart. kill -0 alone lies too (pid reuse). Together —
# reliable, and both failure modes self-heal: the beat goes stale, a reused pid
# doesn't keep the beat fresh.
if [ -f "$BEAT" ] && [ $(( $(date +%s) - $(stat -f %m "$BEAT" 2>/dev/null || echo 0) )) -le 120 ]; then
  old=$(cat "$PIDFILE" 2>/dev/null || echo "")
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    echo "tg-daemon already running (pid $old, beat fresh)" >&2
    exit 0
  fi
  # beat is fresh but the process is gone — the predecessor was killed; take over now.
fi
if [ ! -f "$BEAT" ] && [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null || echo "")
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    echo "tg-daemon already running (pid $old)" >&2
    exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE" "$BEAT"' EXIT INT TERM

# Main loop: long-poll getUpdates with backoff on network errors.
# Hourly: clean up stale msgmap entries (>48 h — comfortably above the 24 h
# question timeout) and dead park markers (>3 min without a touch; live ones are
# touched every 3 s).
LAST_SWEEP=0
while true; do
  touch "$BEAT"
  now=$(date +%s)
  if [ $(( now - LAST_SWEEP )) -gt 3600 ]; then
    find "$MSGMAP" -type f -mmin +2880 -delete 2>/dev/null || true
    find "$PARKED" -type f -mmin +3 -delete 2>/dev/null || true
    LAST_SWEEP=$now
  fi
  OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo "")
  RESP=$(curl -s --max-time 60 \
    "$API/getUpdates?timeout=50${OFFSET:+&offset=$OFFSET}" 2>/dev/null || echo "")
  if [ -z "$RESP" ] || [ "$(jq -r '.ok // false' <<<"$RESP" 2>/dev/null)" != "true" ]; then
    sleep 3
    continue
  fi
  N=$(jq '.result | length' <<<"$RESP" 2>/dev/null || echo 0)
  for ((i = 0; i < N; i++)); do
    uid=$(jq -r ".result[$i].update_id" <<<"$RESP")
    # .caption — so a photo/file with a caption doesn't vanish silently.
    text=$(jq -r --arg cid "$TG_CHAT_ID" \
      ".result[$i].message | select((.chat.id|tostring) == \$cid) | .text // .caption // empty" <<<"$RESP")
    if [ -n "$text" ]; then
      reply=$(jq -r ".result[$i].message.reply_to_message.text // empty" <<<"$RESP")
      reply_mid=$(jq -r ".result[$i].message.reply_to_message.message_id // empty" <<<"$RESP")
      handle "$text" "$reply" "$reply_mid"
    else
      # A message without text/caption (voice, sticker) — an honest bounce
      # instead of silent consumption.
      has_msg=$(jq -r --arg cid "$TG_CHAT_ID" \
        ".result[$i].message | select((.chat.id|tostring) == \$cid) | .message_id // empty" <<<"$RESP")
      [ -n "$has_msg" ] && say "🤷 I only understand text (or a media caption) — please repeat in words."
    fi
    # Advance the offset AFTER handling: a crash before that → the update is
    # re-read (not lost; a duplicate delivery is possible — a deliberate
    # at-least-once choice).
    [ -n "$uid" ] && echo $((uid + 1)) > "$OFFSET_FILE"
  done
done
