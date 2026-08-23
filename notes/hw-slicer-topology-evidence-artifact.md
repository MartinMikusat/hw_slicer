# HW Slicer topology evidence artifact

This note records the implemented topology artifact that precedes region
evidence in [`hw_slicer`](../README.md).

## Observed source contract

[`Topology_Result`](../src/slicing/topology.odin) owns these arrays:

- `layers` partitions vertices and paths by layer.
- `vertices` stores stable IDs, layer indexes, micrometre points, and degree.
- `paths` stores stable IDs, kinds, index spans, signed area, and winding.
- `path_vertex_indices` maps each path entry to a topology vertex.
- `path_segment_indices` maps each path edge to a snapped source segment.

The result also stores open-chain, degenerate-loop, and non-manifold-vertex
counts.

[`topology_result_hash`](../src/slicing/hashes.odin) binds the snapped
segment hash, source segment count, complete topology graph, and issue counts.
It rejects invalid spans, indexes, kinds, coordinates, and path cardinalities.

[`regions_build`](../src/slicing/regions.odin) consumes topology path
indexes directly. A region artifact cannot replay safely until the referenced
topology indexes are available.

## Implemented scope

Store the complete `Topology_Result`, its snapped parent hash, its canonical
result hash, and the source segment count. Use explicit little-endian records.
Do not copy Odin struct memory.

The artifact does not store snapped segment geometry or triangle provenance.
Topology issue replay needs a separate snapped-segment artifact because issue
records resolve segment, triangle, and triangle-edge references.

The artifact stores layer indexes, not physical layer Z values. A two-dimensional
topology view and region replay can use indexes alone. A physical Z readout
requires the earlier layer-schedule artifact.

The format token is `hws-topology-le`. The artifact schema is version 1.
The stage provider is `cpu-canonical-topology` version `0.1.0`.

## Implemented header

Use a 192-byte header.

| Offset | Size | Value |
| ---: | ---: | --- |
| 0 | 8 | Magic `HWSTOPO` followed by a newline |
| 8 | 4 | Artifact schema version |
| 12 | 4 | Header size |
| 16 | 4 | Layer record size |
| 20 | 4 | Vertex record size |
| 24 | 4 | Path record size |
| 28 | 4 | Index record size |
| 32 | 32 | Snapped-segment parent hash |
| 64 | 32 | Canonical topology result hash |
| 96 | 8 | Source segment count |
| 104 | 8 | Layer count |
| 112 | 8 | Vertex count |
| 120 | 8 | Path count |
| 128 | 8 | Path-vertex index count |
| 136 | 8 | Path-segment index count |
| 144 | 8 | Open-chain count |
| 152 | 8 | Degenerate-loop count |
| 160 | 8 | Non-manifold-vertex count |
| 168 | 24 | Reserved zero bytes |

## Implemented records

Use a 24-byte layer record:

| Offset | Size | Value |
| ---: | ---: | --- |
| 0 | 8 | Vertex offset |
| 8 | 4 | Vertex count |
| 12 | 8 | Path offset |
| 20 | 4 | Path count |

Use a 32-byte vertex record:

| Offset | Size | Value |
| ---: | ---: | --- |
| 0 | 8 | Stable vertex ID |
| 8 | 4 | Layer index |
| 12 | 4 | Vertex degree |
| 16 | 8 | X in micrometres |
| 24 | 8 | Y in micrometres |

Use a 72-byte path record:

| Offset | Size | Value |
| ---: | ---: | --- |
| 0 | 8 | Stable path ID |
| 8 | 4 | Layer index |
| 12 | 1 | Path kind |
| 13 | 3 | Reserved zero bytes |
| 16 | 8 | Vertex-index offset |
| 24 | 4 | Vertex-index count |
| 28 | 4 | Reserved zero bytes |
| 32 | 8 | Segment-index offset |
| 40 | 4 | Segment-index count |
| 44 | 4 | Reserved zero bytes |
| 48 | 16 | Signed doubled area as two's-complement `i128` |
| 64 | 1 | Winding code: negative `0`, zero `1`, or positive `2` |
| 65 | 7 | Reserved zero bytes |

