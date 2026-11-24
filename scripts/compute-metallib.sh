#!/bin/sh
# Compiles shaders/*.metal into build/compute/*.metallib, which src/gpu and src/renderer embed
# with #load so Metal shaders are never compiled at run time.
# Does nothing for a library when it is newer than its source. scripts/odin.sh runs it before builds.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/build/compute"

compile_lib() {
  name=$1
  src="$ROOT/shaders/${name}.metal"
  lib="$OUT/${name}.metallib"
  if [ -f "$lib" ] && [ "$lib" -nt "$src" ]; then
    return 0
  fi
  mkdir -p "$OUT"
  xcrun -sdk macosx metal -std=metal3.1 -mmacosx-version-min=15.0 -c "$src" -o "$OUT/${name}.air"
  xcrun -sdk macosx metallib "$OUT/${name}.air" -o "$lib"
}

compile_lib slicer_compute
compile_lib slicer_renderer
