#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ODIN="$ROOT/scripts/odin.sh"
CLANG=$(xcrun --find clang)
SDK_ROOT=$(xcrun --sdk macosx --show-sdk-path)
OUTPUT_DIR="$ROOT/build/strict-feature-probe/asan"
COMPAT_OBJECT="$OUTPUT_DIR/asan_compat.o"
BINARY="$OUTPUT_DIR/hw-slicer-strict-feature-probe"
TOPOLOGY_BINARY="$OUTPUT_DIR/hw-slicer-topology-replay"
ACTUAL="$OUTPUT_DIR/stanford-bunny-v1.actual.json"
EXPECTED="$ROOT/testdata/feature-probes/stanford-bunny-v1.json"
ARTIFACT="$OUTPUT_DIR/path-plan.bin"
BUNDLE="$OUTPUT_DIR/stanford-bunny-path-plan-v1.hwsdebug"
DIRECTORY="$OUTPUT_DIR/stanford-bunny-path-plan-v1.hwsdebug-dir"
BUNDLE_EXPECTED_SHA256=1fab0f11792b7bdf3b01533992475cde4e3faa4f7318ed87cbb572a8f2dad31e
TOPOLOGY_EXPECTED_SHA256=d6eb53fd2b3e2086c0b90ce27892d67cf7230310d509d27653fec0d6579a252a
REGION_EXPECTED_SHA256=ffae9c9887d2c70ae1b22bb53a4c2b651f3d9ac4dc8f3b4bfb3e75b4e7b18cea
TOPOLOGY_REPLAY_ACTUAL="$OUTPUT_DIR/stanford-bunny-topology-replay-v1.actual.json"
TOPOLOGY_REPLAY_EXPECTED="$ROOT/testdata/evidence/stanford-bunny-topology-replay-v1.json"
LIBRARY="../../build/clipper2/asan/libhw_clipper2.a"
APPLE_ASAN_RUNTIME="$(
  "$CLANG" --print-resource-dir
)/lib/darwin/libclang_rt.asan_osx_dynamic.dylib"

mkdir -p "$OUTPUT_DIR"
rm -rf "$DIRECTORY"
"$ROOT/scripts/clipper2-build.sh" asan >/dev/null
"$CLANG" -Wall -Wextra -Werror -O0 -g -isysroot "$SDK_ROOT" -c \
  "$ROOT/host/asan_compat.c" \
  -o "$COMPAT_OBJECT"
"$ODIN" build "$ROOT/cmd/hw-slicer-strict-feature-probe" \
  -out:"$BINARY" \
  -debug \
  -sanitize:address \
  -define:HW_CLIPPER2_LIBRARY="$LIBRARY" \
  -extra-linker-flags:"$COMPAT_OBJECT -lc++ -Wl,-undefined,dynamic_lookup -Wl,-headerpad_max_install_names"
"$ODIN" build "$ROOT/cmd/hw-slicer-topology-replay" \
  -out:"$TOPOLOGY_BINARY" \
  -debug \
  -sanitize:address \
  -define:HW_CLIPPER2_LIBRARY="$LIBRARY" \
  -extra-linker-flags:"$COMPAT_OBJECT -lc++ -Wl,-undefined,dynamic_lookup -Wl,-headerpad_max_install_names"
odin_asan_runtime=$(
  otool -L "$BINARY" |
    awk '/libclang_rt\.asan_osx_dynamic\.dylib/ {print $1; exit}'
)
if [ -z "$odin_asan_runtime" ]; then
  printf '[hw_slicer] strict feature probe did not link ASan\n' >&2
  exit 1
fi
install_name_tool \
  -change "$odin_asan_runtime" "$APPLE_ASAN_RUNTIME" \
  "$BINARY"
topology_asan_runtime=$(
  otool -L "$TOPOLOGY_BINARY" |
    awk '/libclang_rt\.asan_osx_dynamic\.dylib/ {print $1; exit}'
)
if [ -z "$topology_asan_runtime" ]; then
  printf '[hw_slicer] topology replay did not link ASan\n' >&2
  exit 1
fi
install_name_tool \
  -change "$topology_asan_runtime" "$APPLE_ASAN_RUNTIME" \
  "$TOPOLOGY_BINARY"
LLVM_ROOT=$(CDPATH= cd -- "$(dirname -- "$odin_asan_runtime")/../../../../.." && pwd)
SYMBOLIZER="$LLVM_ROOT/bin/llvm-symbolizer"

env \
  DYLD_INSERT_LIBRARIES="$APPLE_ASAN_RUNTIME" \
  ASAN_SYMBOLIZER_PATH="$SYMBOLIZER" \
  ASAN_OPTIONS=detect_leaks=0 \
  "$BINARY" \
    "$ROOT/resources/models/stanford-bunny.stl" \
    "$ARTIFACT" \
    "$BUNDLE" \
    "$DIRECTORY" > "$ACTUAL"
if ! cmp -s "$EXPECTED" "$ACTUAL"; then
  printf '[hw_slicer] ASan Stanford Bunny feature fixture changed\n' >&2
  diff -u "$EXPECTED" "$ACTUAL" >&2 || true
  exit 1
fi
bundle_sha256=$(shasum -a 256 "$BUNDLE" | awk '{print $1}')
if [ "$bundle_sha256" != "$BUNDLE_EXPECTED_SHA256" ]; then
  printf \
    '[hw_slicer] ASan Stanford Bunny evidence bundle changed: %s\n' \
    "$bundle_sha256" >&2
  exit 1
fi
if ! cmp -s \
  "$ARTIFACT" \
  "$DIRECTORY/stages/10-plan-paths/primitives/path-plan.bin"; then
  printf '[hw_slicer] ASan Stanford Bunny evidence directory changed\n' >&2
  exit 1
fi
topology_sha256=$(
  shasum -a 256 \
    "$DIRECTORY/stages/07-reconstruct-topology/primitives/topology.bin" |
    awk '{print $1}'
)
if [ "$topology_sha256" != "$TOPOLOGY_EXPECTED_SHA256" ]; then
  printf \
    '[hw_slicer] ASan Stanford Bunny topology artifact changed: %s\n' \
    "$topology_sha256" >&2
  exit 1
fi
region_sha256=$(
  shasum -a 256 \
    "$DIRECTORY/stages/08-calculate-regions/primitives/regions.bin" |
    awk '{print $1}'
)
if [ "$region_sha256" != "$REGION_EXPECTED_SHA256" ]; then
  printf \
    '[hw_slicer] ASan Stanford Bunny region artifact changed: %s\n' \
    "$region_sha256" >&2
  exit 1
fi
env \
  DYLD_INSERT_LIBRARIES="$APPLE_ASAN_RUNTIME" \
  ASAN_SYMBOLIZER_PATH="$SYMBOLIZER" \
  ASAN_OPTIONS=detect_leaks=0 \
  "$TOPOLOGY_BINARY" \
    --manifest "$DIRECTORY/stages/07-reconstruct-topology/manifest.json" \
    "$DIRECTORY/stages/07-reconstruct-topology/primitives/topology.bin" \
    > "$TOPOLOGY_REPLAY_ACTUAL"
if ! cmp -s "$TOPOLOGY_REPLAY_EXPECTED" "$TOPOLOGY_REPLAY_ACTUAL"; then
  printf '[hw_slicer] ASan Stanford Bunny topology replay changed\n' >&2
  diff -u "$TOPOLOGY_REPLAY_EXPECTED" "$TOPOLOGY_REPLAY_ACTUAL" >&2 || true
  exit 1
fi

printf '[hw_slicer] strict feature ASan fixture passed\n'
