#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE=${1:-debug}

case "$MODE" in
  debug) APP="$ROOT/build/HWSlicer.app" ;;
  asan) APP="$ROOT/build/asan/HWSlicer.app" ;;
  release)
    "$ROOT/build.sh" release
    exec "$ROOT/build/release/HWSlicer.app/Contents/MacOS/HWSlicer"
    ;;
  *)
    echo "usage: ./dev.sh [debug|asan|release]" >&2
    exit 2
    ;;
esac

HOST="$APP/Contents/MacOS/HWSlicer"
RUNTIME="$ROOT/.hw-slicer-runtime"
LOCK="$ROOT/build/dev-watcher.lock"
PID_FILE="$RUNTIME/pid"
SNAPSHOT="$RUNTIME/controls.tsv"
APP_PID=""

fingerprint() {
  find \
    "$ROOT/src" \
    "$ROOT/host" \
    "$ROOT/resources" \
    -type f -print0 |
    xargs -0 stat -f '%m:%z:%N' 2>/dev/null
  stat -f '%m:%z:%N' \
    "$ROOT"/*.sh \
    "$ROOT"/scripts/*.sh \
    "$ROOT"/dependencies.lock \
    "$ROOT"/Info.plist \
    2>/dev/null
}

launch_app() {
  mkdir -p "$RUNTIME"
  if [ "$MODE" = "asan" ]; then
    asan_runtime=$(
      xcrun clang --print-resource-dir
    )/lib/darwin/libclang_rt.asan_osx_dynamic.dylib
    env \
      DYLD_INSERT_LIBRARIES="$asan_runtime" \
      HW_SLICER_ACTIVATE_ON_LAUNCH=0 \
      HW_SLICER_UI_SNAPSHOT="$SNAPSHOT" \
      MTL_DEBUG_LAYER=1 \
      "$HOST" &
  else
    env \
      HW_SLICER_ACTIVATE_ON_LAUNCH=0 \
      HW_SLICER_UI_SNAPSHOT="$SNAPSHOT" \
      MTL_DEBUG_LAYER=1 \
      "$HOST" &
  fi
  APP_PID=$!
  printf '%s\n' "$APP_PID" > "$PID_FILE"
  printf '[hw_slicer] launched pid %s (%s)\n' "$APP_PID" "$MODE"
}

rebuild_and_launch() {
  printf '\n[hw_slicer] rebuilding %s...\n' "$MODE"
  if ! "$ROOT/build.sh" "$MODE"; then
    printf '[hw_slicer] build failed; keeping the current app running\n'
    return 1
  fi
  stop_app
  launch_app
}

stop_app() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  APP_PID=""
}

cleanup() {
  status=$?
  trap - INT TERM EXIT
  stop_app
  rm -f "$PID_FILE"
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null || true
  exit "$status"
}

mkdir -p "$ROOT/build" "$RUNTIME"
if ! mkdir "$LOCK" 2>/dev/null; then
  existing=$(sed -n '1p' "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
    printf '[hw_slicer] dev watcher already running as pid %s\n' "$existing"
    exit 0
  fi
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null || true
  mkdir "$LOCK"
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap cleanup INT TERM EXIT

rebuild_and_launch || exit 1
LAST_FINGERPRINT=$(fingerprint | shasum | cut -d' ' -f1)

while :; do
  sleep 0.5
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    wait "$APP_PID"
    exit $?
  fi
  CURRENT_FINGERPRINT=$(fingerprint | shasum | cut -d' ' -f1)
  if [ "$CURRENT_FINGERPRINT" != "$LAST_FINGERPRINT" ]; then
    LAST_FINGERPRINT=$CURRENT_FINGERPRINT
    rebuild_and_launch
  fi
done
