#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

CONSOLE_USER=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)
TARGET_HOME=""

if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
  TARGET_HOME=$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}' || true)
fi

if [[ -z "$TARGET_HOME" ]]; then
  TARGET_HOME="/Users/Shared"
fi

DESKTOP_DIR="$TARGET_HOME/Desktop"
if [[ ! -d "$DESKTOP_DIR" ]]; then
  DESKTOP_DIR="$TARGET_HOME"
fi

OUT_DIR="$DESKTOP_DIR/Mac_Display_Diag"
ZIP_PATH="$DESKTOP_DIR/Display_Logs_$(date +%Y%m%d).zip"

mkdir -p "$OUT_DIR"

system_profiler SPDisplaysDataType > "$OUT_DIR/displays.txt"
# grep returns non-zero when the key is absent (e.g. Apple Silicon / external-only
# displays); guard so `set -e`/pipefail doesn't abort the whole diagnostic run.
ioreg -lw0 | grep -i "AppleBacklightDisplay" > "$OUT_DIR/ioreg_internal.txt" || true
log show --predicate 'process == "WindowServer"' --last 24h > "$OUT_DIR/windowserver_logs.txt"

if [[ -f /var/log/system.log ]]; then
  cp /var/log/system.log "$OUT_DIR/system_log_backup.txt" 2>/dev/null || true
fi

zip -r "$ZIP_PATH" "$OUT_DIR"