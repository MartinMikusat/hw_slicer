#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/HWSlicer.app/Contents/MacOS/HWSlicer"
OUTPUT=${1:-"$ROOT/.hw-slicer-runtime/render.png"}
BMP="${OUTPUT%.png}.bmp"
LOG="$ROOT/.dev-logs/capture"

if [ ! -x "$APP" ]; then
  echo "[hw_slicer] missing build: run ./build.sh debug" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")" "$LOG"
rm -f "$BMP"

env \
  HW_SLICER_ACTIVATE_ON_LAUNCH=0 \
  HW_SLICER_CAPTURE="$BMP" \
  HW_DEVLOG_DIR="$LOG" \
  HW_DEVLOG_PROFILE=dev \
  "$APP" "$@" >/dev/null 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT INT TERM

attempt=0
while [ ! -f "$BMP" ]; do
  attempt=$((attempt+1))
  if [ "$attempt" -ge 100 ]; then
    echo "[hw_slicer] render capture timed out" >&2
    exit 1
  fi
  sleep 0.1
done

sips -s format png "$BMP" --out "$OUTPUT" >/dev/null
rm -f "$BMP"
printf '[hw_slicer] captured render to %s\n' "$OUTPUT"
