#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ODIN="$ROOT/scripts/odin.sh"

for script in "$ROOT"/*.sh "$ROOT"/scripts/*.sh; do
  sh -n "$script"
done

"$ROOT/test.sh"
"$ODIN" test "$ROOT/src/contracts" -o:speed
"$ODIN" test "$ROOT/src/profiles" -o:speed
"$ODIN" test "$ROOT/src/formats" -o:speed
"$ODIN" test "$ROOT/src/geometry" -o:speed
"$ODIN" test "$ROOT/src/slicing" -o:speed
"$ODIN" test "$ROOT/src/pipeline" -o:speed
"$ROOT/scripts/evidence-test.sh" release
"$ODIN" test "$ROOT/src/benchmark" -o:speed
"$ROOT/scripts/asan-smoke-test.sh"
"$ROOT/scripts/mixed-asan-test.sh" formats
"$ROOT/scripts/clipper2-test.sh" release
"$ROOT/scripts/clipper2-test.sh" asan
"$ROOT/scripts/repair-test.sh" release
"$ROOT/scripts/repair-test.sh" asan
"$ROOT/scripts/features-test.sh" release
"$ROOT/scripts/features-test.sh" asan
"$ROOT/scripts/evidence-test.sh" asan
"$ROOT/scripts/strict-feature-asan-test.sh"
"$ROOT/benchmark.sh" >/dev/null
"$ROOT/polygon-benchmark.sh" >/dev/null
"$ROOT/feature-benchmark.sh" >/dev/null
"$ROOT/region-probe.sh" >/dev/null
"$ROOT/scripts/strict-feature-fixture-test.sh"
"$ROOT/path-plan-replay.sh" --benchmark \
  "$ROOT/build/strict-feature-probe/path-plan.bin" >/dev/null
"$ROOT/topology-replay.sh" --benchmark \
  "$ROOT/build/strict-feature-probe/stanford-bunny-path-plan-v1.hwsdebug-dir/stages/07-reconstruct-topology/primitives/topology.bin" \
  >/dev/null
"$ROOT/topology-replay.sh" --benchmark-regions \
  "$ROOT/build/strict-feature-probe/stanford-bunny-path-plan-v1.hwsdebug-dir/stages/07-reconstruct-topology/primitives/topology.bin" \
  >/dev/null
"$ROOT/topology-issues.sh" >/dev/null
"$ROOT/build.sh" debug
"$ROOT/build.sh" asan
"$ROOT/build.sh" release

test -d "$ROOT/build/hw_slicer.app.dSYM"
test -d "$ROOT/build/asan/hw_slicer.app.dSYM"
file "$ROOT/build/hw_slicer.app/Contents/MacOS/hw_slicer" | grep -q 'arm64'
codesign --verify --deep --strict "$ROOT/build/hw_slicer.app"
codesign --verify --deep --strict "$ROOT/build/asan/hw_slicer.app"
codesign --verify --deep --strict "$ROOT/build/release/hw_slicer.app"

printf '[hw_slicer] foundation check passed\n'
