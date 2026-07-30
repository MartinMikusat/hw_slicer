#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$ROOT/scripts/dependencies.sh" check >&2
"$ROOT/scripts/clipper2-build.sh" release >&2
ODIN="$ROOT/scripts/odin.sh"
OUTPUT_DIR="$ROOT/build/feature-benchmark"
BINARY="$OUTPUT_DIR/hw-slicer-feature-benchmark"
LIBRARY="../../build/clipper2/release/libhw_clipper2.a"

mkdir -p "$OUTPUT_DIR"
"$ODIN" build "$ROOT/cmd/hw-slicer-feature-benchmark" \
  -out:"$BINARY" \
  -o:speed \
  -define:HW_CLIPPER2_LIBRARY="$LIBRARY" \
  -extra-linker-flags:"-lc++"

git_dirty=false
if [ -n "$(git -C "$ROOT" status --short)" ]; then
  git_dirty=true
fi
hardware=$(sysctl -n hw.model 2>/dev/null || true)
if [ -z "$hardware" ]; then
  hardware=$(
    system_profiler SPHardwareDataType 2>/dev/null |
      awk -F': ' '
        /Model Identifier/ {model=$2}
        /^[[:space:]]*Chip:/ {chip=$2}
        END {
          if (model != "" && chip != "") {
            print model " / " chip
          } else if (model != "") {
            print model
          }
        }
      '
  )
fi
if [ -z "$hardware" ]; then
  hardware="$(uname -m) / unidentified"
fi

env \
  HW_SLICER_BENCH_HARDWARE="$hardware" \
  HW_SLICER_BENCH_OS_BUILD="$(sw_vers -buildVersion)" \
  HW_SLICER_BENCH_ODIN="$("$ODIN" version | awk '{print $NF}')" \
  HW_SLICER_BENCH_CLANG="$(xcrun clang --version | sed -n '1p')" \
  HW_SLICER_BENCH_GIT="$(git -C "$ROOT" rev-parse HEAD)" \
  HW_SLICER_BENCH_DIRTY="$git_dirty" \
  HW_SLICER_BENCH_THERMAL="unavailable" \
  "$BINARY" "$ROOT/resources/models/all-in-one-test.stl"
