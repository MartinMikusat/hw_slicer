#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
MODE=${1:-debug}
PART=${2:-all}

case "$MODE" in
  debug)
    APP="$ROOT/build/HWSlicer.app"
    ODIN_FLAGS="-debug -o:none -keep-temp-files"
    CLANG="$(xcrun --find clang)"
    CLANG_FLAGS="-O0 -g"
    HOST_LINK_FLAGS=""
    ;;
  asan)
    APP="$ROOT/build/asan/HWSlicer.app"
    ODIN_FLAGS="-debug -o:none -keep-temp-files -sanitize:address"
    CLANG="$(xcrun --find clang)"
    CLANG_FLAGS="-O0 -g -fsanitize=address"
    HOST_LINK_FLAGS=""
    ;;
  release)
    APP="$ROOT/build/release/HWSlicer.app"
    ODIN_FLAGS="-o:speed"
    CLANG="$(xcrun --find clang)"
    CLANG_FLAGS="-O2"
    HOST_LINK_FLAGS=""
    ;;
  *)
    echo "usage: scripts/hot-reload-build.sh [debug|asan|release] [all|host|module]" >&2
    exit 2
    ;;
esac

"$CLANG" --version >/dev/null
SDK_ROOT=$(xcrun --sdk macosx --show-sdk-path)
CLANG_FLAGS="$CLANG_FLAGS -isysroot $SDK_ROOT"

case "$PART" in
  all|host|module) ;;
  *)
    echo "usage: scripts/hot-reload-build.sh [debug|asan|release] [all|host|module]" >&2
    exit 2
    ;;
esac

"$ROOT/scripts/dependencies.sh" check
ODIN=$("$ROOT/scripts/odin.sh" --print-path)

HOT_DIR="$ROOT/build/hot-reload/$MODE"
HOST="$APP/Contents/MacOS/HWSlicer"
MODULE="$HOT_DIR/slicer.dylib"
MODULE_NEXT="$HOT_DIR/slicer.next.dylib"
mkdir -p "$HOT_DIR" "$APP/Contents/MacOS"

copy_resources() {
  mkdir -p \
    "$APP/Contents/Resources/Fonts" \
    "$APP/Contents/Resources/Icons/Iconoir" \
    "$APP/Contents/Resources/Models/licenses"
  cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
  cp "$ROOT/resources/fonts/Iosevka-Regular.ttf" \
    "$APP/Contents/Resources/Fonts/Iosevka-Regular.ttf"
  cp "$ROOT/resources/fonts/IOSEVKA-LICENSE.md" \
    "$APP/Contents/Resources/Fonts/IOSEVKA-LICENSE.md"
  cp "$ROOT/resources/icons/iconoir/"*.svg \
    "$APP/Contents/Resources/Icons/Iconoir/"
  cp "$ROOT/resources/icons/iconoir/LICENSE" \
    "$APP/Contents/Resources/Icons/Iconoir/LICENSE"
  cp "$ROOT/resources/models/"*.stl "$APP/Contents/Resources/Models/"
  cp "$ROOT/resources/models/LICENSES.md" \
    "$APP/Contents/Resources/Models/LICENSES.md"
  cp "$ROOT/resources/models/licenses/"*.txt \
    "$APP/Contents/Resources/Models/licenses/"
}

build_host() {
  host_object="$HOT_DIR/HWSlicerHost.o"
  # shellcheck disable=SC2086
  "$CLANG" -fobjc-arc -Wall -Wextra -Werror $CLANG_FLAGS -c \
    "$ROOT/host/HWSlicerHost.m" \
    -o "$host_object"
  # shellcheck disable=SC2086
  "$CLANG" $CLANG_FLAGS $HOST_LINK_FLAGS "$host_object" \
    -framework AppKit \
    -framework QuartzCore \
    -framework UniformTypeIdentifiers \
    -o "$HOST"
  if [ "$MODE" = "asan" ]; then
    "$CLANG" -Wall -Wextra -Werror -O0 -g -isysroot "$SDK_ROOT" -c \
      "$ROOT/host/asan_compat.c" \
      -o "$HOT_DIR/asan_compat.o"
  fi
  copy_resources
  if [ "$MODE" != "release" ]; then
    xcrun dsymutil "$HOST" -o "$APP.dSYM"
  fi
}

build_module() {
  module_link_flags="-framework Foundation -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics"
  if [ "$MODE" = "asan" ]; then
    if [ ! -x "$HOST" ]; then
      echo "[hw_slicer] build the ASan host before its module" >&2
      exit 1
    fi
    asan_runtime="$("$CLANG" --print-resource-dir)/lib/darwin/libclang_rt.asan_osx_dynamic.dylib"
    if [ ! -f "$asan_runtime" ]; then
      echo "[hw_slicer] could not resolve the host ASan runtime" >&2
      exit 1
    fi
    module_link_flags="$module_link_flags $HOT_DIR/asan_compat.o -Wl,-undefined,dynamic_lookup"
  fi
  (
    cd "$HOT_DIR"
    # shellcheck disable=SC2086
    "$ODIN" build "$ROOT/src" \
      -build-mode:dll \
      -out:"$MODULE_NEXT" \
      $ODIN_FLAGS \
      -collection:flash="$FLASH_ROOT" \
      -extra-linker-flags:"$module_link_flags"
  )
  if [ "$MODE" = "asan" ]; then
    odin_asan_runtime=$(otool -L "$MODULE_NEXT" |
      awk '/libclang_rt\.asan_osx_dynamic\.dylib/ {print $1; exit}')
    if [ -z "$odin_asan_runtime" ]; then
      echo "[hw_slicer] the ASan module did not link its runtime" >&2
      exit 1
    fi
    if [ "$odin_asan_runtime" != "$asan_runtime" ]; then
      install_name_tool \
        -change "$odin_asan_runtime" "$asan_runtime" \
        "$MODULE_NEXT"
    fi
  fi
  if [ "$MODE" != "release" ]; then
    xcrun dsymutil "$MODULE_NEXT" -o "$MODULE_NEXT.dSYM"
  fi
  mv -f "$MODULE_NEXT" "$MODULE"
  if [ "$MODE" != "release" ]; then
    if [ -d "$MODULE.dSYM" ]; then
      rm -r "$MODULE.dSYM"
    fi
    mv "$MODULE_NEXT.dSYM" "$MODULE.dSYM"
  fi
  cp "$MODULE" "$APP/Contents/MacOS/slicer.dylib"
}

case "$PART" in
  all)
    build_host
    build_module
    ;;
  host)
    build_host
    ;;
  module)
    build_module
    ;;
esac

codesign --force --deep --sign - "$APP"
printf '[hw_slicer] built %s %s: %s\n' "$MODE" "$PART" "${APP#"$ROOT/"}"
