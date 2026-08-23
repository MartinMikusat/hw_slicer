# HW Slicer region evidence artifact

This note defines the region artifact that follows the implemented
[`hws-topology-le`](hw-slicer-topology-evidence-artifact.md) artifact. The
binary codec, capture preflight, stage manifest, and synthetic bundle replay
are implemented. The production fixture and performance gate are pinned.

## Observed source contract

[`Region_Result`](../src/slicing/regions.odin) owns these arrays:

- `layers` partitions contours and regions by topology layer.
- `contours` binds classified contours to topology path indexes.
- `regions` binds each filled region to one outer contour.
- `region_contour_indices` stores each region's outer contour and holes.

The result also stores the hole count.

[`region_result_hash`](../src/slicing/hashes.odin) requires the
topology hash and complete decoded topology graph. It validates layer spans,
path references, stable IDs, contour nesting, winding reversal, membership,
filled areas, bounds, and the hole count before it calculates the region hash.

The region decoder must therefore receive the decoded topology artifact. A
stored topology hash without the graph cannot validate region semantics.

## Implemented scope

Store the complete `Region_Result`, its topology parent hash, and its canonical
result hash. Use explicit little-endian records. Do not copy Odin struct
memory.

The format token is `hws-regions-le`. The artifact schema is version 1. Stage
`calculate-regions` uses ordinal 8. Its provider is `cpu-canonical-regions`
version `0.1.0`.

## Implemented header

Use a 160-byte header.

| Offset | Size | Value |
| ---: | ---: | --- |
| 0 | 8 | Magic `HWSREGN` followed by a newline |
| 8 | 4 | Artifact schema version |
| 12 | 4 | Header size |
| 16 | 4 | Layer record size |
| 20 | 4 | Contour record size |
| 24 | 4 | Region record size |
| 28 | 4 | Index record size |
| 32 | 32 | Topology parent hash |
| 64 | 32 | Canonical region result hash |
| 96 | 8 | Layer count |
| 104 | 8 | Contour count |
| 112 | 8 | Region count |
| 120 | 8 | Region-contour index count |
| 128 | 8 | Hole count |
| 136 | 24 | Reserved zero bytes |

## Implemented records

Use a 24-byte layer record:

| Offset | Size | Value |
| ---: | ---: | --- |
| 0 | 8 | Contour offset |
| 8 | 4 | Contour count |
| 12 | 8 | Region offset |
| 20 | 4 | Region count |

Use a 64-byte contour record:

| Offset | Size | Value |
| ---: | ---: | --- |
| 0 | 8 | Stable contour ID |
| 8 | 4 | Topology path index |
| 12 | 4 | Parent contour index |
| 16 | 4 | Region index |
| 20 | 4 | Nesting depth |
| 24 | 1 | Role: outer `1` or hole `2` |
| 25 | 1 | Reverse-path flag: false `0` or true `1` |
| 26 | 6 | Reserved zero bytes |
| 32 | 8 | Minimum X in micrometres |
| 40 | 8 | Minimum Y in micrometres |
| 48 | 8 | Maximum X in micrometres |
| 56 | 8 | Maximum Y in micrometres |

Use an 80-byte region record:

| Offset | Size | Value |
| ---: | ---: | --- |
| 0 | 8 | Stable region ID |
| 8 | 4 | Layer index |
| 12 | 4 | Outer contour index |
| 16 | 8 | Membership index offset |
| 24 | 4 | Membership index count |
| 28 | 4 | Reserved zero bytes |
| 32 | 16 | Filled doubled area as `u128` |
| 48 | 8 | Minimum X in micrometres |
| 56 | 8 | Minimum Y in micrometres |
| 64 | 8 | Maximum X in micrometres |
| 72 | 8 | Maximum Y in micrometres |

Store membership indexes as packed little-endian `u32` values.

Calculate the exact byte count as:

```text
160 + 24L + 64C + 80R + 4I
```

`L`, `C`, `R`, and `I` are layer, contour, region, and membership-index
counts.

## Implemented decode sequence

1. Validate the byte limit, magic, schema, fixed sizes, and reserved bytes.
2. Compare the stored topology hash with the decoded topology artifact.
3. Calculate the exact payload size with checked `u64` arithmetic.
4. Validate every array count before allocation.
5. Decode the records and reject invalid role and Boolean codes.
6. Run `region_result_hash` with the decoded topology graph.
7. Compare the calculated hash with the stored region hash.
8. Compare counters, bounds, and hashes with the stage manifest.

Destroy all arrays after any failed check. Apply the capture budget before
payload allocation.

## Implemented verification

The 548-byte synthetic artifact contains an outer contour, one hole, and one
nested island. Its SHA-256 is
`cfba9ee257b934ddd9fbc996cc1404daa71950f2bc8f0776948cbf5b22857c0b`.

Tests reject magic, version, fixed-size, topology dependency, reserved-byte,
role, Boolean, path-reference, membership, result-hash, limit, and allocation
failures. A synthetic ZIP and development directory replay stage 7 before
stage 8. They reject a semantically corrupt region artifact after its outer
descriptors are recalculated.

The Bunny artifact is 114,180 bytes. Its SHA-256 is
`ffae9c9887d2c70ae1b22bb53a4c2b651f3d9ac4dc8f3b4bfb3e75b4e7b18cea`.
It contains 539 layers, 683 contours, 683 regions, and 683 membership indexes.
Its stored region hash is
`307170c41140c6aeca7aa3e0af0537a0e0bbaf7c8c229db10645ae4179280a4c`.

The release benchmark performs two warmups and 20 alternating capture and
replay samples. An Apple M4 run measured a 1.34-millisecond capture p95 and a
0.76-millisecond replay p95. Each lane rejects a p95 above three seconds.

The default Stanford Bunny bundle stores stage 8 between topology and path
planning. The ZIP and directory validators decode stage 7 first, then use that
verified topology graph to validate the region artifact.

## Remaining dependency

Load the decoded region records in the application evidence inspector.
