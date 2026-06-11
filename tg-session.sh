#!/bin/bash
# tg-session.sh — реєстр активних Claude-сесій + доставка повідомлень + tg-режим «park».
# Викликається з хуків:
#   SessionStart      → start  (зареєструвати; source=startup/clear скидає стан в idle)
#   UserPromptSubmit  → beat   (оновити активність; state=running)
#   Stop              → stop   (state=idle; інжекція з черги; у tg-режимі — дзеркало
#                               ФІНАЛЬНОЇ відповіді в TG + парк з heartbeat)
#   SessionEnd        → end    (прибрати запис; недоставлене з inbox — bounce у TG)
# Аргумент $1 = подія. stdin = JSON хука (session_id, cwd, transcript_path, ...).
# Реєстр: sessions/<sid> — key=value (name/cwd/started/last/state/stopped/tpath),
# запис атомарний (tmp+mv). Черга: inbox/<sid>. Парк: parked/<sid> — «живість»
# визначається за mtime (парк-цикл touch-ає файл щоітерації), НЕ за kill -0 pid
# (pid-reuse дає хибно-живі парки після SIGKILL).
# Тест: TG_SESSION_TEST=1 source tg-session.sh — визначає функції без запуску.
set -uo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # launchd C-локаль ламає токенізацію $var«кирилиця»

DIR="${TG_HITL_DIR:-$HOME/.claude/tg-hitl}"
SESSIONS="$DIR/sessions"
INBOX="$DIR/inbox"
PARKED="$DIR/parked"
MSGMAP="$DIR/msgmap"
LASTMIRROR="$DIR/lastmirror"   # хеш останньої здзеркаленої відповіді на сесію (дедуп)
mkdir -p "$SESSIONS" "$INBOX" "$PARKED" "$MSGMAP" "$LASTMIRROR"
[ -f "$DIR/.env" ] && . "$DIR/.env"
API="${TG_API_BASE:-https://api.telegram.org}/bot${TG_TOKEN:-}"

# Скільки максимум парк чекає твоє повідомлення (с). Вікно + дзеркало мусять
# влізти в timeout Stop-хука (1800 у settings.json) — див. HOOK_BUDGET.
PARK_SECS="${TG_PARK_SECS:-1500}"
MIRROR_WAIT="${TG_MIRROR_WAIT:-25}"   # стеля очікування фінального тексту в транскрипті, с
HOOK_BUDGET=1740                      # жорсткий ліміт життя stop-хука (запас 60с до 1800)

# ── Запис реєстру ─────────────────────────────────────────────────────────────
read_field() { sed -n "s/^$1=//p" "$f" 2>/dev/null | head -1; }

# save_session <state> [stopped] — атомарно переписати запис, зберігши started і
# поля, яких немає в цьому виклику хука (tpath на start/end може бути порожнім).
save_session() {
  local nowts started stopped tp nm cw
  nowts=$(date +%s)
  started=$(read_field started); [ -n "$started" ] || started=$nowts
  stopped="${2:-$(read_field stopped)}"
  tp="$tpath";  [ -n "$tp" ] || tp=$(read_field tpath)
  nm="$name";   [ -n "$nm" ] || nm=$(read_field name)
  cw="$cwd";    [ -n "$cw" ] || cw=$(read_field cwd)
  printf 'name=%s\ncwd=%s\nstarted=%s\nlast=%s\nstate=%s\nstopped=%s\ntpath=%s\n' \
    "$nm" "$cw" "$started" "$nowts" "$1" "$stopped" "$tp" > "$f.tmp.$$" \
    && mv "$f.tmp.$$" "$f"
}

