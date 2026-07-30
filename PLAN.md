# Executive Summary

- Build one deterministic slicing engine with a CLI, a macOS application, and
  versioned stage contracts. The UI and CLI submit the same immutable
  `Slice_Request` and consume the same results.
- Keep the pipeline explicit: decode, normalize, repair, schedule layers, build
  acceleration data, intersect, reconstruct topology, calculate regions,
  generate print features, plan paths, and emit G-code. Each stage owns one
  input contract and one output contract.
- Use signed 64-bit micrometre coordinates for authoritative planar geometry.
  Use filtered floating-point predicates and exact fallbacks where topology
  depends on a sign. Do not use one global epsilon.
- Use a layer-span index for normal horizontal slicing. A triangle contributes
  only to the layers that cross its Z interval. Keep BVH providers for support
  queries, arbitrary section planes, picking, and later incremental workflows.
- Keep CPU geometry authoritative. Move triangle-to-layer expansion,
  unambiguous plane intersections, prefix compaction, dense support fields,
  distance transforms, and preview generation to Metal only after a measured
  CPU baseline exists.
- Make GPU output deterministic at the contract boundary. Metal kernels attach
  source identifiers, reject ambiguous cases to a CPU replay queue, and return
  unordered records. The CPU snaps, sorts, validates, and canonicalizes them.
- Treat visual debugging as pipeline output. Every stage can emit a bounded,
  versioned `.hwsdebug` evidence bundle with stable identifiers, structured
  summaries, invariants, geometry, provenance, and deterministic SVG or PNG
  views.
- Render the same debug evidence in a 3D source view, a 2D layer view, a stage
  timeline, and an inspector. Command-line render and diff operations make the
  evidence readable by engineers, tests, and multimodal AI systems.
- Bind replaceable providers once at stage boundaries. Procedure-table dispatch
  does not occur inside geometry loops. Conformance fixtures and canonical
  stage hashes permit a CPU, Metal, or third-party provider to replace another.
- Use a thin AppKit host, direct Metal rendering, project-styled controls,
  `hw_odin_ui_flash`, and the shared immediate-mode control registry. Use native
  panels only for operating-system file and security workflows.
- Target a gated 38–52 engineer-week path for one engineer. A useful
  deterministic slicer arrives earlier, but robust supports, profiles,
  multi-material behavior, GPU validation, diagnostics, and release engineering
  define the production gate.

## Architecture Diagram

```text
                  Slice_Request + profile revisions
                              |
        +---------------------v----------------------+
        |          bounded pipeline scheduler        |
        | byte permits | cancellation | stage cache  |
        +---------------------+----------------------+
                              |
  +--------+  +-----------+  +-------------+  +----------------+
  | decode |->| normalize |->| layer index |->| intersections  |
  +--------+  | + repair  |  | + BVH       |  | CPU / Metal    |
      |       +-----------+  +-------------+  +--------+-------+
      |                                                |
      |       +----------+  +------------+  +----------v-------+
      +------>| topology |->| polygons   |->| print features   |
              | + loops  |  | + offsets |  | skin/infill/etc. |
              +----------+  +------------+  +----------+-------+
                                                        |
                              +-------------+  +---------v------+
                              | G-code emit |<-| path planning  |
                              | + validate  |  | + extrusion    |
                              +------+------+  +----------------+
                                     |
                              G-code + manifest

  Every stage boundary also emits:
  +-------------------------------------------------------------+
  | Debug_Evidence: stable IDs | JSON summary | primitive data  |
  | invariants | provenance | timings | canonical SVG/PNG views |
  +-----------------------------+-------------------------------+
                                |
             +------------------+------------------+
             |                  |                  |
       macOS inspector     CLI render/diff    QA and AI review
```

## 1. Core Architecture Design

### Problem & Goals

The engine must transform hostile or very large mesh input into printer-specific
G-code without binding geometry policy to the UI, Metal, a file format, or one
polygon implementation. It must stream enough state to cap memory, preserve the
cross-layer context required by skin and support generation, and expose every
transformation for diagnosis.

The release scope includes STL, OBJ, and 3MF input, deterministic mesh
normalization, fixed and adaptive layer schedules, perimeters, top and bottom
skin, sparse and solid infill, bridges, supports, seam selection, travel and
retraction planning, extrusion calculation, printer profiles, G-code dialects,
preview, and resumable diagnostic capture. Multi-object and multi-material data
must survive the contracts even when their first toolpath policies arrive in a
later milestone.

### Decisions & Rationale

- **Package direction.** `contracts` contains units, identifiers, schemas,
  stage descriptors, errors, and immutable results. `geometry` and `formats`
  depend on `contracts`. `pipeline` coordinates providers. `platform/macos`,
  `app`, and `cli` consume the pipeline. Core packages never import UI or AppKit
  packages.
- **Stage providers.** Decode, polygon, acceleration, intersection, support
  field, path-order, and G-code dialect operations have versioned procedure
  tables. The scheduler selects a provider before work starts. Hot loops call
  concrete procedures with contiguous spans.
- **Canonical units.** Input transforms and three-dimensional normalization use
  `f64` millimetres. Layer Z values and authoritative two-dimensional
  coordinates use signed 64-bit micrometres. Checked `i128` intermediates
  evaluate products and determinants within the accepted build-volume bound.
- **Primary accelerator.** Horizontal slicing builds a two-pass
  `Layer_Span_Index`: calculate each triangle's inclusive layer interval, count
  entries per layer tile, prefix-sum offsets, and scatter stable triangle IDs.
  A BVH is secondary because traversal repeats work that the Z intervals already
  identify.
- **Streaming window.** The scheduler processes contiguous layer tiles. It adds
  a halo large enough for configured top and bottom thickness. Global support
  analysis runs as an explicit pass whose compact masks can be spooled before
  feature generation.
- **Back-pressure.** Each queued result reserves byte permits based on measured
  capacity. A producer blocks at its stage boundary when the following queue or
  debug writer reaches its allowance. Cancellation invalidates future tasks but
  does not free a buffer still owned by a running job.
- **Debug evidence.** A stage publishes `Debug_Evidence` beside its normal
  result. Evidence has a schema version, request hash, stage revision, stable
  source IDs, bounds, units, summary counters, invariant results, provenance
  edges, timings, and references to primitive arrays and renders.
- **Stable identity.** Source objects, components, triangles, layers, segments,
  loops, regions, features, and paths receive deterministic 64-bit IDs derived
  from parent IDs and canonical local order. Debug builds detect collisions.
  Pointer values and worker completion order never become identifiers.
- **Project persistence.** A versioned project document stores source bookmarks,
  transforms, profile revision IDs, modifier regions, overrides, and UI state.
  Derived slices and debug captures are caches with content hashes, not the only
  copy of user intent.

The stage sequence is:

1. Decode the package and validate size, count, and nesting limits.
2. Resolve units, components, instances, materials, and transforms.
3. Normalize the mesh, report defects, and apply the selected repair policy.
4. Calculate the layer schedule and triangle layer spans.
5. Build the layer-span index and query acceleration structures.
6. Intersect triangles with layer planes and canonicalize raw segments.
7. Cluster endpoints and reconstruct directed loops and open chains.
8. Apply fill rules, booleans, offsets, and modifier-region settings.
9. Derive perimeters, gap fill, skin, bridges, infill, and supports.
10. Order extrusion and travel paths, then calculate speed, flow, cooling,
    retractions, tool changes, and time estimates.
11. Emit and validate the chosen G-code dialect with a correlated preview
    manifest.

### Concrete Techniques

- Define `Slice_Request`, `Stage_Descriptor`, `Stage_Result_Header`,
  `Provider_Descriptor`, and `Debug_Evidence_Header` before an algorithm
  implementation. Version serialized contracts independently from in-memory
  layouts.
- Give each result one owner. Transfer arenas between stages or retain immutable
  reference-counted generations. Do not expose frame-arena pointers to workers.
- Store a stage cache key from the input content hash, normalized settings,
  provider name and version, numeric mode, and stage schema version. Invalidate
  only downstream stages after a setting changes.
- Separate settings by earliest affected stage. A color change invalidates
  rendering. A seam change invalidates path planning. A layer-height change
  invalidates the layer schedule and every downstream result.
- Implement deterministic merge points. Workers write private buffers indexed
  by fixed task ordinals. The merge sorts by layer, parent ID, primitive class,
  and canonical coordinates.
- Represent a stage failure as a structured issue with severity, stable code,
  source IDs, layer range, geometry bounds, evidence references, and a proposed
  user action.
- Keep low-cost counters and invariant summaries enabled in every debug build.
  Enable primitive capture by stage, layer range, bounding box, issue code, or
  stable ID. Enforce byte and item limits before capture begins.
- Store each `.hwsdebug` capture as a directory while developing and as a ZIP
  package for transfer. Include `manifest.json`, `summary.json`, per-stage JSON,
  little-endian binary arrays with explicit schemas, canonical SVG layer views,
  PNG 3D views, logs, and SHA-256 hashes.
- Provide CLI operations for slice, inspect, capture, render, query, diff,
  validate, benchmark, and replay. The GUI invokes the same application
  services, not a second slicing path.
- Link the AppKit host and Odin application into one executable in debug and
  AddressSanitizer modes. Relaunch it only after a successful complete build.

Delivery proceeds through gates. A gate closes only when its listed evidence is
stored in the repository or release artifacts.

| Gate | Scope | Exit evidence | Estimate |
|---|---|---|---:|
| G0 Foundations | Project skeleton, pinned toolchain, contracts, scalar math, test and benchmark harness, debug schema | Clean build, compiler smoke suite, schema fixtures, crash artifact | 2–3 weeks |
| G1 Deterministic slice spine | STL and 3MF decode, normalize, fixed layers, layer spans, CPU intersections, loops, CLI | Analytic and degeneracy corpus, stable hashes, small benchmark | 5–6 weeks |
| G2 Planar features and evidence UI | Booleans, offsets, perimeters, thin walls, skin, infill, stage capture and inspector | Polygon conformance, every implemented stage view, UI structural checks | 6–8 weeks |
| G3 Printable output | Supports, bridges, paths, extrusion, profiles, dialect, validator, preview | Dry-run corpus, physical calibration prints, file-failure suite | 6–8 weeks |
| G4 Metal and scale | GPU intersections, scans, dense fields, huge-model tiling, CPU fallback | CPU/GPU differential corpus, Metal validation, medium and huge benchmarks | 5–7 weeks |
| G5 Production feature depth | Adaptive layers, modifiers, multi-object, multi-material policies, tree-support candidate, cache invalidation | Profile matrix, tool-change and support fixtures, full provenance | 8–12 weeks |
| G6 Distribution | Performance closure, fuzz campaigns, accessibility, signing, notarization, clean-machine QA | Release checklist, notarized artifact, pinned assets and licenses | 4–6 weeks |

The summed range is 36–50 weeks. Reserve two weeks for integration failures
that cross provider or stage boundaries, which produces the 38–52 week planning
range. Re-estimate from measured gate throughput instead of preserving this
calendar after evidence changes.

### Risks & Mitigations

- **Contract over-design.** Freeze only units, identity, ownership, stage
  semantics, and serialized evidence first. Keep algorithm-specific scratch
  layouts private to providers.
- **Cross-layer features defeat streaming.** Calculate compact global masks in
  dedicated passes, then consume them through bounded layer windows. Permit an
  mmap-backed spool when the measured memory allowance is insufficient.
- **Parallel work changes output order.** Assign task ordinals before dispatch
  and canonicalize at each externally visible boundary.
- **Debug capture changes the bug.** Keep counters allocation-free, preflight
  capture capacity, and write immutable snapshots after stage barriers.
- **Silent repair changes the part.** Preserve the source mesh, list each repair,
  render before-and-after evidence, and require an explicit policy for repairs
  that change a closed component's volume materially.
- **Provider replacement changes semantics.** Require conformance fixtures,
  invariant parity, canonical stage hashes, and differential fuzzing before a
  provider becomes the default.

### Measurable Acceptance Criteria

- A headless request and a GUI request with identical inputs produce identical
  canonical stage hashes and byte-identical G-code.
- Every one of the 11 pipeline stages can emit a valid bounded debug-evidence
  record, and every evidence primitive resolves to a source ID or parent stage
  ID.
- Cancellation completes within 250 ms after the active kernel or file write
  reaches its documented cancellation boundary. No cancelled request publishes
  a final output.
- The scheduler never exceeds its configured in-flight allowance by more than
  one active task's declared capacity.
- Replacing any registered provider with a conformance fake changes no package
  outside that provider, its registration, and its tests.
- A stage-setting mutation invalidates exactly the expected suffix in 100% of
  the cache-dependency test matrix.
- One debug capture can replay its stage views without the source model or
  project database, and all recorded SHA-256 hashes validate.

## 2. Odin Language Suitability

### Problem & Goals

Odin must express explicit ownership, data-oriented layouts, ARM64 SIMD,
parallel jobs, C ABIs, and macOS framework calls without allowing build and
interop details to leak into geometry. The plan must also account for a smaller
tooling and package ecosystem than C++ or Rust.

### Decisions & Rationale

Odin is suitable because it exposes alignment and array layout, supplies custom
allocators through `context`, supports ARM64, and has a direct foreign system.
Its official documentation describes the foreign system and explicit
memory-layout controls.[^1] Those mechanisms match generation arenas, SoA
buffers, and C-compatible platform shims.

The project will pin one compiler revision in `odin-version`. It will not depend
on a global package manager because Odin does not provide an official one.
Sibling libraries and vendored C or C++ sources receive exact origins, commits,
licenses, and checksums in `dependencies.lock` and the README.

Use Odin for the engine, scheduler, file validation, test harness, CLI, UI
model, and most macOS bindings. Use small Objective-C or C shims where typed
Objective-C message dispatch, blocks, exception boundaries, or SDK structure
layouts would otherwise require unsafe repeated casts. A stable C ABI also
keeps AppKit and Metal bindings replaceable.

Compared with C, Odin supplies slices, array programming, package namespaces,
custom allocators, `defer`, and stricter types with similar layout control. C
retains the broader debugger, library, sanitizer, and static-analysis
ecosystem. Compared with Rust, Odin exposes ownership and allocator policy with
less type-system machinery, but it does not statically prove borrowing and has
a smaller package ecosystem. The project replaces that missing static evidence
with arena ownership rules, checked spans, sanitizers, fuzzing, and stage
contracts.

### Concrete Techniques

- Pin the compiler and Xcode command-line tool versions used by release builds.
  Record `odin version`, SDK build, deployment target, linker version, and Metal
  compiler version in every benchmark and debug manifest.
- Build separate `debug`, `asan`, `profile`, and `release` outputs. Keep bounds
  checks, assertions, Metal validation, NaN traps, and evidence checks in debug.
  Keep symbols and a matching dSYM in every diagnostic build.
- Use package collections for pinned sibling repositories. Make every build
  reject an origin, commit, or dirty-state mismatch.
- Import POSIX and plain C APIs directly when their ABI is stable. Route AppKit,
  Accessibility, Uniform Type Identifiers, Core Text, QuartzCore, and complex
  Metal calls through generated bindings or the project C/Objective-C shim.
- Expose typed C functions from the shim instead of calling variadic
  `objc_msgSend` forms throughout Odin. Keep retain, release, autorelease-pool,
  callback-thread, and ownership rules in each binding declaration.
- Link the application with `-framework Metal`, `-framework Cocoa`,
  `-framework QuartzCore`, `-framework CoreText`, `-framework CoreGraphics`,
  `-framework Accelerate`, `-framework UniformTypeIdentifiers`, and
  `-framework Security`.
  Link `libcompression` or another archive dependency only after its provider
  decision and license audit. Apple's linker accepts `-framework` for
  non-Xcode build systems.
- Use explicit allocators at subsystem entry points. Use frame, stage,
  generation, worker-scratch, and persistent-heap allocators with separate
  high-water counters.
- Use `#no_bounds_check` only inside measured loops with an asserted preflight
  that proves all spans. Keep a checked implementation available for fuzzing.
- Keep format and debug schemas simple enough for independent readers. Generate
  schema documentation and golden fixtures from versioned descriptions, not
  from Odin reflection alone.
- Use `hw-odin-analyze` for ambiguous symbol operations, then verify all changes
  with `odin check` and the project tests.

### Risks & Mitigations

- **Compiler regression.** Pin the compiler, keep a small compiler smoke suite,
  and test the next revision in a separate CI lane before changing the pin.
- **Incomplete macOS bindings.** Generate narrow bindings from the installed SDK
  or add typed shims. Do not maintain a hand-written mirror of an entire
  framework.
- **Weak package distribution.** Vendor small dependencies or pin sibling
  repositories. Verify their exact commits and licenses before each build.
- **Debug information gaps.** Preserve object files, run `dsymutil`, archive the
  binary and dSYM on crashes, and keep CLI reproducers for geometry failures.
- **Foreign lifetime errors.** Put ownership annotations beside declarations,
  use autorelease pools on callback and worker threads, and run ASan, Zombies,
  Guard Malloc, and Core Foundation lifetime traces.
- **Generics obscure hot code.** Prefer concrete geometry types and generated
  specializations. Inspect optimized ARM64 assembly for each accepted kernel.

### Measurable Acceptance Criteria

- A clean Apple Silicon machine can build all four modes from the pinned
  compiler and dependency lock without a global third-party package manager.
- The compiler smoke suite passes on the pinned compiler and on one candidate
  upgrade before the project changes its pin.
- ASan detects the project heap-use-after-free fixture, and the normal ASan test
  suite reports zero sanitizer findings.
- Every Objective-C object crossing the shim has a documented ownership rule,
  and the lifetime stress suite completes 10,000 open, slice, close cycles with
  no retained-object growth.
- `odin check` and the complete unit suite run in less than 90 seconds on the
  reference development Mac by the first public beta.
- Release binaries contain no debug dylib path, unpinned sibling path, or
  writable executable resource.

## 3. Performance-Centric Design

### Problem & Goals

Slicing mixes bandwidth-bound scans, irregular topology, allocation-heavy
polygon work, global feature passes, and graph heuristics. Optimizing isolated
arithmetic while moving excess data or creating excess geometry will not meet
the end-to-end target. Performance evidence must separate decode, compute,
memory, GPU, synchronization, debug, and write costs.

### Decisions & Rationale

Optimize the amount and shape of work first. Layer spans replace repeated mesh
scans. Compact indices replace pointers. SoA or AoSoA buffers serve uniform
numeric kernels, while topology structures use dense indices and segmented
arrays. Stage-local arenas eliminate fine-grained frees. Stable sorting occurs
only at contract boundaries that require canonical output.

Determinism takes priority over reductions whose order depends on workers.
Performance mode can use relaxed floating-point only in calculations that
cannot change topology or emitted quantized values. Precision mode records its
choice in every cache key and output manifest.

Use a fixed benchmark corpus with pinned hashes and generated adversarial
fixtures. Report cold and warm runs, p50 and p95, peak resident memory, bytes
allocated, layer throughput, polygon-edge throughput, CPU utilization, GPU
time, CPU-GPU wait time, ambiguity rate, and output size. Apple's Instruments
templates expose Time Profiler, virtual-memory, Metal resource, GPU, thermal,
and display tracks.[^2]

