#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
EXPECTED_FLASH_URL="https://github.com/MartinMikusat/hw_odin_ui_flash.git"
EXPECTED_FLASH_COMMIT="f4744a6e76c04e99e54fa8e4205de416b612f1db"

if [ "${1:-}" != "check" ]; then
  echo "usage: scripts/dependencies.sh check" >&2
  exit 2
fi

hw-odin toolchain doctor >/dev/null || {
  echo "[hw_slicer] global Odin toolchain is unavailable" >&2
  exit 1
}

if [ ! -d "$FLASH_ROOT/.git" ]; then
  echo "[hw_slicer] missing sibling dependency: $FLASH_ROOT" >&2
  exit 1
fi

ACTUAL_FLASH_URL=$(git -C "$FLASH_ROOT" remote get-url origin)
ACTUAL_FLASH_COMMIT=$(git -C "$FLASH_ROOT" rev-parse HEAD)
if [ "$ACTUAL_FLASH_URL" != "$EXPECTED_FLASH_URL" ]; then
  echo "[hw_slicer] Flash URL mismatch: expected $EXPECTED_FLASH_URL, got $ACTUAL_FLASH_URL" >&2
  exit 1
fi
if [ "$ACTUAL_FLASH_COMMIT" != "$EXPECTED_FLASH_COMMIT" ]; then
  echo "[hw_slicer] Flash commit mismatch: expected $EXPECTED_FLASH_COMMIT, got $ACTUAL_FLASH_COMMIT" >&2
  exit 1
fi

(
  cd "$ROOT"
  shasum -a 256 -c resources/SHA256SUMS >/dev/null
)

echo "[hw_slicer] dependencies match dependencies.lock"
