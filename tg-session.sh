#!/bin/bash
# tg-session.sh — registry of active Claude sessions + message delivery + tg-mode "park".
# Called from hooks:
#   SessionStart      → start  (register; source=startup/clear resets state to idle)
#   UserPromptSubmit  → beat   (refresh activity; state=running)
#   Stop              → stop   (state=idle; inject queued messages; in tg-mode —
#                               mirror the FINAL reply to TG + park with heartbeat)
#   SessionEnd        → end    (remove the record; undelivered inbox — bounce to TG)
# Argument $1 = event. stdin = hook JSON (session_id, cwd, transcript_path, ...).
# Registry: sessions/<sid> — key=value (name/cwd/started/last/state/stopped/tpath),
# written atomically (tmp+mv). Queue: inbox/<sid>. Park: parked/<sid> — liveness
# is judged by mtime (the park loop touches the file every iteration), NOT by
# kill -0 on a pid (pid reuse yields false-alive parks after SIGKILL).
# Testing: TG_SESSION_TEST=1 source tg-session.sh — defines functions without running.
set -uo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # launchd's C locale breaks tokenization of non-ASCII text

DIR="${TG_HITL_DIR:-$HOME/.claude/tg-hitl}"
SESSIONS="$DIR/sessions"
INBOX="$DIR/inbox"
PARKED="$DIR/parked"
MSGMAP="$DIR/msgmap"
LASTMIRROR="$DIR/lastmirror"   # hash of the last mirrored reply per session (dedup)
mkdir -p "$SESSIONS" "$INBOX" "$PARKED" "$MSGMAP" "$LASTMIRROR"
[ -f "$DIR/.env" ] && . "$DIR/.env"
API="${TG_API_BASE:-https://api.telegram.org}/bot${TG_TOKEN:-}"

# Max time the park waits for your message (s). The window + the mirror must
# fit into the Stop hook's timeout (1800 in settings.json) — see HOOK_BUDGET.
PARK_SECS="${TG_PARK_SECS:-1500}"
MIRROR_WAIT="${TG_MIRROR_WAIT:-25}"   # ceiling for waiting for the final text in the transcript, s
HOOK_BUDGET=1740                      # hard lifetime limit of the stop hook (60 s margin below 1800)

# ── Registry record ───────────────────────────────────────────────────────────
read_field() { sed -n "s/^$1=//p" "$f" 2>/dev/null | head -1; }

# Owning claude process (so the daemon can externally check liveness): walk up from
# $PPID to the first ancestor whose comm contains lowercase "claude" (the CLI
# native-binary; the Desktop "Claude" has a capital C and does NOT match — good).
# Echo "<pid>\t<lstart>", where lstart (start time) pins process IDENTITY against
# pid-reuse: a reused pid has a different lstart → the daemon honestly treats the
# session as dead. Nothing = not found.
_claude_proc() {
  local p="${PPID:-0}" hop comm ls
  for hop in 1 2 3 4 5 6; do
    { [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; } || break
    comm=$(ps -p "$p" -o comm= 2>/dev/null)
    case "$comm" in
      # lstart is mandatory: without it pid-reuse can't be told apart, so an empty
      # lstart (process vanished between the two ps calls) → emit NO pid at all
      # (fail-safe: a pid-less record goes to the age-reaper, not to a wrong deletion
      # of a live session with an empty pidstart).
      *claude*) ls=$(ps -p "$p" -o lstart= 2>/dev/null | xargs); [ -n "$ls" ] && printf '%s\t%s' "$p" "$ls"; return 0 ;;
    esac
    p=$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 0
}

