#!/bin/bash
# ./install.sh build        compile to ~/.local/bin/outlook-sync, copy example config
# ./install.sh schedule     run every 30 min via launchd (INTERVAL=900 ./install.sh schedule for 15 min)
# ./install.sh unschedule   stop the scheduled job
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.daniel.outlook-sync"
BIN="$HOME/.local/bin/outlook-sync"
CONF_DIR="$HOME/.config/outlook-sync"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/outlook-sync.log"
INTERVAL="${INTERVAL:-1800}"
DOMAIN="gui/$(id -u)"

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
    if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || (( 10#$INTERVAL < 60 )); then
      echo "INTERVAL must be a whole number of seconds, at least 60."; exit 1
    fi
    INTERVAL=$((10#$INTERVAL))
    mkdir -p "$(dirname "$AGENT")" "$(dirname "$LOG")"
    cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(xml_escape "$LABEL")</string>
  <key>ProgramArguments</key><array><string>$(xml_escape "$BIN")</string></array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$(xml_escape "$LOG")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$LOG")</string>
</dict>
</plist>
EOF
    launchctl bootout "$DOMAIN" "$AGENT" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$AGENT"
    echo "Scheduled every $((INTERVAL / 60)) min. Log: $LOG"
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
