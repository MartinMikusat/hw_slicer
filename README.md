# HW Slicer

An Apple Silicon macOS slicer that converts 3D models into deterministic FFF
toolpaths and exposes visual evidence for every pipeline stage.

## AI-assisted development disclosure

Models used:

- **gpt-5.6-sol**
- **gpt-image-2**

## Status

The native mesh viewer and G0 foundation milestone are implemented. G1 reaches
deterministic CPU loop reconstruction. G2 includes strict region
classification, printable feature generation, unified path planning,
fixed-point extrusion, and constrained motion planning. G3 has an initial
Klipper emitter, an independent state replay validator, and atomic file
publication. G-code targets Klipper only. The profile contract resolves these policies against explicit
printer and material limits before geometry execution.

The [technical implementation plan](PLAN.md) defines the subsystem contracts,
CPU and Metal execution paths, visual-debug protocol, delivery gates,
benchmarks, and research curriculum.

The [roadmap progress note](notes/hw-slicer-roadmap-progress.md) separates
implemented gates, measured bottlenecks, settled contracts, and open product
decisions.

The [research library](research/README.md) stores verified citations, engineering
notes, PDF snapshots, provenance, checksums, and explicit project use decisions.

The SvelteKit research site in `research-site/` presents the catalog through
search, filters, summaries, limitations, and use-state views.

## Viewer implementation

The viewer uses Apple system APIs and project-owned code:

- AppKit creates the window and sends input events.
- `CAMetalLayer` presents frames.
- Metal allocates the mesh buffers, depth texture, pipeline states, and command
  buffers directly for the 3D scene.
- `hw_odin_rune` (`rune:gpu`, `rune:text`) draws the 2D interface and its
  Core Text glyphs into the same command buffer after the scene passes.
- Project code parses STL files and constructs the camera, interface, and
  control registry.
- `hw_odin_ui_flash` selects keyboard targets. It does not render controls or
  own application actions.

The implementation does not use a scene library, MetalKit, or a layout or
widget framework.

The viewer loads the three bundled reference models or an exact binary STL
selected through `01 OPEN`. The same action opens a validated `.hwsdebug`
package in the stage timeline and inspector, which dismisses with Escape or a
click outside the inspector.
The inspector retains the layer schedule, triangle layer-span index, CPU
intersection graph, planar ownership graph, snapped segments, topology, region,
exposed-surface, skin-propagation, perimeter, sparse-infill, unified
feature-source, current unified path-plan, legacy path-plan, extrusion, motion,
and G-code graphs without the source model. Pointer, Flash, and Accessibility
input select one stage record.

The viewer supports orbit, pan, zoom, frame-to-bounds, wireframe rendering,
light and dark themes, Flash navigation, and Accessibility actions. The SECTION
control drags a cutting plane through the loaded mesh and draws the resulting
plane contour in the scene. The top-right `SETTINGS` entry opens the settings
modal; `⌘,` toggles it, and the font size (12–18 pt) scales the whole interface.
The remaining numbered action slots stay visible and disabled until their
slicing stages exist.

Build and run the development app:

```sh
./test.sh
./dev.sh debug
```

The watcher builds `build/hw_slicer.app` and launches it behind the active
application. A source or resource change rebuilds the complete app. The watcher
replaces the running process only after a successful build. Use
`./dev.sh asan` for AddressSanitizer development.

Capture or check the current live control registry:

```sh
./scripts/ui.sh snapshot
./scripts/ui.sh check
```

These commands require the running application. They keep detailed artifacts
under `.hw-slicer-runtime/` and return only the control count and artifact path.

## Engine foundation

The G0 foundation provides:

