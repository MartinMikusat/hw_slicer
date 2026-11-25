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
EXPECTED_FLASH_URL="https://github.com/MartinMikusat/hw_odin_ui_flash.git"
EXPECTED_FLASH_COMMIT="f4744a6e76c04e99e54fa8e4205de416b612f1db"
EXPECTED_DEVLOG_URL="https://github.com/MartinMikusat/hw_odin_devlog.git"
EXPECTED_DEVLOG_COMMIT="98569a7b37883fc09c7a6fa4804cdc3e7811d40f"
EXPECTED_RUNE_URL="https://github.com/MartinMikusat/hw_odin_rune.git"
EXPECTED_RUNE_COMMIT="38993e4c6f1b01f1f6565c5642b46943a0def675"
EXPECTED_COMPONENTS_URL="https://github.com/MartinMikusat/hw_odin_ui_components.git"
EXPECTED_COMPONENTS_COMMIT="7500d9602e8001259c57585dc2acdcc824788aa2"

if [ "${1:-}" != "check" ]; then
  echo "usage: scripts/dependencies.sh check" >&2
  exit 2
fi

hw-odin toolchain doctor >/dev/null || {
  echo "[hw_slicer] global Odin toolchain is unavailable" >&2
  exit 1
}

check_pin() {
  name=$1
  root=$2
  expected_url=$3
  expected_commit=$4
  if [ ! -d "$root/.git" ]; then
    echo "[hw_slicer] missing sibling dependency: $root" >&2
    exit 1
  fi
  actual_url=$(git -C "$root" remote get-url origin)
  actual_commit=$(git -C "$root" rev-parse HEAD)
  if [ "$actual_url" != "$expected_url" ]; then
    echo "[hw_slicer] $name URL mismatch: expected $expected_url, got $actual_url" >&2
    exit 1
  fi
  if [ "$actual_commit" != "$expected_commit" ]; then
    echo "[hw_slicer] $name commit mismatch: expected $expected_commit, got $actual_commit" >&2
    exit 1
  fi
}

check_pin "Flash" "$FLASH_ROOT" "$EXPECTED_FLASH_URL" "$EXPECTED_FLASH_COMMIT"
check_pin "devlog" "$DEVLOG_ROOT" "$EXPECTED_DEVLOG_URL" "$EXPECTED_DEVLOG_COMMIT"
check_pin "rune" "$RUNE_ROOT" "$EXPECTED_RUNE_URL" "$EXPECTED_RUNE_COMMIT"
check_pin "components" "$COMPONENTS_ROOT" "$EXPECTED_COMPONENTS_URL" "$EXPECTED_COMPONENTS_COMMIT"

(
  cd "$ROOT"
  shasum -a 256 -c resources/SHA256SUMS >/dev/null
)

echo "[hw_slicer] dependencies match dependencies.lock"
