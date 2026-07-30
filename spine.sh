#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ODIN="$ROOT/scripts/odin.sh"
OUTPUT="$ROOT/build/spine/hw-slicer-spine"

mkdir -p "$ROOT/build/spine"
"$ODIN" build "$ROOT/cmd/hw-slicer-spine" \
  -o:speed \
  -out:"$OUTPUT"
exec "$OUTPUT" "$@"