### Concrete Techniques

- Align the start of hot arrays to 128 bytes. Treat the cache-line size for each
  supported M-series device as **Unknown** until a startup query or
  microbenchmark records it. Padding the array base must not change serialized
  layouts.
- Partition scan kernels into chunks that contain thousands of primitives.
  Tune chunk sizes by model class and record them in benchmark output.
- Preflight counts, coordinate bounds, output capacity, and provider
  capabilities before dispatch. Stop at the first unsafe boundary and retain a
  bounded issue sample instead of entering an expensive partial stage.
- Split rarely read flags, provenance, and issue metadata from coordinate and
  index arrays. Keep a stable ID array parallel to each primitive span.
- Convert unpredictable branches into classification masks and compact queues
  when the extra writes benchmark faster. Keep degenerate and ambiguous cases
  on a slow path.
- Prefetch sequential layer-span and triangle streams only after an ARM64
  counter trace proves a miss problem. Do not insert unconditional prefetches.
- Reuse capacity for per-worker scratch, scan counts, radix-sort histograms,
  polygon edges, and path candidates. Reset arenas at stage or tile boundaries.
- Add signposts around stages, tiles, Metal command buffers, waits, file reads,
  and debug writes. Include request, stage, tile, and provider IDs.
- Run Time Profiler for CPU attribution, Allocations and VM Tracker for memory,
  File Activity for input and G-code output, Metal System Trace for queue and
  occupancy behavior, and Processor Trace for branch-level investigations on
  supported development systems.
- Disassemble release kernels and record vector instruction counts, spills,
  branch density, and load/store width. Compare generated ARM64 against the
  scalar reference before retaining manual SIMD.
- Run performance tests on AC power, after a warm-up, with thermal state
  recorded. Use 11 measured iterations for p50 and 30 for p95 release gates.

The thresholds below are engineering targets, not claims about Apple hardware.
The reference floor is a base M1-class Mac with 16 GiB memory. Each fixture must
have a generator version or a redistributable source, license, SHA-256, expected
layer count, and canonical output hash before the gate becomes active.

| Benchmark model | Fixed workload | Primary metrics | Release pass threshold |
|---|---:|---|---:|
| Small mechanical | 250,000 triangles, 800 layers, manifold with holes | End-to-end time, layer rate, peak RSS, debug overhead | CPU p50 ≤ 1.5 s, ≥ 530 layers/s, RSS ≤ 400 MiB, summary-only debug overhead ≤ 5% |
| Medium organic | 5,000,000 triangles, 2,000 layers, dense curved surface | Triangle-layer pairs/s, polygon edges/s, GPU speedup, RSS | CPU p50 ≤ 25 s, Metal p50 ≤ 14 s, ≥ 1.6× intersection speedup, RSS ≤ 3 GiB |
| Huge tiled assembly | 50,000,000 triangles, 5,000 layers, 20 instances | End-to-end time, peak RSS, back-pressure, output determinism | Metal p50 ≤ 180 s, RSS ≤ 7 GiB, no unbounded queue growth, identical hashes in 10 runs |
| Degeneracy corpus | 100,000 generated cases near vertices, coplanar faces, overlaps, and zero-area input | Correctness, fallback rate, crash rate | Zero topology invariant failures, zero crashes, 100% CPU/GPU agreement after canonicalization |
| Path stress | 1,000 layers with 100,000 islands total | Path length, planner time, memory | Planner p50 ≤ 20 s, travel length ≤ 1.08× reference heuristic, RSS ≤ 2 GiB |

### Risks & Mitigations

- **Synthetic thresholds hide production behavior.** Add licensed real models
  with pinned hashes and keep generated fixtures for controlled scaling.
- **GPU speedup disappears end to end.** Require total-request improvement and
  report encode, wait, canonicalization, and fallback time separately.
- **Debugging distorts profiles.** Maintain debug-off, summary-only, and full
  capture benchmark lanes.
- **Thermal and background variance.** Record thermal state, reject runs with a
  state transition, and retain raw samples rather than one best result.
- **Fast math changes topology.** Restrict it to non-authoritative fields and
  require canonical agreement with strict mode.
- **Memory reuse retains the high-water footprint.** Apply per-stage capacity
  budgets and release oversized generations after a request class shrinks.

### Measurable Acceptance Criteria

- Each release benchmark records toolchain, hardware identifier, OS, thermal
  state, providers, numeric mode, raw iterations, stage timings, and hashes.
- The release meets every active row in the benchmark table on the reference
  floor or documents a reviewed threshold revision before implementation
  changes are accepted.
- Summary-only debugging adds no more than 5% p50 time and 3% peak RSS on the
  small and medium fixtures.
- No stage performs more than 1.10 times its algorithmically required primitive
  visits on the regular benchmark corpus, excluding documented repair or
  canonicalization passes.
- Ten runs with worker counts from 1 through the available logical CPUs produce
  identical canonical outputs.
- A performance regression greater than 5% in p50 or 10% in p95 blocks a
  release unless the change fixes a correctness defect and records the trade.

## 4. Hot Path Identification

### Problem & Goals

The plan needs concrete kernels and benchmark fixtures before optimization.
Likely hot work includes triangle classification and intersection, span
expansion, endpoint clustering, polygon booleans and offsets, dense field
generation, support propagation, path ordering, extrusion annotation, preview
geometry, and G-code formatting.

### Decisions & Rationale

Create a scalar checked reference for every kernel that can move to SIMD or
Metal. A microbenchmark consumes generated input with a fixed seed, validates
the output hash, reports operations and bytes, and supports adversarial
distributions. Keep microbench results subordinate to the end-to-end benchmark.

Do not assume a BVH traversal is hot in normal horizontal slicing. Measure
layer-span construction and pair expansion first. Do not assume Accelerate
improves irregular geometry. Retain it only for a measured dense operation.

### Concrete Techniques

- **Triangle Z classification.** Scan `z0`, `z1`, and `z2`, apply the half-open
  plane rule, and classify crossing, tangent, coplanar, or rejected triangles.
  Benchmark 100 million classifications with flat, random, and near-plane data.
  Target at least 70% of measured sequential-memory roofline.
- **Triangle-to-layer expansion.** Convert triangle Z bounds to layer intervals,
  count pairs, prefix-sum, and scatter triangle IDs. Benchmark 50 million
  triangles across uniform and adaptive schedules. Report pairs/s, bytes/pair,
  and temporary bytes.
- **Plane intersection.** Calculate two endpoints for unambiguous crossings,
  attach triangle and edge provenance, and enqueue uncertain predicates.
  Benchmark 100 million pairs with 0%, 1%, and 20% ambiguity. Target Metal at
  least 1.6× the CPU kernel including canonicalization on the medium corpus.
- **Endpoint clustering.** Quantize endpoints, radix-sort by layer and
  coordinate, then construct cluster ranges. Benchmark closed loops, many
  islands, and high-degree degeneracies. Report segments/s and maximum cluster
  size.
- **Loop reconstruction.** Walk directed adjacency with a deterministic turn
  rule and issue open-chain or non-manifold evidence. Benchmark 10 million
  segments in simple loops, nested loops, and branch-heavy graphs.
- **Polygon boolean.** Run union, difference, intersection, and XOR over fixed
  integer contours. Benchmark edge counts from 100 to 10 million with holes,
  overlaps, shared edges, and self-intersections. Report input and output
  edges/s by operation.
- **Offset and perimeter generation.** Offset contours with miter, square, and
  round joins, then clean self-intersections under the selected fill rule.
  Benchmark thin walls, acute corners, small arcs, and repeated shells.
- **Rasterization and distance transform.** Tile regions into masks and
  calculate an exact squared Euclidean distance field for support, gap, or
  infill decisions. Benchmark 1K², 4K², and 16K² logical grids with sparse and
  dense occupancy.
- **Infill clipping.** Generate analytic line families or field contours and
  clip them to sparse or solid regions. Benchmark rectilinear, grid, concentric,
  and gyroid workloads by emitted segment count.
- **Support propagation.** Project overhang demand down the layer stack,
  subtract model clearance, merge interfaces, and produce support regions.
  Benchmark tall narrow parts, broad overhangs, and branching tree-support
  candidates.
- **Path ordering.** Build spatial bins, select constrained nearest candidates,
  improve local tours with bounded 2-opt, and insert retractions or tool
  changes. Benchmark 100 to 100,000 islands with known lower bounds.
- **G-code formatting.** Convert quantized coordinates and extrusion state to
  buffered text without locale dependence. Benchmark 20 million moves and
  report commands/s, bytes/s, allocations, and checksum time.

Each microbenchmark must also emit one compact debug capture. The capture shows
input distribution, output samples, rejected items, invariants, and a
human-readable failure view.

### Risks & Mitigations

- **Microbench dead-code elimination.** Hash the validated output and consume
  the hash outside the timed region.
- **Unrepresentative data.** Combine controlled distributions, fuzz regressions,
  and pinned real-stage captures.
- **Reference implementation shares the bug.** Use independent formulas,
  third-party oracles where licensing permits, and invariants that do not depend
  on either implementation.
- **Throughput hides tail behavior.** Report p50, p95, maximum tile time, and
  slow-path counts.
- **Optimization changes allocation behavior.** Measure allocations, committed
  bytes, and peak scratch beside elapsed time.

### Measurable Acceptance Criteria

- Every listed kernel has a checked reference, an optimized candidate, a fixed
  fixture generator, an output oracle or invariant set, and a benchmark command.
- Each microbenchmark completes correctness validation before it reports timing.
- The benchmark harness detects a deliberate wrong result and a deliberate
  unused-output implementation.
- Slow-path and ambiguity rates appear in benchmark JSON and in the associated
  debug summary.
- No optimized kernel becomes the default without equal outputs on its fixed
  corpus and at least 10 million relevant fuzz operations.
- The top five release-profile call sites account for less than 75% of CPU time
  only after each has a recorded optimization decision or a measured reason to
  remain unchanged.

## 5. Memory Layout Strategy

### Problem & Goals

Large meshes and many layers can multiply records faster than source triangle
count. The engine must preserve sequential access, permit CPU and Metal views,
bound temporary memory, and keep ownership visible. Apple Silicon unifies
physical memory, but Metal resource modes still define CPU and GPU access and
synchronization semantics.[^3]

### Decisions & Rationale

Keep a compact indexed canonical mesh and construct stage-specific hot views.
The input representation should not dictate the intersection representation.
Use 32-bit indices when counts fit and upgrade one complete mesh generation to
64-bit indices when they do not. Never mix widths inside one generation.

Use SoA for triangle bounds, classification, coordinates used in uniform
kernels, layer spans, raw segments, and path attributes. Use segmented arrays
for contours and paths: one descriptor span references one contiguous point
span. Use dense index adjacency for topology. Keep verbose issues and provenance
out of hot coordinate arrays.

### Concrete Techniques

- Store canonical vertices as separate `f64` X, Y, and Z arrays plus stable IDs.
  Store triangle vertex indices, material or object IDs, source IDs, and flags
  in parallel arrays.
- Build a transient expanded triangle SoA for CPU slicing and a scaled `f32`
  packed buffer for Metal. Retain source triangle IDs so both views return to
  the canonical mesh.
- Store `Layer_Span_Index` as layer descriptors with `offset` and `count` plus
  one contiguous triangle-ID array. Tile descriptors include the halo and byte
  estimate.
- Store raw segments as endpoint X and Y arrays, triangle ID, source edge codes,
  classification, and flags. Canonical segment order is independent from
  allocation order.
- Store endpoint clusters as sorted endpoint indices plus compact
  `cluster_offset` and `cluster_count` spans. Store loop adjacency as dense edge
  indices.
- Store contours and paths in one point arena with descriptors containing
  offset, count, winding, bounds, role, settings ID, parent ID, and stable ID.
- Allocate persistent project state from the heap, immutable mesh generations
  from generation arenas, tile results from transferable stage arenas,
  per-worker temporaries from resettable scratch arenas, and controls from the
  frame arena.
- Reserve virtual address space for large arenas and commit pages on demand.
  Record reserved, committed, active, and high-water bytes separately.
- Use `mmap` for validated binary STL spans and large uncompressed cache arrays.
  Compare mmap with aligned read-and-parse for small input. Use `madvise` only
  after a trace establishes the access order.
- Decode compressed 3MF entries into bounded buffers or a streaming pull parser.
  Do not expose pointers into a decompressor ring after it advances.
- Use shared Metal buffers for CPU-produced input and CPU-read compact results.
  Measure private buffers plus blits for GPU-only multi-pass fields. Batch
  synchronization at tile boundaries.
- Respond to memory pressure by stopping new tile production, draining completed
  work, releasing caches by recomputation cost, and optionally spooling compact
  immutable stage data. Do not free buffers referenced by an active command
  buffer.

### Risks & Mitigations

- **SoA duplicates source data.** Build hot views lazily and release them by
  stage dependency. Compare saved CPU or GPU time against extra committed bytes.
- **Pointer invalidation.** Exchange offsets, indices, generation handles, and
  stable IDs across stages. Keep raw pointers provider-local.
- **32-bit overflow.** Validate counts and prefix sums with checked 64-bit
  arithmetic before selecting an index width.
- **Unified memory creates false confidence.** Track CPU-GPU waits, cache mode,
  storage mode, and total working set. Evaluate private resources when the GPU
  reuses data without CPU access.
- **mmap faults enter the hot path.** Prefault or sequentially parse when traces
  show major faults during compute.
- **Debug evidence doubles memory.** Snapshot after barriers, stream artifacts,
  filter primitives, and enforce a capture budget.

### Measurable Acceptance Criteria

- Every persistent and transient allocation appears under one named allocator
  in the memory report. Unknown allocation ownership is zero.
- The medium benchmark stays below 3 GiB peak RSS, and the huge benchmark stays
  below 7 GiB on the reference floor.
- The layer pipeline holds no more than the configured core tile count plus two
  halos and one active writer tile.
- All offset, count, byte-size, and prefix-sum overflow tests fail before
  allocation or pointer arithmetic.
- Resetting a stage arena invalidates no handle retained by a downstream result,
  Accessibility object, Metal command buffer, or debug writer.
- Ten repeated medium slices stabilize within 2% committed-memory variation
  after the second request.

## 6. Mathematical Computation Approach

### Problem & Goals

Small numerical inconsistencies can change contour topology, create missing
walls, reverse holes, or produce unsafe G-code. Mesh input also contains
near-coplanar triangles, duplicate facets, zero-length edges, self-intersections,
and coordinates far from the origin. The numeric policy must distinguish exact
topological decisions from intentional manufacturing tolerances.

### Decisions & Rationale

Use three numeric domains:

- `f64` millimetres for transforms, mesh normalization, layer intersection
  parameters, normals, and geometric measurements.
- Signed 64-bit micrometres for authoritative planar coordinates, layer Z,
  widths, clearances, and G-code quantization.
- Filtered exact predicates or checked `i128` determinants for sign decisions.

No global epsilon exists. Each operation names its tolerance and purpose:
import weld distance, degenerate area, plane ambiguity bound, endpoint snap
grid, minimum printable feature, and G-code output resolution are different
values. Tolerances are settings or derived error bounds, not hidden constants.

Adaptive floating-point predicates calculate a fast error bound and execute an
exact expansion only when the sign remains uncertain. This follows Shewchuk's
method.[^4]
Planar booleans use integer coordinates and explicit even-odd or non-zero fill
rules.

The initial production polygon provider will be a pinned, licensed,
integer-based Clipper2 build behind a narrow C ABI. It supplies early
correctness and an independent differential oracle. An Odin scanbeam provider
can replace it after conformance and performance gates. Vatti's general
scanbeam approach supports arbitrary polygon clipping.[^5]
Weiler–Atherton and basic Greiner–Hormann implementations remain teaching and
test references, not production defaults, because degeneracies require
additional policy.

### Concrete Techniques

- Reject NaN and infinity at decode. Normalize negative zero before hashing or
  serialization. Trap new non-finite values at every stage boundary in debug.
- Translate instances near a local origin before `f32` Metal work. Record the
  transform and scale. Reject a GPU item whose error interval crosses the layer
  plane.
- Apply one half-open intersection convention at vertices and horizontal edges.
  Store coplanar triangles separately and resolve them through adjacent face
  ownership rather than emitting duplicate segments.
- Snap raw intersection endpoints to the micrometre grid only after calculating
  in `f64`. Store the unsnapped error and source triangle in debug evidence.
- Radix-sort snapped endpoints by layer, X, Y, and provenance. Cluster exact
  equal keys first. Apply an explicit repair tolerance only in a separate,
  reported clustering pass.
- Reconstruct loop winding from checked signed area. Classify containment with a
  robust point-in-polygon predicate and deterministic boundary rules.
- Implement union, intersection, difference, XOR, and simplify under both
  even-odd and non-zero fill. Preserve operation provenance on output edges.
- Calculate offsets in integer space. Bound miter joins by a profile limit,
  tessellate round joins by maximum chord error, and run a boolean cleanup under
  the selected fill rule.
- Detect thin walls and gap regions from the difference between source regions
  and printable shell coverage. Generate centerlines only when width and flow
  constraints accept them.
- Calculate curvature-aware layer candidates from face-normal error and cusp
  height, then clamp to printer minimum, maximum, and allowed step. Quantize the
  final Z schedule to micrometres and preserve exact total height.
- Use Odin SIMD or Accelerate for dense vector or raster operations only when
  its data transfer, alignment, and call overhead beat the scalar and manual
  NEON baselines.
- Include the predicate path, tolerance name, operands, error bound, result, and
  affected stable IDs in diagnostic evidence for every reported ambiguity.

| Planar approach | General polygons and holes | Degeneracy policy | Integer fit | Initial role |
|---|---|---|---|---|
| Vatti or Clipper-style scanbeam | Strong | Explicit scanbeam and fill rules | Strong | Chosen semantic model |
| Martínez sweep line | Strong | Requires exact event ordering | Strong | Candidate Odin provider |
| Greiner–Hormann | Strong for normal cases | Basic form fails on overlaps and shared vertices | Moderate | Curriculum and differential fixtures |
| Weiler–Atherton | Useful for simple clipping | Limited without substantial extensions | Moderate | Curriculum only |
| Raster mask | Resolution-dependent | Stable at its chosen grid | Strong | Support and dense-field fallback, not shell geometry |

### Risks & Mitigations

- **Micrometre quantization removes a feature.** Report displacement and removed
  features, and compare it with nozzle and output resolution. Keep the source
  mesh unchanged.
- **`i128` arithmetic still overflows.** Enforce a documented maximum normalized
  coordinate and check differences before multiplication.
- **Third-party polygon semantics leak into contracts.** Define fill, boundary,
  winding, and offset semantics in project tests. Adapt provider output to that
  contract.
- **Adaptive layers create excessive schedules.** Cap schedule variation and
  layer count, then show the reason and expected surface error per layer.
- **Repair masks invalid input.** Keep raw and repaired meshes, make each change
  inspectable, and allow strict mode to stop instead.
- **CPU and GPU classify different signs.** Use error intervals on GPU, replay
  uncertain cases on CPU, and validate the final canonical segments.

