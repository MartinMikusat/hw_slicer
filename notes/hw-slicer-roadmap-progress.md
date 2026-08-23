# HW Slicer roadmap progress

This note records implemented work, measured results, and open decisions for
[`hw_slicer`](../README.md). It does not replace the staged
[`PLAN.md`](../PLAN.md).

## Current gate state

G0 is implemented. The foundation gate in
`scripts/foundation-check.sh` verifies package tests, release tests,
AddressSanitizer runs, benchmarks, model probes, application builds, ARM64
artifacts, dSYMs, and code signatures. It also parses every project shell
script before execution.

G1 has a deterministic CPU slice spine. The implementation includes bounded
STL, OBJ, and 3MF decode, mesh audits, fixed layers, triangle spans,
intersections, planar ownership, endpoint snapping, loop reconstruction, and
region classification. The headless entry point is
`cmd/hw-slicer-spine/main.odin`.

G2 currently includes these planar stages:

- Clipper2 Boolean and offset operations in `src/polygon`.
- Explicit contour repair and lineage in `src/repair`.
- Exposed top and bottom masks in
  `src/features/surfaces.odin`.
- Perimeter centerlines in `src/features/perimeters.odin`.
- Exact rectilinear infill in `src/features/infill.odin`.
- Deterministic planar path ordering in
  `src/features/path_plan.odin`.

The all-in-one fixture produces strict printable topology after one explicit
repair. `region-probe.sh` pins 1,360 regions, 500 holes, 1,673
exposed-surface masks, 2,879 perimeter paths, 5,845 infill segments, and 8,724
planned extrusion paths.

## Fixture readiness

The Stanford Bunny reaches strict topology with 200-micrometre fixed layers.
It has no open chains, degenerate loops, or non-manifold vertices. The
foundation gate pins its complete strict G2 output in
`testdata/feature-probes/stanford-bunny-v1.json`. The gate also runs
the complete Bunny path with AddressSanitizer.

The Bunny probe encodes and replays a 35,504,552-byte path-plan evidence
artifact. Its pinned SHA-256 is
`e0074543cb5db6a85e0e53a5588bf7ee37a21211d3b193d25895df2620625f5f`.
The [artifact contract](hw-slicer-path-plan-evidence-artifact.md) records the
byte layout and validation sequence. The fixture gate persists the artifact and
validates a source-independent replay summary through
`path-plan-replay.sh`.

The probe also pins a 1,854-byte stage manifest. Its feature request hash covers
the supplied G2 settings and both providers. The CPU planner has a versioned
descriptor and stable provider ID. Source-independent replay verifies the
manifest byte count and SHA-256 before it decodes the artifact. It then compares
the decoded counters, result hash, and planar bounds with the manifest.

The replay CLI renders canonical SVG data from one decoded layer. The fixture
gate pins all 1,338 bytes of Bunny layer 538 and rejects SVG changes.

The Bunny topology artifact is 12,299,784 bytes. It stores the complete graph
and has SHA-256
`d6eb53fd2b3e2086c0b90ce27892d67cf7230310d509d27653fec0d6579a252a`.
The all-in-one topology artifact is 7,443,736 bytes and preserves its one
non-manifold vertex. Both fixtures replay without their STL files.

The fixture gate also emits a deterministic 47,928,741-byte `.hwsdebug`
package. Its pinned SHA-256 is
`1fab0f11792b7bdf3b01533992475cde4e3faa4f7318ed87cbb572a8f2dad31e`.
The standalone bundle validator verifies all descriptors and replays the
topology, region, and path-plan stages without the STL.

The fixture also publishes the same records through an atomic development
directory. The publisher writes beneath a private sibling, validates the exact
tree, synchronizes it, and uses an exclusive rename. The standalone directory
validator replays all three stages without the STL. The region artifact stores
683 Bunny regions and matches the pinned region hash. Failure injection
covers every file boundary and the pre-rename boundary.

The package and directory now use one retained replay path. It verifies each
descriptor once, retains all three stage manifests, and decodes the topology,
region, and path-plan graphs. `evidence-inspect.sh` emits the retained
records and graph counts as one JSON document. The fixture gate pins the output
for both container forms.

3DBenchy reaches 748 loops with no open chains at the same layer height. It
also has one degenerate loop and three non-manifold vertices. Strict feature
generation must reject this topology. Keep Benchy as diagnostic and repair
coverage until an explicit repair supports those issue classes.

## Measured performance

`feature-benchmark.sh` reports total and per-stage samples. It uses
two warmup runs and 20 measured runs. It checks all stage hashes during each
iteration and rejects a total p95 above three seconds.

A release run on an Apple M4 after the edge-bounds broad phase measured a
480-millisecond total p95. Median stage times were approximately:

- Region classification: 100 milliseconds.
- Exposed-surface classification: 171 milliseconds.
- Perimeter generation: 92 milliseconds.
- Infill generation: 64 milliseconds.
- Path ordering: 47 milliseconds.

The same run issued 2,720 surface Boolean calls, 2,720 perimeter offset calls,
and 1,360 infill offset calls. Surface batching is the clearest remaining
performance target, but it must preserve each mask's region identity.
Surfaces, perimeters, and infill also rebuild the same canonical region
polygons. A shared immutable input cache is another measured optimization
candidate.

These values are observations, not release requirements. The three-second p95
gate is the current regression limit.

The 35,504,552-byte Bunny path-plan artifact has a capture and replay
benchmark. A 20-run release measurement produced these values:

- Capture: 361-millisecond p50, 486-millisecond p95, and 94 MiB/s.
- Replay: 204-millisecond p50, 276-millisecond p95, and 166 MiB/s.

