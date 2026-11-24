#!/bin/sh
# Compiles shaders/slicer_compute.metal into build/compute/slicer_compute.metallib, which
# src/gpu embeds with #load, so the Metal compute kernels are never compiled at run time.
# Does nothing when the library is newer than its source. scripts/odin.sh runs it before builds.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/shaders/slicer_compute.metal"
OUT="$ROOT/build/compute"
LIB="$OUT/slicer_compute.metallib"

if [ -f "$LIB" ] && [ "$LIB" -nt "$SRC" ]; then
  exit 0
fi
mkdir -p "$OUT"
xcrun -sdk macosx metal -std=metal3.1 -mmacosx-version-min=15.0 -c "$SRC" -o "$OUT/slicer_compute.air"
xcrun -sdk macosx metallib "$OUT/slicer_compute.air" -o "$LIB"
