#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
"$ROOT/scripts/dependencies.sh" check
ODIN=$("$ROOT/scripts/odin.sh" --print-path)
"$ODIN" test "$ROOT/src" \
  -debug \
  -o:none \
  -collection:flash="$FLASH_ROOT" \
  -extra-linker-flags:"-framework Foundation -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics"
