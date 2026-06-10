#!/bin/bash
# tg-session.sh — реєстр активних Claude-сесій + доставка повідомлень + tg-режим «park».
# Викликається з хуків:
#   SessionStart      → start  (зареєструвати)
#   UserPromptSubmit  → beat   (оновити «остання активність»)
#   Stop              → stop   (heartbeat; інжекція з черги; у tg-режимі — дзеркало в
#                               TG + парк: чекати твоє повідомлення і продовжити)
#   SessionEnd        → end    (прибрати запис + inbox)
# Аргумент $1 = подія. stdin = JSON хука (session_id, cwd, transcript_path, ...).
# Реєстр: sessions/<sid>. Черга: inbox/<sid>. Конфіг TG: .env поруч.
set -uo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # launchd C-локаль ламає токенізацію $var«кирилиця»

DIR="$HOME/.claude/tg-hitl"
SESSIONS="$DIR/sessions"
INBOX="$DIR/inbox"
PARKED="$DIR/parked"
MSGMAP="$DIR/msgmap"
LASTMIRROR="$DIR/lastmirror"   # хеш останньої здзеркаленої відповіді на сесію (дедуп)
mkdir -p "$SESSIONS" "$INBOX" "$PARKED" "$MSGMAP" "$LASTMIRROR"
[ -f "$DIR/.env" ] && . "$DIR/.env"
API="https://api.telegram.org/bot${TG_TOKEN:-}"

# Скільки максимум парк чекає твоє повідомлення (с). Вікно ≤ timeout Stop-хука
# в settings.json (там 1800). Мовчання понад це → сесія завершує хід нормально.
PARK_SECS=1500

event="${1:-beat}"
in=$(cat 2>/dev/null || echo "{}")
sid=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
cwd=$(printf '%s' "$in" | jq -r '.cwd // ""' 2>/dev/null)
tpath=$(printf '%s' "$in" | jq -r '.transcript_path // ""' 2>/dev/null)
name=$(basename "$cwd")
f="$SESSIONS/$sid"
inbox="$INBOX/$sid"
now=$(date +%s)

write_entry() {
  { echo "name=$name"; echo "cwd=$cwd"; echo "started=${1:-$now}"; echo "last=$now"; } > "$f"
}
beat() {
  if [ -f "$f" ]; then
    local started; started=$(sed -n 's/^started=//p' "$f")
    write_entry "${started:-$now}"
  else
    write_entry "$now"
  fi
}

