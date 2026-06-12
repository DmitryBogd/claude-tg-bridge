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

# Telegram sendMessage rejects text >4096 (HTTP 400). This (and any other) failure
# used to be swallowed by `>/dev/null || true` → /sessions "didn't work" silently.
# Now: split into chunks ≤TG_BYTES on line boundaries, LOG failures (so the next
# failure is diagnosable, not mute), and retry a failed HTML chunk (broken tag) as
# plain — visibly degraded beats silence.
# LIMIT IN BYTES, not code points: Telegram counts 4096 UTF-16 units, and UTF-8
# byte length is always ≥ UTF-16-unit length (ASCII 1B/1u, Cyrillic 2B/1u, astral
# emoji 4B/2u). So "bytes ≤ 4096" ⟹ "UTF-16 ≤ 4096" for any Unicode — no pile-up
# of emoji can breach the limit (a code-point cap fails to catch that).
TG_BYTES=4000          # headroom under 4096
MAX_CHUNKS=20          # cap of chunks per call (~80KB) — anti-flood/anti-ban
blen() { local LC_ALL=C; printf %s "${#1}"; }   # string length in BYTES (C locale)

# Send ONE chunk. Returns 0 only when Telegram answered ok=true.
_tg_send_chunk() {  # $1=text  $2=parse_mode (empty = plain)
  local resp ok
  resp=$(curl -s --max-time 15 -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    ${2:+--data-urlencode "parse_mode=$2"} \
    --data-urlencode "text=$1" 2>/dev/null)
  ok=$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)
  [ "$ok" = "true" ] && return 0
  printf '%s sendMessage FAIL (mode=%s len=%s): %s\n' "$(date '+%F %T')" \
    "${2:-plain}" "${#1}" "$(jq -rc '{error_code,description}' <<<"$resp" 2>/dev/null || printf '%.200s' "$resp")" \
    >> "$DIR/daemon.log"
  return 1
}

# Split text into chunks ≤TG_BYTES on line boundaries and send sequentially. Line
# boundaries are safe for our HTML: every list line is self-balanced (<b>…</b>,
# <code>…</code> wholly within one line), so each chunk stays valid. A single line
# longer than the limit (never in /sessions, but say/say_html are now the general
# path) is sliced char-wise by 900 code points (≤3600 bytes even for solid 4-byte
# emoji). If any chunk never went out (even as plain) — emit a visible marker so a
# partial delivery is not silent-by-omission. Flood guard: never send more than
# MAX_CHUNKS messages per call (no legit daemon message is that big; /sessions is
# bounded by the reaper); the elision is announced + logged, not mute.
_tg_send() {  # $1=text  $2=parse_mode
  local text="$1" mode="$2" chunk="" line failed=0 sent=0 capped=0
  emit() {
    sent=$((sent + 1))
    [ "$sent" -gt "$MAX_CHUNKS" ] && { capped=1; return; }
    _tg_send_chunk "$1" "$mode" || { [ -n "$mode" ] && _tg_send_chunk "$1" ""; } || failed=1
  }
  if [ "$(blen "$text")" -le "$TG_BYTES" ]; then emit "$text"
  else
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$(blen "$line")" -gt "$TG_BYTES" ]; then
        [ -n "$chunk" ] && { emit "$chunk"; chunk=""; }
        while [ "$(blen "$line")" -gt "$TG_BYTES" ]; do emit "${line:0:900}"; line="${line:900}"; done
        chunk="$line"; continue
      fi
      if [ -n "$chunk" ] && [ "$(blen "$chunk
$line")" -gt "$TG_BYTES" ]; then
        emit "$chunk"; chunk="$line"
      else
        chunk="${chunk:+$chunk
}$line"
      fi
    done <<<"$text"
    [ -n "$chunk" ] && emit "$chunk"
  fi
  if [ "$capped" = 1 ]; then
    _tg_send_chunk "✂️ message too large — showing first $MAX_CHUNKS parts ($sent total)" ""
    printf '%s flood cap: %s/%s parts sent (mode=%s)\n' "$(date '+%F %T')" "$MAX_CHUNKS" "$sent" "${mode:-plain}" >> "$DIR/daemon.log"
  fi
  [ "$failed" = 1 ] && _tg_send_chunk "⚠️ part of the message could not be sent — see daemon.log" ""
  return 0
}

say()      { _tg_send "$1" ""; }
# <code>…</code> in Telegram is copied on tap. Escape dynamic parts via esc().
say_html() { _tg_send "$1" "HTML"; }
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

