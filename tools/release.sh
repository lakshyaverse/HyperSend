#!/usr/bin/env bash
# Cuts a release: bumps nothing (bump first), builds every artifact the
# release carries, and publishes the GitHub release with all four platforms.
#
#   ./tools/release.sh 0.3.7           # tag + build + publish
#   ./tools/release.sh 0.3.7 --dry    # build everything, print the plan, no push
#
# Artifacts per release:
#   HyperSend.dmg                      macOS app (Apple Silicon + Intel)
#   HyperSend-<v>-debug.apk            Android receiver/sender
#   hypersend-cli-<v>-linux-x64.tar.gz Linux CLI (needs Node >= 20)
#   hypersend-cli-<v>-windows-x64.zip  Windows CLI (needs Node >= 20)
#
# The npm engine is single-source: the Linux and Windows artifacts carry the
# same dist/ compiled here. CI (cli.yml) typechecks and tests it on all three
# OSes before this script ever runs.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: tools/release.sh <version> [--dry]}"
DRY="${2:-}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be x.y.z" >&2; exit 1; }
git diff --quiet || { echo "working tree dirty — commit first" >&2; exit 1; }

echo "== building mac app + dmg"
(cd mac && ./build.sh dmg)

echo "== building android apk"
(cd android && gradle :app:assembleDebug -q --console=plain 2>&1 | grep -v "SDK XML" || true)
APK="HyperSend-$VERSION-debug.apk"
cp android/app/build/outputs/apk/debug/app-debug.apk "build/$APK"

echo "== packaging linux + windows CLI"
./tools/make-cli-artifacts.sh
CLI_TAR="hypersend-cli-$VERSION-linux-x64.tar.gz"
CLI_ZIP="hypersend-cli-$VERSION-windows-x64.zip"
mv build/cli/"$CLI_TAR" build/cli/"$CLI_ZIP" build/ 2>/dev/null || true

echo "== artifacts"
ls -lh "mac/HyperSend.dmg" "build/$APK" "build/$CLI_TAR" "build/$CLI_ZIP"

if [[ "$DRY" == "--dry" ]]; then
    echo "dry run — nothing pushed"
    exit 0
fi

echo "== tag v$VERSION"
git tag "v$VERSION"
git push origin main "v$VERSION"

echo "== github release"
gh release create "v$VERSION" \
    --title "$VERSION" \
    --generate-notes \
    "mac/HyperSend.dmg" \
    "build/$APK" \
    "build/$CLI_TAR" \
    "build/$CLI_ZIP"

echo "release v$VERSION published"
