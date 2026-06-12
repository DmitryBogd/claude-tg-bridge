#!/bin/bash
# tg-permission.sh — PermissionRequest hook: confirm permissions via Telegram.
#
# Forwards a permission prompt to Telegram if per-project tg-mode is enabled
# for the cwd of this request (flag ~/.claude/tg-hitl/projects/<cwd>):
#       enable in the target project:  ~/.claude/tg-hitl/tg-mode.sh on
#       disable:                       ~/.claude/tg-hitl/tg-mode.sh off
#       (an agent can do this itself — it knows its own cwd)
# Otherwise the hook exits silently and the normal VSCode/CLI dialog is shown.
# The global "away" mode was REMOVED: two switches with OR logic made
# disabling confusing ("off" didn't turn it off because "away" remained).
# The per-project flag is the only mechanism.
#
# Telegram replies: "yes"/"+" → allow; "no"/"-" → deny;
# anything else or 240 s of silence → normal dialog (nothing breaks).
set -uo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

DIR="$HOME/.claude/tg-hitl"

in=$(cat)
cwd=$(printf '%s' "$in" | jq -r '.cwd // ""')
proj=$(basename "$cwd")
projflag="$DIR/projects/$(printf '%s' "$cwd" | sed 's#/#%#g')"

# No cwd or no project flag → send nothing.
if [ -z "$cwd" ] || [ ! -f "$projflag" ]; then
  exit 0
fi

tool=$(printf '%s' "$in" | jq -r '.tool_name // "?"')
# Slice in jq by CODEPOINTS: head -c used to cut UTF-8 mid-character →
# invalid text → Telegram 400 → the permission question silently never arrived.
detail=$(printf '%s' "$in" | jq -r \
  '(.tool_input.command // .tool_input.file_path // (.tool_input | tostring) // "") | .[0:400]')

ans=$("$DIR/tg-ask.sh" "🔐 [$proj] Permission request: $tool
$detail

Reply: yes / no" 240) || exit 0

case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" in
  yes*|y|+|ok|так*|ок|да*)
    jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest",
            decision: {behavior: "allow"}}}'
    ;;
  no*|n|-|ні*|нет*)
    jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest",
            decision: {behavior: "deny", message: "Denied by the user via Telegram"}}}'
    ;;
  *)
    exit 0
    ;;
esac
