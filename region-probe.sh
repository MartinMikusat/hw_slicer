#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$ROOT/scripts/dependencies.sh" check >&2
"$ROOT/scripts/clipper2-build.sh" release >&2
ODIN="$ROOT/scripts/odin.sh"
OUTPUT_DIR="$ROOT/build/region-probe"
BINARY="$OUTPUT_DIR/hw-slicer-region-probe"
TOPOLOGY_ARTIFACT="$OUTPUT_DIR/all-in-one-topology.bin"
TOPOLOGY_REPLAY_ACTUAL="$OUTPUT_DIR/all-in-one-topology-replay-v1.actual.json"
TOPOLOGY_REPLAY_EXPECTED="$ROOT/testdata/evidence/all-in-one-topology-replay-v1.json"
LIBRARY="../../build/clipper2/release/libhw_clipper2.a"

mkdir -p "$OUTPUT_DIR"
rm -f "$TOPOLOGY_ARTIFACT"
"$ODIN" build "$ROOT/cmd/hw-slicer-region-probe" \
  -out:"$BINARY" \
  -o:speed \
  -define:HW_CLIPPER2_LIBRARY="$LIBRARY" \
  -extra-linker-flags:"-lc++"
"$BINARY" \
  "$ROOT/resources/models/all-in-one-test.stl" \
  "$TOPOLOGY_ARTIFACT"
"$ROOT/topology-replay.sh" \
  --topology-only "$TOPOLOGY_ARTIFACT" > "$TOPOLOGY_REPLAY_ACTUAL"
if ! cmp -s "$TOPOLOGY_REPLAY_EXPECTED" "$TOPOLOGY_REPLAY_ACTUAL"; then
  printf '[hw_slicer] all-in-one topology replay changed\n' >&2
  diff -u "$TOPOLOGY_REPLAY_EXPECTED" "$TOPOLOGY_REPLAY_ACTUAL" >&2 || true
  exit 1
fi