- Versioned request, stage, provider, result, and debug-evidence contracts.
- Deterministic 64-bit identifiers from source hashes and canonical order.
- Checked `f64` millimetre to `i64` micrometre conversion.
- Exact `i128` planar orientation within the accepted coordinate bound.
- A versioned debug-evidence manifest with a golden JSON fixture.
- Valid UTF-8 artifact paths, format tokens, schemas, and destination uniqueness.
- A preflighted little-endian layer-schedule artifact with source-independent
  replay.
- A preflighted little-endian layer-span artifact with source-independent
  replay.
- A preflighted little-endian CPU-intersection artifact with source-independent
  replay.
- A preflighted little-endian planar-ownership artifact with source-independent
  replay.
- A preflighted little-endian snapped-segment artifact with source-independent
  replay.
- A preflighted little-endian path-plan artifact with hash-validated replay.
- A preflighted little-endian exposed-surface artifact with source-independent
  replay.
- A preflighted little-endian skin-propagation artifact with dependency-checked
  source-independent replay.
- A preflighted little-endian perimeter artifact with source-independent
  replay.
- A preflighted little-endian sparse-infill artifact with source-independent
  replay.
- A preflighted little-endian unified feature-source artifact with
  source-independent replay.
- A preflighted little-endian unified path-plan artifact with
  source-independent replay.
- A versioned feature request hash and registered CPU path-planner provider.
- A bounded canonical SVG renderer for one decoded path-plan layer.
- A versioned root evidence-bundle manifest with ordered stage descriptors.
- A deterministic stored-ZIP bundle writer and bounded package validator.
- A shared source-file reader that checks size and file growth before decode.
- A checked benchmark harness with raw samples and canonical output hashes.
- Compiler, ARM64 ABI, ASan, dSYM, and application build checks.

Run the scalar benchmark:

```sh
./benchmark.sh
```

The benchmark emits one JSON record. It validates the output hash before it
reports timing.

## Deterministic slice engine

The current engine implementation provides:

- Bounded binary STL, ASCII STL, and OBJ decode with source hashes and
  byte-offset provenance.
- Independent OBJ position, texture, and normal indexes with negative-index
  resolution and deterministic planar polygon triangulation.
- OBJ object, group, smoothing-group, material, and material-library state
  records mapped to each retained source face.
- Bounded 3MF ZIP, OPC, XML, Core mesh, component, material, and metadata
  decode.
- Stable 3MF package-part records with role, path, compression, CRC, size, and
  verified extraction provenance.
- Bounded canonical payload preservation for unknown optional 3MF resource
  namespaces, with resource IDs, model-part provenance, and SHA-256 hashes.
- Deterministic 3MF transform flattening with instance and source provenance.
- Unit resolution into canonical `f64` millimetre mesh arrays.
- Exact-coordinate vertex welding for immutable mesh-defect audits.
- Degenerate face, duplicate face, boundary edge, non-manifold edge, and
  inconsistent-winding reports with triangle provenance.
- Fixed micrometre layer schedules with canonical Z values and stable IDs. Each
  layer is sectioned at its mid-height and printed at its top, and layers
  continue while the section plane is below the model top, so the printed
  height is the model height rounded to the nearest layer.
- A bounded little-endian layer-schedule artifact that retains the request and
  result hashes, Z bounds, first plane, first-layer height, step, and every
  scheduled layer.
- Two-pass triangle span indexes with canonical range and pair validation.
- A bounded little-endian layer-span artifact that retains each triangle range,
  layer descriptor, triangle-layer pair, stable ID, and dependency hash.
- Filtered plane classification with an exact scalar fallback.
- Two-pass CPU intersections with separate planar and degeneracy results.
- A bounded little-endian CPU-intersection artifact that retains each layer,
  raw segment, planar candidate, diagnostic counter, and dependency hash.
- Half-open ownership resolution for manifold coplanar edge groups.
- A bounded little-endian planar-ownership artifact that retains each owned
  segment, source edge, diagnostic counter, and CPU-intersection parent hash.
