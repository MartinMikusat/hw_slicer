#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_DIR="$ROOT/build/strict-feature-probe"
BINARY="$OUTPUT_DIR/hw-slicer-strict-feature-probe"
ACTUAL="$OUTPUT_DIR/stanford-bunny-v1.actual.json"
EXPECTED="$ROOT/testdata/feature-probes/stanford-bunny-v1.json"
ARTIFACT="$OUTPUT_DIR/path-plan.bin"
MANIFEST_ACTUAL="$ARTIFACT.manifest.json"
MANIFEST_EXPECTED="$ROOT/testdata/evidence/stanford-bunny-path-plan-manifest-v1.json"
REPLAY_ACTUAL="$OUTPUT_DIR/stanford-bunny-path-plan-replay-v1.actual.json"
REPLAY_EXPECTED="$ROOT/testdata/evidence/stanford-bunny-path-plan-replay-v1.json"
REPLAY_BINARY="$ROOT/build/path-plan-replay/hw-slicer-path-plan-replay"
RENDER_ACTUAL="$OUTPUT_DIR/stanford-bunny-path-plan-layer-000538-v1.actual.svg"
RENDER_EXPECTED="$ROOT/testdata/evidence/stanford-bunny-path-plan-layer-000538-v1.svg"
BUNDLE_ACTUAL="$OUTPUT_DIR/stanford-bunny-path-plan-v1.hwsdebug"
BUNDLE_EXPECTED_BYTES=47928741
BUNDLE_EXPECTED_SHA256=1fab0f11792b7bdf3b01533992475cde4e3faa4f7318ed87cbb572a8f2dad31e
BUNDLE_VALIDATE_BINARY="$ROOT/build/evidence-bundle-validate/hw-slicer-evidence-bundle-validate"
BUNDLE_VALIDATE_ACTUAL="$OUTPUT_DIR/stanford-bunny-path-plan-bundle-validation-v1.actual.json"
BUNDLE_VALIDATE_EXPECTED="$ROOT/testdata/evidence/stanford-bunny-path-plan-bundle-validation-v1.json"
BUNDLE_INSPECT_ACTUAL="$OUTPUT_DIR/stanford-bunny-bundle-inspection-v1.actual.json"
BUNDLE_INSPECT_EXPECTED="$ROOT/testdata/evidence/stanford-bunny-bundle-inspection-v1.json"
EVIDENCE_INSPECT_BINARY="$ROOT/build/evidence-inspect/hw-slicer-evidence-inspect"
DIRECTORY_ACTUAL="$OUTPUT_DIR/stanford-bunny-path-plan-v1.hwsdebug-dir"
DIRECTORY_VALIDATE_BINARY="$ROOT/build/evidence-directory-validate/hw-slicer-evidence-directory-validate"
DIRECTORY_VALIDATE_ACTUAL="$OUTPUT_DIR/stanford-bunny-path-plan-directory-validation-v1.actual.json"
DIRECTORY_VALIDATE_EXPECTED="$ROOT/testdata/evidence/stanford-bunny-path-plan-directory-validation-v1.json"
DIRECTORY_INSPECT_ACTUAL="$OUTPUT_DIR/stanford-bunny-directory-inspection-v1.actual.json"
DIRECTORY_INSPECT_EXPECTED="$ROOT/testdata/evidence/stanford-bunny-directory-inspection-v1.json"
TOPOLOGY_ARTIFACT="$DIRECTORY_ACTUAL/stages/07-reconstruct-topology/primitives/topology.bin"
TOPOLOGY_EXPECTED_BYTES=12299784
TOPOLOGY_EXPECTED_SHA256=d6eb53fd2b3e2086c0b90ce27892d67cf7230310d509d27653fec0d6579a252a
TOPOLOGY_MANIFEST_ACTUAL="$DIRECTORY_ACTUAL/stages/07-reconstruct-topology/manifest.json"
TOPOLOGY_MANIFEST_EXPECTED="$ROOT/testdata/evidence/stanford-bunny-topology-manifest-v1.json"
TOPOLOGY_REPLAY_BINARY="$ROOT/build/topology-replay/hw-slicer-topology-replay"
TOPOLOGY_REPLAY_ACTUAL="$OUTPUT_DIR/stanford-bunny-topology-replay-v1.actual.json"
TOPOLOGY_REPLAY_EXPECTED="$ROOT/testdata/evidence/stanford-bunny-topology-replay-v1.json"
REGION_ARTIFACT="$DIRECTORY_ACTUAL/stages/08-calculate-regions/primitives/regions.bin"
REGION_EXPECTED_BYTES=114180
REGION_EXPECTED_SHA256=ffae9c9887d2c70ae1b22bb53a4c2b651f3d9ac4dc8f3b4bfb3e75b4e7b18cea
REGION_MANIFEST_ACTUAL="$DIRECTORY_ACTUAL/stages/08-calculate-regions/manifest.json"
REGION_MANIFEST_EXPECTED="$ROOT/testdata/evidence/stanford-bunny-region-manifest-v1.json"
CORRUPT_DIR="$OUTPUT_DIR/corrupt"
CORRUPT_ARTIFACT="$CORRUPT_DIR/path-plan.bin"
CORRUPT_TOPOLOGY="$CORRUPT_DIR/topology.bin"
CORRUPT_BUNDLE="$CORRUPT_DIR/path-plan.hwsdebug"

