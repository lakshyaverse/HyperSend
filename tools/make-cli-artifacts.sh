#!/usr/bin/env bash
# Packages the Node CLI into ready-to-run artifacts for Linux and Windows —
# the same engine that ships inside the Mac app, for people without a Mac.
#
#   ./make-cli-artifacts.sh          → build/cli/hypersend-cli-<os>-<arch>.<ext>
#
# Each artifact carries dist/ (compiled JS), bin/ (the wrappers), package.json
# and README.md. It needs Node >= 20 on the target machine and nothing else —
# the engine is dependency-free, so there is no node_modules to ship.
#
# Run from the repo root.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/cli"
rm -rf "$OUT"
mkdir -p "$OUT"

# Fresh compile so the artifacts always match the tree.
npx tsc

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$STAGING/hypersend"
cp -R dist "$STAGING/hypersend/dist"
cp -R bin "$STAGING/hypersend/bin"
cp package.json README.md LICENSE "$STAGING/hypersend/"

cd "$STAGING"
VERSION=$(node -p "require('./hypersend/package.json').version")

tar -czf "$OLDPWD/$OUT/hypersend-cli-$VERSION-linux-x64.tar.gz" hypersend
zip -qr "$OLDPWD/$OUT/hypersend-cli-$VERSION-windows-x64.zip" hypersend

cd "$OLDPWD"
echo "packaged:"
ls -lh "$OUT"
