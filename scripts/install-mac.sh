#!/usr/bin/env bash
# Builds the Mac app, installs it to ~/Applications and restarts it so the newest version is always running.
# The running copy is asked to quit normally first, so its state is saved.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
# Signed with the owner's certificate when this Mac has one (scripts/signing.sh): the app keeps the same identity
# on every build, so macOS keeps its permissions instead of asking again after each update.
source scripts/signing.sh
# shellcheck disable=SC2086
xcodebuild -project GIFMaker.xcodeproj -scheme GIFMaker -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build $(sign_settings) -quiet build

APP="$HOME/Applications/GIF Maker.app"
RUNNING='GIF Maker\.app/Contents/MacOS/'
if pgrep -f "$RUNNING" >/dev/null; then
  osascript -e 'tell application id "app.gifmaker.mac" to quit' || true
  # Saving can take a while; wait until it has really exited (up to 2 minutes).
  for _ in $(seq 1 480); do pgrep -f "$RUNNING" >/dev/null || break; sleep 0.25; done
  if pgrep -f "$RUNNING" >/dev/null; then echo "The running copy didn't quit; not replacing it."; exit 1; fi
fi

mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "build/Build/Products/Release/GIF Maker.app" "$APP"
open "$APP"
for _ in $(seq 1 40); do pgrep -f "$RUNNING" >/dev/null && break; sleep 0.25; done
pgrep -f "$RUNNING" >/dev/null || { echo "Failed to start"; exit 1; }
echo "GIF Maker restarted with the new build"
