#!/bin/bash
# tg-daemon.sh — ЄДИНИЙ власник Telegram getUpdates для всього HITL-каналу.
#
# Один постійний процес читає апдейти і:
#   - маршрутизує відповіді: реплай на #q… (питання tg-ask) → answers/<qid>;
#     реплай на #s… (повідомлення сесії) → inbox/<sid>; звичайний текст, коли
#     активна РІВНО ОДНА ціль → їй; інакше просить відповісти реплаєм;
#   - команди /sessions, /help.
# Запуск через launchd (KeepAlive). Якщо демон мертвий — tg-ask має self-poll
# fallback. Офлайн-стійкий: на помилці мережі backoff; Telegram тримає апдейти 24год.
# Тест: TG_DAEMON_TEST=1 source tg-daemon.sh — визначає функції без запуску циклу.
set -uo pipefail
# launchd часто дає C-локаль → bash хибно токенізує $змінну впритул до
# багатобайтних символів (кирилиця, «»). UTF-8 це лагодить.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/.env"
API="https://api.telegram.org/bot${TG_TOKEN}"
PENDING="$DIR/pending"
ANSWERS="$DIR/answers"
SESSIONS="$DIR/sessions"
INBOX="$DIR/inbox"
PARKED="$DIR/parked"
MSGMAP="$DIR/msgmap"      # message_id → ціль (s:<sid> / q:<qid>); пише відправник
OFFSET_FILE="$DIR/offset"
PIDFILE="$DIR/daemon.pid"
mkdir -p "$PENDING" "$ANSWERS" "$SESSIONS" "$INBOX" "$PARKED" "$MSGMAP"

