#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR="$ROOT/build/evidence-inspect"
BINARY="$OUTPUT_DIR/hw-slicer-evidence-inspect"

if [ "$#" -ne 1 ]; then
  echo "usage: ./evidence-inspect.sh <evidence-bundle-or-directory>" >&2
  exit 2
fi

"$ROOT/scripts/dependencies.sh" check >&2
"$ROOT/scripts/clipper2-build.sh" release >/dev/null
mkdir -p "$OUTPUT_DIR"
"$ROOT/scripts/odin.sh" build "$ROOT/cmd/hw-slicer-evidence-inspect" \
  -out:"$BINARY" \
  -o:speed \
  -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/release/libhw_clipper2.a" \
  -extra-linker-flags:"-lc++"
"$BINARY" "$1"
