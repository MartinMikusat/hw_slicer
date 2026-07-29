#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE=${1:-debug}

case "$MODE" in
  debug) APP="$ROOT/build/HWSlicer.app" ;;
  asan|release) APP="$ROOT/build/$MODE/HWSlicer.app" ;;
  *)
    echo "usage: ./dev.sh [debug|asan|release]" >&2
    exit 2
    ;;
esac

HOST="$APP/Contents/MacOS/HWSlicer"
MODULE="$ROOT/build/hot-reload/$MODE/slicer.dylib"
RUNTIME="$ROOT/.hw-slicer-runtime"
LOCK="$ROOT/build/dev-watcher.lock"
PID_FILE="$RUNTIME/pid"
SNAPSHOT="$RUNTIME/controls.tsv"
APP_PID=""

module_fingerprint() {
  stat -f '%m:%z:%N' "$ROOT"/src/*.odin "$ROOT/dependencies.lock" 2>/dev/null |
    shasum | cut -d' ' -f1
}

host_fingerprint() {
  stat -f '%m:%z:%N' \
    "$ROOT"/host/* "$ROOT/Info.plist" \
    "$ROOT/scripts/hot-reload-build.sh" \
    "$ROOT"/resources/fonts/* \
    "$ROOT"/resources/icons/iconoir/* \
    "$ROOT"/resources/models/* \
    "$ROOT"/resources/models/licenses/* \
    2>/dev/null | shasum | cut -d' ' -f1
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
      HW_SLICER_MODULE="$MODULE" \
      HW_SLICER_UI_SNAPSHOT="$SNAPSHOT" \
      MTL_DEBUG_LAYER=1 \
      "$HOST" &
  else
    env \
      HW_SLICER_ACTIVATE_ON_LAUNCH=0 \
      HW_SLICER_MODULE="$MODULE" \
      HW_SLICER_UI_SNAPSHOT="$SNAPSHOT" \
      MTL_DEBUG_LAYER=1 \
      "$HOST" &
  fi
  APP_PID=$!
  printf '%s\n' "$APP_PID" > "$PID_FILE"
  printf '[hw_slicer] launched pid %s (%s)\n' "$APP_PID" "$MODE"
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

"$ROOT/scripts/hot-reload-build.sh" "$MODE" all || exit 1
launch_app
LAST_MODULE=$(module_fingerprint)
LAST_HOST=$(host_fingerprint)

while :; do
  sleep 0.5
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    wait "$APP_PID"
    exit $?
  fi
  CURRENT_HOST=$(host_fingerprint)
  CURRENT_MODULE=$(module_fingerprint)
  if [ "$CURRENT_HOST" != "$LAST_HOST" ]; then
    LAST_HOST=$CURRENT_HOST
    LAST_MODULE=$CURRENT_MODULE
    if "$ROOT/scripts/hot-reload-build.sh" "$MODE" all; then
      stop_app
      launch_app
    fi
  elif [ "$CURRENT_MODULE" != "$LAST_MODULE" ]; then
    LAST_MODULE=$CURRENT_MODULE
    "$ROOT/scripts/hot-reload-build.sh" "$MODE" module || true
  fi
done
