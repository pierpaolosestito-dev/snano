#!/usr/bin/env bash
set -euo pipefail

echo ">>> Uninstalling snano..."

# --- Variables ---
BIN_DIR="$HOME/bin"
CONFIG_DIR="$HOME/.config/snano"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

# --- 1. Stop and disable systemd timer ---
if systemctl --user list-unit-files | grep -q snano-prune.timer; then
  systemctl --user stop snano-prune.timer || true
  systemctl --user disable snano-prune.timer || true
  echo ">>> Disabled snano-prune.timer"
fi

# --- 2. Remove systemd units ---
rm -f "$SYSTEMD_USER_DIR/snano-prune.service"
rm -f "$SYSTEMD_USER_DIR/snano-prune.timer"
echo ">>> Removed systemd service and timer"

# --- 3. Remove main script ---
rm -f "$BIN_DIR/snano"
echo ">>> Removed $BIN_DIR/snano"

# --- 4. (Optional) Remove user config ---
if [[ -f "$CONFIG_DIR/config" ]]; then
  echo ">>> Found config at $CONFIG_DIR/config"
  read -rp "Do you want to delete your snano config as well? [y/N] " yn
  case "$yn" in
    [Yy]* ) rm -rf "$CONFIG_DIR"; echo ">>> Config deleted";;
    * ) echo ">>> Config preserved";;
  esac
fi

# --- 5. Reload systemd ---
systemctl --user daemon-reload
echo ">>> systemd reloaded"

echo ">>> Uninstallation complete!"
