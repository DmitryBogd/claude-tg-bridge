#!/bin/bash
# install.sh — install claude-tg-bridge into ~/.claude/tg-hitl/
# Creates the runtime directory, copies scripts, installs the launchd daemon,
# and prints the hook snippet to add to your Claude Code settings.json.
set -euo pipefail

DEST="$HOME/.claude/tg-hitl"
LAUNCHD_LABEL="com.$(id -un).tg-hitl-daemon"
PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing claude-tg-bridge to $DEST"
mkdir -p "$DEST"

# Copy scripts
for f in tg-daemon.sh tg-ask.sh tg-session.sh tg-permission.sh tg-mode.sh; do
  cp "$SCRIPT_DIR/$f" "$DEST/$f"
  chmod +x "$DEST/$f"
done

# Create .env if it doesn't exist
if [ ! -f "$DEST/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$DEST/.env"
  chmod 600 "$DEST/.env"
  echo ""
  echo "  Created $DEST/.env — fill in TG_TOKEN and TG_CHAT_ID before starting the daemon."
  echo ""
else
  echo "  $DEST/.env already exists — skipping."
fi

# Generate and install launchd plist
mkdir -p "$HOME/Library/LaunchAgents"
sed \
  -e "s|__USERNAME__|$(id -un)|g" \
  -e "s|__HOME__|$HOME|g" \
  "$SCRIPT_DIR/launchd/com.USER.tg-hitl-daemon.plist.template" \
  > "$PLIST"

echo "==> Launchd plist written to $PLIST"

# Load (or reload) the daemon
if launchctl list "$LAUNCHD_LABEL" &>/dev/null; then
  launchctl unload "$PLIST" 2>/dev/null || true
fi
launchctl load "$PLIST"
echo "==> Daemon loaded: $LAUNCHD_LABEL"

echo ""
echo "==> Add the following hooks to your ~/.claude/settings.json"
echo "    (or run: cat $SCRIPT_DIR/hooks-config.json)"
echo ""
echo "Done. Run 'tg-mode.sh status' to verify, 'launchctl list $LAUNCHD_LABEL' to check the daemon."
