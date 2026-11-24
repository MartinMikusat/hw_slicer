#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -d "$ROOT/../hw_odin_ui_flash" ]; then
  FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
elif [ -d "$ROOT/../odin_libraries/hw_odin_ui_flash" ]; then
  FLASH_ROOT="$ROOT/../odin_libraries/hw_odin_ui_flash"
elif [ -d "$ROOT/../main/hw_odin_ui_flash" ]; then
  FLASH_ROOT="$ROOT/../main/hw_odin_ui_flash"
elif [ -d "$ROOT/../hw/hw_odin_ui_flash" ]; then
  FLASH_ROOT="$ROOT/../hw/hw_odin_ui_flash"
else
  FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
fi
if [ -d "$ROOT/../hw_odin_devlog" ]; then
  DEVLOG_ROOT="$ROOT/../hw_odin_devlog"
elif [ -d "$ROOT/../odin_libraries/hw_odin_devlog" ]; then
  DEVLOG_ROOT="$ROOT/../odin_libraries/hw_odin_devlog"
else
  DEVLOG_ROOT="$ROOT/../hw_odin_devlog"
fi
if [ -d "$ROOT/../hw_odin_ui_components" ]; then
  COMPONENTS_ROOT="$ROOT/../hw_odin_ui_components"
elif [ -d "$ROOT/../odin_libraries/hw_odin_ui_components" ]; then
  COMPONENTS_ROOT="$ROOT/../odin_libraries/hw_odin_ui_components"
else
  COMPONENTS_ROOT="$ROOT/../hw_odin_ui_components"
fi
RUNE_ROOT="$ROOT/../hw_odin_rune"
NEO_ROOT="$ROOT/../hw_neobrutalism/neo"
MODE=${1:-debug}

case "$MODE" in
  debug)
    APP="$ROOT/build/hw_slicer.app"
    ODIN_FLAGS="-debug -o:none -keep-temp-files"
    CLANG_FLAGS="-O0 -g"
    ;;
  asan)
    APP="$ROOT/build/asan/hw_slicer.app"
    ODIN_FLAGS="-debug -o:none -keep-temp-files -sanitize:address"
    CLANG_FLAGS="-O0 -g -fsanitize=address"
    ;;
  release|cli-release)
    APP="$ROOT/build/release/hw_slicer.app"
    ODIN_FLAGS="-o:speed"
    CLANG_FLAGS="-O2"
    ;;
  *)
    echo "usage: ./build.sh [debug|asan|release|cli-release]" >&2
    exit 2
    ;;
esac

CLIPPER_MODE="$MODE"
if [ "$MODE" = "cli-release" ]; then
  CLIPPER_MODE="release"
fi

"$ROOT/scripts/dependencies.sh" check
if [ "$MODE" != "cli-release" ]; then
  bash "$RUNE_ROOT/scripts/build-metallib.sh"
fi
"$ROOT/scripts/clipper2-build.sh" "$CLIPPER_MODE" >/dev/null
ODIN="$ROOT/scripts/odin.sh"
CLANG=$(xcrun --find clang)
SDK_ROOT=$(xcrun --sdk macosx --show-sdk-path)
BUILD_DIR="$ROOT/build/application/$CLIPPER_MODE"
EXECUTABLE="$APP/Contents/MacOS/hw_slicer"
HOST_OBJECT="$BUILD_DIR/HWSlicerHost.o"
METAL_COMPUTE_OBJECT="$BUILD_DIR/HWSlicerMetalCompute.o"
MOONRAKER_OBJECT="$BUILD_DIR/HWSlicerMoonraker.o"
FRAMEWORKS="-framework AppKit -framework Foundation -framework Metal -framework QuartzCore -framework UniformTypeIdentifiers -framework CoreText -framework CoreGraphics"
CLI_FRAMEWORKS="-framework Foundation -framework Metal"
MCP_FRAMEWORKS="-framework Foundation"
ASAN_COMPAT_OBJECT=""

