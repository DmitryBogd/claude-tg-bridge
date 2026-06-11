#!/bin/bash
# tg-permission.sh — PermissionRequest hook: підтвердження дозволів через Telegram.
#
# Пересилає запит дозволу в Telegram, якщо виконано БУДЬ-ЯКУ з умов:
#   - глобальний away-режим: існує файл ~/.claude/tg-hitl/away (для ВСІХ проєктів)
#       увімкнути:  touch ~/.claude/tg-hitl/away   /  вимкнути: rm ...
#   - per-project tg-mode: для cwd цього запиту увімкнено прапорець
#       увімкнути в потрібному проєкті:  ~/.claude/tg-hitl/tg-mode.sh on
#       (агент може зробити це сам, бо знає свій cwd)
# Інакше хук мовчки виходить і показується звичайний діалог у VSCode/CLI.
#
# Відповіді в Telegram: "так"/"yes"/"+" → дозволити; "ні"/"no"/"-" → відхилити;
# будь-що інше або тиша 240с → звичайний діалог (нічого не зламано).
set -uo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

DIR="$HOME/.claude/tg-hitl"

in=$(cat)
cwd=$(printf '%s' "$in" | jq -r '.cwd // ""')
proj=$(basename "$cwd")
projflag="$DIR/projects/$(printf '%s' "$cwd" | sed 's#/#%#g')"

# Не away і (немає cwd або немає прапорця проєкту) → нічого не шлемо.
if [ ! -f "$DIR/away" ] && { [ -z "$cwd" ] || [ ! -f "$projflag" ]; }; then
  exit 0
fi

tool=$(printf '%s' "$in" | jq -r '.tool_name // "?"')
# Зріз у jq за КОДПОЇНТАМИ: head -c різав UTF-8 посеред символа → невалідний
# текст → Telegram 400 → питання про дозвіл мовчки не доходило.
detail=$(printf '%s' "$in" | jq -r \
  '(.tool_input.command // .tool_input.file_path // (.tool_input | tostring) // "") | .[0:400]')

ans=$("$DIR/tg-ask.sh" "🔐 [$proj] Запит дозволу: $tool
$detail

Відповідай: так / ні" 240) || exit 0

case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" in
  так*|yes*|y|+|ok|ок|да*)
    jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest",
            decision: {behavior: "allow"}}}'
    ;;
  ні*|нет*|no*|n|-)
    jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest",
            decision: {behavior: "deny", message: "Відхилено користувачем з Telegram"}}}'
    ;;
  *)
    exit 0
    ;;
esac