- Canonical micrometre endpoint snapping and deterministic loop reconstruction.
- A bounded little-endian snapped-segment artifact that retains canonical
  geometry, triangle provenance, quantization errors, and its parent hash.
- Strict loop containment with outer, hole, and nested-island classification.
- Edge-bounds rejection before exact contour-intersection predicates.
- Structured region failures with layer, contour, path, and edge provenance.
- Pinned Clipper2 integer Boolean and offset operations behind a project-owned
  provider contract and C ABI.
- Canonical polygon rotation, path ordering, coordinate checks, and output
  limits at the provider boundary.
- Explicit self-intersection repair with fill-rule selection, a named lineage
  tolerance, and output-edge links to source paths, edges, and segments.
- Adjacent-layer Boolean classification of top-exposed and bottom-exposed
  region masks, without assigning profile-dependent skin depth or extrusion.
- A bounded little-endian exposed-surface artifact that retains each layer,
  mask, canonical path, point, configuration value, and result hash.
- Top and bottom skin propagation through physical thickness and minimum layer
  counts, including one disjoint role for simultaneous top and bottom skin.
- Exact skin-to-surface provenance with target-region clipping and a canonical
  stage hash.
- A bounded little-endian skin-propagation artifact that retains layer heights,
  masks, paths, points, source references, configuration values, dependency
  hashes, and the canonical result hash.
- Perimeter bead coverage, uncovered-region, printable-center, over-wide-core,
  and unprinted-remainder masks for thin-wall and gap diagnosis.
- Conservative half-width rounding recorded in a canonical gap-evidence hash.
- Deterministic cross-section samples along each uncovered region's dominant
  axis, with exact one-line, two-line, and unprinted width allocations.
- Doubled-micrometre center coordinates that preserve half-micrometre positions
  without floating-point path state.
- Conservative gap and thin-wall path candidates that connect only continuous
  one-line or two-line sample runs.
- Explicit issues for ambiguous branches, allocation transitions, unprinted
  widths, over-wide regions, and runs with insufficient samples.
- Unsupported bridge masks from current-layer regions minus expanded
  preceding-layer model support.
- Separate bridge evidence for eligible areas and unsupported areas below the
  configured minimum, including exact signed area.
- Bounded bridge-angle scoring with quantized direction vectors, projected
  unsupported span, and separate anchor capacity for both path directions.
- Explicit one-sided bridge evidence when no candidate reaches support at both
  ends.
- Globally phased bridge paths at the nominal line width for each selected
  direction, including arbitrary configured angles.
- Exact rational boundary intersections, explicit micrometre rounding error,
  and canonical path hashes for bridge line endpoints.
- Per-triangle support-demand classification from source winding, downward
  face normals, and the configured surface angle from vertical.
- Canonical micrometre projections and source-triangle provenance for each
  downward overhang face.
- Planar support-demand masks from adjacent-layer model projection intersected
  with the classified mesh overhang projections.
- Fixed-point lateral overhang margins and exact source-face references for
  every nonempty support-demand layer.
- Downward support propagation through physical Z clearance, support
  expansion, and per-layer XY model clearance.
- Disjoint regular and interface support masks, plus build-plate reachability
  filtering and explicit unresolved-demand counts.
- Rectilinear support paths with density-derived regular spacing and explicit
  interface spacing.
- Half-line boundary insets, alternating layer axes, exact rational boundary
  hits, and canonical support-path hashes.
- Priority-ordered model-role subtraction before path generation, with
  canonical source ordering and exact removed-area evidence.
- Explicit rejection of overlapping equal-priority masks, including separate
  evidence for sources that higher-priority geometry removes completely.
- Solid skin paths with the configured spacing, base angle, and per-layer
  angle step, including arbitrary angles and half-line boundary insets.
- Exact rational solid-path endpoints, collision-free path-set identifiers,
  collapsed-mask counts, and canonical hashes.
- A unified role-ordered path plan for perimeter, bridge, gap, skin, sparse
  infill, and support sources.