mkdir -p "$OUTPUT_DIR"
rm -rf "$DIRECTORY_ACTUAL"
"$ROOT/strict-feature-probe.sh" \
  "$ROOT/resources/models/stanford-bunny.stl" \
  "$ARTIFACT" \
  "$BUNDLE_ACTUAL" \
  "$DIRECTORY_ACTUAL" > "$ACTUAL"
if ! cmp -s "$EXPECTED" "$ACTUAL"; then
  printf '[hw_slicer] Stanford Bunny strict feature fixture changed\n' >&2
  diff -u "$EXPECTED" "$ACTUAL" >&2 || true
  exit 1
fi
if ! cmp -s "$MANIFEST_EXPECTED" "$MANIFEST_ACTUAL"; then
  printf '[hw_slicer] Stanford Bunny path-plan manifest changed\n' >&2
  diff -u "$MANIFEST_EXPECTED" "$MANIFEST_ACTUAL" >&2 || true
  exit 1
fi
bundle_bytes=$(wc -c < "$BUNDLE_ACTUAL" | tr -d ' ')
bundle_sha256=$(shasum -a 256 "$BUNDLE_ACTUAL" | awk '{print $1}')
if [ "$bundle_bytes" != "$BUNDLE_EXPECTED_BYTES" ] ||
   [ "$bundle_sha256" != "$BUNDLE_EXPECTED_SHA256" ]; then
  printf \
    '[hw_slicer] Stanford Bunny evidence bundle changed: bytes=%s sha256=%s\n' \
    "$bundle_bytes" \
    "$bundle_sha256" >&2
  exit 1
fi
"$ROOT/evidence-bundle-validate.sh" \
  "$BUNDLE_ACTUAL" > "$BUNDLE_VALIDATE_ACTUAL"
if ! cmp -s "$BUNDLE_VALIDATE_EXPECTED" "$BUNDLE_VALIDATE_ACTUAL"; then
  printf '[hw_slicer] Stanford Bunny evidence bundle validation changed\n' >&2
  diff -u "$BUNDLE_VALIDATE_EXPECTED" "$BUNDLE_VALIDATE_ACTUAL" >&2 || true
  exit 1
fi
"$ROOT/evidence-directory-validate.sh" \
  "$DIRECTORY_ACTUAL" > "$DIRECTORY_VALIDATE_ACTUAL"
if ! cmp -s "$DIRECTORY_VALIDATE_EXPECTED" "$DIRECTORY_VALIDATE_ACTUAL"; then
  printf '[hw_slicer] Stanford Bunny evidence directory validation changed\n' >&2
  diff -u "$DIRECTORY_VALIDATE_EXPECTED" "$DIRECTORY_VALIDATE_ACTUAL" >&2 || true
  exit 1
fi
"$ROOT/evidence-inspect.sh" "$BUNDLE_ACTUAL" > "$BUNDLE_INSPECT_ACTUAL"
if ! cmp -s "$BUNDLE_INSPECT_EXPECTED" "$BUNDLE_INSPECT_ACTUAL"; then
  printf '[hw_slicer] Stanford Bunny bundle inspection changed\n' >&2
  diff -u "$BUNDLE_INSPECT_EXPECTED" "$BUNDLE_INSPECT_ACTUAL" >&2 || true
  exit 1
