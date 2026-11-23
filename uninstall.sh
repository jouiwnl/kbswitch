#!/usr/bin/env bash
LABEL="com.$(id -un).kbswitch"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/kbswitch" "$HOME/.config/kbswitch.conf"
echo "kbswitch removido."