- Deterministic open-path reversal, corner-first rear-visible seam selection,
  per-endpoint line widths, explicit travel moves, and canonical plan hashes.
- A bounded little-endian unified path-plan artifact that retains each layer,
  source identity, selected seam, path, move, endpoint width, and result hash.
- Canonical adapters from every generated path result into the unified source
  layout, including inner-first perimeter ordering and variable gap widths.
- A bounded little-endian unified feature-source artifact that retains each
  role, layer, path, point, width, dependency, and result identity.
- Rounded-bead extrusion volume from endpoint widths and layer height, using a
  pinned fixed-point value of pi and nanometre path lengths.
- Per-role flow scaling and fixed-point filament length with one carried
  remainder across moves, plus exact volume and rounding evidence.
- A bounded little-endian extrusion artifact that retains every fixed-point
  numerator, denominator, length quantum, carry remainder, dependency, and
  result identity. Replay verifies its calculations without source paths.
- Per-role speed, acceleration, and fan annotations with deterministic layer
  duration estimates.
- Exterior-crossing retraction and recovery operations, bounded short-layer
  slowdown, and residual dwell after the minimum print speed is reached.
- A bounded little-endian motion artifact that retains path, extrusion,
  printer, process, layer, operation, timing, and result identities. Package
  and directory replay retain it beside the path-plan primitive in one stage.
- Klipper file emission with millimetre units, absolute XYZ, and relative
  extrusion. The printer's `START_PRINT` macro receives the temperatures and
  the extrusion area and owns homing, heating, meshing, and priming;
  `END_PRINT` owns retraction, parking, and shutdown. Each layer reports
  `SET_PRINT_STATS_INFO`, and acceleration uses `SET_VELOCITY_LIMIT`.
- Exact decimal coordinate, feed, acceleration, and extrusion formatting with
  command-to-motion correlation records.
- An independent strict parser that replays modes, the start and end macros,
  layer reporting, acceleration, cooling, motion, extrusion, and bounds.
- A bounded little-endian G-code artifact that retains profile revisions,
  motion identity, command correlation, summary values, and exact output bytes.
  Generic evidence capture applies budgets before full decoding. Its stage
  manifest cross-checks identity, descriptor, counters, and the result hash.
  Package and directory replay retain the validated graph for inspection.
- Atomic create-only and explicit replacement publication for validated
  `.gcode` files, with synchronized sibling staging and failure cleanup.
- Configured perimeter centerlines at half-width inward offsets, including
  holes, split outputs, collapsed groups, and stable feature identifiers.
- A bounded little-endian perimeter artifact that retains each layer, offset
  group, canonical path, point, configuration value, and result hash.
- Alternating rectilinear infill from globally phased scanlines, with exact
  rational intersections and explicit micrometre rounding evidence.
- A bounded little-endian sparse-infill artifact that retains each layer,
  segment, exact rational boundary hit, configuration value, and result hash.
- Layer and region path ordering with inner perimeters first, canonical nearest
  starts, deterministic infill direction, and explicit travel moves.
- Disjoint feature-ordinal ranges for perimeters, exposed surfaces, and infill.
- Versioned golden hashes for each implemented stage boundary.

The profile resolver provides:

- Separate versioned printer, material, process, and Klipper dialect documents.
- Required canonical units for every physical and process field.
- Combined physical thickness and minimum layer-count skin targets.
- The selected overlap, thin-wall, gap, bridge, support, extrusion, and motion
  policies.
- Explicit process-target validation against printer and material limits.
- Explicit machine-coordinate bounds, one-extruder enforcement, and bounded
  extruder motion limits.
- Typed acceleration, cooling, and file-output policies for the Klipper
  target.
- Deterministic first-layer override resolution and thin-wall width conversion.
- Exact gap-width allocation into unprinted evidence, one centered line, two
  partitioned lines, or a region that is too wide for gap fill.