fi
"$EVIDENCE_INSPECT_BINARY" \
  "$DIRECTORY_ACTUAL" > "$DIRECTORY_INSPECT_ACTUAL"
if ! cmp -s "$DIRECTORY_INSPECT_EXPECTED" "$DIRECTORY_INSPECT_ACTUAL"; then
  printf '[hw_slicer] Stanford Bunny directory inspection changed\n' >&2
  diff -u "$DIRECTORY_INSPECT_EXPECTED" "$DIRECTORY_INSPECT_ACTUAL" >&2 || true
  exit 1
fi
if ! cmp -s \
  "$ARTIFACT" \
  "$DIRECTORY_ACTUAL/stages/10-plan-paths/primitives/path-plan.bin"; then
  printf '[hw_slicer] Stanford Bunny directory artifact changed\n' >&2
  exit 1
fi
topology_bytes=$(wc -c < "$TOPOLOGY_ARTIFACT" | tr -d ' ')
topology_sha256=$(shasum -a 256 "$TOPOLOGY_ARTIFACT" | awk '{print $1}')
if [ "$topology_bytes" != "$TOPOLOGY_EXPECTED_BYTES" ] ||
   [ "$topology_sha256" != "$TOPOLOGY_EXPECTED_SHA256" ]; then
  printf \
    '[hw_slicer] Stanford Bunny topology artifact changed: bytes=%s sha256=%s\n' \
    "$topology_bytes" \
    "$topology_sha256" >&2
  exit 1
fi
if ! cmp -s "$TOPOLOGY_MANIFEST_EXPECTED" "$TOPOLOGY_MANIFEST_ACTUAL"; then
  printf '[hw_slicer] Stanford Bunny topology manifest changed\n' >&2
  diff -u "$TOPOLOGY_MANIFEST_EXPECTED" "$TOPOLOGY_MANIFEST_ACTUAL" >&2 || true
  exit 1
fi
"$ROOT/topology-replay.sh" \
  --manifest "$TOPOLOGY_MANIFEST_ACTUAL" \
  "$TOPOLOGY_ARTIFACT" > "$TOPOLOGY_REPLAY_ACTUAL"
if ! cmp -s "$TOPOLOGY_REPLAY_EXPECTED" "$TOPOLOGY_REPLAY_ACTUAL"; then
  printf '[hw_slicer] Stanford Bunny topology replay changed\n' >&2
  diff -u "$TOPOLOGY_REPLAY_EXPECTED" "$TOPOLOGY_REPLAY_ACTUAL" >&2 || true
  exit 1
fi
region_bytes=$(wc -c < "$REGION_ARTIFACT" | tr -d ' ')
region_sha256=$(shasum -a 256 "$REGION_ARTIFACT" | awk '{print $1}')
if [ "$region_bytes" != "$REGION_EXPECTED_BYTES" ] ||
   [ "$region_sha256" != "$REGION_EXPECTED_SHA256" ]; then
  printf \
    '[hw_slicer] Stanford Bunny region artifact changed: bytes=%s sha256=%s\n' \
    "$region_bytes" \
    "$region_sha256" >&2
  exit 1
fi
if ! cmp -s "$REGION_MANIFEST_EXPECTED" "$REGION_MANIFEST_ACTUAL"; then
  printf '[hw_slicer] Stanford Bunny region manifest changed\n' >&2
  diff -u "$REGION_MANIFEST_EXPECTED" "$REGION_MANIFEST_ACTUAL" >&2 || true
  exit 1
fi
directory_file_count=$(find "$DIRECTORY_ACTUAL" -type f | wc -l | tr -d ' ')
if [ "$directory_file_count" != 8 ]; then
  printf \
    '[hw_slicer] Stanford Bunny evidence directory file count changed: %s\n' \
    "$directory_file_count" >&2
  exit 1
fi
"$ROOT/path-plan-replay.sh" \
  --manifest "$MANIFEST_ACTUAL" "$ARTIFACT" > "$REPLAY_ACTUAL"
