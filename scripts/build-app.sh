#!/usr/bin/env bash
# Builds GIF Maker (universal: Apple Silicon + Intel) and packages dist/GIFMaker-mac.dmg: a DMG that opens on a
# "Drag GIF Maker to Applications" window (Support/DMG, laid out by dmgbuild).
#   scripts/build-app.sh            build the app and the .dmg
#   scripts/build-app.sh --install  also install to ~/Applications and launch
# Extra build settings (a version or feed URL from scripts/release.sh) come in BUILD_SETTINGS="KEY=value …".
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate --quiet

# Signed with a real certificate when there is one, so updates keep the app's permissions (scripts/signing.sh).
source scripts/signing.sh
SIGNING=$(sign_settings)
echo "Signing: ${SIGNING%% *}"
# shellcheck disable=SC2086
xcodebuild -project GIFMaker.xcodeproj -scheme GIFMaker -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  $SIGNING ${BUILD_SETTINGS:-} -quiet build

APP="build/Build/Products/Release/GIF Maker.app"
rm -rf dist && mkdir -p dist
# dmgbuild writes Finder's window layout without scripting Finder; it lives in a venv under build/.
[[ -x build/dmgvenv/bin/dmgbuild ]] || { python3 -m venv build/dmgvenv && build/dmgvenv/bin/pip install -q --disable-pip-version-check dmgbuild; }
build/dmgvenv/bin/dmgbuild -s Support/DMG/dmg-settings.py -D app="$APP" "GIF Maker" "dist/GIFMaker-mac.dmg" >/dev/null
echo "Built dist/GIFMaker-mac.dmg"

[[ "${1:-}" == "--install" ]] && scripts/install-mac.sh || true