- Canonical profile revision hashes for each normalized document.
- Per-stage settings hashes that mark only the affected stages stale (see [staged pipeline](docs/staged-pipeline.md)).
- Explicit owner and invalidation metadata for every normalized field group.
- Rejection before geometry execution when a document or resolved target is
  invalid.

The main test command runs these package tests with the viewer tests:

```sh
./test.sh
```

Slice a model and optionally emit a `.hwsdebug` evidence bundle with the unified CLI:

```sh
./build.sh cli-release
build/release/hw-slicer-cli \
  --input=resources/models/benchy.stl \
  --out=build/gcode/benchy.gcode \
  --evidence-bundle=build/benchy.hwsdebug
```

Compare feature-enabled builds with the end-to-end slicing benchmark. Save a
baseline CLI before changing the slicer. The benchmark rebuilds the candidate.

```sh
./build.sh cli-release
cp build/release/hw-slicer-cli build/baseline-cli
```

After making changes, compare both builds on Benchy.

```sh
./slice-benchmark.sh --suite=core --model=benchy.stl --scenario=ironing \
  --ab=build/baseline-cli --runs=5 --out-json=build/ironing-ab.json
```

Repeat `--scenario` to select presets, or use `--scenarios` for the full set
shared with the OrcaSlicer comparison. Repeat `--hw-set=KEY=VALUE` to override
settings on both builds. With `--compare-orca`, the runner applies the matching
OrcaSlicer preset. Use `--orca-set=KEY=VALUE` to override its settings separately.

Run the validated G1 vertical-spine benchmark:

```sh
./spine-benchmark.sh
```

The benchmark pins the fixture and topology hashes. It reports raw sorted
samples, p50, p95, pairs per second, and layers per second.

Run the repaired-region feature benchmark:

```sh
./feature-benchmark.sh
```

This benchmark times region classification, exposed-surface masks, two
perimeters, exact rectilinear infill, and planar path planning. It validates
every stage hash during two warmup runs and 20 measured runs. It reports total
and per-stage p50 and p95 timings. It also reports Boolean and offset call
counts. The release gate requires a total p95 below three seconds.

Validate and inspect `.hwsdebug` evidence bundles or directories without the source model:

```sh
./evidence-bundle-validate.sh build/benchy.hwsdebug
./evidence-directory-validate.sh build/benchy.hwsdebug-dir
./evidence-inspect.sh build/benchy.hwsdebug
```

The validator applies the ZIP limits, verifies the root and stage manifests,
verifies every content descriptor, and replays supported stage graphs without
reading the source model.

The [path-plan evidence artifact contract](notes/hw-slicer-path-plan-evidence-artifact.md)
defines the binary layout, validation sequence, production fixture, and
performance gate. The
[topology evidence artifact contract](notes/hw-slicer-topology-evidence-artifact.md)
defines the complete graph layout, manifest binding, source-free region replay,
and performance gate. The
[region evidence artifact contract](notes/hw-slicer-region-evidence-artifact.md)
defines the topology-dependent region graph, production fixture, and
performance gate. The
[`.hwsdebug` bundle contract](notes/hw-slicer-evidence-bundle-contract.md)
defines the implemented root schema, transfer ZIP, validation order, and open
publication policy.

Run the Clipper2 conformance and performance gates:

```sh
./scripts/clipper2-test.sh debug
./scripts/clipper2-test.sh release
./scripts/clipper2-test.sh asan
./polygon-benchmark.sh
```

The release benchmark unions 4,096 disjoint paths. It pins the canonical
output hash and requires at least one million input edges per second.

The bundled all-in-one model has no open chains or degenerate loops. Its raw
topology retains one degree-four slice vertex. The explicit contour repair
replaces the affected path, compacts its orphaned vertices, and produces strict
printable topology for feature generation. The strict policy rejects raw
topology with open chains, degenerate loops, or non-manifold vertices.