# Remove dead sessions TOGETHER with their leftovers; a queue nobody will ever take
# is honestly bounced back to TG. PRIMARY signal — owning-process liveness (pid+
# pidstart written by the hook): a session is dead if the process is gone OR the pid
# was reused (lstart differs). A live process → KEEP regardless of age (a session
# working for a full day is valid). The age-reaper stays as BACKSTOP for old-format
# records with no pid:
#   • any record >12 h; or state=running >6 h (crash without SessionEnd).
# Fail-safe: when unsure, do NOT delete (empty pid / pid still claude → keep).
RUNNING_REAP=21600   # 6 h (only for records without a pid)
prune_sessions() {
  local now f sid last state tp act pend tm pid pidstart cur
  now=$(date +%s)
  shopt -s nullglob
  for f in "$SESSIONS"/*; do
    [ -f "$f" ] || continue
    sid=$(basename "$f")
    case "$sid" in *.tmp.*) continue ;; esac   # half-written tmp (SIGKILL mid-write) — not a record
    park_alive "$sid" && continue          # live park — never touch
    pid=$(field "$f" pid); pidstart=$(field "$f" pidstart)
    if [ -n "$pid" ] && [ -n "$pidstart" ]; then
      cur=$(ps -p "$pid" -o lstart= 2>/dev/null | xargs)
      # process alive AND the SAME one (lstart matched) → keep, regardless of age
      [ -n "$cur" ] && [ "$cur" = "$pidstart" ] && continue
      # else: process gone or pid reused → dead, removed below
    else
      # no pid OR no pidstart (old format / empty resolve) → age-reaper.
      # An empty pidstart is NOT treated as "process changed" — that's fail-safe (keep).
      last=$(field "$f" last); [ -n "$last" ] || last=0
      state=$(field "$f" state)
      tp=$(field "$f" tpath); act=$last
      [ -n "$tp" ] && [ -f "$tp" ] && { tm=$(fmtime "$tp"); [ "$tm" -gt "$act" ] && act=$tm; }
      if [ $(( now - act )) -gt 43200 ]; then :
      elif [ "$state" = "running" ] && [ $(( now - act )) -gt "$RUNNING_REAP" ]; then :
      else continue
      fi
    fi
    pend=$( { cat "$INBOX/$sid.taken" 2>/dev/null; cat "$INBOX/$sid" 2>/dev/null; } )
    [ -n "$pend" ] && say "⚠️ [$(field "$f" name)] session is inactive and was removed — NOT delivered: ${pend:0:500}"
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
    case "$(basename "$f")" in *.tmp.*) continue ;; esac   # half-written tmp — don't show
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
    # Proactive: dead sessions get cleaned even without a /sessions command. NB: a
    # mass reap with non-empty queues can briefly stall the poll (say→curl up to 15s
    # per chunk, serially, before this iteration's getUpdates) — rare, acceptable
    # (queues are usually empty).
    prune_sessions
    find "$MSGMAP" -type f -mmin +2880 -delete 2>/dev/null || true
    find "$PARKED" -type f -mmin +3 -delete 2>/dev/null || true
    # pending/answers (the tg-ask queue) are normally cleaned by tg-ask itself; but a
    # SIGKILL before its cleanup trap leaves an orphan forever. Questions time out at
    # 24h, so >48h is definitely dead. Closes a slow leak.
    find "$PENDING" -type f -mmin +2880 -delete 2>/dev/null || true
    find "$ANSWERS" -type f -mmin +2880 -delete 2>/dev/null || true
    # Orphaned tmp (SIGKILL in the ~ms window between printf and mv in the hook/daemon)
    # has no age-sweep of its own and would show as a junk row in /sessions. >60min =
    # definitely abandoned.
    find "$SESSIONS" -name '*.tmp.*' -mmin +60 -delete 2>/dev/null || true
    # daemon.log is both launchd stdout/stderr and the sendMessage-failure log;
    # cap at ~1MB → keep the last 500 lines. COPYTRUNCATE (cat > file, not mv):
    # preserves the inode, so the launchd fd (O_APPEND) stays valid and never
    # writes into a deleted inode.
    if [ -f "$DIR/daemon.log" ] && [ "$(wc -c < "$DIR/daemon.log" 2>/dev/null || echo 0)" -gt 1048576 ]; then
      tail -n 500 "$DIR/daemon.log" > "$DIR/daemon.log.rot" 2>/dev/null \
        && cat "$DIR/daemon.log.rot" > "$DIR/daemon.log" && rm -f "$DIR/daemon.log.rot"
    fi
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