say() {
  curl -s -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
# <code>…</code> у Telegram копіюється по тапу. Динаміку екрануй через esc().
say_html() {
  curl -s -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# /sessions — список зареєстрованих сесій; прибираємо протухлі (>12 год).
list_sessions() {
  local now f name cwd last sid ago out n=0
  now=$(date +%s)
  out="🖥 <b>Активні сесії Claude</b>
(щоб написати — відповідай реплаєм на повідомлення потрібної сесії)"
  shopt -s nullglob
  for f in "$SESSIONS"/*; do
    [ -f "$f" ] || continue
    last=$(sed -n 's/^last=//p' "$f")
    if [ -n "$last" ] && [ $(( now - last )) -gt 43200 ]; then
      rm -f "$f"; continue
    fi
    name=$(esc "$(sed -n 's/^name=//p' "$f")")
    cwd=$(esc "$(sed -n 's/^cwd=//p' "$f")")
    sid=$(basename "$f")
    ago=$(( (now - ${last:-now}) / 60 ))
    out="$out

• <b>${name:-?}</b> — активн. ${ago} хв тому
<code>${sid}</code>
${cwd}"
    n=$((n+1))
  done
  shopt -u nullglob
  if [ "$n" -eq 0 ]; then
    say "Немає зареєстрованих активних сесій."
  else
    say_html "$out"
  fi
}

# Повний session_id за префіксом — ЛИШЕ якщо збіг унікальний (інакше нічого,
# щоб не доставити не тій сесії при колізії 8-hex префікса).
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

deliver_answer() {  # відповідь на питання tg-ask
  printf '%s' "$2" > "$ANSWERS/$1.tmp" && mv "$ANSWERS/$1.tmp" "$ANSWERS/$1"
  rm -f "$PENDING/$1"
}
deliver_to_session() {  # повідомлення в сесію (park-цикл або наступний Stop підхопить)
  printf '%s\n' "$2" >> "$INBOX/$1"
}

# Підтвердити доставку в сесію — ОБОВ'ЯЗКОВО з назвою проєкту. Якщо сесія в живому
# парку — мовчимо, бо «✅ [name] прийнято» пришле сама інжекція; інакше «у черзі».
confirm_session() {
  local sid="$1" nm p
  nm=$(sed -n 's/^name=//p' "$SESSIONS/$sid" 2>/dev/null)
  if p=$(cat "$PARKED/$sid" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    :   # запаркована — підтвердить сама сесія при інжекції
  else
    say "✉️ [${nm:-?}] отримано — доставлю на наступному кроці тієї сесії."
  fi
}

# Маршрутизувати одне текстове повідомлення.
# Сесії — ЛИШЕ реплаєм (за message_id, з fallback на тег), щоб НІКОЛИ не піти не в ту.
handle() {
  local text="$1" reply="$2" reply_mid="$3" spec qid sid8 full nq
  case "$text" in
    /sessions*) list_sessions; return ;;
    /help*)
      say "Команди:
/sessions — активні сесії Claude
/help — ця довідка

Щоб написати сесії — ВІДПОВІДАЙ РЕПЛАЄМ саме на її повідомлення. Бот підтвердить, ЯКИЙ проєкт отримав."
      return ;;
  esac

  # 0) Найнадійніше: реплай за message_id (працює для БУДЬ-ЯКОГО повідомлення сесії).
  # Валідуємо reply_mid як ціле число (Telegram message_id завжди integer).
  if [ -n "$reply_mid" ] && [[ "$reply_mid" =~ ^[0-9]+$ ]] && [ -f "$MSGMAP/$reply_mid" ]; then
    spec=$(cat "$MSGMAP/$reply_mid"); rm -f "$MSGMAP/$reply_mid"
    case "$spec" in
      q:*) qid=${spec#q:}
           if [ -f "$PENDING/$qid" ]; then deliver_answer "$qid" "$text"
           else say "Те питання вже неактуальне."; fi; return ;;
      s:*) sid8=${spec#s:}
           if [ -f "$SESSIONS/$sid8" ]; then deliver_to_session "$sid8" "$text"; confirm_session "$sid8"
           else say "Та сесія вже закрита — доставити нікуди."; fi; return ;;
    esac
  fi
  # 1) Fallback: текстовий тег #q (питання tg-ask).
  qid=$(sed -nE 's/.*#q([0-9a-f]{4}).*/\1/p' <<<"$reply" | head -1)
  if [ -n "$qid" ] && [ -f "$PENDING/$qid" ]; then deliver_answer "$qid" "$text"; return; fi
  # 2) Fallback: текстовий тег #s (сесія).
  sid8=$(sed -nE 's/.*#s([0-9a-f]{8}).*/\1/p' <<<"$reply" | head -1)
  if [ -n "$sid8" ]; then
    full=$(match_session "$sid8")
    [ -n "$full" ] && { deliver_to_session "$full" "$text"; confirm_session "$full"; return; }
  fi
  # 3) Текст без реплая → лише якщо РІВНО ОДНЕ питання tg-ask. У сесію БЕЗ реплая
  #    не доставляємо НІКОЛИ (саме «вгадування» відправило колись не в ту сесію).
  nq=$(ls "$PENDING" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$nq" = "1" ]; then deliver_answer "$(ls "$PENDING")" "$text"; return; fi
  say "↩️ Відповідай РЕПЛАЄМ саме на потрібне повідомлення — інакше я не знаю, кому це. /sessions — список."
}

# ── Для юніт-тестів: визначити функції й не запускати рантайм. ──
[ "${TG_DAEMON_TEST:-0}" = "1" ] && return 0 2>/dev/null

# Один інстанс.
if [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null || echo "")
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    echo "tg-daemon already running (pid $old)" >&2
    exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT INT TERM

# Прибрати протухлі записи мапи message_id (старші за 48 год — із запасом над
# 24-год таймаутом питань, щоб не зрізати на межі).
find "$MSGMAP" -type f -mmin +2880 -delete 2>/dev/null || true

# Головний цикл: long-poll getUpdates з backoff на помилках мережі.
while true; do
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
    text=$(jq -r --arg cid "$TG_CHAT_ID" \
      ".result[$i].message | select((.chat.id|tostring) == \$cid) | .text // empty" <<<"$RESP")
    if [ -n "$text" ]; then
      reply=$(jq -r ".result[$i].message.reply_to_message.text // empty" <<<"$RESP")
      reply_mid=$(jq -r ".result[$i].message.reply_to_message.message_id // empty" <<<"$RESP")
      handle "$text" "$reply" "$reply_mid"
    fi
    # offset просуваємо ПІСЛЯ обробки: крах до цього → апдейт перечитається (не загубиться).
    [ -n "$uid" ] && echo $((uid + 1)) > "$OFFSET_FILE"
  done
done