Exposed-surface masks are geometric evidence, not final print roles. A
single-layer feature can be both top-exposed and bottom-exposed. A future
process profile must select skin depth and resolve role overlap before path
generation. Region inputs use positive outer contours and negative holes, so
the surface stage rejects the negative-winding fill rule instead of emitting an
empty result.

The official Core examples, selected archived verifier cases, and pinned Assimp
OBJ fixtures cover package decode, OBJ edge cases, and deterministic
flattening. Unknown optional resource XML trees remain available to future
extension providers. Long-running format fuzz campaigns and larger real-world
degeneracy corpora remain open.

## Development dependencies

The project requires Apple Silicon macOS, Xcode 26.6 with its C++17 compiler,
and the workspace-global compiler managed by `hw_odin_toolchain`.

The project compiler wrapper forwards every command to `hw-odin` and disables
the threaded semantic checker because concurrent checks can crash on these
packages. Test execution and optimized code generation remain parallel.

`dependencies.lock` pins the sibling checkouts of `hw_odin_ui_flash`,
`hw_odin_devlog`, and `hw_odin_rune` to their repository URLs and commits.
The build rejects a different sibling checkout. The build compiles the rune
shaders into `hw_odin_rune/build/rune.metallib` before it compiles the
application.

## Bundled third-party assets

