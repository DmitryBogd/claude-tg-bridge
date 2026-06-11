#!/bin/bash
# tg-daemon.sh — ЄДИНИЙ власник Telegram getUpdates для всього HITL-каналу.
#
# Один постійний процес читає апдейти і:
#   - маршрутизує відповіді: реплай на повідомлення з msgmap → його цілі
#     (q:<qid> → answers/<qid>, s:<sid> → inbox/<sid>); fallback — теги #q…/#s…
#     у реплайнутому тексті АБО у власному тексті; звичайний текст, коли активна
#     РІВНО ОДНА ціль (одне питання БЕЗ живих парків, або один живий парк БЕЗ
#     питань) → їй; інакше просить відповісти реплаєм;
#   - команди /sessions (зі статусами 🟢/😴/✅/🟡), /help.
# Живість демона — heartbeat-файл daemon.beat (touch щоітерації; ітерація ≤ ~60с
# через long-poll). kill -0 по pid ненадійний (pid-reuse). Живість ПАРКУ сесії —
# mtime parked/<sid> (Stop-хук touch-ає його кожні ~3с).
# Запуск через launchd (KeepAlive). Якщо демон мертвий — tg-ask має self-poll
# fallback. Офлайн-стійкий: на помилці мережі backoff; Telegram тримає апдейти 24год.
# Тест: TG_DAEMON_TEST=1 source tg-daemon.sh — визначає функції без запуску циклу.
set -uo pipefail
# launchd часто дає C-локаль → bash хибно токенізує $змінну впритул до
# багатобайтних символів (кирилиця, «»). UTF-8 це лагодить.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

DIR="${TG_HITL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "$DIR/.env"
API="${TG_API_BASE:-https://api.telegram.org}/bot${TG_TOKEN}"
PENDING="$DIR/pending"
ANSWERS="$DIR/answers"
SESSIONS="$DIR/sessions"
INBOX="$DIR/inbox"
PARKED="$DIR/parked"
MSGMAP="$DIR/msgmap"      # message_id → ціль (s:<sid> / q:<qid>); пише відправник
OFFSET_FILE="$DIR/offset"
PIDFILE="$DIR/daemon.pid"
BEAT="$DIR/daemon.beat"   # heartbeat живості демона
mkdir -p "$PENDING" "$ANSWERS" "$SESSIONS" "$INBOX" "$PARKED" "$MSGMAP"

say() {
  curl -s --max-time 15 -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
# <code>…</code> у Telegram копіюється по тапу. Динаміку екрануй через esc().
say_html() {
  curl -s --max-time 15 -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

fmtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# Парк живий = маркер існує І mtime свіжий (Stop-хук touch-ає кожні ~3с).
# Самозцілюється після SIGKILL хука: mtime протухає за секунди.
park_alive() {
  local pf="$PARKED/$1"
  [ -f "$pf" ] && [ $(( $(date +%s) - $(fmtime "$pf") )) -le 15 ]
}

# "<кількість живих парків> <sid останнього>" — для plain-text-маршрутизації.
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

# Прибрати протухлі сесії (>12 год без активності) РАЗОМ із хвостами; чергу,
# яку вже ніхто не забере, чесно повернути в TG.
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
    [ -n "$pend" ] && say "⚠️ [$(field "$f" name)] сесія протухла й видалена — НЕ доставлено: ${pend:0:500}"
    rm -f "$f" "$INBOX/$sid" "$INBOX/$sid.taken" "$DIR/lastmirror/$sid" "$PARKED/$sid"
  done
  shopt -u nullglob
}

# Побудувати текст /sessions (чисте echo, без відправки — тестовано окремо).
# Статус: живий парк → 😴; state=running + свіжий транскрипт → 🟢, протухлий →
# 🟡 (Esc не дає події Stop — стан міг застрягти); state=idle → ✅ із часом.
# sid у <code> навмисно БЕЗ "#s": кілька #s-тегів в одному повідомленні ламали б
# fallback-маршрутизацію реплая на цей список (regex бере перший збіг).
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
      status="😴 спить — чекає твоєї відповіді в TG"
    elif [ "$state" = "running" ]; then
      act="$last"
      [ -n "$tpath" ] && [ -f "$tpath" ] && act=$(fmtime "$tpath")
      age=$(( now - act ))
      if [ "$age" -le 180 ]; then
        if [ "$age" -lt 60 ]; then status="🟢 працює (активність ${age}с тому)"
        else status="🟢 працює (активність $(( age / 60 )) хв тому)"; fi
      else
        status="🟡 можливо перервана (Esc?) — без активності $(( age / 60 )) хв"
      fi
    elif [ "$state" = "idle" ]; then
      [ -n "$stopped" ] || stopped=$last
      status="✅ завершила хід $(( (now - stopped) / 60 )) хв тому"
    else
      status="активн. $(( (now - last) / 60 )) хв тому"   # запис старого формату
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
    say "Немає зареєстрованих активних сесій."
  else
    say_html "🖥 <b>Активні сесії Claude</b>
(відповідай реплаєм на повідомлення сесії, або тегом #s<перші 8 символів id> у тексті)$body"
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
  local sid="$1" nm
  nm=$(field "$SESSIONS/$sid" name)
  if park_alive "$sid"; then
    :   # запаркована — підтвердить сама сесія при інжекції
  else
    say "✉️ [${nm:-?}] отримано — доставлю на наступному кроці тієї сесії."
  fi
}

# Маршрутизувати одне текстове повідомлення.
# msgmap-записи s:* НЕ видаляються після використання (повторний реплай на той
# самий якір має працювати); чистка — періодична, за віком.
handle() {
  local text="$1" reply="$2" reply_mid="$3" spec qid sid8 full nq parks np phit cleaned
  case "$text" in
    /sessions*) list_sessions; return ;;
    /help*)
      say "Команди:
