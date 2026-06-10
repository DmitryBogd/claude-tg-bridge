#!/bin/bash
# tg-mode.sh — per-project перемикач пересилання дозволів у Telegram.
#
#   tg-mode.sh on  [cwd]   увімкнути для проєкту (типово — поточний $PWD)
#   tg-mode.sh off [cwd]   вимкнути
#   tg-mode.sh status      стан поточного проєкту + список усіх активних
#
# Поки прапорець увімкнено, PermissionRequest-хук (tg-permission.sh) пересилає
# запити дозволів цього проєкту в Telegram — навіть без глобального away-режиму.
# Прапорець = файл ~/.claude/tg-hitl/projects/<cwd із / → %>. away лишається
# глобальним оверрайдом (вмикає геть усі проєкти).
set -uo pipefail

DIR="$HOME/.claude/tg-hitl"
PROJ_DIR="$DIR/projects"
mkdir -p "$PROJ_DIR"

key() { printf '%s' "$1" | sed 's#/#%#g'; }

cmd="${1:-status}"
cwd="${2:-$PWD}"
flag="$PROJ_DIR/$(key "$cwd")"

case "$cmd" in
  on)
    : > "$flag"
    echo "tg-mode ON → $cwd"
    echo "(запити дозволів цього проєкту тепер летять у Telegram)"
    ;;
  off)
    rm -f "$flag"
    echo "tg-mode OFF → $cwd"
    ;;
  status)
    if [ -f "$flag" ]; then echo "Поточний проєкт: ON  ($cwd)"; else echo "Поточний проєкт: OFF ($cwd)"; fi
    [ -f "$DIR/away" ] && echo "away-режим (усі проєкти): ON"
    echo "Активні проєкти:"
    if [ -n "$(ls -A "$PROJ_DIR" 2>/dev/null)" ]; then
      for f in "$PROJ_DIR"/*; do
        [ -f "$f" ] && echo "  - $(basename "$f" | sed 's#%#/#g')"
      done
    else
      echo "  (немає)"
    fi
    ;;
  *)
    echo "usage: tg-mode.sh on|off|status [cwd]" >&2
    exit 2
    ;;
esac