| Asset | Version | Source | SHA-256 | License |
| --- | --- | --- | --- | --- |
| Clipper2 integer clipping and offset source bundle | 2.0.1, commit `21ebba05db8894f0c7217ad35ea518080f324946` | [Official tag](https://github.com/AngusJohnson/Clipper2/tree/Clipper2_2.0.1) | [`be03fc289ca704b97133fcc26fc1167cc5a88554226abf73dc80dccf18448bbe`](third_party/clipper2/SHA256SUMS) | [`third_party/clipper2/LICENSE`](third_party/clipper2/LICENSE) |
| Iconoir `xmark.svg` | 7.11.1, commit `3497016dcb93122b5a64a2df1221598a14ecf4f3` | [Official repository](https://github.com/iconoir-icons/iconoir/blob/v7.11.1/icons/regular/xmark.svg) | `61aa0a4913a440aaafcc45064a87e24fe8eb22ba4abc4c5ef020530928ed8daf` | [`resources/icons/iconoir/LICENSE`](resources/icons/iconoir/LICENSE) |
| Iconoir `minus.svg` | 7.11.1, commit `3497016dcb93122b5a64a2df1221598a14ecf4f3` | [Official repository](https://github.com/iconoir-icons/iconoir/blob/v7.11.1/icons/regular/minus.svg) | `babb05bca016bffdd38cbd1dcaeef6ccdf42fc8654124dee169a412eeed6d425` | [`resources/icons/iconoir/LICENSE`](resources/icons/iconoir/LICENSE) |
| Iconoir `maximize.svg` | 7.11.1, commit `3497016dcb93122b5a64a2df1221598a14ecf4f3` | [Official repository](https://github.com/iconoir-icons/iconoir/blob/v7.11.1/icons/regular/maximize.svg) | `3a3048cdc0e8e4aef5d68353b5434f0c0e074dc672b6c0abf25a5a64bc5cc8f4` | [`resources/icons/iconoir/LICENSE`](resources/icons/iconoir/LICENSE) |
| Iconoir `help-circle.svg` | 7.11.1, commit `3497016dcb93122b5a64a2df1221598a14ecf4f3` | [Official repository](https://github.com/iconoir-icons/iconoir/blob/v7.11.1/icons/regular/help-circle.svg) | `3206fbecd152d26eb60d292d4a2ab3b1bad4da074f29d3d2879d076d1f30258b` | [`resources/icons/iconoir/LICENSE`](resources/icons/iconoir/LICENSE) |
| 3DBenchy STL | Retrieved 2026-07-29 | [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:3DBenchy.stl) | `6ab57f1c3f8e86bc3cbd302c6fa6270acf06277c6335454e922419c25d42e97e` | [`resources/models/licenses/CC0-1.0.txt`](resources/models/licenses/CC0-1.0.txt) |
| All In One 3D Printer Test STL | Retrieved 2026-07-29 | [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Thingiverse_-_3D_Printer_test_stl.stl) | `c44411c2d6652cc48da16f253f34937c14af5d9787ce2a632f76e7f523dce9b8` | [`resources/models/licenses/CC-BY-4.0.txt`](resources/models/licenses/CC-BY-4.0.txt) |
| Stanford Bunny STL | Retrieved 2026-07-29 | [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Stanford_Bunny.stl) | `e1ff1293a49eb066de3c02cde6ccd260835e9da8544d43b1411f83f2d55c2eba` | [`resources/models/licenses/CC-BY-3.0.txt`](resources/models/licenses/CC-BY-3.0.txt) |
| Assimp OBJ `box.obj` | v6.0.5, commit `392a658f9c271be965271f45e7521a1b80ea4392` | [Official repository](https://github.com/assimp/assimp/blob/v6.0.5/test/models/OBJ/box.obj) | `65ad6ed518b8c0592a6f6f80773b8f65c17b80d6d17235447422a4ecd4746638` | [`testdata/assimp-obj/LICENSE`](testdata/assimp-obj/LICENSE) |
| Assimp OBJ `box_without_lineending.obj` | v6.0.5, commit `392a658f9c271be965271f45e7521a1b80ea4392` | [Official repository](https://github.com/assimp/assimp/blob/v6.0.5/test/models/OBJ/box_without_lineending.obj) | `df2dc98bacc8cb65f8ec63a087342b803a2144693974c7336047daf6f69d6de4` | [`testdata/assimp-obj/LICENSE`](testdata/assimp-obj/LICENSE) |
| Assimp OBJ `multiple_spaces.obj` | v6.0.5, commit `392a658f9c271be965271f45e7521a1b80ea4392` | [Official repository](https://github.com/assimp/assimp/blob/v6.0.5/test/models/OBJ/multiple_spaces.obj) | `3fde51f80c491a1b54420e651353360cf2a7b9586de56da86a25884fccbf20bf` | [`testdata/assimp-obj/LICENSE`](testdata/assimp-obj/LICENSE) |
| Assimp OBJ `cube_mtllib_after_g.obj` | v6.0.5, commit `392a658f9c271be965271f45e7521a1b80ea4392` | [Official repository](https://github.com/assimp/assimp/blob/v6.0.5/test/models/OBJ/cube_mtllib_after_g.obj) | `7583367a46f96c6824ddaaa87062769cfe4e812da58c91f0c6860d8bfb0deb5f` | [`testdata/assimp-obj/LICENSE`](testdata/assimp-obj/LICENSE) |
| Assimp OBJ `concave_polygon.obj` | v6.0.5, commit `392a658f9c271be965271f45e7521a1b80ea4392` | [Official repository](https://github.com/assimp/assimp/blob/v6.0.5/test/models/OBJ/concave_polygon.obj) | `cce772ab32d58b141b96d2ed3f1955c44b5ddb544cf5d97734ae7c85742015a9` | [`testdata/assimp-obj/LICENSE`](testdata/assimp-obj/LICENSE) |
| Assimp OBJ `number_formats.obj` | v6.0.5, commit `392a658f9c271be965271f45e7521a1b80ea4392` | [Official repository](https://github.com/assimp/assimp/blob/v6.0.5/test/models/OBJ/number_formats.obj) | `a88822457583d4b9262fdf6edfc5f17fa0ae06d3a8d8a9a549fcc2a72297214e` | [`testdata/assimp-obj/LICENSE`](testdata/assimp-obj/LICENSE) |
| 3MF Core box example | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/examples/core/box.3mf) | `d45d18cbbc4f189c2951b5c8c400333c0de633c4b88608dc6f5416b8f7677524` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |
| 3MF Core cylinder example | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/examples/core/cylinder.3mf) | `2a263ec8c0e35a677b3a3fc97941f4596a8df3c071bac94551a4512ae95ca086` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |
| 3MF archived parts-relationships case | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/validation%20tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter2.1_PartsRelationships.3mf) | `e16d5eaf45b3c178575e2d92ec9bc81176f3dd2ca0ecf41368db9670a6623cc7` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |
| 3MF archived ignorable-markup case | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/validation%20tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter2.3a_IgnorableMarkup.3mf) | `80207083fc6c7b1d97793803fd050fb56cad2420246cc318128fd80180a6bb53` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |
| 3MF archived multiple-transform case | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/validation%20tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter3.2c_MultipleItemsTransform.3mf) | `535ca50b2de4659a6d696e03e18ee3d7646265655e0a3f0607734582421afce7` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |
| 3MF archived unknown-metadata case | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/validation%20tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter3.4.1c_MustIgnoreUndefinedMetadataName.3mf) | `a2fa11225ab7bd1cd9d22422f2519fe6b2300905706c850089c758a168131092` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |
| 3MF archived unreferenced-object case | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/validation%20tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter3.4.3a_MustNotOutputNonReferencedObjects.3mf) | `5e44c36ea13fe6f579738caac3c5b82617369604c07141e223272f9abc9dbf8e` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |
| 3MF archived components case | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/validation%20tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter4.2_Components.3mf) | `edafa758aed598d9a960dc48b04971be6861e017d41bd5fafe81b609c731b2c7` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |
| 3MF archived sRGB-material case | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/validation%20tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter5.1c_MaterialResources_sRGB_RGB_Colors.3mf) | `f33c92890c5aa5a55246c826b9dd5e1a13a9c6c140e7783730dae1a08ec2e87f` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |
| 3MF archived external-relationship rejection | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/validation%20tests/_archive/3mf-Verify/MUSTFAIL/MUSTFAIL_Chapter2.1.1b_PartsRelationships_LinkToExternal.3mf) | `f3a9600d57a104533cfcc3402c03852de3e59923d52b3125f29ee05c5ce72043` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |
| 3MF archived multiple-root rejection | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/validation%20tests/_archive/3mf-Verify/MUSTFAIL/MUSTFAIL_Chapter3.4a_MoreThanOneModel.3mf) | `804f9f81a43d99f4732f277b28df3236b8d1fc62e93a28262ae1151d06c26fb8` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |
| 3MF archived duplicate-metadata rejection | commit `665e20dc4d7777fd4c9702bca86a2d4028440337` | [Official repository](https://github.com/3MFConsortium/3mf-samples/blob/665e20dc4d7777fd4c9702bca86a2d4028440337/validation%20tests/_archive/3mf-Verify/MUSTFAIL/MUSTFAIL_Chapter3.4.1b_DuplicatedMetadataName.3mf) | `63a4f31762243567a2f7c227e421ea507fc35ba829a5f74fd7cfdba9241ec294` | [`testdata/3mf-consortium/LICENSE`](testdata/3mf-consortium/LICENSE) |

See [`resources/models/LICENSES.md`](resources/models/LICENSES.md) for model
attribution and license checksums.

## Project details

The current project tasks are tracked in [TODO.md](TODO.md). Execute the staged
plan through the release gate. Preserve the versioned stage contracts and
debug-evidence protocol when an implementation is replaced.

Extend retained evidence through the remaining intermediate feature graphs.
Add geometric rendering and cross-stage selection for the retained records.
Connect those stages to the production slice action before physical printer
calibration. Preserve the profile provenance and invalidation rules from the
[process-profile decision contract](notes/hw-slicer-process-profile-decisions.md).
