#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:-debug}

if [ "$MODE" = "asan" ]; then
  "$ROOT/scripts/mixed-asan-test.sh" gcode
  exit 0
fi

ODIN="$ROOT/scripts/odin.sh"
"$ROOT/scripts/clipper2-build.sh" "$MODE" >/dev/null
LIBRARY="../../build/clipper2/$MODE/libhw_clipper2.a"

case "$MODE" in
  debug)
    ODIN_FLAGS="-debug"
    OUTPUT_FLAG="-o:none"
    ;;
  release)
    ODIN_FLAGS=""
    OUTPUT_FLAG="-o:speed"
    ;;
  *)
    printf '[hw_slicer] invalid G-code test mode: %s\n' "$MODE" >&2
    exit 2
    ;;
esac

# The archive path is relative to the Odin package that imports it.
# shellcheck disable=SC2086
"$ODIN" test "$ROOT/src/gcode" \
  $ODIN_FLAGS \
  "$OUTPUT_FLAG" \
  -define:HW_CLIPPER2_LIBRARY="$LIBRARY" \
  -extra-linker-flags:"-lc++"
