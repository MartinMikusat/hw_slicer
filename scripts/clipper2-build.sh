#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:-debug}
THIRD_PARTY="$ROOT/third_party/clipper2"
OUTPUT_DIR="$ROOT/build/clipper2/$MODE"
INCLUDE_DIR="$THIRD_PARTY/include"
LIBRARY="$OUTPUT_DIR/libhw_clipper2.a"

case "$MODE" in
  debug)
    MODE_FLAGS="-O0 -g"
    ;;
  release)
    MODE_FLAGS="-O3 -DNDEBUG"
    ;;
  asan)
    MODE_FLAGS="-O1 -g -fsanitize=address -fno-omit-frame-pointer"
    ;;
  *)
    printf '[hw_slicer] invalid Clipper2 build mode: %s\n' "$MODE" >&2
    exit 2
    ;;
esac

(
  cd "$THIRD_PARTY"
  shasum -a 256 -c SHA256SUMS >/dev/null
)

mkdir -p "$OUTPUT_DIR"
CXX=$(xcrun --find clang++)
AR=$(xcrun --find ar)
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
COMMON_FLAGS="-std=c++17 -fPIC -isysroot $SDKROOT"

"$CXX" $COMMON_FLAGS $MODE_FLAGS \
  -I"$INCLUDE_DIR" \
  -c "$THIRD_PARTY/src/clipper.engine.cpp" \
  -o "$OUTPUT_DIR/clipper.engine.o"
"$CXX" $COMMON_FLAGS $MODE_FLAGS \
  -I"$INCLUDE_DIR" \
  -c "$THIRD_PARTY/src/clipper.offset.cpp" \
  -o "$OUTPUT_DIR/clipper.offset.o"
"$CXX" $COMMON_FLAGS $MODE_FLAGS \
  -I"$INCLUDE_DIR" \
  -I"$ROOT/src/polygon" \
  -c "$ROOT/src/polygon/hw_clipper2.cpp" \
  -o "$OUTPUT_DIR/hw_clipper2.o"
"$AR" rcs "$LIBRARY" \
  "$OUTPUT_DIR/clipper.engine.o" \
  "$OUTPUT_DIR/clipper.offset.o" \
  "$OUTPUT_DIR/hw_clipper2.o"

printf '%s\n' "$LIBRARY"
