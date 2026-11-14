#!/bin/bash
# Sets up the Mac side: builds the menu bar app, schedules the watcher, and starts both at login.
# Safe to run again after pulling changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$HOME/Library/Application Support/AppReviewWatcher"
APP="$HOME/Applications/App Review Watcher.app"
AGENTS="$HOME/Library/LaunchAgents"
CHECK_LABEL="com.local.app-review-watcher.check"
APP_LABEL="com.local.app-review-watcher.menubar"
NODE="$(command -v node || true)"

[ -n "$NODE" ] || { echo "Node.js is required (brew install node)"; exit 1; }
[ -d "/Applications/Google Chrome.app" ] || echo "Note: Google Chrome wasn't found; the Mac fallback check needs it."
mkdir -p "$DATA" "$AGENTS" "$HOME/Applications"

echo "→ Installing dependencies"
(cd "$ROOT" && npm install --silent --no-fund --no-audit)

echo "→ Writing settings"
REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' || true)"
ROOT="$ROOT" NODE="$NODE" REPO="$REPO" DATA="$DATA" "$NODE" <<'JS'
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const file = path.join(process.env.DATA, "config.json");
let cfg = {}; try { cfg = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
cfg.node = process.env.NODE;
cfg.watcher = path.join(process.env.ROOT, "watch.mjs");
if (process.env.REPO) cfg.repo = process.env.REPO;
// ntfy topics are public to anyone who knows the name, so use a long random one.
if (!cfg.ntfyTopic) cfg.ntfyTopic = "appreview-" + crypto.randomBytes(9).toString("base64url").toLowerCase().replace(/[^a-z0-9]/g, "x");
fs.writeFileSync(file, JSON.stringify(cfg, null, 2));
JS

echo "→ Building the menu bar app"
(cd "$ROOT/MenuBarApp" && swift build -c release 2>&1 | grep -E "error|Build complete" || true)
BIN="$ROOT/MenuBarApp/.build/release/AppReviewWatcher"
[ -x "$BIN" ] || { echo "Build failed. Xcode or its command line tools are required."; exit 1; }
launchctl bootout "gui/$UID/$APP_LABEL" 2>/dev/null || true
pkill -x AppReviewWatcher 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AppReviewWatcher"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.app-review-watcher</string>
  <key>CFBundleName</key><string>App Review Watcher</string>
  <key>CFBundleDisplayName</key><string>App Review Watcher</string>
  <key>CFBundleExecutable</key><string>AppReviewWatcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null

echo "→ Scheduling"
for old in com.local.apple-appt-watcher "$CHECK_LABEL"; do
  launchctl bootout "gui/$UID/$old" 2>/dev/null || true
done
rm -f "$AGENTS/com.local.apple-appt-watcher.plist"

cat > "$AGENTS/$CHECK_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$CHECK_LABEL</string>
  <key>ProgramArguments</key><array><string>$NODE</string><string>$ROOT/watch.mjs</string></array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$DATA/watch.log</string>
  <key>StandardErrorPath</key><string>$DATA/watch.log</string>
</dict></plist>
PLIST

cat > "$AGENTS/$APP_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$APP_LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-g</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST

launchctl bootstrap "gui/$UID" "$AGENTS/$CHECK_LABEL.plist"
launchctl bootstrap "gui/$UID" "$AGENTS/$APP_LABEL.plist"

TOPIC="$("$NODE" -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).ntfyTopic)' "$DATA/config.json")"
echo
echo "Done. Look for the calendar icon in your menu bar."
echo "Phone alerts: install the ntfy app and subscribe to this topic:  $TOPIC"
