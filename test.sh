#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
"$ROOT/scripts/dependencies.sh" check
ODIN="$ROOT/scripts/odin.sh"
"$ODIN" test "$ROOT/src" \
  -debug \
  -o:none \
  -collection:flash="$FLASH_ROOT" \
  -extra-linker-flags:"-framework Foundation -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics"
"$ODIN" test "$ROOT/src/contracts" -debug -o:none
"$ODIN" test "$ROOT/src/formats" -debug -o:none
"$ODIN" test "$ROOT/src/geometry" -debug -o:none
"$ROOT/scripts/clipper2-test.sh" debug
"$ROOT/scripts/repair-test.sh" debug
"$ROOT/scripts/features-test.sh" debug
"$ODIN" test "$ROOT/src/slicing" -debug -o:none
"$ODIN" test "$ROOT/src/pipeline" -debug -o:none
"$ROOT/scripts/evidence-test.sh" debug
"$ODIN" test "$ROOT/src/benchmark" -debug -o:none
"$ODIN" test "$ROOT/tests/compiler-smoke" -debug -o:none
mkdir -p "$ROOT/build/test"
"$ODIN" build "$ROOT/cmd/hw-slicer-spine" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-spine"
"$ODIN" build "$ROOT/cmd/hw-slicer-spine-benchmark" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-spine-benchmark"
"$ODIN" build "$ROOT/cmd/hw-slicer-region-probe" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-region-probe" \
  -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/debug/libhw_clipper2.a" \
  -extra-linker-flags:"-lc++"
"$ODIN" build "$ROOT/cmd/hw-slicer-topology-issues" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-topology-issues"
"$ODIN" build "$ROOT/cmd/hw-slicer-feature-benchmark" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-feature-benchmark" \
  -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/debug/libhw_clipper2.a" \
  -extra-linker-flags:"-lc++"
"$ODIN" build "$ROOT/cmd/hw-slicer-strict-feature-probe" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-strict-feature-probe" \
  -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/debug/libhw_clipper2.a" \
  -extra-linker-flags:"-lc++"
"$ODIN" build "$ROOT/cmd/hw-slicer-path-plan-replay" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-path-plan-replay" \
  -define:HW_CLIPPER2_LIBRARY="../../build/clipper2/debug/libhw_clipper2.a" \
  -extra-linker-flags:"-lc++"
"$ODIN" build "$ROOT/cmd/hw-slicer-topology-replay" \
  -debug \
  -o:none \
  -out:"$ROOT/build/test/hw-slicer-topology-replay" \
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
source_limit_output=$(
  "$ROOT/build/test/hw-slicer-strict-feature-probe" \
    "$ROOT/testdata/evidence/invalid-short-path-plan.bin" 2>&1
)
source_limit_status=$?
set -e
if [ "$source_limit_status" -ne 1 ] ||
   [ "$source_limit_output" != \
     "[hw_slicer] strict feature probe fixture read failed: Size_Limit" ]; then
  printf '%s\n' "$source_limit_output" >&2
  printf '[hw_slicer] source-file preflight rejection changed\n' >&2
  exit 1
fi

set +e
collision_output=$(
  "$ROOT/build/test/hw-slicer-strict-feature-probe" \
    "$ROOT/testdata/evidence/invalid-short-path-plan.bin" \
    "$ROOT/testdata/evidence/invalid-short-path-plan.bin" 2>&1
)
collision_status=$?
set -e
if [ "$collision_status" -ne 2 ] ||
   [ "$collision_output" != \
     "[hw_slicer] source and output paths must be non-empty, distinct, and valid for their output types" ]; then
  printf '%s\n' "$collision_output" >&2
  printf '[hw_slicer] capture path collision rejection changed\n' >&2
  exit 1
fi

collision_alias="$ROOT/build/test/source-alias.stl"
rm -f "$collision_alias"
ln -s "$ROOT/testdata/evidence/invalid-short-path-plan.bin" "$collision_alias"
set +e
alias_collision_output=$(
  "$ROOT/build/test/hw-slicer-strict-feature-probe" \
    "$ROOT/testdata/evidence/invalid-short-path-plan.bin" \
    "$collision_alias" 2>&1
)
alias_collision_status=$?
set -e
if [ "$alias_collision_status" -ne 2 ] ||
   [ "$alias_collision_output" != \
     "[hw_slicer] source and output paths must be non-empty, distinct, and valid for their output types" ]; then
  printf '%s\n' "$alias_collision_output" >&2
  printf '[hw_slicer] capture path alias rejection changed\n' >&2
  exit 1
fi

existing_directory="$ROOT/build/test/existing-evidence-directory"
mkdir -p "$existing_directory"
set +e
directory_collision_output=$(
  "$ROOT/build/test/hw-slicer-strict-feature-probe" \
    "$ROOT/testdata/evidence/invalid-short-path-plan.bin" \
    "$ROOT/build/test/path-plan.bin" \
    "$ROOT/build/test/path-plan.hwsdebug" \
    "$existing_directory" 2>&1
)
directory_collision_status=$?
set -e
if [ "$directory_collision_status" -ne 2 ] ||
   [ "$directory_collision_output" != \
     "[hw_slicer] source and output paths must be non-empty, distinct, and valid for their output types" ]; then
  printf '%s\n' "$directory_collision_output" >&2
  printf '[hw_slicer] existing evidence directory rejection changed\n' >&2
  exit 1
fi

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
