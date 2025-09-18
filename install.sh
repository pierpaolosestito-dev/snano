#!/usr/bin/env bash
set -euo pipefail

echo ">>> Installing snano..."

# --- Variables ---
BIN_DIR="$HOME/bin"
CONFIG_DIR="$HOME/.config/snano"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

# --- 1. Install the main script ---
mkdir -p "$BIN_DIR"
cp snano "$BIN_DIR/snano"
chmod +x "$BIN_DIR/snano"
echo ">>> Script installed in $BIN_DIR/snano"

# --- 2. User config ---
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config" ]]; then
  cp config/config.example "$CONFIG_DIR/config"
  echo ">>> Config file created at $CONFIG_DIR/config"
else
  echo ">>> Existing config detected, not overwriting"
fi

# --- 3. Systemd user units ---
mkdir -p "$SYSTEMD_USER_DIR"
cp systemd/snano-prune.service "$SYSTEMD_USER_DIR/"
cp systemd/snano-prune.timer "$SYSTEMD_USER_DIR/"
echo ">>> Service and timer copied to $SYSTEMD_USER_DIR"

# --- 4. Enable timer ---
systemctl --user daemon-reload
systemctl --user enable --now snano-prune.timer
echo ">>> snano-prune timer enabled (runs hourly)"

# --- 5. Status ---
systemctl --user status snano-prune.timer --no-pager || true

echo ">>> Installation complete!"
