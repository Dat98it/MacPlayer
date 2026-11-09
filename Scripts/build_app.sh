#!/usr/bin/env bash
# Build MacPlayer with SwiftPM and assemble an ad-hoc signed .app bundle (no Xcode needed).
# Pattern adapted from the author's own Mac Clean Scripts/build_app.sh (same MIT-licensed family of apps).
# Usage: Scripts/build_app.sh [release|debug] [universal]
#   universal  also build for Intel. Only arm64 has been tested: see README.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/MacPlayer.app"

ARCH_FLAGS=()
if [[ "${2:-}" == "universal" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" --product MacPlayer ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" --product MacPlayer ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/MacPlayer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacPlayer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/en.lproj Resources/vi.lproj "$APP/Contents/Resources/"

# Ad-hoc signature: enough to run on the machine that built it. Distribution needs a Developer ID and notarization.
codesign --force --sign - "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/MacPlayer"))"
