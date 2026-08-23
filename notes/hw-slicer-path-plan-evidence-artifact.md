# HW Slicer path-plan evidence artifact

This note records the implemented path-plan artifact in
[`hw_slicer`](../README.md). The artifact replays a completed planar
path plan without the source model.

## Implemented contract

The encoder writes an explicit little-endian byte stream. It does not copy Odin
struct memory or depend on host padding.

The stream contains:

- The two parent result hashes.
- The canonical path-plan result hash.
- The start point and path-order configuration.
- The topology policy.
- Layer spans.
- Planned path records.
- Travel and extrusion move records.

The implementation is in
[`path_plan_artifact.odin`](../src/evidence/path_plan_artifact.odin).
The current schema version is 1.

## Header layout

The header is 192 bytes.

| Offset | Size | Value |
| ---: | ---: | --- |
| 0 | 8 | Magic `HWSPLAN` followed by a newline |
| 8 | 4 | Artifact schema version |
| 12 | 4 | Header size |
| 16 | 4 | Layer record size |
| 20 | 4 | Path record size |
| 24 | 4 | Move record size |
| 28 | 4 | Reserved zero bytes |
| 32 | 32 | Perimeter result hash |
| 64 | 32 | Infill result hash |
| 96 | 32 | Path-plan result hash |
| 128 | 8 | Start X in micrometres |
| 136 | 8 | Start Y in micrometres |
| 144 | 4 | Topology policy |
| 148 | 4 | Configuration flags |
| 152 | 8 | Layer count |
| 160 | 8 | Path count |
| 168 | 8 | Move count |
| 176 | 8 | Travel move count |
| 184 | 8 | Extrusion move count |

Flag bit 0 stores `inner_perimeters_first`. All other flag bits must be zero.

## Record layout

Each layer record is 24 bytes. It stores path and move offsets followed by
their counts.

Each path record is 64 bytes. It stores stable IDs, source and region indexes,
layer ownership, start selection, direction, closure, and its move span.

Each move record is 56 bytes. It stores stable IDs, the move kind, the source
edge, and two micrometre endpoints.

Reserved record bytes must be zero. This rule prevents unversioned data from
entering unused padding.

## Decode sequence

The decoder executes these checks before it publishes a result:

1. Validate the byte limit, magic, schema, and fixed record sizes.
2. Validate reserved bytes and configuration flags.
3. Calculate the exact payload size with checked `u64` arithmetic.
4. Validate layer, path, and move limits before allocation.
5. Decode each field from little-endian bytes.
6. Validate the complete path-plan graph through `path_plan_result_hash`.
7. Recalculate the result hash from both parent hashes.
8. Compare the calculated hash with the stored result hash.

The decoder reports malformed framing separately from an invalid record or a
hash mismatch. It destroys all allocated result arrays after a failed decode.

The capture wrapper calculates the complete byte and record counts before it
allocates the payload. It then applies the request level and accumulated item
and byte budgets.

The codec default caps one artifact at 1 GiB. A capture request can apply a
smaller byte limit.

## Manifest-gated replay

The standalone replay accepts a stage manifest through `--manifest`. It applies
these checks in order:

1. Read no more than 1 MiB of manifest data.
2. Decode and validate the complete manifest.
3. Select the primitive whose path matches the artifact file name.
4. Match the primitive format and schema with the path-plan decoder.
5. Compare the bounded artifact byte count and SHA-256 with the primitive.
6. Extract the required summary counters and canonical result invariant.
7. Decode and validate the internal path-plan graph.
8. Compare all decoded counters and the result hash with the manifest.
9. Recalculate the planar bounds from the decoded moves.

The manifest hash check runs before the decoder allocates graph arrays. The
strict fixture changes one artifact byte and requires a manifest hash mismatch.
Manifest validation also parses the provider semantic version and derives its
stage-specific stable ID from the provider name, version, and stage.

## Canonical layer SVG

The replay command renders one decoded layer through `--render-layer`. The
renderer writes each move in serialized order with its stable move and path
IDs. It maps Y coordinates to SVG screen space and preserves the source
micrometre coordinate scale in the view box.

Travel moves use muted text color `#787D75`. Extrusion moves use Coffee
`#B27D57`. The background uses dark modal color `#0E0F0E`.

The renderer accepts no more than 250,000 moves or 64 MiB of output for one
layer. It validates the complete artifact result hash before it allocates the
SVG buffer.

The synthetic SVG is 752 bytes. Its SHA-256 is:

`22ce7a00e061fa94afb56c836ce732c549622a67504fdda1d70481e947abdd79`

Stanford Bunny layer 538 produces 1,338 bytes. Its SHA-256 is:

`fd7a02c7882d2d0fdc7a9db3cfb6da283e0b569b30348e00b288462bc514ff4a`

## Golden evidence

The synthetic one-path fixture produces 336 bytes. Its SHA-256 is:

`4f8619139f3ea9a6b38217aa3b86e4fbb0d6502d8dd33f8fb8ba432fbc036d92`

The Stanford Bunny fixture contains 633,143 records and produces 35,504,552
bytes. Its SHA-256 is:

`e0074543cb5db6a85e0e53a5588bf7ee37a21211d3b193d25895df2620625f5f`

The Bunny probe decodes the artifact and validates its result hash and array
counts. The same replay passes under AddressSanitizer.

The fixture gate writes the Bunny artifact to `build/`. It then invokes
`path-plan-replay.sh` with the stage manifest and without the STL. It compares
the JSON summary with a golden fixture.

The probe also writes a 1,854-byte stage manifest. The manifest pins the feature
request, CPU planner provider, bounds, counters, invariants, and artifact
descriptor.

The standalone manifest names `path-plan.bin`. The bundle variant uses the
root-relative primitive path and produces 1,886 bytes. Both descriptors bind
the same 35,504,552-byte payload and SHA-256.

The release benchmark uses two warmups and 20 alternating capture and replay
samples. An Apple M4 run measured these values:

- Capture: 361-millisecond p50, 486-millisecond p95, and 94 MiB/s.
- Replay: 204-millisecond p50, 276-millisecond p95, and 166 MiB/s.

These values are observations. Each lane has a three-second p95 regression
limit.

## Scope boundary

The artifact stores planar path ordering only. It does not store speed, flow,
retraction, seam, cooling, or machine state.

Those values require the unresolved process, material, printer, and dialect
profiles. The artifact schema does not select defaults for them.

## Manifest identity

`Feature_Pipeline_Request` hashes the supplied surface, perimeter, infill, and
path-order settings. It also hashes the spine request and polygon provider.

The implemented CPU path planner has provider name `cpu-canonical-nearest`,
version `0.1.0`, and stable ID `8d284a7409f377bb`.

These contracts identify the supplied regression settings. They do not resolve
or select a printer, material, process, or dialect profile.

## Remaining evidence work

The following work remains open:

- Publish a transfer file atomically after the operating-system save workflow
  selects an absent destination.
- Load decoded artifacts in the application evidence inspector.