tg() {  # надіслати простий текст у TG
  [ -n "${TG_TOKEN:-}" ] || return 0
  curl -s -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
tg_html() {  # надіслати з HTML (для <code> — копіюється по тапу)
  [ -n "${TG_TOKEN:-}" ] || return 0
  curl -s -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
# надіслати і повернути message_id (для прив'язки реплаїв за id)
send_id() {
  [ -n "${TG_TOKEN:-}" ] || return 0
  local resp
  resp=$(curl -s -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" 2>/dev/null)
  jq -r '.result.message_id // empty' <<<"$resp" 2>/dev/null
}

# tg-режим активний для цього cwd? (глобальний away АБО per-project прапорець)
tg_mode_on() {
  [ -f "$DIR/away" ] && return 0
  [ -n "$cwd" ] && [ -f "$DIR/projects/$(printf '%s' "$cwd" | sed 's#/#%#g')" ]
}

# Останній текст асистента з транскрипту (для дзеркала в TG).
last_reply() {
  [ -n "$tpath" ] && [ -f "$tpath" ] || return 0
  # Беремо ОСТАННІЙ запис асистента, що МІСТИТЬ текст (не лише tool_use).
  tail -n 400 "$tpath" 2>/dev/null | jq -rs \
    '[.[] | select(.type=="assistant") | select(any(.message.content[]?; .type=="text"))]
     | (last // {}) | [.message.content[]? | select(.type=="text") | .text] | join("\n")' \
    2>/dev/null | head -c 3500
}

# Інжектувати повідомлення в сесію (продовжити хід із цим текстом).
inject() {
  tg "✅ [$name] прийнято, продовжую."   # ЛИШЕ при реальній доставці; з назвою проєкту
  jq -n --arg r "[Дмитро через Telegram]
$1" '{decision: "block", reason: $r}'
}

daemon_alive() {
  local p; [ -f "$DIR/daemon.pid" ] || return 1
  p=$(cat "$DIR/daemon.pid" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# Атомарно забрати вміст inbox: mv (атомарний) → читаємо копію. Якщо демон
# дописав (append) між нашим читанням і видаленням — це піде в НОВИЙ inbox, не згубиться.
take_inbox() {
  [ -s "$inbox" ] || return 1
  mv "$inbox" "$inbox.taken" 2>/dev/null || return 1
  cat "$inbox.taken"; rm -f "$inbox.taken"
}

case "$event" in
  start) write_entry "$now" ;;
  beat)  beat ;;
  end)   rm -f "$f" "$inbox" "$PARKED/$sid" "$LASTMIRROR/$sid" ;;
  stop)
    beat
    # 1) Уже є повідомлення в черзі (надіслане, поки сесія працювала) — доставити.
    if msg=$(take_inbox); then
      inject "$msg"
      exit 0
    fi
    # 2) Поза tg-режимом — звичайна зупинка.
    tg_mode_on || exit 0
    # 3) tg-режим: дзеркалю відповідь у TG і паркуюсь, чекаючи твоє повідомлення.
    # Дочекатись НОВОЇ відповіді. На ходах після інжекції (decision:block) продовжена
    # відповідь ще не в транскрипті в момент Stop → last_reply спершу віддає стару.
    # PARK_SECS + 15 ≤ Stop-timeout (1800с у settings.json) — залежність, не ламати.
    prevh=$(cat "$LASTMIRROR/$sid" 2>/dev/null || echo "")
    rep=""; newh=""
    for _w in $(seq 1 15); do
      cand=$(last_reply)
      if [ -n "$cand" ]; then
        h=$(printf '%s' "$cand" | cksum | tr -d ' ')
        if [ "$h" != "$prevh" ]; then rep="$cand"; newh="$h"; break; fi
      fi
      sleep 1
    done
    echo $$ > "$PARKED/$sid"            # pid — щоб демон бачив, що парк живий
    trap 'rm -f "$PARKED/$sid"' EXIT
    if [ -n "$rep" ]; then
      printf '%s' "$newh" > "$LASTMIRROR/$sid"
      mid=$(send_id "💬 $name:

$rep

↩️ Щоб продовжити розмову — відповідай саме на ЦЕ повідомлення.")
    else
      # Відповідь не з'явилась у транскрипті за 15с (injection-хід, повільний flush) —
      # нейтральне запрошення без стале-тексту (краще за показ попередньої відповіді).
      mid=$(send_id "💬 $name завершив крок і чекає на тебе.
↩️ Щоб продовжити — відповідай саме на ЦЕ повідомлення.")
    fi
    # Прив'язка реплая за message_id (відповідь на це повідомлення піде саме цій сесії).
    [ -n "$mid" ] && echo "s:$sid" > "$MSGMAP/$mid"
    deadline=$(( $(date +%s) + PARK_SECS ))   # від ЗАРАЗ, не від входу в хук
    dead_since=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if msg=$(take_inbox); then
        rm -f "$PARKED/$sid"
        inject "$msg"
        exit 0
      fi
      # Демон лежить довше ~60с → не висіти мовчки, завершуємо хід (KeepAlive зазвичай
      # піднімає за ~10с; якщо мертвий назовсім — краще віддати керування).
      if daemon_alive; then dead_since=0
      else
        [ "$dead_since" = 0 ] && dead_since=$(date +%s)
        if [ $(( $(date +%s) - dead_since )) -gt 60 ]; then
          tg "⚠️ [$name] демон Telegram недоступний — парк завершую; твоє повідомлення дійде на наступному кроці сесії."
          break
        fi
      fi
      sleep 3
    done
    rm -f "$PARKED/$sid"
    exit 0   # таймаут парку / мертвий демон → дозволяємо зупинку
    ;;
esac
exit 0
