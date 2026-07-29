#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUNTIME="$ROOT/.hw-slicer-runtime"
PID_FILE="$RUNTIME/pid"
CURRENT="$RUNTIME/controls.tsv"
ARTIFACTS="$RUNTIME/artifacts"
BASELINE="$ROOT/ui-baselines/idle.tsv"
COMMAND=${1:-snapshot}

pid=$(sed -n '1p' "$PID_FILE" 2>/dev/null || true)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "[hw_slicer] the running application is required" >&2
  exit 1
fi
if [ ! -f "$CURRENT" ]; then
  echo "[hw_slicer] the live control registry is not ready" >&2
  exit 1
fi

mkdir -p "$ARTIFACTS"
stamp=$(date -u '+%Y%m%dT%H%M%SZ')
artifact="$ARTIFACTS/ui-$stamp.tsv"
cp "$CURRENT" "$artifact"

find "$ARTIFACTS" -type f -name 'ui-*.tsv' -print |
  sort -r |
  sed -n '21,$p' |
  while IFS= read -r old; do
    [ -n "$old" ] && rm -f "$old"
  done

case "$COMMAND" in
  snapshot)
    count=$(sed -n '1s/^controls	\([0-9][0-9]*\).*/\1/p' "$artifact")
    printf '[hw_slicer] controls=%s artifact=%s\n' "$count" "$artifact"
    ;;
  baseline)
    mkdir -p "$ROOT/ui-baselines"
    cp "$artifact" "$BASELINE"
    printf '[hw_slicer] saved baseline=%s\n' "$BASELINE"
    ;;
  check)
    if [ ! -f "$BASELINE" ]; then
      echo "[hw_slicer] missing baseline: $BASELINE" >&2
      exit 1
    fi
    if cmp -s "$BASELINE" "$artifact"; then
      count=$(sed -n '1s/^controls	\([0-9][0-9]*\).*/\1/p' "$artifact")
      printf '[hw_slicer] controls=%s diff=0 artifact=%s\n' "$count" "$artifact"
    else
      diff_path="$ARTIFACTS/ui-$stamp.diff"
      diff -u "$BASELINE" "$artifact" > "$diff_path" || true
      lines=$(wc -l < "$diff_path" | tr -d ' ')
      printf '[hw_slicer] diff=%s artifact=%s\n' "$lines" "$diff_path" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: scripts/ui.sh [snapshot|baseline|check]" >&2
    exit 2
    ;;
esac