### Measurable Acceptance Criteria

- Predicate tests include exact, near-zero, scaled, translated, and randomized
  cases and return the correct sign for 100 million generated inputs.
- The planar kernel passes all conformance fixtures for four boolean operations,
  two fill rules, three join styles, holes, shared edges, overlaps, and
  self-intersections.
- No accepted model coordinate can overflow the checked planar predicate or
  offset intermediate.
- CPU strict, CPU optimized, and Metal-assisted slicing produce identical
  canonical loops on the degeneracy corpus.
- Each topology-changing tolerance has a name, unit, value, source, and evidence
  counter. Hidden numeric tolerances are zero.
- Adaptive schedules meet their configured cusp-height bound on analytic sphere,
  cone, and saddle fixtures after Z quantization.

## 7. Metal Compute Pipeline

### Problem & Goals

Metal must reduce end-to-end slice time without becoming the only correct path.
Apple GPUs execute wide data-parallel work well, while polygon topology, graph
walks, and printer policy contain irregular control flow. The design must batch
enough work to cover command costs, control temporary memory, preserve
deterministic contracts, and expose GPU failures as normal stage evidence.

### Decisions & Rationale

Move a stage to Metal only when all of these conditions hold:

- Its records are independent or use a bounded scan, reduction, or tiled field.
- Input and output can remain contiguous for several passes.
- The CPU can validate a compact result without repeating all GPU work.
- The medium end-to-end benchmark improves by at least 15%.
- A maintained CPU implementation remains within the same stage contract.

The first Metal target is triangle-to-layer pair processing: count spans,
prefix-sum counts, scatter pairs, classify plane crossings, emit unambiguous
segments, and compact uncertain records. Later targets are tiled region
rasterization, exact squared distance transforms, support-field propagation,
field-based infill evaluation, and preview tessellation. Polygon booleans,
offset topology, loop reconstruction, and constrained path ordering remain on
the CPU until a specific benchmark and correctness design justify a move.

Apple documents that threadgroup width and maximum threads come from the
created compute pipeline state. The project will query
`threadExecutionWidth` and `maxTotalThreadsPerThreadgroup` rather than embed a
hardware number.[^6]
Threadgroup memory capacity, supported GPU family, counter availability, and
effective occupancy are **Unknown** for a particular machine until runtime
capability inspection and a calibration benchmark record them.

### Concrete Techniques

- Build one CPU-prepared tile descriptor with local origin, coordinate scale,
  layer Z span, triangle span, count limits, and output capacity. Reject a tile
  before dispatch if any checked capacity calculation fails.
- Use a count, exclusive-scan, and scatter sequence instead of global append
  atomics for variable triangle-layer output. Use hierarchical scans for large
  arrays and retain a scalar oracle.
- Dispatch the classification and intersection kernels over compact
  triangle-layer pairs. Each record writes its source triangle ID, layer ID,
  endpoints, classification, and numeric confidence.
- Calculate an error interval for `f32` plane classification. Compact a record
  to the ambiguity queue if an interval contains zero, an endpoint is not
  finite, a scale limit is exceeded, or output quantization could change its
  topology.
- Read back compact counts and records through shared buffers. Canonicalize,
  snap, stable-sort, and validate on CPU. Re-run only ambiguity records through
  the strict `f64` and exact-predicate path.
- Use shared storage for CPU-populated inputs and compact CPU-consumed outputs.
  Benchmark private storage plus blits for multi-pass raster and distance-field
  intermediates that the CPU does not inspect.
- Triple-buffer command resources by tile generation. Associate a completion
  handler and generation handle with each command buffer. Recycle memory only
  after completion.
- Allocate threadgroup scratch for scan tiles or field halos only after querying
  the device limit. Generate several pipeline specializations and select them
  with a startup microbenchmark cached by hardware and OS build.
- Dispatch multiples of the measured execution width when the grid permits.
  Use non-uniform dispatch only when the runtime GPU family supports it.
- Insert barriers after all threads write shared prefix or halo data and before
  any thread reads it. Keep inter-threadgroup dependencies in separate command
  encoders or command buffers.
- Evaluate Metal Performance Shaders only for documented dense image, reduction,
  or sort operations that match the required semantics. Do not use MPS for
  authoritative polygon geometry. Record the MPS framework and OS version when
  selected.
- Compile `.metal` sources into a release metallib during the build. Use source
  compilation only in development. Cache pipeline states and, when the
  deployment target supports them, binary archives.
- Capture Metal validation messages, command status, pipeline name, tile IDs,
  buffer bounds, ambiguity counts, and signpost times in `Debug_Evidence`.
- Render GPU debug layers from copied evidence buffers, not from transient
  command resources. Views include tile bounds, pair density, slow-path
  locations, field values, dispatch timing, and CPU/GPU diffs.

### Risks & Mitigations

- **Pair expansion consumes excessive memory.** Tile by layer range, preflight
  pair counts, and split a tile before scatter when it exceeds its byte permit.
- **`f32` changes a crossing.** Translate to a local origin, calculate an error
  interval, replay ambiguous work on CPU, and compare canonical output.
- **Synchronization removes speedup.** Batch several passes and tiles per
  command buffer, retain data on GPU between passes, and report CPU wait time.
- **One M-series generation behaves differently.** Query GPU families and
  pipeline properties, keep calibrated specializations, and test the oldest and
  newest supported machines.
- **GPU errors become silent data loss.** Treat non-completed command buffers,
  overflow flags, and validation findings as stage failures that automatically
  retry on CPU.
- **Metal capture changes timing.** Separate correctness captures from release
  timing and retain lightweight counters in normal profile runs.

### Measurable Acceptance Criteria

- Metal-assisted intersection produces the same canonical segment and loop
  hashes as CPU strict mode for the complete benchmark and fuzz corpus.
- Every rejected, ambiguous, overflowed, or failed GPU record reaches the CPU
  fallback or fails the stage with a structured issue. Silent drops are zero.
- Metal intersection is at least 1.6 times faster than CPU intersection on the
  medium fixture and improves medium end-to-end p50 by at least 15%.
- CPU waits for Metal consume less than 10% of medium end-to-end p50 after the
  pipeline reaches steady state.
- No dispatch exceeds queried thread, threadgroup-memory, buffer, or grid limits
  on any supported test machine.
- A forced Metal error completes through the CPU fallback with identical output
  and a diagnostic capture.
- Full Metal validation reports zero API, resource-lifetime, or bounds errors in
  the release candidate suite.

## 8. File I/O and Parsing

### Problem & Goals

STL, OBJ, and 3MF expose different units, indexing, transforms, metadata, and
failure modes. Input can be truncated, maliciously nested, highly compressed,
or larger than memory. G-code output can contain millions of stateful commands
and must not leave a valid-looking partial file after cancellation or failure.

### Decisions & Rationale

Each format provider writes one canonical scene contract containing source
units, objects, instances, transforms, indexed meshes, materials, metadata, and
issues. Parsing and model normalization are separate stages. The parser
preserves source locations and identifiers so later geometric defects resolve
to an input record.

Binary STL and large uncompressed arrays can use read-only `mmap` after size
validation. ASCII STL and OBJ use a bounded streaming lexer. 3MF uses a bounded
ZIP and XML pull path with entity expansion disabled. Implement the published
3MF Core 1.3.0 conformance set first, then evaluate the consortium's current
revision and required extensions as explicit provider versions. The consortium
publishes core and extension revisions together.[^7]

G-code writes to a staging file through a large sequential buffer. The writer
owns one explicit machine-state model and a dialect provider. Validation
re-parses the staged output, checks state and bounds, flushes it, then atomically
replaces the selected destination when the file system permits.

### Concrete Techniques

- Detect binary STL from validated length and record structure rather than the
  header text alone. Check `84 + triangle_count × 50` with overflow-safe
  arithmetic before mapping records.
- Parse ASCII numbers with locale-independent rules and reject non-finite
  values. Record byte offsets, line and column where the format provides text.
- Parse OBJ continuation, relative indices, groups, objects, smoothing groups,
  material references, polygons, and independent position, texture, and normal
  indices. Triangulate faces through a validated planar projection and preserve
  the source face ID.
- Parse 3MF ZIP central-directory and entry metadata under limits for entries,
  uncompressed bytes, compression ratio, path length, nesting, and total mesh
  counts. Reject traversal paths and duplicate critical parts.
- Validate OPC content types, relationships, model parts, units, resource IDs,
  component graphs, transforms, build items, and required extensions. Detect
  component cycles before instantiation.
- Disable external XML entities, DTD retrieval, and network access. Bound XML
  depth, attributes, text length, and numeric counts.
- Preserve unknown optional 3MF namespaces and metadata in the project document.
  Stop when an unknown required extension changes geometry semantics.
- Read large sources on a utility queue and parse into provider-owned chunks.
  Submit normalized generations to the pipeline through a bounded handoff.
  Use GCD for coarse I/O completion, not one task per line or triangle.
- Calculate SHA-256 while reading. Cache only after the complete input validates.
  Include source hash, parser revision, unit transform, and issue counts in the
  stage manifest.
- Define printer, process, material, and G-code dialect profiles as separate,
  versioned documents. Resolve inheritance before slicing and serialize the
  normalized result into the request hash.
- Format decimal output with an explicit precision and rounding rule. Normalize
  line endings by dialect. Never use the process locale.
- Maintain G-code state for position, extrusion mode, coordinate mode, active
  tool, temperature, fan, acceleration, feed rate, and comments correlated to
  stable path IDs.
- Implement optional line numbers and checksums in dialect providers that
  require them. Do not add them to dialects that do not.
- Write an adjacent JSON manifest with source, settings, engine, provider and
  output hashes, estimated time, filament use, bounding boxes, warnings, and
  debug-capture reference.

### Risks & Mitigations

- **ZIP bombs exhaust memory or disk.** Enforce declared and observed limits,
  compression-ratio limits, byte permits, and cancellation during inflate.
- **OBJ triangulation changes a non-planar face.** Report the projection error,
  preserve the source polygon, and render its triangulation evidence.
- **3MF vendor metadata changes print meaning.** Preserve unknown metadata, add
  explicit vendor adapters only behind versioned providers, and warn when
  unsupported required semantics appear.
- **mmap input changes during slicing.** Open one file descriptor, record
  identity and size, and copy or fail if validation detects mutation.
- **A failed write replaces valid G-code.** Stage in the destination directory,
  validate, sync, and replace only after success. Keep the old file on any
  failure.
- **A dialect emits unsafe state.** Re-parse generated commands and enforce
  profile bounds, finite coordinates, valid tool state, monotonic line numbers,
  and configured extrusion limits.

### Measurable Acceptance Criteria

- All official or licensed STL, OBJ, and 3MF conformance fixtures produce their
  expected canonical scenes or documented errors.
- Parser fuzzing executes at least 100 million inputs per format without a
  crash, hang, out-of-bounds access, or configured-limit bypass.
- A 10 GiB declared ZIP bomb and a cyclic 3MF component graph fail before mesh
  allocation exceeds 64 MiB.
- Binary STL decode sustains at least 1 GiB/s from the file cache on the
  reference development Mac, excluding hashing, or records the measured storage
  limit when lower.
- G-code formatting sustains at least 500 MiB/s to a memory sink and performs
  zero per-command heap allocations.
- Cancelling or injecting a write failure preserves the previous destination
  file byte for byte.
- Re-parsing every release-corpus G-code file produces the same final state,
  motion bounds, command count, and output hash recorded in its manifest.

## 9. GUI Framework Considerations

### Problem & Goals

The application needs native macOS input, menus, text, IME, Accessibility, file
security, and window behavior while rendering millions of triangles, paths,
fields, and diagnostic overlays. It also needs deterministic offscreen views
that represent stage evidence without depending on window size or transient UI
state.

### Decisions & Rationale

Use a thin AppKit host with a project-owned immediate-mode UI and direct Metal
renderer. AppKit creates the window, menu, panels, drag regions, event bridge,
Accessibility elements, and `CAMetalLayer`. Core Text shapes Iosevka interface
text. Metal renders the model, toolpaths, fields, controls, and overlays.

SDL2 would reduce some window and input work but adds a shipped dependency and
still needs AppKit for native menus, file panels, Accessibility, complete IME,
and project window behavior. `wgpu-metal` is a rendering abstraction, not a GUI
framework. It adds portability and shader translation but does not solve those
macOS services. Direct Metal is the default because Metal compute is already a
core dependency and the first target is macOS-only.

| Option | Native menus, panels, IME, Accessibility | Metal and offscreen control | Dependency and FFI cost | Portability value | Decision |
|---|---|---|---|---|---|
| AppKit host + direct Metal | Complete through native host and project bridge | Direct access and lowest abstraction cost | Objective-C shim and bindings | Low | **Default** |
| SDL2 + Metal | Requires AppKit supplements for product requirements | Good native Metal window access | Shipped C library plus AppKit bridge | Medium | Rejected for initial UI |
| AppKit host + wgpu-metal | AppKit still supplies all native services | Portable render abstraction with extra translation layer | Rust/C ABI or native wgpu distribution | High | Keep behind future renderer boundary |

The main workspace has four synchronized regions: a 3D source and feature view,
a 2D layer view, a stage timeline, and an evidence inspector. Selecting a stage,
layer, issue, or stable ID updates every region through immutable view state.

### Concrete Techniques

- Reuse `hw_odin_ui_flash`, `hw_odin_ui_commandPalette`, and the established
  control registry through pinned sibling commits. Construct each visible
  control once and derive pointer, keyboard, Accessibility, and Flash behavior
  from that record.
- Use the required light and dark neutral themes and the Sand, Stone, Coffee,
  Ochre, Gum, Moss, Forest, and Basalt accents. Use fill and spacing for normal
  boundaries. Reserve colored borders for focus, selection, and exceptional
  actions.
- Use these exact light neutrals: Canvas `#CCC7B8`, header and modal
  `#E8E3D1`, surface `#E0DBC9`, raised surface `#D9D4C2`, control
  `#D4CFBD`, text `#262528`, and muted text `#7A756B`.
- Use these exact dark neutrals: Canvas `#0A0B0A`, header `#080908`, surface
  and modal `#0E0F0E`, raised and control `#111211`, overlay `#050605`, text
  `#F7F2E0`, and muted text `#787D75`.
- Use accent values Sand `#E1D9C9`, Stone `#AE9372`, Coffee `#B27D57`, Ochre
  `#7F4B30`, Gum `#7D8769`, Moss `#424C21`, Forest `#173125`, and Basalt
  `#212E40`. Keep accents off alternating base surfaces.
- Show selected rows with their normal fill and a four-point leading accent.
  Show active progress as a four-point Coffee bottom edge without an unfilled
  track. Preserve the complete action rectangle.
- Draw no neutral panel, field, button, modal, or inactive-option border when
  fill and spacing define the boundary. Keep action bars and primary regions
  inside the standard compact outer margin.
- Provide custom Iconoir `xmark`, `minus`, and `maximize` window controls. Use a
  square, shadowless window and one title-strip fill-and-restore action for
  double-click and maximize.
- Put stable two-digit actions in the inset bottom action bar. The initial slots
  are Open, Slice, Cancel, Capture, Compare, and Export. Preserve disabled
  positions. Keep continuous layer and camera controls outside the numbered
  contract.
- Add the `DARK` or `LIGHT` control, command palette, Flash navigation, durable
  notifications, contextual Help, and local preference persistence from the
  workspace standards.
- Render Flash badges at 18 points. Calculate width as the larger of 16 points
  and `8 + 8 × label length`, inset the anchor by two points, and clamp the
  complete badge to the view. Use the workspace's separate normal and selected
  Flash colors.
- Bundle one exact Iosevka Regular file and only the used Iconoir Regular SVG
  sources. Record each version, source, SHA-256, and adjacent license before the
  first distributable build.
- Shape and measure one complete glyph run, then place it from its destination
  rectangle. Keep text layout independent from the Core Text backend contract.
- Render on demand while idle. During orbit, scrub, or active slicing, schedule
  frames through the display link and limit in-flight drawables. Never wait for
  a slice worker or Metal compute command on the main thread.
- Keep compute and render command ownership separate. Render immutable published
  stage generations. Do not read a buffer that a compute pass still mutates.
- Implement stable camera, layer, stage, color-map, and evidence-filter
  descriptors. Canonical debug renders use fixed descriptors from the capture,
  not current interactive state.
- Render vector layer evidence to SVG through the debug renderer and raster 3D
  evidence to PNG through an offscreen Metal target. Include units, origin,
  scale, legend, stage, layer, request hash, and highlighted stable IDs.
- Use `NSOpenPanel` and `NSSavePanel` for source, project, G-code, and debug
  package workflows. Store security-scoped bookmarks only if the sandboxed
  product must reopen a user-selected source.

| Pipeline stage | Human view | Structured and AI-readable evidence |
|---|---|---|
| Decode | Source objects, instances, transforms, materials, and invalid records | Counts, units, source offsets, relationship graph, warnings |
| Normalize and repair | Before/after mesh overlay, normals, holes, non-manifold and changed edges | Repair operations, displacement, volume delta, affected source IDs |
| Layer schedule and acceleration | Layer planes, cusp-error colors, triangle span heat map, BVH boxes | Layer reasons, span histograms, node occupancy, bounds |
| Intersections | Raw segments by class, coplanar faces, rejected and ambiguous items | Triangle and edge provenance, predicate path, error interval |
| Topology | Endpoint clusters, directed graph, open chains, degree anomalies, loops | Adjacency spans, winding, containment, invariant failures |
| Booleans and offsets | Operands, scan events, fill state, joins, self-intersection cleanup | Operation tree, fill rule, event order, edge lineage |
| Print features | Perimeters, thin walls, skin, bridges, infill, supports, modifier ownership | Role, settings provenance, width, spacing, field values |
| Path planning | Ordered extrusion and travel, seam, retraction, speed, flow, tool state | Cost components, constraint decisions, state transitions |
| G-code | Command cursor correlated with path and simulated machine state | Parsed command, source path ID, bounds, estimates, warnings |
| Metal | Tile bounds, pair density, fallback points, fields, CPU diff | Dispatch shape, resource sizes, timings, counters, command status |

### Risks & Mitigations

- **Debug detail overwhelms the interface.** Default to stage summaries and
  issues. Filter by layer, role, issue, stable ID, or bounding box before loading
  primitives.
- **The custom UI loses native behavior.** Keep menus, file panels, IME handoff,
  Accessibility actions, and security workflows in AppKit. Test them separately.
- **Compute work causes frame stalls.** Publish immutable generations, bound GPU
  work per command buffer, and prioritize the render queue during interaction.
- **Interactive and canonical views disagree.** Drive both from the same
  `Debug_Evidence` scene and use explicit view descriptors.
- **Large paths exceed render memory.** Build level-of-detail spans by layer and
  role, cull by viewport, and stream visible tiles.
- **A rebuild interrupts transient work.** Persist durable project state through
  normal storage. Relaunch only after a successful complete build.

### Measurable Acceptance Criteria

- The main thread spends no interval longer than 8 ms waiting for slicing,
  debug writing, or compute completion during the medium benchmark.