/sessions — активні сесії Claude (🟢 працює · 😴 чекає відповіді · ✅ завершила хід · 🟡 можливо перервана)
/help — ця довідка

Щоб написати сесії — відповідай РЕПЛАЄМ на її повідомлення, або додай тег #s<перші 8 символів id> у свій текст (id — у /sessions). Якщо активна рівно одна ціль — можна писати без реплаю. Бот підтвердить, ЯКИЙ проєкт отримав."
      return ;;
  esac

  # 0) Найнадійніше: реплай за message_id (працює для БУДЬ-ЯКОГО повідомлення сесії).
  # Валідуємо reply_mid як ціле число (Telegram message_id завжди integer).
  if [ -n "$reply_mid" ] && [[ "$reply_mid" =~ ^[0-9]+$ ]] && [ -f "$MSGMAP/$reply_mid" ]; then
    spec=$(cat "$MSGMAP/$reply_mid")
    case "$spec" in
      q:*) qid=${spec#q:}
           if [ -f "$PENDING/$qid" ]; then deliver_answer "$qid" "$text"
           else say "Те питання вже неактуальне."; fi; return ;;
      s:*) sid8=${spec#s:}
           if [ -f "$SESSIONS/$sid8" ]; then deliver_to_session "$sid8" "$text"; confirm_session "$sid8"
           else say "Та сесія вже закрита — доставити нікуди."; fi; return ;;
    esac
  fi
  # 1) Fallback: текстовий тег #q у реплайнутому повідомленні (питання tg-ask).
  qid=$(sed -nE 's/.*#q([0-9a-f]{4}).*/\1/p' <<<"$reply" | head -1)
  if [ -n "$qid" ] && [ -f "$PENDING/$qid" ]; then deliver_answer "$qid" "$text"; return; fi
  # 2) Fallback: текстовий тег #s у реплайнутому повідомленні (сесія).
  sid8=$(sed -nE 's/.*#s([0-9a-f]{8}).*/\1/p' <<<"$reply" | head -1)
  if [ -n "$sid8" ]; then
    full=$(match_session "$sid8")
    [ -n "$full" ] && { deliver_to_session "$full" "$text"; confirm_session "$full"; return; }
  fi
  # 2.5) Теги у ВЛАСНОМУ тексті — адресація без реплаю («#sa1980da9 зроби X»).
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
  # 3) Текст без реплая → лише коли ціль ОДНОЗНАЧНА: рівно одне питання і нуль
  # живих парків (як раніше), АБО рівно один живий парк і нуль питань (обіцянка
  # CLAUDE.md). У сесію поза парком без реплая — НІКОЛИ (колись «вгадування»
  # відправило не в ту сесію).
  nq=$(ls "$PENDING" 2>/dev/null | wc -l | tr -d ' ')
  parks=$(live_parks); np=${parks%% *}; phit=${parks#* }
  if [ "$nq" = "1" ] && [ "$np" = "0" ]; then deliver_answer "$(ls "$PENDING")" "$text"; return; fi
  if [ "$np" = "1" ] && [ "$nq" = "0" ] && [ -f "$SESSIONS/$phit" ]; then
    deliver_to_session "$phit" "$text"; confirm_session "$phit"; return
  fi
  say "↩️ Відповідай РЕПЛАЄМ саме на потрібне повідомлення (або додай тег #s<id> у текст) — інакше я не знаю, кому це. /sessions — список."
}

# ── Для юніт-тестів: визначити функції й не запускати рантайм. ──
[ "${TG_DAEMON_TEST:-0}" = "1" ] && return 0 2>/dev/null

# Один інстанс. Живість конкурента — за heartbeat (kill -0 бреше при pid-reuse:
# мертвий «демон» назавжди блокував би старт нового, а апдейти Telegram викидає
# через 24 год — реальна втрата).
if [ -f "$BEAT" ] && [ $(( $(date +%s) - $(stat -f %m "$BEAT" 2>/dev/null || echo 0) )) -le 120 ]; then
  echo "tg-daemon already running (beat fresh)" >&2
  exit 0
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

# Головний цикл: long-poll getUpdates з backoff на помилках мережі.
# Щогодини: чистка протухлих msgmap (>48 год — із запасом над 24-год таймаутом
# питань) і мертвих парк-маркерів (>3 хв без touch; живі touch-аються кожні 3с).
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
    # .caption — щоб фото/файл із підписом не зникали мовчки.
    text=$(jq -r --arg cid "$TG_CHAT_ID" \
      ".result[$i].message | select((.chat.id|tostring) == \$cid) | .text // .caption // empty" <<<"$RESP")
    if [ -n "$text" ]; then
      reply=$(jq -r ".result[$i].message.reply_to_message.text // empty" <<<"$RESP")
      reply_mid=$(jq -r ".result[$i].message.reply_to_message.message_id // empty" <<<"$RESP")
      handle "$text" "$reply" "$reply_mid"
    else
      # Повідомлення без тексту/підпису (войс, стікер) — чесний bounce замість
      # мовчазного споживання.
      has_msg=$(jq -r --arg cid "$TG_CHAT_ID" \
        ".result[$i].message | select((.chat.id|tostring) == \$cid) | .message_id // empty" <<<"$RESP")
      [ -n "$has_msg" ] && say "🤷 Розумію лише текст (або підпис до медіа) — продублюй словами."
    fi
    # offset просуваємо ПІСЛЯ обробки: крах до цього → апдейт перечитається (не
    # загубиться; можливий дубль доставки — свідомий вибір на користь at-least-once).
    [ -n "$uid" ] && echo $((uid + 1)) > "$OFFSET_FILE"
  done
done
