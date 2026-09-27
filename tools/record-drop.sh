#!/usr/bin/env bash
# Records the drop choreography live: launches HyperSend with HS_SIM_DROP so
# the drop path fires on a timer, then captures the window to a QuickTime
# movie with `screencapture -v` while the ripple runs.
#
#   tools/record-drop.sh [x y] [out.mov]
#
# Timeline: launch at t=0 → recording starts t≈5 s → the simulated drop
# fires at t=6.5 s (2 s into the recording) → recording stops at t≈13 s,
# covering calm, impact, and the settling tail.

set -euo pipefail
cd "$(dirname "$0")/.."

X="${1:-430}"
Y="${2:-300}"
OUT="${3:-/tmp/hypersend-drop.mov}"

APP="/Applications/HyperSend.app"

echo "launching with simulated drop at ($X, $Y)…"
HS_SIM_DROP="$X,$Y,6.5" open -a "$APP"

# Wait for the window and grab its ID.
WID=""
for _ in $(seq 1 40); do
  sleep 0.5
  WID=$(xcrun swift tools/window-id.swift HyperSend 2>/dev/null || true)
  if [[ -n "${WID:-}" ]]; then break; fi
done
[[ -n "$WID" ]] || { echo "no HyperSend window found" >&2; exit 1; }
echo "window $WID — recording…"

# Recording starts around t≈5 s; the drop fires at t=6.5 s, two seconds in.
sleep 5
screencapture -v -x -l "$WID" "$OUT" &
REC_PID=$!
sleep 8
kill -INT $REC_PID 2>/dev/null || true
wait $REC_PID 2>/dev/null || true

echo "saved $OUT ($(du -h "$OUT" | cut -f1))"
echo "extract frames with: mkdir -p /tmp/dropframes && ffmpeg -i $OUT -r 30 /tmp/dropframes/f%02d.png"
