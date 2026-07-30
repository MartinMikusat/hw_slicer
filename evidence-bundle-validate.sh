#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$#" -ne 1 ]; then
  printf 'usage: %s <evidence-bundle>\n' "$0" >&2
  exit 2
fi

"$ROOT/scripts/dependencies.sh" check >&2
"$ROOT/scripts/clipper2-build.sh" release >&2
ODIN="$ROOT/scripts/odin.sh"
OUTPUT_DIR="$ROOT/build/evidence-bundle-validate"
BINARY="$OUTPUT_DIR/hw-slicer-evidence-bundle-validate"
LIBRARY="../../build/clipper2/release/libhw_clipper2.a"

mkdir -p "$OUTPUT_DIR"
"$ODIN" build "$ROOT/cmd/hw-slicer-evidence-bundle-validate" \
  -out:"$BINARY" \
  -o:speed \
  -define:HW_CLIPPER2_LIBRARY="$LIBRARY" \
  -extra-linker-flags:"-lc++"
"$BINARY" "$1"