- Camera and layer interaction maintain p95 frame time below 16.7 ms at
  2560 × 1600 points with 10 million visible line segments after level-of-detail
  selection.
- Every visible discrete control appears once in the control registry with a
  unique functional name and matching pointer, Accessibility, Flash, and
  numbered-action behavior where applicable.
- Every pipeline stage in the evidence table has at least one deterministic
  render fixture and one structured summary fixture.
- Rendering the same capture twice produces byte-identical SVG and
  pixel-identical canonical PNG output on the same renderer and OS build.
- An AI review package can identify an injected open contour from
  `summary.json`, locate its stable ID in the layer SVG, and resolve its source
  triangles without opening the application.
- Structural UI checks pass across idle, slicing, cancelled, issue-selected,
  comparison, export, dark-theme, and light-theme states.

## 10. Odin Limitations Analysis

### Problem & Goals

The project depends on evolving compiler tooling, direct ABI work, complex
debugging, shader compilation, and a large test matrix. The plan must isolate
these costs so they do not turn core geometry into build-system or platform
code.

### Decisions & Rationale

Treat the compiler, language server, debugger, package discovery, and framework
bindings as pinned infrastructure with smoke tests. Keep the application build
as explicit scripts and small tools rather than introduce a speculative general
build framework. Keep Objective-C syntax and block ABI details in shims.

Odin's official FAQ states that it has no official package manager.[^8]
Dependency reproducibility
therefore comes from repository pins, vendoring, checksums, and build-time
verification. Parametric procedures remain useful for containers and numeric
helpers, but hot geometry kernels use concrete types so generated code and
debugger behavior remain inspectable.

### Concrete Techniques

- Add compiler fixtures for foreign callbacks, Objective-C shims, ARM64 SIMD,
  `i128`, atomics, thread-local context, sanitizers, dylib export, dSYM
  generation, and Metal structure layouts.
- Keep one generated binding source and one typed shim per required framework
  surface. Check SDK size and offset assertions at build or startup.
- Put AppKit classes, Objective-C callback trampolines, frame timing, run loop,
  and Accessibility bridge in a typed platform shim. Link that shim and the
  Odin application into one executable.
- Rebuild the complete application after source or resource changes. Replace
  the running process only after a successful build.
- Archive the executable and dSYM with each crash.
- Generate and archive optimized LLVM or ARM64 assembly for designated kernels.
  Fail a performance-review check if a kernel unexpectedly loses SIMD or gains
  stack spills above its accepted record.
- Use LLDB-DAP or LLDB for source debugging, ASan for memory faults, allocator
  modes for guard pages and scribble, Zombies for Objective-C lifetime, Metal
  validation for GPU APIs, and debug-evidence replay for deterministic geometry.
- Implement repository-local `build.sh`, `test.sh`, `dev.sh`, benchmark, capture,
  dependency-check, package, and release commands. Each command emits a compact
  machine-readable result where automation consumes it.
- Record every bundled compiler-independent asset in the README with version,
  source URL, SHA-256, and adjacent license. This includes Iosevka, Iconoir,
  polygon providers, archive or XML libraries, profiles, and benchmark models.
- Sign release Mach-O files from the inside out with a Developer ID Application
  identity and hardened runtime. Do not include development watcher tooling or
  `get-task-allow` in release.
- Submit the signed archive with `notarytool`, inspect the notarization log,
  staple the ticket, verify signatures, and run Gatekeeper assessment. Apple
  requires Developer ID signing and hardened runtime for notarized direct
  distribution.[^9]
- Start with direct Developer ID distribution without App Sandbox. Maintain a
  sandbox test configuration because a later Mac App Store build would require
  user-selected file entitlements and security-scoped bookmarks. Apple
  documents that open and save panels extend sandbox access to selected URLs
  through explicit user action.[^10]

### Risks & Mitigations

- **A compiler update breaks ABI or code generation.** Run the smoke, correctness,
  assembly, and benchmark gates before changing the pin.
- **Generated bindings drift from SDK headers.** Pin the SDK for release, include
  generated-source provenance, and assert ABI sizes and offsets.
- **Debuggers cannot explain optimized geometry.** Preserve checked scalar
  paths, stage captures, replay commands, symbols, and minimized fuzz cases.
- **Development settings conflict with release security.** Keep validation and
  diagnostic settings in development builds. Package one fixed signed engine
  in release.
- **Build scripts become an opaque build system.** Keep each script narrow,
  fail on unknown modes, print invoked tool versions, and test clean builds.
- **External providers block notarization or licensing.** Prefer source-built
  static libraries with compatible licenses and audit all nested code before
  release.

### Measurable Acceptance Criteria

- Every compiler upgrade passes the infrastructure smoke suite, full
  correctness suite, ABI assertions, and benchmark regression gate before its
  commit changes.
- A deterministic crash fixture archives the exact executable or dylib, dSYM,
  UUID, Git revision, request manifest, and debug capture.
- Debug and ASan watchers rebuild the complete application and relaunch it
  behind active applications only after a successful build.
- The release bundle contains only signed expected Mach-O files and no writable
  or unsigned executable code.
- `codesign --verify`, notarization, stapling, and Gatekeeper assessment pass for
  the distributed archive.
- A quarantined release opens, slices the small benchmark, writes G-code through
  a native save panel, reopens its project, and validates its debug capture on a
  clean supported Apple Silicon Mac.

## 11. Cross-Platform Implications (Deferred)

### Problem & Goals

The current target is macOS on Apple Silicon. Some early choices can still make
later Windows or Linux work unnecessarily invasive. The project should isolate
platform dependencies now without adding unrequested backends, shaders, or
lowest-common-denominator behavior.

### Decisions & Rationale

Portability is a boundary rule, not a current deliverable. Canonical geometry,
profiles, project documents, G-code, debug evidence, benchmark manifests, and
stage semantics remain platform-neutral. Windowing, file security, timers,
threads, virtual memory, dynamic loading, crash capture, SIMD specialization,
and compute or render backends sit behind narrow providers.

Direct Metal remains the only implemented GPU backend. A renderer or compute
contract must describe data and synchronization needs without exposing
`MTLBuffer`, command encoders, or Objective-C objects to the pipeline. A later
wgpu, Direct3D, or Vulkan investigation can implement that contract after it
proves required semantics and performance. No current code will pretend those
backends exist.

### Concrete Techniques

- Keep platform-neutral packages free of AppKit, Core Foundation, GCD, Mach,
  Metal, POSIX file descriptors, and security-scoped URL types.
- Represent files in core requests as opened byte sources, output sinks, or
  stable project resource handles. Resolve native paths and bookmarks in the
  platform layer.
- Define monotonic clocks, signposts, threads, semaphores, memory reservation,
  mapped files, process information, and crash artifacts under
  `platform`.
- Define compute buffers, dispatch descriptors, fences, capabilities, and
  completion records in a backend-neutral stage-provider contract. Keep
  Metal-specific storage modes and pipeline objects private.
- Keep Metal Shading Language source beside the Metal provider. Share generated
  constants and schema tests, not a preprocessor language pretending to target
  every GPU API.
- Keep NEON kernels beside scalar kernels under one CPU provider. A future SIMD
  provider must pass the same conformance and canonicalization gates.
- Serialize little-endian debug arrays with explicit byte widths and alignment.
  Readers swap bytes when required. Do not serialize native pointers, `int`,
  enum layout, or framework types.
- Keep project and profile schemas tolerant of unknown optional fields and strict
  about required semantic versions. Use the same schema corpus on every future
  platform.
- Use forward slashes and logical resource IDs inside project and debug packages.
  Let the platform layer create legal native paths.
- Record deferred portability issues in provider manifests and architecture
  tests. Do not build unused abstraction layers beyond the named boundaries.

### Risks & Mitigations

- **Metal semantics leak through buffer contracts.** Review core APIs for Metal
  names and make CPU fake providers compile without Metal imports.
- **AppKit ownership shapes application state.** Store project and view state in
  plain engine records. Let the host retain only native objects and stable
  handles.
- **Integer geometry differs by compiler.** Specify widths, overflow behavior,
  rounding, and serialization. Run golden stage fixtures on each future target.
- **Portable abstractions reduce Apple performance.** Permit provider-private
  layouts and extensions. Canonicalize only at stage boundaries.
- **A future port needs different threading.** Keep scheduler semantics separate
  from the initial worker implementation and test with a serial scheduler.
- **Deferred work becomes implied support.** Label non-macOS providers and
  packaging as out of scope until a separate plan defines their product,
  performance, and QA requirements.

### Measurable Acceptance Criteria

- A platform-dependency check finds zero macOS or Metal imports in `contracts`,
  canonical geometry, profiles, G-code semantics, and debug-schema packages.
- The complete engine correctness suite runs with a serial CPU scheduler and a
  fake compute provider.
- Debug packages contain no native pointers, path separators with platform
  meaning, or unspecified native-size integers.
- A second CPU implementation can consume every stage contract without linking
  AppKit or Metal.
- Cross-platform work remains outside release scope until a reviewed plan adds
  its target, benchmark floor, native UI policy, GPU backend, and distribution
  gates.

[^1]: Odin Project, “Overview,” current documentation,
  <https://odin-lang.org/docs/overview/>.
[^2]: Apple, “Analyzing the Performance of Your Metal App,” current
  documentation,
  <https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app/>.
[^3]: Apple, “Resource Fundamentals,” current documentation,
  <https://developer.apple.com/documentation/metal/resource-fundamentals>.
[^4]: Shewchuk, “Adaptive Precision Floating-Point Arithmetic and Fast Robust
  Geometric Predicates,” 1997,
  <https://doi.org/10.1007/PL00009321>.
[^5]: Vatti, “A Generic Solution to Polygon Clipping,” 1992,
  <https://doi.org/10.1145/129902.129906>.
[^6]: Apple, “Calculating Threadgroup and Grid Sizes,” current documentation,
  <https://developer.apple.com/documentation/metal/calculating-threadgroup-and-grid-sizes>.
[^7]: 3MF Consortium, “Specifications,” current index,
  <https://3mf.io/spec/>.
[^8]: Odin Project, “Frequently Asked Questions,” current documentation,
  <https://odin-lang.org/docs/faq/>.
[^9]: Apple, “Notarizing macOS Software Before Distribution,” current
  documentation,
  <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>.
[^10]: Apple, “Accessing Files from the macOS App Sandbox,” current
  documentation,
  <https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox>.

## Research & Learning Curriculum

## C0. Overview & Principles

- Execute the curriculum in dependency order: floating-point behavior, robust
  geometry, mesh processing, planar topology, acceleration, manufacturing
  semantics, path planning, CPU performance, Metal, platform integration, and
  verification.
- Convert every lab into a real slicer artifact. Its fixtures, oracle,
  benchmark, evidence schema, and failure renders enter the project repository
  when they meet the module rubric.
- Allocate 12–15 focused hours each week. Complete the 2-hour diagnostic first,
  then budget approximately 738 hours across modules and a 60-hour capstone.
  The labs and milestones become project implementation, so this is not 798
  hours of work before development starts.
- Read primary papers to recover assumptions and invariants. Use textbooks and
  courses to connect them. Do not port an algorithm until its input model,
  degeneracy policy, complexity, and validation method are written down.
- Run each optimized lab on Apple Silicon with checked scalar, optimized CPU,
  and applicable Metal paths. Preserve raw measurements and canonical outputs.

## C1. Prerequisites & Diagnostic

### Readiness checklist

- Calculate dot products, cross products, affine transforms, plane
  intersections, signed polygon area, and barycentric coordinates.
- Explain IEEE 754 rounding, ULPs, cancellation, overflow, underflow, NaN, and
  why a fixed epsilon cannot prove an orientation sign at every scale.
- Implement arrays, slices, arenas, hash tables, radix sort, graphs, queues, and
  binary parsers in Odin or C.
- Read ARM64 assembly for loads, stores, branches, scalar floating-point, NEON,
  and procedure calls.
- Explain cache locality, false sharing, atomic ordering, work partitioning,
  prefix sums, and bounded producer-consumer queues.
- Build and profile a Metal compute kernel, inspect a GPU capture, and describe
  buffer ownership across one command buffer.
- Read a binary format specification, derive overflow checks, and construct
  malformed fixtures.
- Design unit, property, differential, fuzz, benchmark, and golden tests as
  different forms of evidence.

### Two-hour diagnostic

1. **Minutes 0–20, numeric execution.** Derive the error-sensitive form of a
   triangle-plane intersection. Explain when `f32` classification can disagree
   with `f64`. Expected output names cancellation, scale, a computed error
   bound, and an exact or higher-precision fallback.
2. **Minutes 20–40, topology.** Given six segments with one duplicate and one
   T-junction, construct endpoint clusters and directed adjacency. Expected
   output identifies degrees, closed loops, open chains, winding, and a
   deterministic branch rule.
3. **Minutes 40–60, data layout.** Lay out ten million triangles for a Z-range
   scan on M-series CPU and GPU. Expected output separates persistent indexed
   mesh data from a transient SoA, names alignment and ownership, and calculates
   bytes read.
4. **Minutes 60–80, parallel pipeline.** Design count, prefix-sum, and scatter
   for triangle-layer pairs. Expected output proves bounds, describes
   synchronization, and preserves deterministic IDs.
5. **Minutes 80–100, format safety.** Review a binary STL length and a
   compressed 3MF entry. Expected output detects integer overflow, truncation,
   compression bombs, path traversal, and XML entity hazards.
6. **Minutes 100–120, verification.** Define evidence for a GPU intersection
   speedup claim. Expected output includes a scalar oracle, canonical output
   comparison, end-to-end timing, warm-up, sample distribution, thermal state,
   and CPU-GPU wait time.

Score each block from 0 to 3: 0 means no operational answer, 1 names concepts,
2 gives a correct procedure, and 3 gives a correct procedure with bounds and a
verification method. A score below 12 starts with remediation. A score from 12
to 15 permits modules M1–M4 with their full labs. A score above 15 permits
reading compression but does not waive labs or acceptance tests.

### Remediation

- For numeric or geometry gaps, complete M1 before any production predicate
  work and add 12 hours of exercises from Higham and de Berg.
- For data-structure gaps, implement a checked arena, radix sort, dense graph,
  and bounded queue before M4. Require ASan and property tests.
- For ARM64 or performance gaps, complete the scalar-to-NEON lab in M8 and use
  Time Profiler plus assembly inspection before interpreting a benchmark.
- For Metal gaps, complete Apple's compute samples and M9's scan lab before any
  slicer kernel moves to GPU.
- For test-design gaps, complete M12's differential-fuzz lab first and attach
  its reducer to every earlier module.

## C2. Core Topics & Modules

### M1. Floating-Point Execution and Robust Predicates

**Title & Goal**

Build an explicit numeric policy for ARM64 CPU and Metal execution. Implement
filtered orientation and plane-side predicates that return a proven sign or
invoke an exact fallback.

**Why it matters to this slicer**

Plane classification, segment joining, winding, containment, scan-event order,
and offset cleanup all mutate topology from numeric signs. One wrong sign can
remove a contour or connect two islands.

**Primary Readings**