Store both index arrays as packed little-endian `u32` values.

Calculate the exact byte count as:

```text
192 + 24L + 32V + 72P + 4PV + 4PS
```

`L`, `V`, and `P` are layer, vertex, and path counts. `PV` and `PS` are the two
index counts.

## Implemented decode sequence

1. Validate the byte limit, magic, schema, fixed sizes, and reserved bytes.
2. Calculate the exact payload size with checked `u64` arithmetic.
3. Validate every array count before allocation.
4. Decode all fields without publishing partial arrays.
5. Validate contiguous layer vertex and path spans.
6. Validate each vertex ID, layer index, degree, and coordinate.
7. Validate path kinds, layer ownership, spans, and loop cardinalities.
8. Validate every vertex and source-segment index.
9. Require unique vertex and path stable IDs.
10. Recalculate vertex degrees from the path walks.
11. Require source-segment indexes to form one exact permutation.
12. Recalculate loop area, winding, and the three issue counts.
13. Run `topology_result_hash` with the stored parent hash and segment count.
14. Compare the calculated hash with the stored topology hash.

Destroy all arrays after any failed check. Apply the capture budget before
payload allocation.

## Manifest and bundle binding

Stage `reconstruct-topology`, ordinal 7, declares
these counters:

- Layers.
- Vertices.
- Paths.
- Path-vertex indexes.
- Path-segment indexes.
- Open chains.
- Degenerate loops.
- Non-manifold vertices.

Store the canonical topology hash and source-independent replay as invariants.
Calculate planar bounds from decoded vertices and compare them with the
manifest.

The primitive path is
`stages/07-reconstruct-topology/primitives/topology.bin`. The ZIP and directory
validators decode the primitive and compare its graph with the stage manifest.

## Verification

The 1,056-byte synthetic artifact covers one loop, four open chains, one
degenerate loop, and one degree-four vertex. Its SHA-256 is
`2726f6e7d28c1ccf0690ada3efa778067e87165b2c3456311369685e0fa1388a`.
Region reconstruction from the decoded graph produces
`028163b0bafde773627eafa6efab771b1e281cb58dbe3ea1bf57de207a7b3d21`.

The Stanford Bunny artifact is 12,299,784 bytes. Its SHA-256 is
`d6eb53fd2b3e2086c0b90ce27892d67cf7230310d509d27653fec0d6579a252a`.
It stores 539 layers, 305,937 vertices, 683 paths, and 305,937 indexes in each
index array. Source-free region reconstruction produces the pinned region hash
`307170c41140c6aeca7aa3e0af0537a0e0bbaf7c8c229db10645ae4179280a4c`.

The all-in-one artifact is 7,443,736 bytes. Its SHA-256 is
`9259465ab0151513b450fad9bf8ce329b63cec28809ef91d3fe32d1d0a1797c2`.
Topology-only replay preserves its one non-manifold vertex. Region
reconstruction remains behind the existing explicit contour repair because
the raw fixture contains an intentional self-intersection.

The release benchmark performs two warmups and 20 alternating capture and
replay samples. An Apple M4 run measured a 338-millisecond capture p95 and a
256-millisecond replay p95. Each lane rejects a p95 above three seconds.

The evidence test suite rejects header, reserved-byte, span, index, counter,
kind, area, hash, limit, and allocation failures. The fixture gate rejects
content corruption after outer SHA-256 descriptors are recalculated. The
AddressSanitizer gate covers codec replay, bundle validation, and region
reconstruction.

## Implemented dependency

The [region artifact](hw-slicer-region-evidence-artifact.md) validates its
complete graph against this decoded topology. Keep 3DBenchy as diagnostic issue
coverage until repair supports its degenerate loop and three non-manifold
vertices.
