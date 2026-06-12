#!/bin/bash
# tg-mode.sh — per-project toggle for routing permission prompts to Telegram.
#
#   tg-mode.sh on  [cwd]   enable for a project (defaults to the current $PWD)
#   tg-mode.sh off [cwd]   disable
#   tg-mode.sh status      current project's state + list of all active projects
#
# While the flag is on, the PermissionRequest hook (tg-permission.sh) forwards
# this project's permission prompts to Telegram, and the Stop hook mirrors
# replies and parks. The flag = file ~/.claude/tg-hitl/projects/<cwd with / → %>.
# This is the ONLY switch: the global "away" mode was removed (two switches
# with OR logic made disabling confusing — "off" didn't turn it off).
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
    echo "(this project's permission prompts now go to Telegram)"
    ;;
  off)
    rm -f "$flag"
    # report the ACTUAL state after removal, not the intent — so "disabled"
    # never diverges from reality
    if [ -f "$flag" ]; then
      echo "⚠️ NOT DISABLED: flag $flag could not be removed" >&2
      exit 1
    fi
    echo "tg-mode OFF → $cwd (verified: flag removed, mode inactive)"
    ;;
  status)
    if [ -f "$flag" ]; then echo "Current project: ON  ($cwd)"; else echo "Current project: OFF ($cwd)"; fi
    echo "Active projects:"
    if [ -n "$(ls -A "$PROJ_DIR" 2>/dev/null)" ]; then
      for f in "$PROJ_DIR"/*; do
        [ -f "$f" ] && echo "  - $(basename "$f" | sed 's#%#/#g')"
      done
    else
      echo "  (none)"
    fi
    ;;
  *)
    echo "usage: tg-mode.sh on|off|status [cwd]" >&2
    exit 2
    ;;
esac
