#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE=${1:-}

case "$PACKAGE" in
  formats|polygon|repair|features|evidence|gcode) ;;
  *)
    printf '[hw_slicer] invalid mixed ASan package: %s\n' "$PACKAGE" >&2
    exit 2
    ;;
esac

ODIN="$ROOT/scripts/odin.sh"
CLANG=$(xcrun --find clang)
SDK_ROOT=$(xcrun --sdk macosx --show-sdk-path)
OUTPUT_DIR="$ROOT/build/$PACKAGE/asan"
COMPAT_OBJECT="$OUTPUT_DIR/asan_compat.o"
TEST_BINARY="$OUTPUT_DIR/$PACKAGE-tests"
APPLE_ASAN_RUNTIME="$("$CLANG" --print-resource-dir)/lib/darwin/libclang_rt.asan_osx_dynamic.dylib"

mkdir -p "$OUTPUT_DIR"
"$CLANG" -Wall -Wextra -Werror -O0 -g -isysroot "$SDK_ROOT" -c \
  "$ROOT/host/asan_compat.c" \
  -o "$COMPAT_OBJECT"
LINKER_FLAGS="$COMPAT_OBJECT -Wl,-undefined,dynamic_lookup -Wl,-headerpad_max_install_names"
set -- "-extra-linker-flags:$LINKER_FLAGS"
if [ "$PACKAGE" != "formats" ]; then
  "$ROOT/scripts/clipper2-build.sh" asan >/dev/null
  LIBRARY="../../build/clipper2/asan/libhw_clipper2.a"
  LINKER_FLAGS="$COMPAT_OBJECT -lc++ -Wl,-undefined,dynamic_lookup -Wl,-headerpad_max_install_names"
  set -- \
    "-define:HW_CLIPPER2_LIBRARY=$LIBRARY" \
    "-extra-linker-flags:$LINKER_FLAGS"
fi
"$ODIN" build "$ROOT/src/$PACKAGE" \
  -build-mode:test \
  -out:"$TEST_BINARY" \
  -debug \
  -sanitize:address \
  -define:ODIN_TEST_THREADS=1 \
  "$@"
odin_asan_runtime=$(otool -L "$TEST_BINARY" |
  awk '/libclang_rt\.asan_osx_dynamic\.dylib/ {print $1; exit}')
if [ -z "$odin_asan_runtime" ]; then
  printf '[hw_slicer] %s tests did not link the ASan runtime\n' \
    "$PACKAGE" >&2
  exit 1
fi
install_name_tool \
  -change "$odin_asan_runtime" "$APPLE_ASAN_RUNTIME" \
  "$TEST_BINARY"
LLVM_ROOT=$(CDPATH= cd -- "$(dirname -- "$odin_asan_runtime")/../../../../.." && pwd)
SYMBOLIZER="$LLVM_ROOT/bin/llvm-symbolizer"
env \
  DYLD_INSERT_LIBRARIES="$APPLE_ASAN_RUNTIME" \
  ASAN_SYMBOLIZER_PATH="$SYMBOLIZER" \
  ASAN_OPTIONS=detect_leaks=0 \
  "$TEST_BINARY"
