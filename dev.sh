#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE="debug"
WATCH_SOURCES=0

for arg in "$@"; do
  case "$arg" in
    debug|asan|release) MODE="$arg" ;;
    --watch) WATCH_SOURCES=1 ;;
    *)
      echo "usage: ./dev.sh [debug|asan|release] [--watch]" >&2
      exit 2
      ;;
  esac
done

case "$MODE" in
  debug) APP="$ROOT/build/HWSlicer.app" ;;
  asan) APP="$ROOT/build/asan/HWSlicer.app" ;;
  release)
    "$ROOT/build.sh" release
    exec "$ROOT/build/release/HWSlicer.app/Contents/MacOS/HWSlicer"
    ;;
esac

HW_DEVLOG_DIR=${HW_DEVLOG_DIR:-"$ROOT/.dev-logs/$MODE"}
HW_DEVLOG_PROFILE=${HW_DEVLOG_PROFILE:-dev}
export HW_DEVLOG_DIR HW_DEVLOG_PROFILE
HOST="$APP/Contents/MacOS/HWSlicer"
READY_STAMP="$ROOT/build/.ready-$MODE"
RUNTIME="$ROOT/.hw-slicer-runtime"
LOCK="$ROOT/build/dev-watcher.lock"
PID_FILE="$RUNTIME/pid"
SNAPSHOT="$RUNTIME/controls.tsv"
APP_PID=""

ready_stamp() {
  if [ -f "$READY_STAMP" ]; then
    cat "$READY_STAMP" 2>/dev/null || true
  elif [ -f "$HOST" ]; then
    stat -f '%m:%z' "$HOST" 2>/dev/null || true
  fi
}

source_fingerprint() {
  find \
    "$ROOT/src" \
    "$ROOT/host" \
    "$ROOT/resources" \
    -path "$ROOT/resources/designs" -prune -o \
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
  activate=$1
  mkdir -p "$RUNTIME"
  if [ "$MODE" = "asan" ]; then
    asan_runtime=$(
      xcrun clang --print-resource-dir
    )/lib/darwin/libclang_rt.asan_osx_dynamic.dylib
    env \
      DYLD_INSERT_LIBRARIES="$asan_runtime" \
      HW_SLICER_ACTIVATE_ON_LAUNCH="$activate" \
      HW_SLICER_UI_SNAPSHOT="$SNAPSHOT" \
      MTL_DEBUG_LAYER=1 \
      "$HOST" &
  else
    env \
      HW_SLICER_ACTIVATE_ON_LAUNCH="$activate" \
      HW_SLICER_UI_SNAPSHOT="$SNAPSHOT" \
      MTL_DEBUG_LAYER=1 \
      "$HOST" &
  fi
  APP_PID=$!
  printf '%s\n' "$APP_PID" > "$PID_FILE"
  printf '[hw_slicer] launched pid %s (%s)\n' "$APP_PID" "$MODE"
  printf '[hw_slicer] dev log: %s\n' "$HW_DEVLOG_DIR"
}

stop_app() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  APP_PID=""
}

relaunch_app() {
  printf '\n[hw_slicer] new %s build detected; relaunching...\n' "$MODE"
  stop_app
  launch_app 0
}

rebuild_and_launch() {
  activate=$1
  printf '\n[hw_slicer] rebuilding %s...\n' "$MODE"
  if ! "$ROOT/build.sh" "$MODE"; then
    printf '[hw_slicer] build failed; keeping the current app running\n'
    return 1
  fi
  stop_app
  launch_app "$activate"
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

if [ ! -x "$HOST" ]; then
  rebuild_and_launch 1 || exit 1
else
  launch_app 1
fi
LAST_STAMP=$(ready_stamp)
LAST_SOURCES=""
if [ "$WATCH_SOURCES" -eq 1 ]; then
  LAST_SOURCES=$(source_fingerprint | shasum | cut -d' ' -f1)
fi

while :; do
  sleep 0.5
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    wait "$APP_PID"
    exit $?
  fi
  CURRENT_STAMP=$(ready_stamp)
  if [ -n "$CURRENT_STAMP" ] && [ "$CURRENT_STAMP" != "$LAST_STAMP" ]; then
    LAST_STAMP=$CURRENT_STAMP
    relaunch_app
    if [ "$WATCH_SOURCES" -eq 1 ]; then
      LAST_SOURCES=$(source_fingerprint | shasum | cut -d' ' -f1)
    fi
    continue
  fi
  if [ "$WATCH_SOURCES" -eq 1 ]; then
    CURRENT_SOURCES=$(source_fingerprint | shasum | cut -d' ' -f1)
    if [ "$CURRENT_SOURCES" != "$LAST_SOURCES" ]; then
      LAST_SOURCES=$CURRENT_SOURCES
      rebuild_and_launch 0
      LAST_STAMP=$(ready_stamp)
    fi
  fi
done
