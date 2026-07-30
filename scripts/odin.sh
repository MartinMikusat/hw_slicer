#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXPECTED_ODIN=$(tr -d '\r\n' < "$ROOT/odin-version")

odin_version() {
  "$1" version 2>/dev/null | awk '{print $NF}'
}

if [ -n "${HW_SLICER_ODIN:-}" ]; then
  ODIN=$HW_SLICER_ODIN
  if [ ! -x "$ODIN" ]; then
    echo "[hw_slicer] HW_SLICER_ODIN is not executable: $ODIN" >&2
    exit 1
  fi

  ACTUAL_ODIN=$(odin_version "$ODIN" || true)
  if [ "$ACTUAL_ODIN" != "$EXPECTED_ODIN" ]; then
    echo "[hw_slicer] Odin version mismatch: expected $EXPECTED_ODIN, got ${ACTUAL_ODIN:-unknown} from $ODIN" >&2
    exit 1
  fi
else
  ODIN=""
  PATH_ODIN=$(command -v odin 2>/dev/null || true)
  for CANDIDATE in /opt/homebrew/bin/odin "$PATH_ODIN"; do
    if [ -z "$CANDIDATE" ] || [ ! -x "$CANDIDATE" ]; then
      continue
    fi
    if [ "$(odin_version "$CANDIDATE" || true)" = "$EXPECTED_ODIN" ]; then
      ODIN=$CANDIDATE
      break
    fi
  done

  if [ -z "$ODIN" ]; then
    ACTUAL_ODIN=""
    if [ -n "$PATH_ODIN" ] && [ -x "$PATH_ODIN" ]; then
      ACTUAL_ODIN=$(odin_version "$PATH_ODIN" || true)
    fi
    echo "[hw_slicer] could not find Odin $EXPECTED_ODIN" >&2
    if [ -n "$PATH_ODIN" ]; then
      echo "[hw_slicer] PATH resolves $PATH_ODIN (${ACTUAL_ODIN:-unknown})" >&2
    fi
    echo "[hw_slicer] set HW_SLICER_ODIN to the pinned compiler path" >&2
    exit 1
  fi
fi

if [ "${1:-}" = "--print-path" ]; then
  printf '%s\n' "$ODIN"
  exit 0
fi

case "${1:-}" in
  build|bundle|check|run|test)
    # The pinned compiler can race in its semantic checker on this project.
    COMMAND=$1
    shift
    TARGET=${1:-}
    if [ -z "$TARGET" ]; then
      exec "$ODIN" "$COMMAND"
    fi
    shift
    exec "$ODIN" "$COMMAND" "$TARGET" -no-threaded-checker "$@"
    ;;
esac

exec "$ODIN" "$@"
