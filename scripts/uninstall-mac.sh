#!/bin/bash
# Removes the Mac side (menu bar app and schedules). The GitHub workflow keeps running until you disable it.
set -uo pipefail
for label in com.local.app-review-watcher.check com.local.app-review-watcher.menubar com.local.apple-appt-watcher; do
  launchctl bootout "gui/$UID/$label" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
pkill -x AppReviewWatcher 2>/dev/null
rm -rf "$HOME/Applications/App Review Watcher.app"
echo "Removed. Settings and logs are still in ~/Library/Application Support/AppReviewWatcher (delete that folder to remove them too)."