# save_session <state> [stopped] — atomically rewrite the record, preserving
# started and any fields absent in this hook call (tpath may be empty on start/end).
# pid/pidstart are resolved on EVERY event (save_session is a fixed printf that does
# not carry unknown fields; resolving each time avoids the Stop-rewrite wiping them).
# Resolve miss → preserve the previous value (fail-safe: better to keep the old pid
# than to wipe it and rely on the age-reaper alone).
save_session() {
  local nowts started stopped tp nm cw proc pid pidstart
  nowts=$(date +%s)
  started=$(read_field started); [ -n "$started" ] || started=$nowts
  stopped="${2:-$(read_field stopped)}"
  tp="$tpath";  [ -n "$tp" ] || tp=$(read_field tpath)
  nm="$name";   [ -n "$nm" ] || nm=$(read_field name)
  cw="$cwd";    [ -n "$cw" ] || cw=$(read_field cwd)
  proc=$(_claude_proc)
  if [ -n "$proc" ]; then pid=${proc%%$'\t'*}; pidstart=${proc#*$'\t'}
  else pid=$(read_field pid); pidstart=$(read_field pidstart); fi
  printf 'name=%s\ncwd=%s\nstarted=%s\nlast=%s\nstate=%s\nstopped=%s\ntpath=%s\npid=%s\npidstart=%s\n' \
    "$nm" "$cw" "$started" "$nowts" "$1" "$stopped" "$tp" "$pid" "$pidstart" > "$f.tmp.$$" \
    && mv "$f.tmp.$$" "$f"
  # Observability on ALL events (not just start): if the record ends up pid-less the
  # walk-up found no claude ancestor → liveness-reaping is disabled for it (age-reaper
  # only). A systematic miss (a new launch model) must be visible in the log.
  [ -z "$pid" ] && printf '%s session-register: no claude ancestor for %s (cwd=%s)\n' \
    "$(date '+%F %T')" "$sid" "$cw" >> "$DIR/daemon.log"
}

# ── Telegram ──────────────────────────────────────────────────────────────────
tg() {  # send plain text to TG (best-effort)
  [ -n "${TG_TOKEN:-}" ] || return 0
  curl -s --max-time 15 -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
# send and return the message_id; 3 attempts. Failure → return 1 (do NOT park
# for the full window without an anchor: there would be nothing to reply to).
send_id() {
  [ -n "${TG_TOKEN:-}" ] || return 1
  local try resp mid
  for try in 1 2 3; do
    resp=$(curl -s --max-time 15 -X POST "$API/sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=$1" 2>/dev/null)
    mid=$(jq -r '.result.message_id // empty' <<<"$resp" 2>/dev/null)
    [ -n "$mid" ] && { echo "$mid"; return 0; }
    sleep 2
  done
  return 1
}

# Is tg-mode active for this cwd? (per-project flag; the global "away" mode was
# removed — OR logic of two switches made disabling confusing)
tg_mode_on() {
  [ -n "$cwd" ] && [ -f "$DIR/projects/$(printf '%s' "$cwd" | sed 's#/#%#g')" ]
}

# ── Mirror candidate ──────────────────────────────────────────────────────────
# Takes the LAST assistant text and decides whether it is FINAL: no tool_use
# after it (or inside it). Intermediate status texts always have tool activity
# after them — this cuts off the "mirrored a status instead of the reply" class.
# Slice — 3000 CODEPOINTS in jq (a byte-wise head -c cut UTF-8 mid-character →
# Telegram 400 → the mirror was silently lost). A truncated last jsonl line fails
# jq -s entirely → empty candidate → retry on the next tick (self-healing).
read_candidate() {
  CAND_TEXT=""; CAND_FINAL=0
  [ -n "$tpath" ] && [ -f "$tpath" ] || return 0
  local obj
  obj=$(tail -n 2000 "$tpath" 2>/dev/null | jq -cs '
    [.[] | select(.type=="assistant") | select(.isSidechain != true)
         | {t: (any(.message.content[]?; .type=="text")),
            u: (any(.message.content[]?; .type=="tool_use")),
            x: ([.message.content[]? | select(.type=="text") | .text] | join("\n"))}]
    | (map(.t) | rindex(true)) as $li
    | if $li == null then {final: false, text: ""}
      else {final: ((.[$li].u | not) and ((.[($li+1):] | map(select(.u)) | length) == 0)),
            text: (.[$li].x
                   | if length > 3000 then .[0:3000] + "…\n[truncated — full text in the IDE]"
                     else . end)}
      end' 2>/dev/null)
  [ -n "$obj" ] || return 0
  CAND_TEXT=$(jq -r '.text // ""' <<<"$obj" 2>/dev/null)
  [ "$(jq -r '.final // false' <<<"$obj" 2>/dev/null)" = "true" ] && CAND_FINAL=1
  return 0
}

# Inject a message into the session (continue the turn with this text).
inject() {
  save_session running
  tg "✅ [$name] received, continuing."   # ONLY on actual delivery; with the project name
  jq -n --arg r "[User via Telegram]
$1" '{decision: "block", reason: $r}'
}

# Is the daemon alive? Primary criterion — the heartbeat file (the daemon touches
# it every iteration; freshness ≤120 s, since long-poll holds an iteration up to
# ~60 s). kill -0 on the pid is only a transition-period fallback (pid reuse
# makes it unreliable).
daemon_alive() {
  local b="$DIR/daemon.beat" p
  if [ -f "$b" ]; then
    [ $(( $(date +%s) - $(stat -f %m "$b" 2>/dev/null || echo 0) )) -le 120 ]
    return
  fi
  p=$(cat "$DIR/daemon.pid" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# Atomically take the inbox contents: mv (atomic) → read the copy. If the daemon
# appends between our read and delete — it goes to a NEW inbox, nothing is lost.
take_inbox() {
  [ -s "$inbox" ] || return 1
  mv "$inbox" "$inbox.taken" 2>/dev/null || return 1
  cat "$inbox.taken"; rm -f "$inbox.taken"
}

park_is_ours() { [ "$(cat "$PARKED/$sid" 2>/dev/null)" = "$$" ]; }

# ── For unit tests: define the functions and skip the runtime. ──
[ "${TG_SESSION_TEST:-0}" = "1" ] && return 0 2>/dev/null

ENTRY_TS=$(date +%s)
event="${1:-beat}"
in=$(cat 2>/dev/null || echo "{}")
sid=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
cwd=$(printf '%s' "$in" | jq -r '.cwd // ""' 2>/dev/null)
tpath=$(printf '%s' "$in" | jq -r '.transcript_path // ""' 2>/dev/null)
src=$(printf '%s' "$in" | jq -r '.source // ""' 2>/dev/null)
name=$(basename "$cwd" 2>/dev/null || echo "")
f="$SESSIONS/$sid"
inbox="$INBOX/$sid"

# Structural filter: do NOT register sessions whose cwd is the home dir ($HOME).
# Real working sessions always run inside a project dir; cwd=$HOME means headless/
# eval sessions (Desktop cowork, `claude -p`, benchmarks) that start in bursts,
# never fire SessionEnd, and flood /sessions with hundreds of dead records faster
# than any reaper. Filtering at registration is the root cause, not the symptom.
# exit 0 on ANY event: an unregistered session needs no cleanup either.
[ -n "$HOME" ] && [ "$cwd" = "$HOME" ] && exit 0

case "$event" in
  start)
    # startup/clear — definitely no active turn → idle. resume/compact can fire
    # MID-turn → keep the previous state so we don't lie.
    case "$src" in
      startup|clear) save_session idle ;;
      *) st=$(read_field state); save_session "${st:-idle}" ;;
    esac
    ;;
  beat) save_session running ;;
  end)
    # A queue nobody will ever take — honestly bounce it to TG, don't silently drop.
    pend=$( { cat "$inbox.taken" 2>/dev/null; cat "$inbox" 2>/dev/null; } )
    [ -n "$pend" ] && tg "⚠️ [$name] session closed — NOT delivered: ${pend:0:500}"
    rm -f "$f" "$inbox" "$inbox.taken" "$inbox".merge.* "$PARKED/$sid" "$LASTMIRROR/$sid"
    ;;
  stop)
    save_session idle "$ENTRY_TS"   # the turn ended the moment we entered the hook
    # 0) Recover an orphaned .taken (the hook was killed between mv and cat last time).
    # The trailing ":" in the group is mandatory: without it the group's rc = rc of
    # the last cat (inbox is usually absent) and the mv after && would never run.
    if [ -f "$inbox.taken" ]; then
      { cat "$inbox.taken" 2>/dev/null; cat "$inbox" 2>/dev/null; :; } > "$inbox.merge.$$" \
        && mv "$inbox.merge.$$" "$inbox" && rm -f "$inbox.taken"
    fi
    # 1) A message is already queued (sent while the session was working) — deliver.
    if msg=$(take_inbox); then
      inject "$msg"
      exit 0
    fi
    # 2) Outside tg-mode — a normal stop.
    tg_mode_on || exit 0
    # 3) tg-mode: wait for the FINAL reply in the transcript and mirror it.
    # The final text flushes to the jsonl at the moment of Stop or a few seconds
    # later (incident: the mirror ran 0.3 s before the flush and picked up an
    # intermediate status). Acceptance criterion: the candidate is FINAL (no
    # tool_use after it) and stable two ticks in a row. The lastmirror hash is
    # ONLY for deduplicating "nothing new" (a turn without text), not for
    # choosing the candidate.
    prevh=$(cat "$LASTMIRROR/$sid" 2>/dev/null || echo "")
    rep=""; newh=""; stable=""
    i=0
    while [ "$i" -lt "$MIRROR_WAIT" ]; do
      read_candidate
      if [ "$CAND_FINAL" = 1 ] && [ -n "$CAND_TEXT" ]; then
        h=$(printf '%s' "$CAND_TEXT" | cksum | tr -d ' ')
        if [ -n "$stable" ] && [ "$h" = "$stable" ]; then rep="$CAND_TEXT"; newh="$h"; break; fi
        stable="$h"
      else
        stable=""
      fi
      sleep 1; i=$((i + 1))
    done
    sid8="${sid:0:8}"
    park_secs="$PARK_SECS"
    if [ -n "$rep" ] && [ "$newh" != "$prevh" ]; then
      # Write lastmirror ONLY after a successful send — otherwise a one-off
      # network failure would "eat" the reply forever (hash committed, no retry).
      if mid=$(send_id "💬 $name [#s$sid8]:

$rep

↩️ To continue the conversation — reply to this message."); then
        printf '%s' "$newh" > "$LASTMIRROR/$sid"
      else
        mid=""
      fi
    else
      # The final text didn't materialize within MIRROR_WAIT or was already
      # mirrored → an honest neutral invitation WITHOUT stale text (old text was
      # misleading). DELIBERATELY the same for a final still being written
      # (cksum grows tick-to-tick): better "see the IDE" than a chunk cut
      # mid-word.
      mid=$(send_id "💬 $name [#s$sid8] finished its turn and is waiting for you (details — in the IDE).
↩️ To continue — reply to this message.") || mid=""
    fi
    # Reply binding by message_id; [#s...] in the text is a fallback for repeat
    # replies to the same anchor. Without an anchor (TG unreachable) — a short
    # park: the only way to reach the session anyway is the #s tag in your own text.
    [ -n "$mid" ] && echo "s:$sid" > "$MSGMAP/$mid"
    [ -n "$mid" ] || park_secs=$(( PARK_SECS / 5 ))
    trap 'park_is_ours && rm -f "$PARKED/$sid"' EXIT
    echo $$ > "$PARKED/$sid"
    # Deadline: both the park and the final attempts must finish before the
    # hook's ceiling, otherwise SIGKILL without trap → a consumed message is lost.
    deadline=$(( $(date +%s) + park_secs ))
    hard=$(( ENTRY_TS + HOOK_BUDGET - 60 ))
    [ "$deadline" -gt "$hard" ] && deadline="$hard"
    dead_since=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
      touch "$PARKED/$sid" 2>/dev/null   # heartbeat: "live park" = fresh mtime
      if msg=$(take_inbox); then
        park_is_ours && rm -f "$PARKED/$sid"
        inject "$msg"
        exit 0
      fi
      # Daemon down longer than ~60 s → don't hang silently (KeepAlive usually
      # brings it back in ~10 s; if it's dead for good — better to yield control).
      if daemon_alive; then dead_since=0
      else
        [ "$dead_since" = 0 ] && dead_since=$(date +%s)
        if [ $(( $(date +%s) - dead_since )) -gt 60 ]; then
          tg "⚠️ [$name] the Telegram daemon is unreachable — ending the park; your message will arrive on the session's next turn."
          break
        fi
      fi
      sleep 3
    done
    # Leaving the park: FIRST remove the marker (so the daemon honestly says
    # "queued"), THEN one last inbox attempt — closes the "arrived in the last
    # 3 s" window.
    park_is_ours && rm -f "$PARKED/$sid"
    if msg=$(take_inbox); then
      inject "$msg"
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