# ── Telegram ──────────────────────────────────────────────────────────────────
tg() {  # надіслати простий текст у TG (best-effort)
  [ -n "${TG_TOKEN:-}" ] || return 0
  curl -s --max-time 15 -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
# надіслати і повернути message_id; 3 спроби. Невдача → return 1 (НЕ паркуємось
# на повний строк без якоря: реплаїти не буде на що).
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

# tg-режим активний для цього cwd? (глобальний away АБО per-project прапорець)
tg_mode_on() {
  [ -f "$DIR/away" ] && return 0
  [ -n "$cwd" ] && [ -f "$DIR/projects/$(printf '%s' "$cwd" | sed 's#/#%#g')" ]
}

# ── Кандидат на дзеркало ──────────────────────────────────────────────────────
# Бере ОСТАННІЙ assistant-текст і визначає, чи він ФІНАЛЬНИЙ: після нього (і в
# ньому самому) немає tool_use. Проміжні статуси завжди мають tool-активність
# після себе — це відсікає клас «віддзеркалили статус замість відповіді».
# Зріз — 3000 КОДПОЇНТІВ у jq (байтовий head -c різав UTF-8 посеред символу →
# Telegram 400 → дзеркало мовчки губилось). Обірваний останній рядок jsonl валить
# jq -s цілком → порожній кандидат → ретрай наступного тіку (самозцілення).
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
                   | if length > 3000 then .[0:3000] + "…\n[обрізано — повний текст в IDE]"
                     else . end)}
      end' 2>/dev/null)
  [ -n "$obj" ] || return 0
  CAND_TEXT=$(jq -r '.text // ""' <<<"$obj" 2>/dev/null)
  [ "$(jq -r '.final // false' <<<"$obj" 2>/dev/null)" = "true" ] && CAND_FINAL=1
  return 0
}

# Інжектувати повідомлення в сесію (продовжити хід із цим текстом).
inject() {
  save_session running
  tg "✅ [$name] прийнято, продовжую."   # ЛИШЕ при реальній доставці; з назвою проєкту
  jq -n --arg r "[Дмитро через Telegram]
$1" '{decision: "block", reason: $r}'
}

