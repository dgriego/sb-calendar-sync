#!/bin/bash
# ./install.sh build        compile to ~/.local/bin/outlook-sync, copy example config
# ./install.sh schedule     sync once every "scheduleEveryDays" (config.json, default 1).
#                           launchd checks hourly; outlook-sync skips if it already synced.
# ./install.sh unschedule   stop the scheduled job
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.daniel.outlook-sync"
BIN="$HOME/.local/bin/outlook-sync"
CONF_DIR="$HOME/.config/outlook-sync"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/outlook-sync.log"
CONFIG="$CONF_DIR/config.json"
DOMAIN="gui/$(id -u)"

# Read a value from the JSON config, or print nothing if it isn't there.
config_value() { plutil -extract "$1" raw -o - "$CONFIG" 2>/dev/null || true; }

# Escape a value for use inside the launchd plist's XML.
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

case "${1:-}" in
  build)
    mkdir -p "$(dirname "$BIN")" "$CONF_DIR"
    swiftc -O outlook-sync.swift -o "$BIN" \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
    if [ ! -f "$CONF_DIR/config.json" ]; then
      cp config.example.json "$CONF_DIR/config.json"
      echo "Created $CONF_DIR/config.json — edit it before syncing."
    fi
    echo "Built $BIN"
    ;;
  schedule)
    [ -x "$BIN" ] || { echo "Run ./install.sh build first."; exit 1; }
    [ -f "$CONFIG" ] || { echo "No config at $CONFIG. Run ./install.sh build first."; exit 1; }

    # launchd starts it at the top of every hour (not at login). With
    # --scheduled, outlook-sync exits right away unless its last sync was at
    # least "scheduleEveryDays" days ago, so it syncs at most that often.
    DAYS="$(config_value scheduleEveryDays)"
    DAYS="${DAYS:-1}"
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || (( 10#$DAYS < 1 || 10#$DAYS > 365 )); then
      echo "scheduleEveryDays must be a whole number from 1 to 365 (got \"$DAYS\")."; exit 1
    fi
    DAYS=$((10#$DAYS))
    if (( DAYS == 1 )); then DESCRIPTION="once a day"; else DESCRIPTION="once every $DAYS days"; fi

    mkdir -p "$(dirname "$AGENT")" "$(dirname "$LOG")"
    cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(xml_escape "$LABEL")</string>
  <key>ProgramArguments</key><array><string>$(xml_escape "$BIN")</string><string>--scheduled</string></array>
  <key>StartCalendarInterval</key><dict><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$(xml_escape "$LOG")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$LOG")</string>
</dict>
</plist>
EOF
    launchctl bootout "$DOMAIN" "$AGENT" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$AGENT"
    echo "Scheduled to sync $DESCRIPTION (checked at the top of each hour). Log: $LOG"
    echo "If macOS asks to let outlook-sync access your calendars, click Allow."
    ;;
  unschedule)
    launchctl bootout "$DOMAIN" "$AGENT" 2>/dev/null || true
    rm -f "$AGENT"
    echo "Unscheduled."
    ;;
  *)
    echo "Usage: $0 build | schedule | unschedule"; exit 1 ;;
esac
