#!/usr/bin/env bash
# Builds and runs the engine conformance tests. Engine sources only — no AppKit,
# no Xcode, no test framework.
set -euo pipefail
cd "$(dirname "$0")"

OUT="/tmp/hypersend-enginetests"

# shellcheck disable=SC2086
swiftc -O -target arm64-apple-macos14.0 \
  Sources/Engine/*.swift \
  Sources/Format.swift \
  Tests/EngineTests.swift \
  Tests/main.swift \
  -framework CryptoKit \
  -o "$OUT"

exec "$OUT"
