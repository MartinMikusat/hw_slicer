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
RUNE_ROOT="$ROOT/../hw_odin_rune"
"$ROOT/scripts/dependencies.sh" check
bash "$RUNE_ROOT/scripts/build-metallib.sh"
python3 "$DEVLOG_ROOT/scripts/lint_devlog.py" "$ROOT"
ODIN="$ROOT/scripts/odin.sh"
"$ROOT/scripts/clipper2-build.sh" debug >/dev/null
"$ODIN" test "$ROOT/src" \
  -debug \
  -o:none \
  -collection:flash="$FLASH_ROOT" \
  -collection:devlog="$DEVLOG_ROOT" \
  -collection:rune="$RUNE_ROOT" \
  -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/debug/libhw_clipper2.a" \
  -extra-linker-flags:"-lc++ -framework Foundation -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics"
"$ODIN" test "$ROOT/src/contracts" -debug -o:none
"$ODIN" test "$ROOT/src/profiles" -debug -o:none
"$ODIN" test "$ROOT/src/formats" -debug -o:none
"$ODIN" test "$ROOT/src/geometry" -debug -o:none
"$ROOT/scripts/clipper2-test.sh" debug
"$ROOT/scripts/repair-test.sh" debug
"$ROOT/scripts/features-test.sh" debug
"$ROOT/scripts/gcode-test.sh" debug
"$ODIN" test "$ROOT/src/slicing" -debug -o:none
"$ODIN" test "$ROOT/src/pipeline" -debug -o:none
"$ROOT/scripts/evidence-test.sh" debug
"$ODIN" test "$ROOT/src/benchmark" -debug -o:none
"$ODIN" test "$ROOT/tests/compiler-smoke" -debug -o:none
mkdir -p "$ROOT/build/test"
"$ODIN" build "$ROOT/cmd/hw-slicer-spine-benchmark" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-spine-benchmark"
"$ODIN" build "$ROOT/cmd/hw-slicer-feature-benchmark" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-feature-benchmark" \
  -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/debug/libhw_clipper2.a" \
  -extra-linker-flags:"-lc++"
"$ODIN" build "$ROOT/cmd/hw-slicer-evidence-bundle-validate" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-evidence-bundle-validate" \
  -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/debug/libhw_clipper2.a" \
  -extra-linker-flags:"-lc++"
"$ODIN" build "$ROOT/cmd/hw-slicer-evidence-directory-validate" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-evidence-directory-validate" \
  -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/debug/libhw_clipper2.a" \
  -extra-linker-flags:"-lc++"
"$ODIN" build "$ROOT/cmd/hw-slicer-evidence-inspect" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-evidence-inspect" \
  -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/debug/libhw_clipper2.a" \
  -extra-linker-flags:"-lc++"

set +e
bundle_limit_output=$(
  "$ROOT/build/test/hw-slicer-evidence-bundle-validate" \
    "$ROOT/testdata/evidence/invalid-short-path-plan.bin" 2>&1
)
bundle_limit_status=$?
set -e
if [ "$bundle_limit_status" -ne 1 ] ||
   [ "$bundle_limit_output" != \
     "[hw_slicer] evidence bundle read failed: Size_Limit" ]; then
  printf '%s\n' "$bundle_limit_output" >&2
  printf '[hw_slicer] evidence bundle source limit rejection changed\n' >&2
  exit 1
fi

set +e
directory_limit_output=$(
  "$ROOT/build/test/hw-slicer-evidence-directory-validate" \
    "$ROOT/testdata/evidence/invalid-short-path-plan.bin" 2>&1
)
directory_limit_status=$?
set -e
if [ "$directory_limit_status" -ne 1 ] ||
   [ "$directory_limit_output" != \
     "[hw_slicer] evidence directory validation failed: Invalid_Destination" ]; then
  printf '%s\n' "$directory_limit_output" >&2
  printf '[hw_slicer] evidence directory source rejection changed\n' >&2
  exit 1
fi
