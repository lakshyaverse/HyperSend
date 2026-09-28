#!/usr/bin/env bash
# Builds and runs the engine conformance tests. Engine sources only — no AppKit,
# no Xcode, no test framework.
set -euo pipefail
cd "$(dirname "$0")"

OUT="/tmp/hypersend-enginetests"

# Target the machine we are ON. The hardcoded arm64 triple locked Intel Macs —
# still inside the macos14 deployment target — out of the whole suite.
ARCH=$(uname -m)

# shellcheck disable=SC2086
swiftc -O -target "${ARCH}-apple-macos14.0" \
  Sources/Engine/*.swift \
  Sources/Format.swift \
  Tests/EngineTests.swift \
  Tests/main.swift \
  -framework CryptoKit \
  -o "$OUT"

exec "$OUT"
