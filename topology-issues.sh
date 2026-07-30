#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$ROOT/scripts/dependencies.sh" check >&2
ODIN="$ROOT/scripts/odin.sh"
OUTPUT_DIR="$ROOT/build/topology-issues"
BINARY="$OUTPUT_DIR/hw-slicer-topology-issues"

mkdir -p "$OUTPUT_DIR"
"$ODIN" build "$ROOT/cmd/hw-slicer-topology-issues" \
  -out:"$BINARY" \
  -o:speed
"$BINARY" "$ROOT/resources/models/all-in-one-test.stl"