1. IEEE Computer Society. *IEEE Standard for Floating-Point Arithmetic,
   IEEE 754-2019*, 2019.
   [DOI 10.1109/IEEESTD.2019.8766229](https://doi.org/10.1109/IEEESTD.2019.8766229).
   This defines rounding, exceptions, formats, and reproducibility limits.
2. Goldberg, D. “What Every Computer Scientist Should Know About
   Floating-Point Arithmetic.” *ACM Computing Surveys* 23(1), 1991.
   [DOI 10.1145/103162.103163](https://doi.org/10.1145/103162.103163).
   This connects representation error to concrete program transformations.
3. Shewchuk, J. R. “Adaptive Precision Floating-Point Arithmetic and Fast
   Robust Geometric Predicates.” *Discrete & Computational Geometry* 18, 1997.
   [DOI 10.1007/PL00009321](https://doi.org/10.1007/PL00009321).
   This supplies expansion arithmetic and adaptive sign tests.
4. Fortune, S., and van Wyk, C. J. “Efficient Exact Arithmetic for
   Computational Geometry.” *SCG '93*, 1993.
   [DOI 10.1145/160985.160998](https://doi.org/10.1145/160985.160998).
   This shows how expression analysis produces exact geometric decisions.
5. Priest, D. M. “Algorithms for Arbitrary Precision Floating Point
   Arithmetic.” *10th IEEE Symposium on Computer Arithmetic*, 1991.
   [DOI 10.1109/ARITH.1991.145565](https://doi.org/10.1109/ARITH.1991.145565).
   This gives the arithmetic operations behind expansion methods.
6. Ogita, T., Rump, S. M., and Oishi, S. “Accurate Sum and Dot Product.”
   *SIAM Journal on Scientific Computing* 26(6), 2005.
   [DOI 10.1137/030601818](https://doi.org/10.1137/030601818).
   This provides error-free transforms for reductions used in measurements.

**Secondary Readings**

- Higham, N. J. *Accuracy and Stability of Numerical Algorithms*, 2nd ed.,
  SIAM, 2002. ISBN 978-0-89871-521-7.
- Muller, J.-M. et al. *Handbook of Floating-Point Arithmetic*, 2nd ed.,
  Birkhäuser, 2018. ISBN 978-3-319-76525-9.
- Eberly, D. *Geometric Tools for Computer Graphics*, Morgan Kaufmann, 2002.
  ISBN 978-1-55860-594-7.

**Courses**

- MIT 18.335J, *Introduction to Numerical Methods*, Fall 2019, Lectures 1–3 on
  floating-point arithmetic, conditioning, and stability.
- UC Berkeley CS 267, Spring 2024, Lectures 2–4 on sources of error, dense
  arithmetic, and performance models.
- CMU 15-458/858, *Discretization in Geometry and Dynamics*, Lectures 1–3 on
  orientation, discrete geometry, and robust construction.

**Hands-on Labs**

1. **Predicate filter lab.** Input: scaled and translated 2D and 3D point sets
   with exact rational reference signs. Output: scalar `f64` filter, error bound,
   expansion fallback, counters, and `.hwsdebug` failure render. Acceptance:
   correct signs for 100 million cases and zero fallback omissions. Performance:
   at least 50 million 2D orientation filters/s on the reference Mac. Rubric:
   40% correctness, 25% proof of bound, 20% performance, 15% evidence quality.
2. **Plane classifier lab.** Input: triangle-layer pairs with controlled ULP
   distance and coordinate scale. Output: CPU strict and simulated `f32`
   classification plus ambiguity queue. Acceptance: every disagreement is
   classified ambiguous before output. Performance: ambiguity compaction adds
   less than 10% time at a 1% ambiguity rate. Rubric: 45% classification,
   25% fallback completeness, 20% throughput, 10% visualization.

**Milestone Project**

Promote the predicate package, numeric-mode manifest, NaN boundary checks, and
plane-classification microbenchmark into Sections 4 and 6 of the real slicer.
It passes when the degeneracy corpus produces stable signs across worker counts
and optimization levels.

**Time Estimate**

Readings: 18 hours. Courses and exercises: 10 hours. Labs: 24 hours. Milestone:
8 hours. Total: 60 hours.

### M2. Mesh Processing, Repair, and Sectioning

**Title & Goal**

Convert triangle soups and indexed models into an inspectable canonical scene.
Detect topology defects, apply bounded repairs, and derive reliable layer
intersections without losing source provenance.

**Why it matters to this slicer**

Modern input contains duplicated vertices, inconsistent winding, non-manifold
edges, self-intersections, component transforms, and non-planar source faces.
Repair policy determines whether later contours describe the intended solid.

**Primary Readings**

1. Dolenc, A., and Mäkelä, I. “Slicing Procedures for Layered Manufacturing
   Techniques.” *Computer-Aided Design* 26(2), 1994.
   [DOI 10.1016/0010-4485(94)90032-9](https://doi.org/10.1016/0010-4485(94)90032-9).
   This establishes layer-section cases and manufacturing-oriented slicing.
2. Tata, K., Fadel, G., Bagchi, A., and Aziz, N. “Efficient Slicing for Layered
   Manufacturing.” *Rapid Prototyping Journal* 4(4), 1998.
   [DOI 10.1108/13552549810239003](https://doi.org/10.1108/13552549810239003).
   This studies direct triangle-layer organization and slicing cost.
3. Attene, M. “A Lightweight Approach to Repairing Digitized Polygon Meshes.”
   *The Visual Computer* 26, 2010.
   [DOI 10.1007/s00371-010-0416-3](https://doi.org/10.1007/s00371-010-0416-3).
   This provides a practical classification of repair operations.
4. Ju, T. “Robust Repair of Polygonal Models.” *ACM Transactions on Graphics*
   23(3), 2004.
   [DOI 10.1145/1015706.1015815](https://doi.org/10.1145/1015706.1015815).
   This supplies a volumetric repair path for difficult non-watertight input.
5. Barequet, G., and Kumar, S. “Repairing CAD Models.” *IEEE Visualization
   '97*, 1997.
   [DOI 10.1109/VISUAL.1997.663888](https://doi.org/10.1109/VISUAL.1997.663888).
   This links crack detection and stitching to manufacturing models.
6. Campen, M., and Kobbelt, L. “Exact and Robust (Self-)Intersections for
   Polygonal Meshes.” *Computer Graphics Forum* 29(2), 2010.
   [DOI 10.1111/j.1467-8659.2009.01609.x](https://doi.org/10.1111/j.1467-8659.2009.01609.x).
   This gives a robust basis for detecting intersecting input surfaces.

**Secondary Readings**

- Botsch, M. et al. *Polygon Mesh Processing*, A K Peters, 2010.
  ISBN 978-1-56881-426-1.
- Kettner, L. “Using Generic Programming for Designing a Data Structure for
  Polyhedral Surfaces.” *Computational Geometry* 13, 1999.
  [DOI 10.1016/S0925-7721(99)00007-3](https://doi.org/10.1016/S0925-7721(99)00007-3).
- Ericson, C. *Real-Time Collision Detection*, Morgan Kaufmann, 2005.
  ISBN 978-1-55860-732-3.

**Courses**

- Carnegie Mellon 15-462, Fall 2020, Lectures 9–11 on geometry representations,
  meshes, and spatial data structures.
- Stanford CS 468, Spring 2013, Lectures 2–5 on mesh data structures,
  differential properties, smoothing, and remeshing.
- ETH Zürich *Shape Modeling and Geometry Processing*, Weeks 1–3 on polygon
  meshes, topology, and repair.

**Hands-on Labs**

1. **Canonical mesh lab.** Input: STL and OBJ fixtures with duplicates,
   reversed components, non-manifold edges, holes, and zero-area faces. Output:
   indexed mesh, defect table, stable IDs, and before/after render. Acceptance:
   exact expected counts and no unreported mutation. Performance: normalize
   five million triangles in under 5 seconds. Rubric: 35% topology, 25%
   provenance, 20% safety, 20% throughput.
2. **Sectioning lab.** Input: analytic cubes, spheres, vertex-on-plane meshes,
   coplanar sheets, and repaired fixtures. Output: classified raw segments with
   triangle provenance. Acceptance: expected analytic contour and half-open
   behavior at every layer. Performance: at least 100 million rejected or
   crossing pairs/s in the optimized CPU path. Rubric: 45% correctness, 20%
   degeneracies, 20% performance, 15% evidence.

**Milestone Project**

Integrate canonical scene generations, repair reports, source-stable IDs, and
the first two stage views. This becomes the decode and normalize spine used by
the capstone.

**Time Estimate**

Readings: 16 hours. Courses: 8 hours. Labs: 26 hours. Milestone: 10 hours.
Total: 60 hours.

### M3. Planar Topology, Polygon Clipping, and Offsetting

**Title & Goal**

Construct deterministic loops from segments, evaluate containment and fill
rules, execute polygon booleans, and generate robust offsets in integer space.

**Why it matters to this slicer**

Perimeters, skin, infill clipping, support masks, modifiers, and thin-wall
coverage all depend on planar sets. A fast intersection kernel has no value if
the planar kernel emits invalid or differently wound regions.

**Primary Readings**

1. Vatti, B. R. “A Generic Solution to Polygon Clipping.” *Communications of
   the ACM* 35(7), 1992.
   [DOI 10.1145/129902.129906](https://doi.org/10.1145/129902.129906).
   This defines a general scanbeam model for complex polygons.
2. Greiner, G., and Hormann, K. “Efficient Clipping of Arbitrary Polygons.”
   *ACM Transactions on Graphics* 17(2), 1998.
   [DOI 10.1145/274363.274364](https://doi.org/10.1145/274363.274364).
   This gives a compact intersection-entry traversal and exposes its assumptions.
3. Sutherland, I. E., and Hodgman, G. W. “Reentrant Polygon Clipping.”
   *Communications of the ACM* 17(1), 1974.
   [DOI 10.1145/360767.360802](https://doi.org/10.1145/360767.360802).
   This supplies the baseline clipping pipeline for convex clip regions.
4. Martínez, F., Rueda, A. J., and Feito, F. R. “A New Algorithm for Computing
   Boolean Operations on Polygons.” *Computers & Geosciences* 35(6), 2009.
   [DOI 10.1016/j.cageo.2008.08.009](https://doi.org/10.1016/j.cageo.2008.08.009).
   This presents a sweep-line alternative for arbitrary polygon sets.
5. Chen, X., and McMains, S. “Polygon Offsetting by Computing Winding Numbers.”
   *ASME International Design Engineering Technical Conferences*, 2005.
   [DOI 10.1115/DETC2005-85513](https://doi.org/10.1115/DETC2005-85513).
   This connects offsets, winding, and self-intersection cleanup.
6. Held, M. “FIST: Fast Industrial-Strength Triangulation of Polygons.”
   *Algorithmica* 30, 2001.
   [DOI 10.1007/s00453-001-0028-4](https://doi.org/10.1007/s00453-001-0028-4).
   This gives an industrial triangulation strategy for imperfect polygons.

**Secondary Readings**

- de Berg, M. et al. *Computational Geometry: Algorithms and Applications*,
  3rd ed., Springer, 2008. ISBN 978-3-540-77973-5.
- O'Rourke, J. *Computational Geometry in C*, 2nd ed., Cambridge University
  Press, 1998. ISBN 978-0-521-64976-6.
- Hormann, K., Agathos, A., and others. “Clipping Simple Polygons with
  Degenerate Intersections.” *Computers & Graphics* 2019 reading set,
  [arXiv 1211.3376](https://arxiv.org/abs/1211.3376).

**Courses**

- MIT 6.838, *Computational Geometry*, Fall 2001, Lectures 1–4 on orientation,
  convex hulls, segment intersections, and planar subdivisions.
- ETH Zürich *Computational Geometry*, Spring 2024, Weeks 2–5 on arrangements,
  sweeps, point location, and polygon triangulation.
- UC Davis ECS 178, *Computational Geometry*, Lectures 5–9 on segment
  intersection, polygon operations, and planar graphs.

**Hands-on Labs**

1. **Segment-to-loop lab.** Input: shuffled, duplicated, reversed, open, and
   branched segment sets. Output: clusters, directed adjacency, loops, chains,
   issues, and layer SVG. Acceptance: deterministic topology for every
   permutation and explicit failure for ambiguous branch policy. Performance:
   ten million segments/s. Rubric: 40% topology, 20% determinism, 20%
   performance, 20% diagnostic quality.
2. **Boolean and offset lab.** Input: integer contours with holes, shared edges,
   overlaps, self-intersections, acute corners, and thin channels. Output: four
   boolean operations, three join styles, provenance, and differential results
   against pinned Clipper2. Acceptance: zero invariant or oracle disagreements
   after semantic normalization. Performance: one million input edges/s on the
   medium distribution. Rubric: 45% correctness, 20% semantics, 20%
   performance, 15% evidence.

**Milestone Project**

Define the production `Polygon_Provider` contract and promote Clipper2 as the
initial provider and differential oracle. The Odin provider remains
experimental until it passes the complete conformance and performance gates.

**Time Estimate**

Readings: 18 hours. Courses: 10 hours. Labs: 30 hours. Milestone: 10 hours.
Total: 68 hours.

### M4. Layer Indexes and Acceleration Structures

**Title & Goal**

Build the layer-span index for horizontal slicing and compare SAH BVH and LBVH
providers for secondary spatial queries and large-model construction.

**Why it matters to this slicer**

The primary index determines how many triangles the engine revisits per layer.
Secondary acceleration supports overhang rays, picking, collision, arbitrary
planes, and future incremental updates.

**Primary Readings**

1. Goldsmith, J., and Salmon, J. “Automatic Creation of Object Hierarchies for
   Ray Tracing.” *IEEE Computer Graphics and Applications* 7(5), 1987.
   [DOI 10.1109/MCG.1987.276983](https://doi.org/10.1109/MCG.1987.276983).
   This introduces cost-based automatic hierarchy construction.
2. MacDonald, J. D., and Booth, K. S. “Heuristics for Ray Tracing Using Space
   Subdivision.” *The Visual Computer* 6, 1990.
   [DOI 10.1007/BF01911006](https://doi.org/10.1007/BF01911006).
   This formalizes traversal and intersection cost trade-offs.
3. Wald, I. “On Fast Construction of SAH-Based Bounding Volume Hierarchies.”
   *IEEE Symposium on Interactive Ray Tracing*, 2007.
   [DOI 10.1109/RT.2007.4342588](https://doi.org/10.1109/RT.2007.4342588).
   This gives a practical binned SAH construction.
4. Lauterbach, C. et al. “Fast BVH Construction on GPUs.” *Computer Graphics
   Forum* 28(2), 2009.
   [DOI 10.1111/j.1467-8659.2009.01377.x](https://doi.org/10.1111/j.1467-8659.2009.01377.x).
   This compares linear construction and hierarchy quality on GPUs.
5. Karras, T. “Maximizing Parallelism in the Construction of BVHs, Octrees,
   and k-d Trees.” *High Performance Graphics*, 2012.
   [DOI 10.2312/EGGH/HPG12/033-037](https://doi.org/10.2312/EGGH/HPG12/033-037).
   This derives a fully parallel binary radix tree from sorted Morton codes.
6. Apetrei, C. “Fast and Simple Agglomerative LBVH Construction.”
   *High-Performance Graphics*, 2014.
   [DOI 10.1145/2619648.2619655](https://doi.org/10.1145/2619648.2619655).
   This improves hierarchy quality while preserving parallel construction.

**Secondary Readings**

- Pharr, M., Jakob, W., and Humphreys, G. *Physically Based Rendering*, 4th ed.,
  2023, Chapter 7, [official online edition](https://pbr-book.org/4ed/).
- Ericson, C. *Real-Time Collision Detection*, Morgan Kaufmann, 2005,
  Chapters 4–6. ISBN 978-1-55860-732-3.
- Blelloch, G. E. “Prefix Sums and Their Applications.” CMU-CS-90-190, 1990.
  [Stable report](https://www.cs.cmu.edu/~guyb/papers/Ble93.pdf).

**Courses**

- Stanford CS 348B, Spring 2022, Lectures 7–9 on ray intersections, BVHs, and
  sampling data structures.
- CMU 15-462, Fall 2020, Lectures 12–13 on acceleration structures and ray
  tracing.
- NVIDIA *Fundamentals of Ray Tracing*, Chapters 6–8 on AABBs, BVH build, and
  traversal. Use it only for the data-structure portions.

**Hands-on Labs**

1. **Layer-span lab.** Input: uniform and adaptive schedules plus horizontal,
   vertical, random, and tall triangles. Output: count, prefix, scatter index
   and span heat map. Acceptance: exact pair set against brute force with stable
   order. Performance: build 50 million triangle spans in under 2 seconds and
   sustain at least 500 million emitted pairs/s. Rubric: 35% correctness, 25%
   bounds, 25% performance, 15% evidence.
2. **BVH comparison lab.** Input: one million to 50 million triangles. Output:
   binned SAH and LBVH layouts, construction timing, query cost, occupancy view,
   and quality metrics. Acceptance: identical query hits. Performance: LBVH
   build at least 2× faster than SAH on the largest fixture while SAH performs
   no more than 70% of LBVH node visits on the irregular query set. Rubric: 35%
   correctness, 25% measurement, 25% implementation, 15% visualization.

**Milestone Project**

Integrate the layer-span provider as the default slicer accelerator and retain
the better measured BVH provider for support and picking. Publish both through
the acceleration contract.

**Time Estimate**

Readings: 14 hours. Courses: 8 hours. Labs: 26 hours. Milestone: 8 hours.
Total: 56 hours.

### M5. FFF Process Planning and Print Features

**Title & Goal**

Translate planar part geometry and printer constraints into layers, shells,
skin, bridges, extrusion widths, speeds, cooling decisions, and material-aware
feature regions.

**Why it matters to this slicer**

Geometrically valid contours do not define a printable part. Nozzle width,
layer adhesion, overhang, cooling, flow, motion limits, and feature order
determine whether the emitted path can produce the requested geometry.

**Primary Readings**

1. Kulkarni, P., Marsan, A., and Dutta, D. “A Review of Process Planning
   Techniques in Layered Manufacturing.” *Rapid Prototyping Journal* 6(1),
   2000.
   [DOI 10.1108/13552540010309859](https://doi.org/10.1108/13552540010309859).
   This organizes the complete geometry-to-process planning problem.
2. Pandey, P. M., Reddy, N. V., and Dhande, S. G. “Real Time Adaptive Slicing
   for Fused Deposition Modelling.” *International Journal of Machine Tools and
   Manufacture* 43(1), 2003.
   [DOI 10.1016/S0890-6955(02)00164-5](https://doi.org/10.1016/S0890-6955(02)00164-5).
   This relates surface error to an adaptive layer schedule.
3. Ahn, S.-H. et al. “Anisotropic Material Properties of Fused Deposition
   Modeling ABS.” *Rapid Prototyping Journal* 8(4), 2002.
   [DOI 10.1108/13552540210441166](https://doi.org/10.1108/13552540210441166).
   This ties path direction and layer bonding to part behavior.
4. Turner, B. N., Strong, R., and Gold, S. A. “A Review of Melt Extrusion
   Additive Manufacturing Processes: I. Process Design and Modeling.”
   *Rapid Prototyping Journal* 20(3), 2014.
   [DOI 10.1108/RPJ-01-2013-0012](https://doi.org/10.1108/RPJ-01-2013-0012).
   This explains extrusion and thermal process variables.
5. Ding, D., Pan, Z., Cuiuri, D., and Li, H. “A Tool-Path Generation Strategy
   for Wire and Arc Additive Manufacturing.” *The International Journal of
   Advanced Manufacturing Technology* 73, 2014.
   [DOI 10.1007/s00170-014-5808-5](https://doi.org/10.1007/s00170-014-5808-5).
   This connects path continuity and deposition constraints in an additive
   process.
6. Jin, Y., He, Y., Fu, J., Gan, W., and Lin, Z. “Optimization of Tool-Path
   Generation for Material Extrusion-Based Additive Manufacturing Technology.”
   *Additive Manufacturing* 1–4, 2014.
   [DOI 10.1016/j.addma.2014.08.004](https://doi.org/10.1016/j.addma.2014.08.004).
   This evaluates path geometry against manufacturing objectives.

**Secondary Readings**

- Gibson, I., Rosen, D., Stucker, B., and Khorasani, M. *Additive
  Manufacturing Technologies*, 3rd ed., Springer, 2021.
  ISBN 978-3-030-56126-0.
- Chua, C. K., and Leong, K. F. *3D Printing and Additive Manufacturing*,
  5th ed., World Scientific, 2017. ISBN 978-981-3146-75-4.
- Bellehumeur, C. et al. “Modeling of Bond Formation Between Polymer Filaments
  in the Fused Deposition Modeling Process.” *Journal of Manufacturing
  Processes* 6(2), 2004.
  [DOI 10.1016/S1526-6125(04)70071-7](https://doi.org/10.1016/S1526-6125(04)70071-7).

**Courses**

- MIT 2.008, *Design and Manufacturing II*, additive-manufacturing unit,
  Lectures 18–20 on process constraints, toolpaths, and design rules.
- TU Delft edX, *Additive Manufacturing*, Weeks 2–5 on material extrusion,
  process planning, supports, and quality.
- Carnegie Mellon 24-642, *Additive Manufacturing*, Weeks 3–6 on slicing,
  process parameters, anisotropy, and design validation.

**Hands-on Labs**

1. **Layer and shell lab.** Input: analytic sphere, cone, thin wall, stepped
   cavity, and profile constraints. Output: fixed and adaptive schedules,
   perimeters, gap regions, and cusp-error evidence. Acceptance: shell coverage
   has no overlap beyond the configured tolerance and adaptive layers meet the
   error bound. Performance: generate features for 2,000 layers in under
   3 seconds after polygon input. Rubric: 40% geometry, 25% process semantics,
   20% performance, 15% evidence.
2. **Skin and bridge lab.** Input: upper and lower layer regions with openings,
   cantilevers, and narrow roofs. Output: top, bottom, bridge, and unsupported
   masks with direction and settings provenance. Acceptance: analytic expected
   masks and no role overlap. Performance: process one million region edges/s.
   Rubric: 40% classification, 20% process policy, 20% throughput, 20%
   diagnostics.

**Milestone Project**

Promote layer scheduling, shell, thin-wall, skin, and bridge providers into the
pipeline. Store every setting decision on the emitted feature so later paths
and G-code can explain their origin.

**Time Estimate**

Readings: 16 hours. Courses: 8 hours. Labs: 28 hours. Milestone: 12 hours.
Total: 64 hours.

### M6. Infill Fields, Distance Transforms, and Supports

**Title & Goal**

Generate sparse and solid infill, distance-aware gap strategies, overhang masks,
support interfaces, and optional tree-support candidates through analytic and
tiled field methods.

**Why it matters to this slicer**

These stages dominate geometry count on many parts and need context across
layers. Dense grids map well to Metal, but resolution and threshold choices
must remain visible and cannot silently redefine authoritative shell geometry.

**Primary Readings**

1. Felzenszwalb, P. F., and Huttenlocher, D. P. “Distance Transforms of Sampled
   Functions.” *Theory of Computing* 8, 2012.
   [DOI 10.4086/toc.2012.v008a019](https://doi.org/10.4086/toc.2012.v008a019).
   This derives a linear-time exact squared Euclidean distance transform.
2. Meijster, A., Roerdink, J. B. T. M., and Hesselink, W. H. “A General
   Algorithm for Computing Distance Transforms in Linear Time.”
   *Mathematical Morphology and Its Applications to Image and Signal
   Processing*, 2000.
   [DOI 10.1007/0-306-47025-X_36](https://doi.org/10.1007/0-306-47025-X_36).
   This supplies a separable exact transform suitable for tiled fields.
3. Dumas, J., Hergel, J., and Lefebvre, S. “Bridging the Gap: Automated Steady
   Scaffoldings for 3D Printing.” *ACM Transactions on Graphics* 33(4), 2014.
   [DOI 10.1145/2601097.2601153](https://doi.org/10.1145/2601097.2601153).
   This connects support topology with stable printable scaffolds.
4. Vanek, J., Galicia, J. A. G., and Benes, B. “Clever Support: Efficient
   Support Structure Generation for Digital Fabrication.” *Computer Graphics
   Forum* 33(5), 2014.
   [DOI 10.1111/cgf.12437](https://doi.org/10.1111/cgf.12437).
   This gives a tree-like support strategy that reduces material.
5. Hu, K. et al. “Least Cost Paths for 3D Printing Support Structures.”
   *ACM Transactions on Graphics* 34(6), 2015.
   [DOI 10.1145/2816795.2817810](https://doi.org/10.1145/2816795.2817810).
   This frames support branches as a constrained cost problem.
6. Jones, M. W., Bærentzen, J. A., and Sramek, M. “3D Distance Fields: A
   Survey of Techniques and Applications.” *IEEE Transactions on Visualization
   and Computer Graphics* 12(4), 2006.
   [DOI 10.1109/TVCG.2006.56](https://doi.org/10.1109/TVCG.2006.56).
   This compares field representations, error, and computation.

**Secondary Readings**

- Serra, J. *Image Analysis and Mathematical Morphology*, Academic Press, 1982.
  ISBN 978-0-12-637240-3.
- Osher, S., and Fedkiw, R. *Level Set Methods and Dynamic Implicit Surfaces*,
  Springer, 2003. ISBN 978-0-387-95482-0.
- Amenta, N., Bern, M., and Eppstein, D. “The Crust and the Beta-Skeleton.”
  *Graphical Models and Image Processing* 60(2), 1998.
  [DOI 10.1006/gmip.1998.0465](https://doi.org/10.1006/gmip.1998.0465).

**Courses**

- Stanford CS 233, *Geometric and Topological Data Analysis*, Weeks 2–4 on
  distance functions, medial axes, and sampled geometry.
- Brown CS 224, *Interactive Computer Graphics*, Lectures 12–14 on implicit
  fields, level sets, and GPU grids.
- TU Delft *Additive Manufacturing*, Weeks 5–6 on infill, overhang, support,
  and material use.

**Hands-on Labs**

1. **Distance-field lab.** Input: binary masks at 1K², 4K², and 16K² plus
   analytic circles and rectangles. Output: exact squared distances from scalar,
   parallel CPU, and Metal providers with heat-map evidence. Acceptance:
   bit-identical fields and correct halo behavior. Performance: Metal at least
   2× CPU on 16K² including transfer. Rubric: 40% correctness, 20% tiling, 25%
   performance, 15% evidence.
2. **Support lab.** Input: stair, bridge, tree, broad roof, and trapped-cavity
   fixtures. Output: overhang demand, clearance, interface, support, and branch
   candidates with layer provenance. Acceptance: expected masks and no support
   collision with model clearance. Performance: 2,000 layers in under
   5 seconds on the medium fixture. Rubric: 35% geometry, 25% manufacturing
   policy, 20% performance, 20% inspectability.

**Milestone Project**

Integrate rectilinear, grid, concentric, and gyroid infill providers plus normal
support and interface generation. Keep tree supports behind an experimental
provider until collision, stability, and path gates pass.

**Time Estimate**

Readings: 16 hours. Courses: 8 hours. Labs: 30 hours. Milestone: 14 hours.
Total: 68 hours.

### M7. Path Planning, Motion Constraints, and G-code

**Title & Goal**

Order extrusion features and travel moves under precedence, seam, collision,
retraction, material, and tool-change constraints, then emit and re-parse
stateful G-code.

**Why it matters to this slicer**

Path ordering changes print time, stringing, seam placement, cooling, and tool
changes. G-code is a state machine. A geometrically correct move can be wrong
under the active coordinate, extrusion, tool, or feed mode.

**Primary Readings**

1. Dantzig, G. B., and Ramser, J. H. “The Truck Dispatching Problem.”
   *Management Science* 6(1), 1959.
   [DOI 10.1287/mnsc.6.1.80](https://doi.org/10.1287/mnsc.6.1.80).
   This establishes route optimization with capacity and ordering constraints.
2. Lin, S. “Computer Solutions of the Traveling Salesman Problem.” *Bell
   System Technical Journal* 44(10), 1965.
   [DOI 10.1002/j.1538-7305.1965.tb04146.x](https://doi.org/10.1002/j.1538-7305.1965.tb04146.x).
   This develops practical local route improvement.
3. Lin, S., and Kernighan, B. W. “An Effective Heuristic Algorithm for the
   Traveling-Salesman Problem.” *Operations Research* 21(2), 1973.
   [DOI 10.1287/opre.21.2.498](https://doi.org/10.1287/opre.21.2.498).
   This supplies variable-depth edge exchanges for high-quality tours.
4. Helsgaun, K. “An Effective Implementation of the Lin–Kernighan Traveling
   Salesman Heuristic.” *European Journal of Operational Research* 126(1),
   2000.
   [DOI 10.1016/S0377-2217(99)00284-2](https://doi.org/10.1016/S0377-2217(99)00284-2).
   This turns the heuristic into an efficient candidate-based implementation.
5. Jiang, J., Xu, X., and Stringer, J. “Optimization of Process Planning for
   Reducing Material Waste in Extrusion Based Additive Manufacturing.”
   *Robotics and Computer-Integrated Manufacturing* 59, 2019.
   [DOI 10.1016/j.rcim.2019.05.007](https://doi.org/10.1016/j.rcim.2019.05.007).
   This relates support, orientation, path planning, and material use.
6. Kramer, T. R., Proctor, F. M., and Messina, E. *The NIST RS274NGC
   Interpreter, Version 3*, NISTIR 6556, 2000.
   [Stable NIST record](https://doi.org/10.6028/NIST.IR.6556).
   This defines a stateful reference interpreter and validation model.

**Secondary Readings**

- Applegate, D. et al. *The Traveling Salesman Problem: A Computational Study*,
  Princeton University Press, 2006. ISBN 978-0-691-12993-8.
- Toth, P., and Vigo, D., eds. *The Vehicle Routing Problem*, SIAM, 2002.
  ISBN 978-0-89871-498-2.
- Marlin Firmware. *G-code Index*, current official documentation,
  [marlinfw.org/meta/gcode](https://marlinfw.org/meta/gcode/).
- Klipper. *G-Codes*, current official documentation,
  [klipper3d.org/G-Codes.html](https://www.klipper3d.org/G-Codes.html).

**Courses**

- MIT 15.S60, *The Analytics Edge*, Weeks 5–6 on routing formulations and
  heuristics.
- Georgia Tech CS 6505, *Computability, Algorithms, and Complexity*, Lectures
  17–19 on NP-hardness, approximation, and TSP.
- Coursera, *Discrete Optimization*, Weeks 4–6 on local search, routing, and
  large-neighborhood methods.

**Hands-on Labs**

1. **Constrained tour lab.** Input: 100 to 100,000 islands with role
   precedence, seam candidates, forbidden travel zones, and tool groups.
   Output: deterministic ordered paths, cost breakdown, and before/after tour
   view. Acceptance: all constraints hold and travel is no more than 1.08× the
   reference heuristic. Performance: plan 100,000 islands in under 20 seconds.
   Rubric: 35% constraints, 25% cost quality, 25% performance, 15% explanation.
2. **G-code state lab.** Input: normalized paths and profiles for two dialects.
   Output: G-code, manifest, independent parse trace, and command-correlated
   preview. Acceptance: identical final state and bounds after re-parse, with
   injected mode errors rejected. Performance: 20 million commands/s to a
   memory sink. Rubric: 45% state correctness, 20% dialect isolation, 20%
   throughput, 15% evidence.

**Milestone Project**

Integrate spatial-bin nearest selection, bounded 2-opt, seam policy, retraction,
speed and flow annotations, the initial Marlin-compatible dialect, and the
independent validator. Add other dialects only through conformance fixtures.

**Time Estimate**

Readings: 14 hours. Courses: 8 hours. Labs: 28 hours. Milestone: 12 hours.
Total: 62 hours.

### M8. Data-Oriented Parallelism on Apple Silicon

**Title & Goal**

Design bounded CPU jobs, deterministic merges, SoA kernels, prefix operations,
and ARM64 SIMD implementations that use M-series memory bandwidth without
oversubscribing the UI or Metal work.

**Why it matters to this slicer**

Most stages scan or partition large arrays. Allocation, completion order,
cache traffic, false sharing, and repeated passes can dominate arithmetic.

**Primary Readings**

1. Frigo, M., Leiserson, C. E., Prokop, H., and Ramachandran, S.
   “Cache-Oblivious Algorithms.” *FOCS '99*, 1999.
   [DOI 10.1109/SFFCS.1999.814600](https://doi.org/10.1109/SFFCS.1999.814600).
   This derives locality bounds without hard-coding a cache size.
2. Lamport, L. “How to Make a Multiprocessor Computer That Correctly Executes
   Multiprocess Programs.” *IEEE Transactions on Computers* C-28(9), 1979.
   [DOI 10.1109/TC.1979.1675439](https://doi.org/10.1109/TC.1979.1675439).
   This defines sequential consistency and the ordering problem.
3. Michael, M. M., and Scott, M. L. “Simple, Fast, and Practical Non-Blocking
   and Blocking Concurrent Queue Algorithms.” *PODC '96*, 1996.
   [DOI 10.1145/248052.248106](https://doi.org/10.1145/248052.248106).
   This supplies queue algorithms and memory-order reasoning.
4. Satish, N. et al. “Designing Efficient Sorting Algorithms for Manycore GPUs.”
   *IPDPS 2009*, 2009.
   [DOI 10.1109/IPDPS.2009.5161005](https://doi.org/10.1109/IPDPS.2009.5161005).
   This gives histogram and radix-partition techniques that also inform CPU
   layout.
5. Merrill, D., and Garland, M. “Single-Pass Parallel Prefix Scan with
   Decoupled Look-Back.” NVIDIA Technical Report NVR-2016-002, 2016.
   [Stable report](https://research.nvidia.com/publication/2016-03_single-pass-parallel-prefix-scan-decoupled-look-back).
   This analyzes a bandwidth-efficient scan organization.
6. Apple. *Dispatch Queue*, current documentation.
   [Official documentation](https://developer.apple.com/documentation/dispatch/dispatch-queue).
   This defines queue execution, global thread pools, and main-queue behavior.

**Secondary Readings**

- McCool, M., Reinders, J., and Robison, A. *Structured Parallel Programming*,
  Morgan Kaufmann, 2012. ISBN 978-0-12-391443-9.
- Gregg, B. *Systems Performance*, 2nd ed., Addison-Wesley, 2020.
  ISBN 978-0-13-682015-4.
- Arm. *Arm Architecture Reference Manual for A-profile Architecture*, current
  edition, [official developer documentation](https://developer.arm.com/documentation/ddi0487/latest/).

**Courses**

- MIT 6.172, *Performance Engineering of Software Systems*, Fall 2018,
  Lectures 2–6 on performance models, bit operations, assembly, compiler
  behavior, and caching; Lectures 13–16 on parallelism.
- Stanford CS 149, Fall 2023, Lectures 2–7 on multicore execution, SIMD,
  scheduling, synchronization, and bandwidth.
- CMU 15-418, Spring 2024, Lectures 2–6 on parallel models and locality and
  Lectures 11–13 on synchronization and work distribution.

**Hands-on Labs**

1. **Layout and SIMD lab.** Input: 100 million triangle bounds in AoS, SoA, and
   AoSoA layouts. Output: scalar and NEON classification, assembly listing,
   cache and bandwidth profile. Acceptance: identical masks. Performance:
   optimized SoA reaches at least 70% of measured sequential bandwidth and is
   at least 1.5× the baseline AoS. Rubric: 30% measurement, 30% correctness,
   25% assembly analysis, 15% explanation.
2. **Bounded pipeline lab.** Input: variable-size layer tiles with injected slow
   workers and cancellation. Output: byte-permit scheduler, deterministic
   merges, queue trace, and memory graph. Acceptance: configured bound plus one
   active task, no deadlock, identical output for worker counts 1–N.
   Performance: scheduler overhead below 5% for 1 ms tasks. Rubric: 35%
   correctness, 25% bounds, 20% determinism, 20% performance.

**Milestone Project**

Promote the worker pool, byte permits, transferable stage arenas, deterministic
merge, ARM64 kernel review, and benchmark metadata into the pipeline runtime.

**Time Estimate**

Readings: 14 hours. Courses: 12 hours. Labs: 26 hours. Milestone: 10 hours.
Total: 62 hours.

### M9. Metal Compute on Apple Silicon

**Title & Goal**

Build, profile, validate, and tune Metal count, scan, scatter, intersection, and
dense-field kernels while preserving a CPU oracle and bounded fallback.

**Why it matters to this slicer**

Triangle-layer expansion and dense fields contain enough independent work to
benefit from GPU execution. Command overhead, buffer modes, occupancy,
divergence, and CPU readback can erase that gain unless the complete data path
is measured.

**Primary Readings**

1. Apple. *Metal Shading Language Specification*, current edition.
   [Official specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf).
   This defines kernel language types, address spaces, atomics, barriers, and
   SIMD-group operations.
2. Apple. *Metal Feature Set Tables*, current edition.
   [Official tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf).
   This provides the capabilities and limits that runtime selection must query.
3. Apple. “Calculating Threadgroup and Grid Sizes,” current documentation.
   [Official documentation](https://developer.apple.com/documentation/metal/calculating-threadgroup-and-grid-sizes).
   This derives dispatch shape from compute-pipeline properties.
4. Apple. “Resource Fundamentals,” current documentation.
   [Official documentation](https://developer.apple.com/documentation/metal/resource-fundamentals).
   This defines shared, private, and managed resource semantics.
5. Apple. “Analyzing Your Metal Workload,” current documentation.
   [Official documentation](https://developer.apple.com/documentation/xcode/analyzing-your-metal-workload).
   This describes capture, dependency, resource, and timing analysis.
6. Karras, T. “Maximizing Parallelism in the Construction of BVHs, Octrees,
   and k-d Trees.” *High Performance Graphics*, 2012.
   [DOI 10.2312/EGGH/HPG12/033-037](https://doi.org/10.2312/EGGH/HPG12/033-037).
   This provides a concrete scan, sorted-key, and hierarchy workload.
7. Merrill, D., and Garland, M. “Single-Pass Parallel Prefix Scan with
   Decoupled Look-Back.” NVIDIA Technical Report NVR-2016-002, 2016.
   [Stable report](https://research.nvidia.com/publication/2016-03_single-pass-parallel-prefix-scan-decoupled-look-back).
   This supplies a bandwidth-oriented scan design to adapt and measure.

**Secondary Readings**

- Apple. *Metal Programming Guide*, archived fundamentals and current API
  topics, [developer.apple.com/metal](https://developer.apple.com/metal/).
- Kirk, D. B., and Hwu, W.-m. W. *Programming Massively Parallel Processors*,
  4th ed., Morgan Kaufmann, 2022. ISBN 978-0-323-91231-0.
- Hwu, W.-m. W., Kirk, D. B., and El Hajj, I. *Programming Massively Parallel
  Processors: A Hands-on Approach*, current exercise set.

**Courses**

- Apple WWDC20 session 10603, *Optimize Metal Apps and Games with GPU Counters*.
- Apple WWDC22 session 10106, *Profile and Optimize Your Game's Memory*,
  together with WWDC20 session 10632, *Optimize Metal Performance for Apple
  Silicon Macs*.
- Coursera, *Heterogeneous Parallel Programming*, Weeks 3–6 on coalescing,
  scans, atomics, and tiled kernels. Translate the mechanisms to Metal.

**Hands-on Labs**

1. **Metal scan lab.** Input: count arrays from 1 Ki to 256 Mi elements.
   Output: exclusive scan, total count, CPU oracle, pipeline calibration, and
   GPU capture. Acceptance: bit-identical results and checked overflow.
   Performance: at least 65% of measured device buffer bandwidth for large
   arrays. Rubric: 35% correctness, 25% synchronization, 25% performance, 15%
   capture analysis.
2. **Metal intersection lab.** Input: the M1 plane-classifier corpus packed into
   layer tiles. Output: unambiguous segments, ambiguity queue, CPU
   canonicalization, and CPU/GPU diff view. Acceptance: identical canonical
   loops and complete fallback. Performance: at least 1.6× CPU intersection and
   15% medium end-to-end improvement. Rubric: 40% correctness, 20% fallback,
   25% end-to-end speed, 15% evidence.

**Milestone Project**

Promote the calibrated Metal provider, metallib build, completion ownership,
CPU replay queue, and Metal debug metadata into Section 7. Retain the CPU
provider as a release-tested fallback.

**Time Estimate**

Readings: 14 hours. Courses: 8 hours. Labs: 28 hours. Milestone: 10 hours.
Total: 60 hours.

### M10. File Formats, Streaming I/O, and Defensive Parsing

**Title & Goal**

Implement bounded STL, OBJ, 3MF, project, debug-package, profile, and G-code I/O
with explicit source locations, checksums, cancellation, and crash-safe output.

**Why it matters to this slicer**

Format input defines units, transforms, material ownership, and triangle
identity. Malformed sizes or compressed input can exceed memory before geometry
validation starts. Output failure must never replace a known-good file.

**Primary Readings**

1. 3MF Consortium. *3MF Core Specification and Reference Guide*, version 1.3.0,
   2021.
   [Official specification](https://3mf.io/wp-content/uploads/sites/106/2025/02/3MF_Core_Specification_v1.3.0.pdf).
   This defines package relationships, model units, meshes, components, and
   build items.
2. PKWARE. *.ZIP File Format Specification*, APPNOTE.TXT, current revision.
   [Official specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT).
   This defines archive records, Zip64, checksums, and size fields.
3. Deutsch, P. “DEFLATE Compressed Data Format Specification version 1.3.”
   RFC 1951, 1996.
   [DOI 10.17487/RFC1951](https://doi.org/10.17487/RFC1951).
   This defines the compressed stream inside common 3MF entries.
4. W3C. *Extensible Markup Language (XML) 1.0, Fifth Edition*, 2008.
   [Official recommendation](https://www.w3.org/TR/2008/REC-xml-20081126/).
   This defines tokenization, entities, encodings, and well-formedness.
5. Wavefront Technologies. *Object Files (.obj), Version 3.0*, 1995.
   [Stable specification copy](https://www.loc.gov/preservation/digital/formats/fdd/fdd000507.shtml).
   This defines independent indices, face records, groups, and material links.
6. Kramer, T. R., Proctor, F. M., and Messina, E. *The NIST RS274NGC
   Interpreter, Version 3*, NISTIR 6556, 2000.
   [DOI 10.6028/NIST.IR.6556](https://doi.org/10.6028/NIST.IR.6556).
   This supplies a complete stateful output parser model.

**Secondary Readings**

- The Open Group. *The Open Group Base Specifications Issue 8*, `mmap`,
  `read`, `write`, `fsync`, and `rename`.
  [Official POSIX specification](https://pubs.opengroup.org/onlinepubs/9799919799/).
- Apple. *Dispatch I/O*, current documentation,
  [developer.apple.com/documentation/dispatch/dispatchio](https://developer.apple.com/documentation/dispatch/dispatchio).
- Lemire, D. “Number Parsing at a Gigabyte per Second.” *Software: Practice and
  Experience* 51(8), 2021.
  [DOI 10.1002/spe.2984](https://doi.org/10.1002/spe.2984).

**Courses**

- CMU 15-445, Fall 2023, Lectures 3–5 on storage, buffer management, and
  checksums; use the I/O mechanisms, not the database product design.
- Stanford CS 110, Spring 2021, Lectures 3–6 on files, system calls,
  concurrency, and crash behavior.
- Fuzzing Book, Chapters 8–10 on grammar-based input generation, parser
  fuzzing, and reduction.

**Hands-on Labs**

1. **Bounded parser lab.** Input: valid and generated malformed STL, OBJ, ZIP,
   XML, and 3MF files with truncation, overflow, cycles, entities, and bombs.
   Output: canonical scene or structured error with source location and memory
   report. Acceptance: no limit bypass in 100 million fuzz cases and a 10 GiB
   declared bomb fails below 64 MiB RSS growth. Performance: cached binary STL
   decode at 1 GiB/s. Rubric: 40% safety, 25% semantics, 20% speed, 15%
   diagnostics.
2. **Crash-safe writer lab.** Input: 20 million normalized moves and injected
   short writes, cancellation, full disk, and rename failures. Output: staged
   G-code, parsed manifest, and final destination. Acceptance: prior file
   remains byte-identical on every failure. Performance: 500 MiB/s to a memory
   sink with zero per-command allocations. Rubric: 40% failure safety, 25%
   state correctness, 20% throughput, 15% evidence.

**Milestone Project**

Promote the parser-provider contract, archive limits, content hashing, project
schema, staged output, and G-code validator into Section 8.

**Time Estimate**

Readings: 12 hours. Courses: 8 hours. Labs: 26 hours. Milestone: 10 hours.
Total: 56 hours.

### M11. Odin, Objective-C Interop, AppKit, and Debug UI

**Title & Goal**

Build the pinned Odin toolchain, typed macOS shims, single application
executable, immediate-mode control registry, Metal renderer, and evidence
inspector.

**Why it matters to this slicer**

The engine needs native file and Accessibility behavior and direct GPU access,
but platform ownership must not enter geometry. Debug views must consume the
same evidence that CLI and automated review consume.

**Primary Readings**

1. Odin Project. *Overview*, current documentation.
   [Official documentation](https://odin-lang.org/docs/overview/).
   This defines packages, foreign imports, arrays, SIMD types, allocators, and
   language execution semantics.
2. Odin Project. *Frequently Asked Questions*, current documentation.
   [Official documentation](https://odin-lang.org/docs/faq/).
   This records toolchain, package-management, architecture, and ABI scope.
3. Odin Project. *Core Library: Darwin Packages*, current generated
   documentation.
   [Official package index](https://pkg.odin-lang.org/core/).
   This identifies maintained system bindings and their target assumptions.
4. Apple. *Objective-C Runtime Programming Guide*, 2013 archive.
   [Official archive](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/).
   This defines classes, selectors, message dispatch, method encodings, and
   runtime ownership boundaries.
5. Arm. *Procedure Call Standard for the Arm 64-bit Architecture*, current
   ABI release.
   [Official ABI repository](https://github.com/ARM-software/abi-aa/releases).
   This defines register, stack, aggregate, and callback calling conventions.
6. Apple. *Cocoa Drawing Guide* and current AppKit documentation.
   [Official archive](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaDrawingGuide/).
   This defines view coordinates, scale, invalidation, and native window
   integration.
7. Apple. *Core Text Programming Guide*, 2013 archive.
   [Official archive](https://developer.apple.com/library/archive/documentation/StringsTextFonts/Conceptual/CoreText_Programming/).
   This defines shaping, glyph runs, metrics, and draw placement.

**Secondary Readings**

- Apple. *Accessibility Programming Guide for OS X*, official archive,
  [developer.apple.com/library/archive](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/).
- Apple. *View Programming Guide for Cocoa*, official archive,
  [developer.apple.com/library/archive](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaViewsGuide/).
- Apple. *Dynamic Library Programming Topics*, official archive,
  [developer.apple.com/library/archive](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/DynamicLibraries/).

**Courses**

- Odin Project, *Overview* study sequence, Chapters “Packages,” “Foreign
  system,” “Memory,” and “SIMD,” followed by the matching core-library examples.
- Apple WWDC19 session 210, *What's New in AppKit for macOS*, and WWDC22
  session 10074, *What's New in AppKit*, for native window and control
  behavior.
- Apple WWDC21 session 10119, *SwiftUI Accessibility: Beyond the Basics*,
  sections on labels, actions, grouping, focus, and testing.

**Hands-on Labs**

1. **Interop and lifetime lab.** Input: window, Metal device, file panel,
   callback, background autorelease pool, and forced failures. Output: typed
   shim, ABI assertions, lifetime log, ASan and Zombies run. Acceptance:
   10,000 create-use-release cycles without retained growth or stale callback.
   Rubric: 40% ownership, 25% ABI, 20% failure handling, 15% diagnostics.
2. **Evidence inspector lab.** Input: fixed `.hwsdebug` fixtures from M2, M3,
   M6, and M9. Output: 3D view, 2D layer view, timeline, inspector, SVG/PNG
   renderer, control registry, Accessibility tree, Flash targets, and numbered
   actions. Acceptance: deterministic renders and structural UI fixtures in both
   themes. Performance: p95 frame below 16.7 ms for the designated visible
   workload. Rubric: 30% evidence fidelity, 25% interaction contracts, 25%
   rendering, 20% accessibility and automation.

**Milestone Project**

Promote the AppKit shim, Odin executable, renderer, complete control registry,
evidence readers, and structural UI CLI into the application.

**Time Estimate**

Readings: 12 hours. Courses: 8 hours. Labs: 28 hours. Milestone: 12 hours.
Total: 60 hours.

### M12. Determinism, Fuzzing, Benchmarking, and macOS Distribution

**Title & Goal**

Build the proof system for correctness, performance, reproducibility,
diagnostics, signing, notarization, and clean-machine release.

**Why it matters to this slicer**

Geometry failures often require one rare input and one stage transition.
Performance claims vary with thermal state and configuration. A useful release
must reproduce the failure, explain the stage, preserve user files, and pass
Gatekeeper on another Mac.

**Primary Readings**

1. Claessen, K., and Hughes, J. “QuickCheck: A Lightweight Tool for Random
   Testing of Haskell Programs.” *ICFP '00*, 2000.
   [DOI 10.1145/351240.351266](https://doi.org/10.1145/351240.351266).
   This defines property generators, shrinking, and executable invariants.
2. McKeeman, W. M. “Differential Testing for Software.” *Digital Technical
   Journal* 10(1), 1998.
   [Stable paper](https://www.digiater.nl/openvms/decus/vmslt98b/nt/differential_testing_for_software.pdf).
   This establishes independent implementation comparison as an oracle.
3. Zeller, A., and Hildebrandt, R. “Simplifying and Isolating Failure-Inducing
   Input.” *IEEE Transactions on Software Engineering* 28(2), 2002.
   [DOI 10.1109/32.988498](https://doi.org/10.1109/32.988498).
   This gives a systematic reducer for failing geometry and format inputs.
4. Zalewski, M. “American Fuzzy Lop: A Security-Oriented Fuzzer.” 2014.
   [Official project technical notes](https://lcamtuf.coredump.cx/afl/technical_details.txt).
   This explains coverage-guided mutation and execution feedback.
5. Georges, A., Buytaert, D., and Eeckhout, L. “Statistically Rigorous Java
   Performance Evaluation.” *OOPSLA '07*, 2007.
   [DOI 10.1145/1297027.1297033](https://doi.org/10.1145/1297027.1297033).
   This supplies experimental controls and distribution-aware reporting.
6. Mytkowicz, T. et al. “Producing Wrong Data Without Doing Anything Obviously
   Wrong!” *ASPLOS XIV*, 2009.
   [DOI 10.1145/1508244.1508275](https://doi.org/10.1145/1508244.1508275).
   This demonstrates environmental bias in performance measurement.
7. Apple. “Notarizing macOS Software Before Distribution,” current
   documentation.
   [Official documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
   This defines Developer ID, hardened runtime, submission, tickets, and
   stapling.

**Secondary Readings**

- Sutton, M., Greene, A., and Amini, P. *Fuzzing: Brute Force Vulnerability
  Discovery*, Addison-Wesley, 2007. ISBN 978-0-321-44611-4.
- Klees, G. et al. “Evaluating Fuzz Testing.” *CCS '18*, 2018.
  [DOI 10.1145/3243734.3243804](https://doi.org/10.1145/3243734.3243804).
- Apple. “Accessing Files from the macOS App Sandbox,” current documentation,
  [official documentation](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

**Courses**

- UC Berkeley CS 262A, Fall 2023, Lectures 3–5 on experimental methods,
  reproducibility, and systems measurement.
- The Fuzzing Book, Chapters 1–7 and 11–13 on mutation, coverage, grammars,
  reduction, and API fuzzing.
- Apple WWDC21 session 10087, *Diagnose Power and Performance Regressions in
  Your App*, plus Apple's notarization command-line workflow.

**Hands-on Labs**

1. **Differential geometry fuzz lab.** Input: generated meshes, layer schedules,
   contours, and provider pairs. Output: invariant checks, canonical diffs,
   reduced reproducers, and evidence bundles. Acceptance: injected bugs are
   detected and reduced below 20 primitives. Performance: ten million small
   cases/hour across workers. Rubric: 35% oracle quality, 25% reduction, 20%
   throughput, 20% evidence.
2. **Release-evidence lab.** Input: pinned benchmark corpus, signed app, clean
   user account, quarantine attribute, and injected failures. Output: raw
   benchmark samples, notarized archive, Gatekeeper result, crash bundle, and
   reproducibility manifest. Acceptance: all benchmark gates and clean-machine
   workflows pass. Rubric: 30% correctness evidence, 25% measurement rigor,
   25% distribution, 20% artifact completeness.

**Milestone Project**

Promote the property, fuzz, differential, reducer, benchmark, crash-capture,
codesign, notarization, stapling, and clean-machine suites into release
automation. A green build alone does not replace artifact review.

**Time Estimate**

Readings: 14 hours. Courses: 8 hours. Labs: 28 hours. Milestone: 12 hours.
Total: 62 hours.

## C3. Reading Roadmap Table

Read modules in the listed order unless the diagnostic assigns M12 remediation
first. Modules M5–M8 can overlap after M3 and M4 pass. M9 starts only after the
CPU count, scan, scatter, and intersection baselines exist.

| Module | Load-bearing readings | Plan sections unlocked | Estimated hours | Hard lab goal |
|---|---|---:|---:|---|
| M1 Floating point | IEEE 754; Goldberg; Shewchuk; Fortune–van Wyk | 4, 6, 7 | 60 | 100 million correct predicate cases; ≥50 million orientation filters/s |
| M2 Mesh processing | Dolenc–Mäkelä; Tata; Attene; Ju | 1, 4, 5, 8 | 60 | Normalize 5 million triangles ≤5 s; complete source provenance |
| M3 Planar topology | Vatti; Greiner–Hormann; Martínez; Chen–McMains | 4, 6 | 68 | ≥1 million boolean input edges/s; zero differential failures |
| M4 Acceleration | Wald; Lauterbach; Karras; Apetrei | 1, 4, 5, 7 | 56 | Layer-span build for 50 million triangles ≤2 s; ≥500 million pairs/s |
| M5 FFF features | Kulkarni; Pandey; Ahn; Turner; Ding | 1, 4, 6 | 64 | Feature generation for 2,000 layers ≤3 s after polygon input |
| M6 Fields and support | Felzenszwalb–Huttenlocher; Dumas; Vanek; Hu | 4, 6, 7 | 68 | Metal distance transform ≥2× CPU at 16K²; support ≤5 s |
| M7 Paths and G-code | Lin; Lin–Kernighan; Helsgaun; NISTIR 6556 | 1, 4, 8 | 62 | 100,000 islands ≤20 s and ≤1.08× reference travel |
| M8 CPU parallelism | Frigo; Lamport; Michael–Scott; Merrill–Garland | 1, 3, 4, 5 | 62 | ≥70% measured scan bandwidth; scheduler overhead <5% |
| M9 Metal | Metal specification; feature tables; resource and profiling docs | 3, 4, 7 | 60 | Intersection ≥1.6× CPU and medium end-to-end ≥15% faster |
| M10 Formats | 3MF Core; ZIP APPNOTE; RFC 1951; XML; NISTIR 6556 | 1, 8 | 56 | 100 million fuzz inputs; binary STL ≥1 GiB/s cached |
| M11 Odin and UI | Odin Overview and FAQ; Objective-C runtime; AAPCS64 | 2, 9, 10, 11 | 60 | p95 UI frame <16.7 ms; 10,000 lifetime cycles |
| M12 Verification and release | QuickCheck; differential testing; delta debugging; Apple notarization | All | 62 | Reduce injected failures <20 primitives; pass clean-machine release |

The curriculum total before the capstone is 738 hours. At 12–15 hours each
week, it spans approximately 50–62 weeks. Labs become implementation work, so
these hours overlap the engineering schedule instead of preceding it.

## C4. Capstone & Validation

The capstone is a three-week, 60-hour integration sprint. It produces one
vertical pipeline slice rather than a separate demonstration.

1. **Week 1, input through raw intersections.** Integrate bounded binary STL and
   3MF Core input, canonical mesh generations, fixed layer schedules,
   layer-span indexing, scalar predicates, CPU intersections, stable IDs,
   cancellation, and stage summaries. Verify analytic and degeneracy fixtures
   before adding optimization.
2. **Week 2, topology through G-code.** Integrate endpoint clustering, loop
   reconstruction, the initial polygon provider, two perimeters, rectilinear
   infill, deterministic nearest-neighbor path ordering, one validated G-code
   dialect, and content-addressed stage caching.
3. **Week 3, evidence and application.** Integrate `.hwsdebug` capture, canonical
   SVG and PNG rendering, the 3D and 2D views, timeline, inspector, CLI replay,
   structural UI checks, benchmark manifests, and crash artifacts.

The capstone passes only when all of these checks pass:

- The small mechanical fixture completes on the reference floor with CPU p50 at
  or below 1.5 seconds, at least 530 layers/s, and peak RSS at or below 400 MiB.
- Summary-only debug evidence adds no more than 5% p50 time and includes valid
  records for every implemented stage.
- Ten worker-count and scheduling variations produce identical canonical stage
  hashes and byte-identical G-code.
- The complete degeneracy subset produces zero topology invariant failures,
  crashes, missing fallbacks, or non-finite values.
- Cancelling each stage leaves no published final output and preserves any
  previous destination file.
- A capture replays without the source model. Its summary resolves one selected
  path through feature, region, loop, segment, triangle, and source record.
- The UI structural checks pass in both themes, and the canonical evidence
  renderer produces its golden SVG and PNG results.

Rubric: 35% geometry and output correctness, 20% deterministic evidence, 15%
bounded memory and cancellation, 15% benchmark thresholds, and 15% UI and
release artifact quality. Any correctness, ownership, or data-loss failure is
an automatic fail regardless of the weighted score.

## C5. Bibliography

### Numerical computation and geometry

- Chen, X., and McMains, S. “Polygon Offsetting by Computing Winding Numbers.”
  2005.
  [DOI 10.1115/DETC2005-85513](https://doi.org/10.1115/DETC2005-85513).
- Fortune, S., and van Wyk, C. J. “Efficient Exact Arithmetic for
  Computational Geometry.” 1993.
  [DOI 10.1145/160985.160998](https://doi.org/10.1145/160985.160998).
- Goldberg, D. “What Every Computer Scientist Should Know About Floating-Point
  Arithmetic.” 1991.
  [DOI 10.1145/103162.103163](https://doi.org/10.1145/103162.103163).
- Greiner, G., and Hormann, K. “Efficient Clipping of Arbitrary Polygons.”
  1998. [DOI 10.1145/274363.274364](https://doi.org/10.1145/274363.274364).
- Held, M. “FIST: Fast Industrial-Strength Triangulation of Polygons.” 2001.
  [DOI 10.1007/s00453-001-0028-4](https://doi.org/10.1007/s00453-001-0028-4).
- IEEE Computer Society. *IEEE 754-2019*. 2019.
  [DOI 10.1109/IEEESTD.2019.8766229](https://doi.org/10.1109/IEEESTD.2019.8766229).
- Martínez, F., Rueda, A. J., and Feito, F. R. “A New Algorithm for Computing
  Boolean Operations on Polygons.” 2009.
  [DOI 10.1016/j.cageo.2008.08.009](https://doi.org/10.1016/j.cageo.2008.08.009).
- Ogita, T., Rump, S. M., and Oishi, S. “Accurate Sum and Dot Product.” 2005.
  [DOI 10.1137/030601818](https://doi.org/10.1137/030601818).
- Priest, D. M. “Algorithms for Arbitrary Precision Floating Point
  Arithmetic.” 1991.
  [DOI 10.1109/ARITH.1991.145565](https://doi.org/10.1109/ARITH.1991.145565).
- Shewchuk, J. R. “Adaptive Precision Floating-Point Arithmetic and Fast Robust
  Geometric Predicates.” 1997.
  [DOI 10.1007/PL00009321](https://doi.org/10.1007/PL00009321).
- Sutherland, I. E., and Hodgman, G. W. “Reentrant Polygon Clipping.” 1974.
  [DOI 10.1145/360767.360802](https://doi.org/10.1145/360767.360802).
- Vatti, B. R. “A Generic Solution to Polygon Clipping.” 1992.
  [DOI 10.1145/129902.129906](https://doi.org/10.1145/129902.129906).
- de Berg, M. et al. *Computational Geometry: Algorithms and Applications*,
  3rd ed. ISBN 978-3-540-77973-5.
- Higham, N. J. *Accuracy and Stability of Numerical Algorithms*, 2nd ed.
  ISBN 978-0-89871-521-7.
- Muller, J.-M. et al. *Handbook of Floating-Point Arithmetic*, 2nd ed.
  ISBN 978-3-319-76525-9.

### Meshes, acceleration, and manufacturing

- Ahn, S.-H. et al. “Anisotropic Material Properties of Fused Deposition
  Modeling ABS.” 2002.
  [DOI 10.1108/13552540210441166](https://doi.org/10.1108/13552540210441166).
- Apetrei, C. “Fast and Simple Agglomerative LBVH Construction.” 2014.
  [DOI 10.1145/2619648.2619655](https://doi.org/10.1145/2619648.2619655).
- Attene, M. “A Lightweight Approach to Repairing Digitized Polygon Meshes.”
  2010. [DOI 10.1007/s00371-010-0416-3](https://doi.org/10.1007/s00371-010-0416-3).
- Barequet, G., and Kumar, S. “Repairing CAD Models.” 1997.
  [DOI 10.1109/VISUAL.1997.663888](https://doi.org/10.1109/VISUAL.1997.663888).
- Campen, M., and Kobbelt, L. “Exact and Robust (Self-)Intersections for
  Polygonal Meshes.” 2010.
  [DOI 10.1111/j.1467-8659.2009.01609.x](https://doi.org/10.1111/j.1467-8659.2009.01609.x).
- Ding, D. et al. “A Tool-Path Generation Strategy for Wire and Arc Additive
  Manufacturing.” 2014.
  [DOI 10.1007/s00170-014-5808-5](https://doi.org/10.1007/s00170-014-5808-5).
- Dolenc, A., and Mäkelä, I. “Slicing Procedures for Layered Manufacturing
  Techniques.” 1994.
  [DOI 10.1016/0010-4485(94)90032-9](https://doi.org/10.1016/0010-4485(94)90032-9).
- Goldsmith, J., and Salmon, J. “Automatic Creation of Object Hierarchies for
  Ray Tracing.” 1987.
  [DOI 10.1109/MCG.1987.276983](https://doi.org/10.1109/MCG.1987.276983).
- Jin, Y. et al. “Optimization of Tool-Path Generation for Material
  Extrusion-Based Additive Manufacturing Technology.” 2014.
  [DOI 10.1016/j.addma.2014.08.004](https://doi.org/10.1016/j.addma.2014.08.004).
- Ju, T. “Robust Repair of Polygonal Models.” 2004.
  [DOI 10.1145/1015706.1015815](https://doi.org/10.1145/1015706.1015815).
- Karras, T. “Maximizing Parallelism in the Construction of BVHs, Octrees,
  and k-d Trees.” 2012.
  [DOI 10.2312/EGGH/HPG12/033-037](https://doi.org/10.2312/EGGH/HPG12/033-037).
- Kulkarni, P., Marsan, A., and Dutta, D. “A Review of Process Planning
  Techniques in Layered Manufacturing.” 2000.
  [DOI 10.1108/13552540010309859](https://doi.org/10.1108/13552540010309859).
- Lauterbach, C. et al. “Fast BVH Construction on GPUs.” 2009.
  [DOI 10.1111/j.1467-8659.2009.01377.x](https://doi.org/10.1111/j.1467-8659.2009.01377.x).
- MacDonald, J. D., and Booth, K. S. “Heuristics for Ray Tracing Using Space
  Subdivision.” 1990.
  [DOI 10.1007/BF01911006](https://doi.org/10.1007/BF01911006).
- Pandey, P. M., Reddy, N. V., and Dhande, S. G. “Real Time Adaptive Slicing
  for Fused Deposition Modelling.” 2003.
  [DOI 10.1016/S0890-6955(02)00164-5](https://doi.org/10.1016/S0890-6955(02)00164-5).
- Tata, K. et al. “Efficient Slicing for Layered Manufacturing.” 1998.
  [DOI 10.1108/13552549810239003](https://doi.org/10.1108/13552549810239003).
- Turner, B. N., Strong, R., and Gold, S. A. “A Review of Melt Extrusion
  Additive Manufacturing Processes: I.” 2014.
  [DOI 10.1108/RPJ-01-2013-0012](https://doi.org/10.1108/RPJ-01-2013-0012).
- Wald, I. “On Fast Construction of SAH-Based Bounding Volume Hierarchies.”
  2007. [DOI 10.1109/RT.2007.4342588](https://doi.org/10.1109/RT.2007.4342588).
- Botsch, M. et al. *Polygon Mesh Processing*. ISBN 978-1-56881-426-1.
- Gibson, I. et al. *Additive Manufacturing Technologies*, 3rd ed.
  ISBN 978-3-030-56126-0.

### Fields, support, routing, and parallel execution

- Dantzig, G. B., and Ramser, J. H. “The Truck Dispatching Problem.” 1959.
  [DOI 10.1287/mnsc.6.1.80](https://doi.org/10.1287/mnsc.6.1.80).
- Dumas, J., Hergel, J., and Lefebvre, S. “Bridging the Gap.” 2014.
  [DOI 10.1145/2601097.2601153](https://doi.org/10.1145/2601097.2601153).
- Felzenszwalb, P. F., and Huttenlocher, D. P. “Distance Transforms of Sampled
  Functions.” 2012.
  [DOI 10.4086/toc.2012.v008a019](https://doi.org/10.4086/toc.2012.v008a019).
- Frigo, M. et al. “Cache-Oblivious Algorithms.” 1999.
  [DOI 10.1109/SFFCS.1999.814600](https://doi.org/10.1109/SFFCS.1999.814600).
- Helsgaun, K. “An Effective Implementation of the Lin–Kernighan Traveling
  Salesman Heuristic.” 2000.
  [DOI 10.1016/S0377-2217(99)00284-2](https://doi.org/10.1016/S0377-2217(99)00284-2).
- Hu, K., Jin, S., and Wang, C. C. L. “Support Slimming for Single Material
  Based Additive Manufacturing.” 2015.
  [DOI 10.1016/j.cad.2015.03.001](https://doi.org/10.1016/j.cad.2015.03.001).
- Jiang, J., Xu, X., and Stringer, J. “Optimization of Process Planning for
  Reducing Material Waste in Extrusion Based Additive Manufacturing.” 2019.
  [DOI 10.1016/j.rcim.2019.05.007](https://doi.org/10.1016/j.rcim.2019.05.007).
- Jones, M. W., Bærentzen, J. A., and Sramek, M. “3D Distance Fields.” 2006.
  [DOI 10.1109/TVCG.2006.56](https://doi.org/10.1109/TVCG.2006.56).
- Lamport, L. “How to Make a Multiprocessor Computer That Correctly Executes
  Multiprocess Programs.” 1979.
  [DOI 10.1109/TC.1979.1675439](https://doi.org/10.1109/TC.1979.1675439).
- Lin, S. “Computer Solutions of the Traveling Salesman Problem.” 1965.
  [DOI 10.1002/j.1538-7305.1965.tb04146.x](https://doi.org/10.1002/j.1538-7305.1965.tb04146.x).
- Lin, S., and Kernighan, B. W. “An Effective Heuristic Algorithm for the
  Traveling-Salesman Problem.” 1973.
  [DOI 10.1287/opre.21.2.498](https://doi.org/10.1287/opre.21.2.498).
- Meijster, A., Roerdink, J. B. T. M., and Hesselink, W. H. “A General
  Algorithm for Computing Distance Transforms in Linear Time.” 2000.
  [DOI 10.1007/0-306-47025-X_36](https://doi.org/10.1007/0-306-47025-X_36).
- Merrill, D., and Garland, M. “Single-Pass Parallel Prefix Scan with Decoupled
  Look-Back.” 2016.
  [Stable report](https://research.nvidia.com/publication/2016-03_single-pass-parallel-prefix-scan-decoupled-look-back).
- Michael, M. M., and Scott, M. L. “Simple, Fast, and Practical Non-Blocking
  and Blocking Concurrent Queue Algorithms.” 1996.
  [DOI 10.1145/248052.248106](https://doi.org/10.1145/248052.248106).
- Satish, N. et al. “Designing Efficient Sorting Algorithms for Manycore GPUs.”
  2009. [DOI 10.1109/IPDPS.2009.5161005](https://doi.org/10.1109/IPDPS.2009.5161005).
- Vanek, J., Galicia, J. A. G., and Benes, B. “Clever Support.” 2014.
  [DOI 10.1111/cgf.12437](https://doi.org/10.1111/cgf.12437).

### Formats, tooling, verification, and distribution

- 3MF Consortium. *3MF Core Specification*, version 1.3.0, 2021.
  [Official specification](https://3mf.io/spec/).
- Apple. *Metal Shading Language Specification* and *Metal Feature Set Tables*,
  current editions. [Metal resources](https://developer.apple.com/metal/).
- Apple. “Notarizing macOS Software Before Distribution,” current
  documentation. [Official documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
- Arm. *Procedure Call Standard for the Arm 64-bit Architecture*, current
  release. [Official ABI releases](https://github.com/ARM-software/abi-aa/releases).
- Claessen, K., and Hughes, J. “QuickCheck.” 2000.
  [DOI 10.1145/351240.351266](https://doi.org/10.1145/351240.351266).
- Deutsch, P. “DEFLATE Compressed Data Format Specification.” 1996.
  [DOI 10.17487/RFC1951](https://doi.org/10.17487/RFC1951).
- Georges, A., Buytaert, D., and Eeckhout, L. “Statistically Rigorous Java
  Performance Evaluation.” 2007.
  [DOI 10.1145/1297027.1297033](https://doi.org/10.1145/1297027.1297033).
- Kramer, T. R., Proctor, F. M., and Messina, E. *The NIST RS274NGC
  Interpreter, Version 3*. 2000.
  [DOI 10.6028/NIST.IR.6556](https://doi.org/10.6028/NIST.IR.6556).
- Lemire, D. “Number Parsing at a Gigabyte per Second.” 2021.
  [DOI 10.1002/spe.2984](https://doi.org/10.1002/spe.2984).
- McKeeman, W. M. “Differential Testing for Software.” 1998.
  [Stable paper](https://www.digiater.nl/openvms/decus/vmslt98b/nt/differential_testing_for_software.pdf).
- Mytkowicz, T. et al. “Producing Wrong Data Without Doing Anything Obviously
  Wrong!” 2009.
  [DOI 10.1145/1508244.1508275](https://doi.org/10.1145/1508244.1508275).
- Odin Project. *Overview*, *FAQ*, and core package documentation, current
  editions. [Official site](https://odin-lang.org/docs/).
- PKWARE. *.ZIP File Format Specification*, current revision.
  [Official APPNOTE](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT).
- W3C. *XML 1.0, Fifth Edition*. 2008.
  [Official recommendation](https://www.w3.org/TR/2008/REC-xml-20081126/).
- Zeller, A., and Hildebrandt, R. “Simplifying and Isolating Failure-Inducing
  Input.” 2002.
  [DOI 10.1109/32.988498](https://doi.org/10.1109/32.988498).

## Deliverables Checklist

- [x] Executive Summary with 11 bullets.
- [x] One ASCII architecture diagram.
- [x] Sections 1–11 with Problem & Goals, Decisions & Rationale, Concrete
  Techniques, Risks & Mitigations, and Measurable Acceptance Criteria.
- [x] GUI, planar-kernel, benchmark, debug-evidence, and curriculum roadmap
  tables.
- [x] Apple-specific FFI and link flags, profiling, Metal, packaging,
  notarization, sandbox, determinism, and QA plans.
- [x] A visual-debug and structured-evidence contract for every pipeline stage.
- [x] Curriculum C0–C5 with 12 modules, primary and secondary readings, courses,
  labs, milestones, time estimates, roadmap, capstone, and bibliography.
- [x] Reality checks, assumptions, open questions, and six self-scores.
- [x] No implementation source code.

## Appendix A: Reality Checks

1. **Wrong claim: Unified memory makes CPU-GPU transfer and synchronization
   free.** Shared physical memory can remove a discrete-device copy, but storage
   mode, caches, hazards, command scheduling, and CPU-GPU waits still consume
   time. Measure shared and private paths with complete command timing.
2. **Wrong claim: A GPU triangle intersection automatically makes the slicer
   faster.** Pair construction, command encoding, readback, sorting,
   canonicalization, and CPU fallbacks remain. Accept Metal only after the
   medium end-to-end request improves by 15%.
3. **Wrong claim: Metal provides a fast general `f64` geometry path on every
   Apple GPU.** The project must not depend on GPU double precision. Scale
   bounded work to `f32`, calculate error intervals, and replay uncertain
   topology on CPU.
4. **Wrong claim: A BVH is always the best accelerator for slicing.** Parallel
   horizontal planes need each triangle's layer interval. A layer-span index
   visits the direct candidate pairs, while a BVH remains useful for other
   spatial queries.
5. **Wrong claim: One small epsilon fixes geometric robustness.** Scale,
   conditioning, manufacturing tolerance, and exact topological decisions are
   different concerns. Use named tolerances plus proven predicate bounds.
6. **Wrong claim: Integer polygon coordinates eliminate all robustness
   failures.** Event ordering, overlap semantics, checked products, offset
   joins, fill rules, and conversion into the integer grid can still fail.
7. **Wrong claim: `mmap` is always faster than `read`.** Page faults, access
   order, file mutation, compressed formats, and small-file overhead change the
   result. Benchmark both providers and keep mapping behind a validated span.
8. **Wrong claim: GCD assigns hot work to performance cores in a deterministic
   order.** Public scheduling APIs do not provide that contract. Partition work,
   set appropriate QoS, avoid oversubscription, and canonicalize outputs.
9. **Wrong claim: Direct `objc_msgSend` calls remove the need for a shim.**
   Different return and argument ABIs, blocks, ownership, and SDK structure
   layouts still need typed declarations. A narrow shim centralizes them.
10. **Wrong claim: Odin's foreign system is a package manager or full macOS
    binding generator.** It links foreign symbols. This project still pins
    dependencies, verifies sources, generates narrow bindings, and owns shims.
11. **Wrong claim: Notarization requires App Sandbox.** Direct Developer ID
    distribution requires signing and hardened runtime, while sandboxing is a
    separate product and distribution choice. Test both configurations only if
    both are planned.
12. **Wrong claim: The Apple Neural Engine can run arbitrary slicing kernels.**
    Public general-purpose ANE programming is unavailable. Core ML is not an
    appropriate replacement for deterministic polygon and path algorithms.
13. **Wrong claim: Matching a third-party polygon library proves correctness.**
    It proves agreement under normalized semantics. Independent invariants,
    analytic fixtures, fuzzing, and reduced counterexamples remain required.
14. **Wrong claim: A deterministic SVG proves the underlying geometry is
    correct.** The render proves presentation stability. Structured primitives,
    topology invariants, provenance, and independent oracles prove separate
    properties.

## Appendix B: Assumptions & Open Questions

| Item | Current assumption | Validation before commitment |
|---|---|---|
| Minimum hardware | Base M1-class Apple Silicon with 16 GiB is the performance floor | Run the complete benchmark and UI suite on the oldest intended machine |
| Minimum macOS | Undecided until required AppKit, Metal, and security APIs are inventoried | Build an API availability table, then test a clean installation at that version |
| Development compiler | Start from the workspace's validated Odin revision, then create a project pin | Run compiler smoke, full tests, dSYM, ASan, and benchmark gates |
| Build volume bound | Normalized coordinates fit a documented printer-scale bound before micrometre conversion | Derive safe `i64` and `i128` limits and reject boundary-plus-one fixtures |
| Planar grid | One signed integer unit equals one micrometre | Compare displacement and feature loss against printer profiles and golden models |
| Polygon dependency | A pinned Clipper2 provider is acceptable for initial production and as an oracle | Review license, source, checksum, ABI, semantics, speed, and notarized bundle |
| Archive and XML provider | Undecided between small vendored libraries and narrow project implementations | Build a security, licensing, fuzzability, maintenance, and throughput matrix |
| 3MF coverage | Core 1.3.0 first; Materials and Production follow; current revisions require separate review | Run official conformance files and a vendor corpus, then record required extensions |
| Repair default | Safe local repairs run automatically; volume-changing repairs require explicit approval | Measure a licensed broken-model corpus and conduct before/after human review |
| Adaptive layers | Included after fixed-layer correctness, with profile limits and cusp evidence | Compare analytic surface error, print time, and firmware Z resolution |
| GPU value | Intersections and dense fields will meet the defined speedup gates | Implement CPU baselines, then profile on oldest and newest supported M-series GPUs |
| GPU limits | Threadgroup and memory values come from runtime properties and current feature tables | Record capabilities and calibration in benchmark manifests on each machine |
| Support scope | Normal supports and interfaces are release requirements; tree supports are a later gated provider | Define stability, trapped-volume, collision, material, and print validation fixtures |
| Multi-material scope | Contracts preserve material and tool ownership from the start | Choose target printers and define purge, wipe, prime, tool-change, and tower policy |
| G-code dialects | One Marlin-compatible dialect is first; other firmware requires provider tests | Select physical printers, pin documentation, dry-run, and compare parsed state |
| Printer profiles | Profiles are versioned data, not bundled claims until verified | Obtain manufacturer data, record license and source, then run physical calibration |
| Benchmark corpus | Generated fixtures plus redistributable real models can cover scale and defects | Select exact models, record licenses and SHA-256 hashes, and publish expected results |
| Performance thresholds | The table defines the desired release floor | Calibrate the initial scalar engine; revise only through a recorded engineering decision |
| App Sandbox | Direct notarized distribution launches without sandboxing | Revisit only if Mac App Store distribution or stronger containment becomes a requirement |
| Debug package size | Summary is always on; primitives and renders are filtered and budgeted | Capture huge-model failures and set default, warning, and hard limits from evidence |
| AI-readable evidence | JSON summaries, stable IDs, SVG, PNG, and explicit schemas are sufficient | Give blind captures to independent human and multimodal AI reviews and score diagnosis |
| Physical print validation | Geometry and G-code simulation precede controlled printer tests | Define safe printers, materials, calibration parts, observation forms, and abort criteria |
| Remote printer control | Out of scope for the slicer release | Add only through a separate security, network, device, and failure-recovery plan |
| Schedule | 38–52 engineer-weeks assumes focused execution and reuses curriculum labs | Re-estimate at every delivery gate from measured throughput and unresolved defects |

## Self-Score

- **Specificity — 5/5.** The plan fixes stage contracts, numeric domains, debug
  artifacts, providers, kernels, gates, commands, and acceptance measurements.
- **Feasibility — 4/5.** The staged CPU-first path and initial polygon provider
  are practical, but full support and multi-material quality require physical
  validation and may extend the schedule.
- **Apple-Silicon Accuracy — 5/5.** The plan uses runtime Metal limits, explicit
  resource modes, ARM64 validation, native profiling, and no invented device
  capacity.
- **Odin Specificity — 5/5.** It defines compiler pins, allocator boundaries,
  foreign linking, Objective-C shims, rebuild watchers, symbol analysis, and
  concrete tooling mitigations.
- **Performance Rigor — 5/5.** It separates microbenchmarks from end-to-end
  results and records memory, fallbacks, thermal state, synchronization, raw
  samples, and deterministic hashes.
- **Testability — 5/5.** Every section has quantitative gates backed by
  analytic fixtures, conformance tests, differential providers, fuzzing,
  evidence replay, structural UI checks, and clean-machine release tests.
