#!/usr/bin/env bash
# Packs build/MacPlayer.app into dist/: a .dmg (drag to Applications), a .zip and a SHA-256 list.
# The app is ad-hoc signed, not notarized (notarization needs a paid Apple Developer account), so on first launch macOS asks the person to
# confirm: see docs/huong-dan-cai-dat.md. Nothing is uploaded anywhere.
# Usage: Scripts/make_release.sh [universal]
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build_app.sh release "${1:-}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/MacPlayer.app/Contents/Info.plist)"
DIST="dist"; NAME="MacPlayer-$VERSION"
rm -rf "$DIST"; mkdir -p "$DIST/stage"
cp -R build/MacPlayer.app "$DIST/stage/"
ln -s /Applications "$DIST/stage/Applications"
hdiutil create -quiet -volname "MacPlayer $VERSION" -srcfolder "$DIST/stage" -ov -format UDZO "$DIST/$NAME.dmg"
ditto -c -k --keepParent build/MacPlayer.app "$DIST/$NAME.zip"
rm -rf "$DIST/stage"
( cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt )
codesign --verify --deep --strict build/MacPlayer.app && echo "signature: ad-hoc, valid"
echo "Built:"; ls -lh "$DIST"
