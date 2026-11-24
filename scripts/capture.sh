#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/hw_slicer.app/Contents/MacOS/hw_slicer"
OUTPUT=${1:-"$ROOT/.hw-slicer-runtime/render.png"}
BMP="${OUTPUT%.png}.bmp"
LOG="$ROOT/.dev-logs/capture"
# Seconds to wait for the first frame. `--stage-run` slices before that frame, so raise it there.
TIMEOUT=${CAPTURE_TIMEOUT:-10}

if [ ! -x "$APP" ]; then
  echo "[hw_slicer] missing build: run ./build.sh debug" >&2
  exit 1
fi

# Each capture starts its own journal, so the summary describes only this run.
rm -rf "$LOG"
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
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "[hw_slicer] the app exited before its first frame; see hw-devlog --dir $LOG summary" >&2
    exit 1
  fi
  if [ "$attempt" -ge $((TIMEOUT*10)) ]; then
    echo "[hw_slicer] render capture timed out after ${TIMEOUT} s; set CAPTURE_TIMEOUT to wait longer" >&2
    exit 1
  fi
  sleep 0.1
done

sips -s format png "$BMP" --out "$OUTPUT" >/dev/null
rm -f "$BMP"
printf '[hw_slicer] captured render to %s\n' "$OUTPUT"
