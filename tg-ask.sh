#!/bin/bash
# tg-ask.sh — human-in-the-loop через Telegram (бот @important_decisions_bot).
#
#   tg-ask.sh --notify "текст"          надіслати сповіщення, не чекати відповіді
#   tg-ask.sh "питання" [timeout_sec]   надіслати питання і чекати відповіді
#                                       (типово 86400с = 24 год; вихід 124 без відповіді)
#
# Кожне питання отримує ID #q3f2a. Маршрутизація відповідей:
#   - реплай у Telegram на конкретне питання → йде тому, хто питав;
#   - звичайний текст, коли активне рівно одне питання → йде йому;
#   - інакше бот просить відповісти реплаєм.
#
# Механіка приймання відповідей:
#   - ОСНОВНА: getUpdates читає постійний tg-daemon.sh (один читач на токен) і
#     розкладає відповіді у answers/<qid>. tg-ask лише чекає на свій файл.
#   - FALLBACK: якщо демон мертвий — tg-ask сам кооперативно полить getUpdates
#     під спільним lock'ом (старий режим), щоб HITL працював і без демона.
# Стан: pending/, answers/, offset, daemon.pid, poll.lock. Конфіг: .env поруч.
set -uo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/.env"
API="https://api.telegram.org/bot${TG_TOKEN}"
PENDING="$DIR/pending"
ANSWERS="$DIR/answers"
MSGMAP="$DIR/msgmap"
OFFSET_FILE="$DIR/offset.fallback"   # ОКРЕМИЙ курсор: fallback не чіпає offset демона (інакше міг би «з'їсти» reply для сесії під час респавну)
PIDFILE="$DIR/daemon.pid"
LOCK="$DIR/poll.lock"
mkdir -p "$PENDING" "$ANSWERS" "$MSGMAP"

send() {
  curl -s -X POST "$API/sendMessage" \
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

daemon_alive() {
  local p
  [ -f "$PIDFILE" ] || return 1
  p=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# Чекаємо появи нашої відповіді у answers/<QID> (її кладе або демон, або,
# у fallback-режимі, інший очікувач). Спільне для обох режимів.
finish_if_answered() {
  if [ -f "$ANSWERS/$QID" ]; then
    local ANSWER; ANSWER=$(cat "$ANSWERS/$QID")
    send "✅ #q$QID — прийнято, продовжую."
    echo "$ANSWER"
    exit 0
  fi
}

echo "$QUESTION" > "$PENDING/$QID"
# Шлемо питання і ловимо message_id → прив'язка реплая за id (надійніше за тег #q).
QMID=$(curl -s -X POST "$API/sendMessage" \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "text=❓ #q$QID
$QUESTION

↩️ Відповідай реплаєм саме на це повідомлення." 2>/dev/null | jq -r '.result.message_id // empty' 2>/dev/null)
[ -n "$QMID" ] && echo "q:$QID" > "$MSGMAP/$QMID"

# ── Режим ДЕМОНА: лише чекаємо на файл-відповідь, getUpdates не торкаємось. ──
if daemon_alive; then
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    finish_if_answered
    sleep 2
    daemon_alive || break   # демон помер під час очікування → перейти у fallback
  done
  finish_if_answered
fi

# ── FALLBACK: демона немає (або помер) — кооперативний self-poll. ──
route_updates() {
  local resp="$1" n i text reply qid target
  n=$(jq '.result | length' <<<"$resp") || return
  for ((i = 0; i < n; i++)); do
    text=$(jq -r --arg cid "$TG_CHAT_ID" \
      ".result[$i].message | select((.chat.id|tostring) == \$cid) | .text // empty" \
      <<<"$resp")
    [ -n "$text" ] || continue
    reply=$(jq -r ".result[$i].message.reply_to_message.text // empty" <<<"$resp")
    target=""
    qid=$(sed -nE 's/.*#q([0-9a-f]{4}).*/\1/p' <<<"$reply" | head -1)
    if [ -n "$qid" ] && [ -f "$PENDING/$qid" ]; then
      target="$qid"
    elif [ "$(ls "$PENDING" | wc -l | tr -d ' ')" = "1" ]; then
      target=$(ls "$PENDING")
    fi
    if [ -n "$target" ]; then
      printf '%s' "$text" > "$ANSWERS/$target.tmp" && mv "$ANSWERS/$target.tmp" "$ANSWERS/$target"
      rm -f "$PENDING/$target"
    else
      send "⚠️ Зараз активні кілька питань — відповідай реплаєм на конкретне (повідомлення з #q...)."
    fi
  done
}

# Якщо ми перше активне питання — пропустити старий backlog (лише fallback).
if [ "$(ls -1 "$PENDING" 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
  LAST=$(curl -s "$API/getUpdates?offset=-1&timeout=0" 2>/dev/null \
    | jq -r '.result[-1].update_id // empty')
  [ -n "$LAST" ] && echo $((LAST + 1)) > "$OFFSET_FILE"
fi

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  finish_if_answered
  # Демон міг піднятися (launchd) — віддати йому полінг.
  if daemon_alive; then sleep 2; continue; fi
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
  MAXID=$(jq -r '.result[-1].update_id // empty' <<<"$RESP" 2>/dev/null)
  [ -n "$MAXID" ] && echo $((MAXID + 1)) > "$OFFSET_FILE"
  route_updates "$RESP"
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null
  trap cleanup EXIT
done

echo "NO_RESPONSE: користувач не відповів за ${TIMEOUT}с" >&2
exit 124