Capture validates the artifact SHA-256. Replay validates the complete graph and
result hash. Each lane has a three-second p95 regression limit.

The 12,299,784-byte Bunny topology artifact has the same 20-run gate. A release
measurement produced these values:

- Capture: 321-millisecond p50, 338-millisecond p95, and 37 MiB/s.
- Replay: 238-millisecond p50, 256-millisecond p95, and 49 MiB/s.

Each iteration validates the complete graph, artifact SHA-256, topology hash,
and array counts. The benchmark also rebuilds regions once and matches the
pinned region hash.

The 114,180-byte Bunny region artifact has a 20-run gate. A release
measurement produced these values:

- Capture: 1.34-millisecond p95.
- Replay: 0.76-millisecond p95.

Each iteration validates the topology dependency, complete region graph,
artifact SHA-256, region hash, and array counts. Each lane has a three-second
p95 regression limit.

## Settled implementation contracts

Raw topology remains immutable. Repair creates a separate topology view for
strict feature generation.

Strict feature generation rejects open chains, degenerate loops, and
non-manifold vertices. Diagnostic generation requires an explicit policy.

Exposed-surface masks are geometric evidence. They do not select skin depth,
extrusion width, speed, bridge behavior, or overlap resolution.

Feature child ordinals use separate ranges for perimeters, exposed surfaces,
and infill. The helpers are in
`src/features/identifiers.odin`.

The project compiler wrapper disables the pinned Odin compiler's threaded
semantic checker. Test execution and optimized code generation remain
parallel.

The application and diagnostic CLIs use one bounded source-file reader. It
checks the file size before allocation and rejects a file that grows during the
read.

The evidence writer and reader apply the same schema and record validation.
Artifact paths must be valid UTF-8, relative, normalized, and unique.
Artifact formats use lowercase tokens, and every primitive or render declares a
schema. Provenance edges must be unique. Capture preflight rejects invalid
evidence levels and disabled nonzero usage.

The application uses the retained replay path for `.hwsdebug` packages and
published evidence directories. Its modal timeline exposes one registered
control per stage. Pointer, Flash, and Accessibility input select the same
typed action. The inspector shows stage identity, provider, schema, artifact
counts, byte counts, summary counters, and retained-graph state.

Path planning has a bounded, little-endian replay artifact. The decoder checks
framing, sizes, limits, reserved bytes, graph invariants, parent hashes, and the
stored result hash before it publishes arrays. Its capture wrapper applies the
request level and accumulated budgets before payload allocation.

Topology has a bounded, little-endian replay artifact. Its semantic validator
reconstructs layer ownership, stable-ID uniqueness, vertex degrees,
source-segment permutation, loop area, winding, and issue counts before it
accepts the canonical topology hash.

Manifest-gated replay validates the manifest path, format, schema, byte count,
and SHA-256 before artifact decoding. The fixture gate pins a single-byte
corruption rejection.

Manifest providers use canonical semantic versions. The validator derives each
provider ID from its name, version, and stage. Path-plan summary counters,
result hashes, and planar bounds must match the decoded artifact.

The feature request hash binds the spine request, every implemented feature
setting, the Clipper2 provider, and the CPU path-planner provider.

The benchmark harness rejects nondeterministic counters. The feature benchmark
uses two warmup runs and 20 measured runs.

## Open decisions

The next print-feature stages require a process-profile contract. Decide these
values before generating extrusion:

- Top and bottom skin thickness or layer count.
- Overlap precedence when one area has multiple surface roles.
- Thin-wall and gap-fill width limits.
- Bridge detection margin, direction, speed, and flow.
- Support overhang threshold, clearance, interface depth, and density.
- Printer, material, process, and G-code dialect profile boundaries.

The [process-profile decision contract](hw-slicer-process-profile-decisions.md)
lists the required choices, proposed ownership, invalidation boundaries, and
analytic fixtures. Its proposals are not selected defaults.

The evidence interface is also open. The engine has stable IDs, hashes,
provenance, issue reports, a generic evidence manifest, a deterministic
transfer-bundle codec, and an atomic development-directory publisher. It does
not yet render every implemented G2 graph in the application 3D and 2D views.

The topology, region, and path-plan artifacts have valid stage manifests and
both container forms. The path plan also has a canonical layer renderer.
Region evidence has a bounded codec, capture preflight, production fixture,
performance gate, and topology-dependent bundle replay. The application
inspector loads and retains these records. Geometric stage rendering and
cross-view selection remain open. The
[topology artifact contract](hw-slicer-topology-evidence-artifact.md) records
the implemented layout, validation sequence, fixture hashes, and performance
gate.

The
[bundle contract](hw-slicer-evidence-bundle-contract.md) uses a development
directory and a deterministic stored ZIP for transfer. Root manifest schema 1,
the stored-ZIP writer, the atomic directory publisher, and both inverse
validators are implemented. The validators reject unlisted content, verify
every descriptor, cross-check stage identity and artifact ownership, and replay
the topology, region, and path-plan primitives. Atomic transfer-file publication
remains open.

## Proposed next order

1. Define the versioned process-profile contract and its invalidation rules.
2. Propagate exposed masks through the configured skin depth.
3. Emit thin-wall and gap evidence before selecting extrusion paths.
4. Add bridge and support geometry after their policies are explicit.
5. Add extrusion calculation, printer profiles, and validated G-code in G3.
6. Extend the inspector with 3D and 2D rendering as each graph contract lands.

The first item needs product decisions. The later feature stages can use golden
geometry, strict topology fixtures, release benchmarks, and ASan as completion
gates. The retained bundle records provide the source-independent input for
incremental inspector rendering.
