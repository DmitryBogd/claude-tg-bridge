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
#   - Демон мертвий → СПОЧАТКУ kickstart через launchd (демон і так KeepAlive) і
#     далі чекаємо файл. Self-poll — останній резерв, і він маршрутизує ТАКОЖ
#     сесійні реплаї (msgmap/#s → inbox/<sid>): просування offset підтверджує
#     Telegram-у ВЕСЬ батч, тож усе зчитане мусить бути розкладене, інакше
#     зникне назавжди (стара версія мовчки «з'їдала» реплаї сесіям).
# Стан: pending/, answers/, offset.fallback, daemon.beat, poll.lock. Конфіг: .env.
set -uo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

DIR="${TG_HITL_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=/dev/null
[ -f "$DIR/.env" ] && source "$DIR/.env"
# Без конфігу — чесний exit 124 (як «без відповіді»): caller'и падають у свій
# fallback-діалог замість крашу «unbound variable» під set -u.
if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
  echo "NO_RESPONSE: TG_TOKEN/TG_CHAT_ID не задані в $DIR/.env" >&2
  exit 124
fi
API="${TG_API_BASE:-https://api.telegram.org}/bot${TG_TOKEN}"
PENDING="$DIR/pending"
ANSWERS="$DIR/answers"
MSGMAP="$DIR/msgmap"
SESSIONS="$DIR/sessions"
INBOX="$DIR/inbox"
OFFSET_FILE="$DIR/offset.fallback"   # окремий курсор fallback-полера (не чіпає offset демона)
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

# Живість демона — heartbeat-файл (touch щоітерації, ітерація ≤ ~60с);
# kill -0 по pid — лише fallback на перехідний період (pid-reuse бреше).
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
# До 3 спроб: без message_id реплай-маршрутизація працює лише через текстовий тег.
QMID=""
for _try in 1 2 3; do
  QMID=$(curl -s --max-time 15 -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=❓ #q$QID
$QUESTION

↩️ Відповідай реплаєм саме на це повідомлення." 2>/dev/null | jq -r '.result.message_id // empty' 2>/dev/null)
  [ -n "$QMID" ] && break
  sleep 2
done
[ -n "$QMID" ] && echo "q:$QID" > "$MSGMAP/$QMID"

# ── Режим ДЕМОНА: лише чекаємо на файл-відповідь, getUpdates не торкаємось. ──
if daemon_alive; then
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    finish_if_answered
    sleep 2
    daemon_alive || break   # демон помер під час очікування → kickstart/fallback
  done
  finish_if_answered
fi

# ── FALLBACK: демона немає — маршрутизуємо самі (повна копія правил демона
# не потрібна: питання + сесійні реплаї за msgmap/#s; решта — підказка). ──
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
    # 0) msgmap за message_id — і питання, і сесії.
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
               send "✉️ отримано — доставлю сесії на наступному кроці."
             fi; continue ;;
      esac
    fi
    # 1) Тег #q у реплаї.
    qid=$(sed -nE 's/.*#q([0-9a-f]{4}).*/\1/p' <<<"$reply" | head -1)
    if [ -n "$qid" ] && [ -f "$PENDING/$qid" ]; then
      printf '%s' "$text" > "$ANSWERS/$qid.tmp" && mv "$ANSWERS/$qid.tmp" "$ANSWERS/$qid"
      rm -f "$PENDING/$qid"
      continue
    fi
    # 2) Тег #s у реплаї або у власному тексті → сесія.
    sid8=$(sed -nE 's/.*#s([0-9a-f]{8}).*/\1/p' <<<"$reply" | head -1)
    [ -n "$sid8" ] || sid8=$(sed -nE 's/.*#s([0-9a-f]{8}).*/\1/p' <<<"$text" | head -1)
    if [ -n "$sid8" ]; then
      full=$(match_session "$sid8")
      if [ -n "$full" ]; then
        printf '%s\n' "$(sed -E 's/#s[0-9a-f]{8}[[:space:]]*//' <<<"$text")" >> "$INBOX/$full"
        send "✉️ отримано — доставлю сесії на наступному кроці."
        continue
      fi
    fi
    # 3) Рівно одне активне питання → йому.
    if [ "$(ls "$PENDING" | wc -l | tr -d ' ')" = "1" ]; then
      target=$(ls "$PENDING")
      printf '%s' "$text" > "$ANSWERS/$target.tmp" && mv "$ANSWERS/$target.tmp" "$ANSWERS/$target"
      rm -f "$PENDING/$target"
      continue
    fi
    send "⚠️ Демон TG лежить, я в резервному режимі. Відповідай реплаєм на конкретне повідомлення (#q…/#s…)."
  done
}

# Пропустити старий backlog можна ЛИШЕ якщо нікому нічого не належить: ми —
# єдине питання І немає зареєстрованих сесій (стрибок offset підтверджує
# Telegram-у все пропущене — для сесійних реплаїв це була б тиха втрата).
if [ "$(ls -1 "$PENDING" 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
   && [ -z "$(ls -A "$SESSIONS" 2>/dev/null)" ]; then
  LAST=$(curl -s --max-time 15 "$API/getUpdates?offset=-1&timeout=0" 2>/dev/null \
    | jq -r '.result[-1].update_id // empty')
  [ -n "$LAST" ] && echo $((LAST + 1)) > "$OFFSET_FILE"
fi

LAST_KICK=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  finish_if_answered
  # Демон міг піднятися (launchd) — віддати йому полінг.
  if daemon_alive; then sleep 2; continue; fi
  # Спроба реанімувати демона (KeepAlive; не частіше ніж раз на 60с).
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
  # offset ПІСЛЯ розкладання (at-least-once, як у демона): крах посеред
  # маршрутизації → батч перечитається, а не «підтверджено й втрачено».
  MAXID=$(jq -r '.result[-1].update_id // empty' <<<"$RESP" 2>/dev/null)
  [ -n "$MAXID" ] && echo $((MAXID + 1)) > "$OFFSET_FILE"
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null
  trap cleanup EXIT
done

echo "NO_RESPONSE: користувач не відповів за ${TIMEOUT}с" >&2
exit 124
