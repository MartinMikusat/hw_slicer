#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$#" -lt 1 ] || [ "$#" -gt 4 ]; then
  printf \
    'usage: %s <binary-stl> [path-plan-artifact [evidence-bundle [evidence-directory]]]\n' \
    "$0" >&2
  exit 2
fi

"$ROOT/scripts/dependencies.sh" check >&2
"$ROOT/scripts/clipper2-build.sh" release >&2
ODIN="$ROOT/scripts/odin.sh"
OUTPUT_DIR="$ROOT/build/strict-feature-probe"
BINARY="$OUTPUT_DIR/hw-slicer-strict-feature-probe"
LIBRARY="../../build/clipper2/release/libhw_clipper2.a"

mkdir -p "$OUTPUT_DIR"
"$ODIN" build "$ROOT/cmd/hw-slicer-strict-feature-probe" \
  -out:"$BINARY" \
  -o:speed \
  -define:HW_CLIPPER2_LIBRARY="$LIBRARY" \
  -extra-linker-flags:"-lc++"
"$BINARY" "$@"