mkdir -p "$BUILD_DIR"

# Compile headless Metal compute bridge (used by both GUI and CLI; no AppKit dependency).
# shellcheck disable=SC2086
"$CLANG" -fobjc-arc -Wall -Wextra -Werror $CLANG_FLAGS \
  -isysroot "$SDK_ROOT" \
  -c "$ROOT/host/HWSlicerMetalCompute.m" \
  -o "$METAL_COMPUTE_OBJECT"

# Compile Moonraker native transport (used by GUI and read-only printer MCP server).
# shellcheck disable=SC2086
"$CLANG" -fobjc-arc -Wall -Wextra -Werror $CLANG_FLAGS \
  -isysroot "$SDK_ROOT" \
  -c "$ROOT/host/HWSlicerMoonraker.m" \
  -o "$MOONRAKER_OBJECT"

if [ "$MODE" != "cli-release" ]; then
  mkdir -p "$APP/Contents/MacOS"
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
      -collection:devlog="$DEVLOG_ROOT" \
      -collection:rune="$RUNE_ROOT" \
      -collection:components="$COMPONENTS_ROOT" \
      -collection:neo="$NEO_ROOT" \
      -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/$CLIPPER_MODE/libhw_clipper2.a" \
      -extra-linker-flags:"$HOST_OBJECT $METAL_COMPUTE_OBJECT $MOONRAKER_OBJECT $ASAN_COMPAT_OBJECT -lc++ $FRAMEWORKS"
  )
fi

CLI_EXECUTABLE="$ROOT/build/hw-slicer-cli"
if [ "$CLIPPER_MODE" != "debug" ]; then
  CLI_EXECUTABLE="$ROOT/build/$CLIPPER_MODE/hw-slicer-cli"
  mkdir -p "$ROOT/build/$CLIPPER_MODE"
fi
(
  cd "$BUILD_DIR"
  # shellcheck disable=SC2086
  "$ODIN" build "$ROOT/src/cli" \
    -out:"$CLI_EXECUTABLE" \
    $ODIN_FLAGS \
    -collection:devlog="$DEVLOG_ROOT" \
    -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/$CLIPPER_MODE/libhw_clipper2.a" \
    -extra-linker-flags:"$METAL_COMPUTE_OBJECT $ASAN_COMPAT_OBJECT -lc++ $CLI_FRAMEWORKS"
)

MCP_EXECUTABLE="$ROOT/build/hw-slicer-printer-mcp"
if [ "$CLIPPER_MODE" != "debug" ]; then
  MCP_EXECUTABLE="$ROOT/build/$CLIPPER_MODE/hw-slicer-printer-mcp"
fi
(
  cd "$BUILD_DIR"
  # shellcheck disable=SC2086
  "$ODIN" build "$ROOT/src/printer_mcp" \
    -out:"$MCP_EXECUTABLE" \
    $ODIN_FLAGS \
    -collection:devlog="$DEVLOG_ROOT" \
    -extra-linker-flags:"$MOONRAKER_OBJECT $ASAN_COMPAT_OBJECT $MCP_FRAMEWORKS"
)

if [ "$MODE" = "cli-release" ]; then
  echo "[hw_slicer] built cli-release: ${CLI_EXECUTABLE#"$ROOT"/}"
  exit 0
fi

rm -rf "$APP/Contents/Resources/Fonts"
mkdir -p \
  "$APP/Contents/Resources/Icons/Iconoir" \
  "$APP/Contents/Resources/Models/licenses"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/resources/app-icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
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
READY_STAMP="$ROOT/build/.ready-$MODE"
printf '%s:%s\n' "$(date +%s)" "$$" > "$READY_STAMP.tmp"
mv "$READY_STAMP.tmp" "$READY_STAMP"
printf '[hw_slicer] built %s: %s\n' "$MODE" "${APP#"$ROOT/"}"
