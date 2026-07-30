#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ODIN="$ROOT/scripts/odin.sh"
CLANG=$(xcrun --find clang)
SDK_ROOT=$(xcrun --sdk macosx --show-sdk-path)
ARTIFACT="$ROOT/build/asan-probe"
PROBE="$ARTIFACT/HWSlicerASanProbe"
REPORT="$ARTIFACT/asan-report.txt"
MANIFEST="$ARTIFACT/manifest.txt"
COMPAT_OBJECT="$ARTIFACT/asan_compat.o"
ASAN_RUNTIME="$("$CLANG" --print-resource-dir)/lib/darwin/libclang_rt.asan_osx_dynamic.dylib"

mkdir -p "$ARTIFACT"
"$CLANG" -Wall -Wextra -Werror -O0 -g -isysroot "$SDK_ROOT" -c \
  "$ROOT/host/asan_compat.c" \
  -o "$COMPAT_OBJECT"
(
  cd "$ARTIFACT"
  "$ODIN" build "$ROOT/tests/asan-probe" \
    -out:"$PROBE" \
    -debug \
    -sanitize:address \
    -keep-temp-files \
    -extra-linker-flags:"$COMPAT_OBJECT -Wl,-undefined,dynamic_lookup -Wl,-headerpad_max_install_names"
)
odin_asan_runtime=$(otool -L "$PROBE" |
  awk '/libclang_rt\.asan_osx_dynamic\.dylib/ {print $1; exit}')
if [ -z "$odin_asan_runtime" ]; then
  echo "[hw_slicer] the ASan probe did not link its runtime" >&2
  exit 1
fi
LLVM_ROOT=$(CDPATH= cd -- "$(dirname -- "$odin_asan_runtime")/../../../../.." && pwd)
SYMBOLIZER="$LLVM_ROOT/bin/llvm-symbolizer"
if [ ! -x "$SYMBOLIZER" ]; then
  echo "[hw_slicer] could not resolve llvm-symbolizer" >&2
  exit 1
fi
if [ "$odin_asan_runtime" != "$ASAN_RUNTIME" ]; then
  install_name_tool \
    -change "$odin_asan_runtime" "$ASAN_RUNTIME" \
    "$PROBE"
fi
if [ -d "$PROBE.dSYM" ]; then
  rm -r "$PROBE.dSYM"
fi
xcrun dsymutil "$PROBE" -o "$PROBE.dSYM"

set +e
output=$(env \
  DYLD_INSERT_LIBRARIES="$ASAN_RUNTIME" \
  ASAN_SYMBOLIZER_PATH="$SYMBOLIZER" \
  ASAN_OPTIONS=detect_leaks=0 \
  "$PROBE" 2>&1)
status=$?
set -e
printf '%s\n' "$output" > "$REPORT"

if [ "$status" -eq 0 ]; then
  echo "[hw_slicer] ASan probe did not reject the invalid write" >&2
  exit 1
fi
case "$output" in
  *"heap-use-after-free"*) ;;
  *)
    printf '%s\n' "$output" >&2
    echo "[hw_slicer] ASan probe returned an unexpected diagnostic" >&2
    exit 1
    ;;
esac

{
  printf 'schema_version=1\n'
  printf 'fixture=heap-use-after-free\n'
  printf 'binary_sha256='
  shasum -a 256 "$PROBE" | awk '{print $1}'
  printf 'git_revision='
  git -C "$ROOT" rev-parse HEAD
  printf 'git_dirty='
  if [ -n "$(git -C "$ROOT" status --short)" ]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
  printf 'odin_version='
  "$ODIN" version | awk '{print $NF}'
  xcrun dwarfdump --uuid "$PROBE"
} > "$MANIFEST"

printf '[hw_slicer] ASan smoke test passed: %s\n' "${REPORT#"$ROOT/"}"