# Демон живий? Основний критерій — heartbeat-файл (демон touch-ає його щоітерації;
# свіжість ≤120с, бо long-poll тримає ітерацію до ~60с). kill -0 по pid — лише
# fallback на перехідний період (pid-reuse робить його ненадійним).
daemon_alive() {
  local b="$DIR/daemon.beat" p
  if [ -f "$b" ]; then
    [ $(( $(date +%s) - $(stat -f %m "$b" 2>/dev/null || echo 0) )) -le 120 ]
    return
  fi
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

park_is_ours() { [ "$(cat "$PARKED/$sid" 2>/dev/null)" = "$$" ]; }

# ── Для юніт-тестів: визначити функції й не запускати рантайм. ──
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

case "$event" in
  start)
    # startup/clear — точно немає активного ходу → idle. resume/compact можуть
    # стріляти ПОСЕРЕД живого ходу → зберегти попередній стан, щоб не брехати.
    case "$src" in
      startup|clear) save_session idle ;;
      *) st=$(read_field state); save_session "${st:-idle}" ;;
    esac
    ;;
  beat) save_session running ;;
  end)
    # Черга, яку вже ніхто не забере, — чесно повернути в TG, а не мовчки стерти.
    pend=$( { cat "$inbox.taken" 2>/dev/null; cat "$inbox" 2>/dev/null; } )
    [ -n "$pend" ] && tg "⚠️ [$name] сесія закрилась — НЕ доставлено: ${pend:0:500}"
    rm -f "$f" "$inbox" "$inbox.taken" "$inbox".merge.* "$PARKED/$sid" "$LASTMIRROR/$sid"
    ;;
  stop)
    save_session idle "$ENTRY_TS"   # хід завершено в момент входу в хук
    # 0) Повернути осиротілий .taken (хук минулого разу вбили між mv і cat).
    # «:» в кінці групи обов'язковий: без нього rc групи = rc останнього cat
    # (inbox зазвичай відсутній) і mv по && ніколи б не виконався.
    if [ -f "$inbox.taken" ]; then
      { cat "$inbox.taken" 2>/dev/null; cat "$inbox" 2>/dev/null; :; } > "$inbox.merge.$$" \
        && mv "$inbox.merge.$$" "$inbox" && rm -f "$inbox.taken"
    fi
    # 1) Уже є повідомлення в черзі (надіслане, поки сесія працювала) — доставити.
    if msg=$(take_inbox); then
      inject "$msg"
      exit 0
    fi
    # 2) Поза tg-режимом — звичайна зупинка.
    tg_mode_on || exit 0
    # 3) tg-режим: дочекатись ФІНАЛЬНОЇ відповіді в транскрипті й здзеркалити.
    # Фінальний текст флашиться в jsonl у момент Stop або на кілька секунд пізніше
    # (інцидент 2026-06-11: дзеркало пішло на 0.3с раніше за флаш і взяло проміжний
    # статус). Критерій прийняття: кандидат ФІНАЛЬНИЙ (без tool_use після нього)
    # і стабільний два тіки поспіль. Хеш lastmirror — ЛИШЕ для дедуплікації
    # «нічого нового» (хід без тексту), не для вибору кандидата.
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
      # lastmirror пишемо ЛИШЕ після успішної відправки — інакше разовий збій
      # мережі назавжди «з'їдав» відповідь (хеш закомічено, повтору не буде).
      if mid=$(send_id "💬 $name [#s$sid8]:

$rep

↩️ Щоб продовжити розмову — відповідай реплаєм на це повідомлення."); then
        printf '%s' "$newh" > "$LASTMIRROR/$sid"
      else
        mid=""
      fi
    else
      # Фінал не зчитався за MIRROR_WAIT або він уже дзеркалився → чесне
      # нейтральне запрошення БЕЗ stale-тексту (старий текст вводив в оману).
      # СВІДОМО так і для фіналу, що ще дописується (cksum росте тік-до-тіку):
      # краще «дивись в IDE», ніж обрізаний на півслові шматок.
      mid=$(send_id "💬 $name [#s$sid8] завершив хід і чекає на тебе (деталі — в IDE).
↩️ Щоб продовжити — відповідай реплаєм на це повідомлення.") || mid=""
    fi
    # Прив'язка реплая за message_id; [#s...] у тексті — fallback для повторних
    # реплаїв на той самий якір. Без якоря (TG недоступний) — короткий парк:
    # достукатись однаково можна лише тегом #s у власному тексті.
    [ -n "$mid" ] && echo "s:$sid" > "$MSGMAP/$mid"
    [ -n "$mid" ] || park_secs=$(( PARK_SECS / 5 ))
    trap 'park_is_ours && rm -f "$PARKED/$sid"' EXIT
    echo $$ > "$PARKED/$sid"
    # Дедлайн: і парк, і фінальні спроби мусять закінчитись до стелі хука,
    # інакше SIGKILL без trap → спожите повідомлення втрачено.
    deadline=$(( $(date +%s) + park_secs ))
    hard=$(( ENTRY_TS + HOOK_BUDGET - 60 ))
    [ "$deadline" -gt "$hard" ] && deadline="$hard"
    dead_since=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
      touch "$PARKED/$sid" 2>/dev/null   # heartbeat: «живий парк» = свіжий mtime
      if msg=$(take_inbox); then
        park_is_ours && rm -f "$PARKED/$sid"
        inject "$msg"
        exit 0
      fi
      # Демон лежить довше ~60с → не висіти мовчки (KeepAlive зазвичай підіймає
      # за ~10с; якщо мертвий назовсім — краще віддати керування).
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
    # Вихід з парку: СПОЧАТКУ зняти маркер (демон далі чесно скаже «у черзі»),
    # ПОТІМ остання спроба inbox — закриває вікно «прилетіло в останні 3с».
    park_is_ours && rm -f "$PARKED/$sid"
    if msg=$(take_inbox); then
      inject "$msg"
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