if ! cmp -s "$REPLAY_EXPECTED" "$REPLAY_ACTUAL"; then
  printf '[hw_slicer] Stanford Bunny path-plan replay changed\n' >&2
  diff -u "$REPLAY_EXPECTED" "$REPLAY_ACTUAL" >&2 || true
  exit 1
fi

"$REPLAY_BINARY" \
  --manifest "$MANIFEST_ACTUAL" \
  --render-layer 538 \
  "$ARTIFACT" > "$RENDER_ACTUAL"
if ! cmp -s "$RENDER_EXPECTED" "$RENDER_ACTUAL"; then
  printf '[hw_slicer] Stanford Bunny path-plan layer render changed\n' >&2
  diff -u "$RENDER_EXPECTED" "$RENDER_ACTUAL" >&2 || true
  exit 1
fi

mkdir -p "$CORRUPT_DIR"
cp "$ARTIFACT" "$CORRUPT_ARTIFACT"
printf '\001' |
  dd of="$CORRUPT_ARTIFACT" bs=1 seek=200 conv=notrunc status=none
set +e
corrupt_output=$(
  "$REPLAY_BINARY" \
    --manifest "$MANIFEST_ACTUAL" "$CORRUPT_ARTIFACT" 2>&1
)
corrupt_status=$?
set -e
if [ "$corrupt_status" -ne 1 ] ||
   [ "$corrupt_output" != \
     "[hw_slicer] path-plan manifest verification failed: Artifact_Hash_Mismatch" ]; then
  printf '%s\n' "$corrupt_output" >&2
  printf '[hw_slicer] corrupt path-plan manifest rejection changed\n' >&2
  exit 1
fi

cp "$TOPOLOGY_ARTIFACT" "$CORRUPT_TOPOLOGY"
printf '\001' |
  dd of="$CORRUPT_TOPOLOGY" bs=1 seek=200 conv=notrunc status=none
set +e
corrupt_topology_output=$(
  "$TOPOLOGY_REPLAY_BINARY" \
    --manifest "$TOPOLOGY_MANIFEST_ACTUAL" "$CORRUPT_TOPOLOGY" 2>&1
)
corrupt_topology_status=$?
set -e
if [ "$corrupt_topology_status" -ne 1 ] ||
   [ "$corrupt_topology_output" != \
     "[hw_slicer] topology manifest verification failed: Artifact_Hash_Mismatch" ]; then
  printf '%s\n' "$corrupt_topology_output" >&2
  printf '[hw_slicer] corrupt topology manifest rejection changed\n' >&2
  exit 1
fi

cp "$BUNDLE_ACTUAL" "$CORRUPT_BUNDLE"
printf '\001' |
  dd of="$CORRUPT_BUNDLE" bs=1 seek=200 conv=notrunc status=none
set +e
corrupt_bundle_output=$("$BUNDLE_VALIDATE_BINARY" "$CORRUPT_BUNDLE" 2>&1)
corrupt_bundle_status=$?
set -e
if [ "$corrupt_bundle_status" -ne 1 ] ||
   [ "$corrupt_bundle_output" != \
     "[hw_slicer] evidence bundle validation failed: Zip_Read_Failed" ]; then
  printf '%s\n' "$corrupt_bundle_output" >&2
  printf '[hw_slicer] corrupt evidence bundle rejection changed\n' >&2
  exit 1
fi

set +e
short_output=$(
  "$REPLAY_BINARY" \
    "$ROOT/testdata/evidence/invalid-short-path-plan.bin" 2>&1
)
short_status=$?
set -e
if [ "$short_status" -ne 1 ] ||
   [ "$short_output" != \
     "[hw_slicer] path-plan artifact size is outside the limit" ]; then
  printf '%s\n' "$short_output" >&2
  printf '[hw_slicer] short path-plan rejection changed\n' >&2
  exit 1
fi

set +e
benchy_output=$(
  "$BINARY" "$ROOT/resources/models/benchy.stl" 2>&1
)
benchy_status=$?
set -e
if [ "$benchy_status" -ne 1 ] ||
   [ "$benchy_output" != \
     "[hw_slicer] strict topology rejected: open=0 degenerate=1 non_manifold=3" ]; then
  printf '%s\n' "$benchy_output" >&2
  printf '[hw_slicer] 3DBenchy strict rejection changed\n' >&2
  exit 1
fi

printf '[hw_slicer] strict feature fixtures passed\n'
