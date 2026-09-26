#!/usr/bin/env bash
# Builds HyperSend.app with xcodebuild (the real project, hardened runtime),
# and can package HyperSend.dmg.
#
#   ./build.sh          release app into ./build/HyperSend.app
#   ./build.sh debug    debug build
#   ./build.sh run      build, then launch
#   ./build.sh dmg      release build, then package HyperSend.dmg
#
# Open mac/HyperSend.xcodeproj in Xcode for development; this script is the
# command-line path over the same project, so both always agree.

set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
APP="build/HyperSend.app"
DMG="HyperSend.dmg"

case "$MODE" in
  debug) CONFIG=Debug ;;
  *)     CONFIG=Release ;;
esac

echo "building ($CONFIG) with xcodebuild…"
xcodebuild -project HyperSend.xcodeproj \
  -scheme HyperSend \
  -configuration "$CONFIG" \
  -derivedDataPath build/DD \
  build >/dev/null

mkdir -p build
rm -rf "$APP"
cp -R "build/DD/Build/Products/$CONFIG/HyperSend.app" "$APP"

# Archive-style re-sign: strips the debug entitlement so the release bundle
# keeps the hardened runtime flag without get-task-allow.
if [[ "$CONFIG" == "Release" ]]; then
  printf '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict/></plist>' > build/no-entitlements.plist
  codesign --force --sign - --timestamp=none --options runtime --entitlements build/no-entitlements.plist "$APP" 2>/dev/null
fi

codesign --verify --strict "$APP" && echo "built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "$MODE" == "run" ]]; then
  pkill -f "$APP/Contents/MacOS/HyperSend" 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "launched"
fi

if [[ "$MODE" == "dmg" ]]; then
  STAGING=$(mktemp -d)
  trap 'rm -rf "$STAGING"' EXIT
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  rm -f "$DMG"
  hdiutil create -volname "HyperSend" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
  echo "packaged $DMG ($(du -h "$DMG" | cut -f1))"
fi
