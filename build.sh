#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
MODE=${1:-debug}

case "$MODE" in
  debug)
    APP="$ROOT/build/HWSlicer.app"
    ODIN_FLAGS="-debug -o:none -keep-temp-files"
    CLANG_FLAGS="-O0 -g"
    ;;
  asan)
    APP="$ROOT/build/asan/HWSlicer.app"
    ODIN_FLAGS="-debug -o:none -keep-temp-files -sanitize:address"
    CLANG_FLAGS="-O0 -g -fsanitize=address"
    ;;
  release)
    APP="$ROOT/build/release/HWSlicer.app"
    ODIN_FLAGS="-o:speed"
    CLANG_FLAGS="-O2"
    ;;
  *)
    echo "usage: ./build.sh [debug|asan|release]" >&2
    exit 2
    ;;
esac

"$ROOT/scripts/dependencies.sh" check
"$ROOT/scripts/clipper2-build.sh" "$MODE" >/dev/null
ODIN="$ROOT/scripts/odin.sh"
CLANG=$(xcrun --find clang)
SDK_ROOT=$(xcrun --sdk macosx --show-sdk-path)
BUILD_DIR="$ROOT/build/application/$MODE"
EXECUTABLE="$APP/Contents/MacOS/HWSlicer"
HOST_OBJECT="$BUILD_DIR/HWSlicerHost.o"
FRAMEWORKS="-framework AppKit -framework Foundation -framework Metal -framework QuartzCore -framework UniformTypeIdentifiers -framework CoreText -framework CoreGraphics"
ASAN_COMPAT_OBJECT=""

mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS"

# shellcheck disable=SC2086
"$CLANG" -fobjc-arc -Wall -Wextra -Werror $CLANG_FLAGS \
  -isysroot "$SDK_ROOT" \
  -c "$ROOT/host/HWSlicerHost.m" \
  -o "$HOST_OBJECT"

if [ "$MODE" = "asan" ]; then
  ASAN_COMPAT_OBJECT="$BUILD_DIR/application_asan_compat.o"
  "$CLANG" -Wall -Wextra -Werror -O0 -g \
    -isysroot "$SDK_ROOT" \
    -c "$ROOT/host/application_asan_compat.c" \
    -o "$ASAN_COMPAT_OBJECT"
fi

(
  cd "$BUILD_DIR"
  # shellcheck disable=SC2086
  "$ODIN" build "$ROOT/src" \
    -out:"$EXECUTABLE" \
    $ODIN_FLAGS \
    -collection:flash="$FLASH_ROOT" \
    -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/$MODE/libhw_clipper2.a" \
    -extra-linker-flags:"$HOST_OBJECT $ASAN_COMPAT_OBJECT -lc++ $FRAMEWORKS"
)

rm -rf "$APP/Contents/Resources/Fonts"
mkdir -p \
  "$APP/Contents/Resources/Icons/Iconoir" \
  "$APP/Contents/Resources/Models/licenses"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/resources/icons/iconoir/"*.svg \
  "$APP/Contents/Resources/Icons/Iconoir/"
cp "$ROOT/resources/icons/iconoir/LICENSE" \
  "$APP/Contents/Resources/Icons/Iconoir/LICENSE"
cp "$ROOT/resources/models/"*.stl "$APP/Contents/Resources/Models/"
cp "$ROOT/resources/models/LICENSES.md" \
  "$APP/Contents/Resources/Models/LICENSES.md"
cp "$ROOT/resources/models/licenses/"*.txt \
  "$APP/Contents/Resources/Models/licenses/"

if [ "$MODE" != "release" ]; then
  xcrun dsymutil "$EXECUTABLE" -o "$APP.dSYM"
fi

codesign --force --deep --sign - "$APP"
printf '[hw_slicer] built %s: %s\n' "$MODE" "${APP#"$ROOT/"}"
