#!/usr/bin/env bash
# Builds HyperSend.app from Sources/ using the Command Line Tools only —
# no Xcode project, no package manager, no dependencies.
#
#   ./build.sh          debug-ish build into ./HyperSend.app
#   ./build.sh release  optimised build
#   ./build.sh run      build, then launch

set -euo pipefail
cd "$(dirname "$0")"

APP="HyperSend.app"
BINARY="$APP/Contents/MacOS/HyperSend"
MODE="${1:-release}"

SWIFT_FLAGS=(-target arm64-apple-macos14.0 -framework AppKit -framework QuartzCore -framework CryptoKit)
if [[ "$MODE" == "release" ]]; then
  SWIFT_FLAGS+=(-O -whole-module-optimization)
else
  SWIFT_FLAGS+=(-Onone -g)
fi

# bash 3.2 ships with macOS, so no mapfile/readarray here.
SOURCES=$(find Sources -name '*.swift' | sort)
if [[ -z "$SOURCES" ]]; then
  echo "no sources found" >&2
  exit 1
fi
COUNT=$(printf '%s\n' "$SOURCES" | wc -l | tr -d ' ')

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The icon is generated, not drawn by hand — see tools/make-icon.swift. The
# bundle still builds without it; it just looks unfinished in the Dock.
if [[ -f HyperSend.icns ]]; then
  cp HyperSend.icns "$APP/Contents/Resources/HyperSend.icns"
else
  echo "note: HyperSend.icns missing — run tools/make-icon.swift to regenerate" >&2
fi

echo "compiling $COUNT source files…"
# shellcheck disable=SC2086 -- deliberately unquoted so the file list splits
swiftc "${SWIFT_FLAGS[@]}" $SOURCES -o "$BINARY"

# Ad-hoc signature: enough for local runs and for the local-network prompt to
# behave, and it keeps Gatekeeper quiet on this machine.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "warning: ad-hoc codesign failed (the app still runs locally)"

echo "built $APP ($(du -h "$BINARY" | cut -f1))"

if [[ "$MODE" == "run" ]]; then
  pkill -f "$BINARY" 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "launched"
fi
