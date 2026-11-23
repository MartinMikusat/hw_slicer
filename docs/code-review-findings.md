# `hw_slicer` Code Review Findings

Comprehensive static & architectural code review of `/Users/martin/projects/hw_slicer` (as of `2bc76b1`). Findings are recorded incrementally as discovered, ranked by severity.

---

## High Severity

### [CR-01] `i64` Overflow Risk for Valid Coordinates Near `MAX_PLANAR_COORDINATE_UM` — **RESOLVED**
- **Locations:**
  - `src/polygon/odin_vatti.odin`: `vatti_seg_intersect`, `vatti_segs_collinear`
  - `src/features/bridge_directions.odin`: `bridge_polygon_contains_twice`
  - `src/features/infill_patterns.odin`: `band_edges_contains_twice`
  - `shaders/slicer_compute.metal`: `int64_t` cross products
- **Issue:** `geometry.MAX_PLANAR_COORDINATE_UM` is `1_000_000_000_000` (`1e12 µm`). While physical printer beds (`<= 500 mm = 5e5 µm`) stay well within `i64` (`(2 * 5e5)^2 = 1e12 << 9.22e18`), any API caller or test passing coordinates `> 3e9 µm` passes `polygon_set_validate` and silently overflows `i64` in `dx * dy` cross products.
- **Resolution:** Guarded the `i64` fast path with a `< 2_000_000_000` delta ceiling and exact `i128` fallback in `vatti_seg_intersect`, `vatti_segs_collinear`, `bridge_polygon_contains_twice`, and `band_edges_contains_twice`.

### [CR-02] Nozzle Z State Not Restored After `z_offset_um` Moves (Scarf Seam / Vase Mode) — **RESOLVED**
- **Locations:**
  - `src/features/scarf_seam.odin:60-61, 96-97`
  - `src/gcode/klipper.odin`
  - `src/gcode/klipper_validator.odin`
- **Issue:** When `op.z_offset_um != 0`, `klipper_emit_operation` emits `G1 X... Y... Z<state.z + z_offset_um> E...` without updating `state.z` or tracking that physical Z diverged from `state.z`. If the next move has `op.z_offset_um == 0` (e.g., after a scarf ramp ends before `z_off == 0`, or on a travel/infill move), no `Z<state.z>` is emitted to restore the nozzle to the nominal layer height.
- **Resolution:** Added `physical_z` tracking to `Klipper_State` and `Klipper_Validation_State`. Whenever a `.Travel` or `.Extrude` (including `G2`/`G3` arcs) has target Z differing from `physical_z`, `Z<target>` is emitted and validated, and `physical_z` is updated.

---

## Medium Severity

### [CR-03] Worker Thread `temp_allocator` Leaks & Allocator Thread-Safety Assumptions — **RESOLVED**
- **Locations:**
  - `src/features/parallel.odin` (`parallel_for`)
  - `src/slicing/cpu_intersections.odin` (`slicing_parallel_for`)
- **Issue:**
  1. Spawned worker threads in `parallel_for` and `slicing_parallel_for` never called `free_all(context.temp_allocator)` before exiting, leaking any temp allocations made by worker bodies that lacked a `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()`.
  2. Callers passing a non-thread-safe custom `mem.Allocator` into these functions would hit data races on concurrent `make`/`delete`.
- **Resolution:** Added a `spawned_worker_fn` wrapper with `defer free_all(context.temp_allocator)` for all spawned worker threads in both `parallel_for` and `slicing_parallel_for` (leaving the calling thread's temp allocator untouched).

### [CR-04] Non-Thread-Safe Lazy Initialization & Silent Shader Failure in `HWSlicerMetalCompute.m` — **RESOLVED**
- **Location:** `host/HWSlicerMetalCompute.m`
- **Issue:** `hw_metal_compute_init` used an unsynchronized `static bool g_initialized`, discarded `NSError *err` on shader/pipeline compilation failure without logging, and returned `true` even if `g_trv_pso` or `g_tri_pso` failed to compile.
- **Resolution:** Replaced `g_initialized` with `dispatch_once(&g_init_once, ...)`, logged `err.localizedDescription` to `stderr` on library or PSO failure, and required all three PSOs (`g_pip_pso`, `g_tri_pso`, `g_trv_pso`) to succeed.

### [CR-05] `odin_offset` Single-Pass `.Positive` Union Can Create Ghost Islands on Collapsed Holes (and Contributes to `-3.1%` Filament Delta) — **RESOLVED**
- **Location:** `src/polygon/odin_offset.odin`
- **Issue:**
  1. All offset outer rings (CCW, `+1`) and hole rings (CW, `-1`) are fed into one `odin_vatti_boolean(raw_set, {}, .Union, .Positive)` pass. When a positive offset (`d > 0`) shrinks a small CW hole past its medial axis, the hole inverts to CCW (`+1`) and `.Positive` retains it as a spurious solid island.
  2. At sharp concave corners (`denom <= 0.05`), emitting `p0 -> v -> p1` places the un-offset vertex `v` onto the offset path.
  3. This divergence from Clipper2's separate outer/hole offset + miter handling is the primary cause of the ~`-3.1%` filament difference on `benchy.stl` and `stanford-bunny.stl`.
- **Resolution:** Separated outer (`area > 0`) and hole (`area < 0`) rings in `odin_offset`, beveled sharp concave corners (`denom <= 0.05` -> `p0 -> p1`), discarded collapsed/inverted rings whose area flipped sign, cleaned outers and holes independently via `.Union .Positive`, and combined them via `.Difference .Non_Zero`.

### [CR-06] `fuzzy_skin_apply` Perturbs All Perimeters Instead of Only the Outer Perimeter — **RESOLVED**
- **Location:** `src/features/fuzzy_skin.odin`, `src/pipeline/orchestrator.odin`
- **Issue:** Filters only on `src.source_kind != .Perimeter`, perturbing inner and middle perimeter loops in addition to the outermost perimeter. This causes inner walls to overlap infill/adjacent walls.
- **Resolution:** Passed `perimeters` into `fuzzy_skin_apply` and skipped any perimeter source where `perimeters.paths[src.source_index].perimeter_index != 0`.

### [CR-07] `--sequential` Validates Clearance but Still Slices Objects Layer-by-Layer — **RESOLVED**
- **Locations:** `src/pipeline/sequential.odin`, `src/cli/main.odin`
- **Issue:** `plate_validate_sequential` validated extruder/gantry clearance and sorted objects front-to-back, but `main.odin` then merged all objects via `plate_merge_to_mesh` and ran a single layer-by-layer slice.
- **Resolution:** Implemented `plate_slice_sequential` in `src/pipeline/sequential.odin` and wired it into `src/cli/main.odin` when `--sequential` is set on multi-object plates: each sorted `Plate_Object` is sliced independently and concatenated with safe `G0 Z<max_z + 2mm>` clearance transitions between objects.

### [CR-08] `mesh_auto_repair` Missing Vertex Bounds Checks & Open-Mesh Signed Volume Risk — **RESOLVED**
- **Location:** `src/repair/mesh_repair.odin`
- **Issue:**
  1. `mesh.vertex_x[ib]` was indexed without checking `ia, ib, ic < u32(len(mesh.vertex_x))`.
  2. Global signed-volume flipping (`vol6 < -1e-6`) could invert an open (non-watertight) mesh.
  3. Doc comment claimed BFS manifold winding propagation and boundary hole filling, neither of which was implemented.
- **Resolution:** Added vertex index bounds validation before indexing, gated signed-volume face inversion on an undirected-edge watertightness check (every edge shared by exactly 2 faces), and aligned the doc comment with actual behavior.

---

## Low Severity

### [CR-09] Missing `allocator` Parameter in `fuzzy_skin_apply` Cleanup Path — **RESOLVED (VERIFIED SAFE)**
- **Location:** `src/features/fuzzy_skin.odin`, `src/pipeline/orchestrator.odin`
- **Issue:** `delete(new_pts)` and `delete(new_ws)` omitted `allocator`, while `owned_points` / `owned_widths` stored slices freed by the caller.
- **Resolution:** Verified Odin dynamic arrays carry their own allocator on `delete(dyn_arr)`, and verified `orchestrator.odin` frees `fuzzy_owned_pts` / `fuzzy_owned_ws` with the exact same `allocator` passed to `fuzzy_skin_apply`.

### [CR-10] CLI `filament=` Summary Ignores Post-Extrusion Filament Changes (`--scarf-seam`, `--modifier=...:flow=...`) — **RESOLVED**
- **Locations:** `src/cli/main.odin`, `src/pipeline/sequential.odin`
- **Issue:** `scarf_seam` and flow-scaling modifiers mutate `motion.operations[k].filament_delta_nm` after `extrusion_calculate`, so the CLI summary printed the stale pre-modifier `extrusion.total_filament_nm`.
- **Resolution:** Updated CLI and sequential summaries to report net emitted filament (`klipper.positive_filament_nm - klipper.negative_filament_nm`, excluding retraction/recovery pairs).

### [CR-11] `gap_evidence` Single-Loop Fast Path Can Omit Acute-Corner Inter-Perimeter Gaps — **RESOLVED**
- **Location:** `src/features/gap_evidence.odin`
- **Issue:** On a single-contour region where all `N` concentric perimeters survive with `path_count == 1`, approximating uncovered area as `offset(innermost, -half_w)` could skip small inter-perimeter triangular gaps at very acute corners.
- **Resolution:** Added `gap_contour_has_acute_corner` (zero-`sqrt` dot-product test for interior angles `< 60°`) to gate the single-loop fast path and fall back to exact coverage subtraction whenever acute corners are present.

### [CR-12] Build Hygiene: Deprecated `zlib.inflate` & Always-Linked C++ Clipper2 — **RESOLVED**
- **Locations:** `src/formats/bounded_zip.odin`, `build.sh`
- **Issue:**
  1. `bounded_zip.odin:378` called deprecated `zlib.inflate`, emitting a compiler warning on every build.
  2. `build.sh` links `libhw_clipper2.a` for A/B reference parity testing (`--polygon-provider=clipper2`).
- **Resolution:** Migrated `bounded_zip.odin` to `core:compress/deflate` (`deflate.inflate_raw`), eliminating all deprecation warnings and removing an intermediate buffer copy. `libhw_clipper2.a` is intentionally retained only for optional `--polygon-provider=clipper2` parity verification in `scripts/accept.sh`.

---

## Pass 2 Findings (as of `bdf4f09`)

### High Severity (Pass 2)

### [CR-13] `arc_fit.odin` Does Not Guard Against Merging `z_offset_um != 0` Operations — **RESOLVED**
- **Location:** `src/features/arc_fit.odin:57-79`
- **Issue:** `motion_plan_fit_arcs` checks `kind`, `arc`, `path_id`, `role`, `speed`, `acceleration`, `fan_ratio`, and `point_a == prev.point_b`, but never checks `op.z_offset_um == 0`. If invoked after `motion_plan_apply_z_ramps` (or on helical/vase-mode operations), it would collapse Z-ramped segments into a single planar arc and drop intermediate Z offsets.
- **Resolution:** Added `op0.z_offset_um != 0` and `cur.z_offset_um != 0` guards in `motion_plan_fit_arcs`.

### [CR-14] `variable_walls_adapt` Missing `len(src.line_widths)` Bounds Check — **RESOLVED**
- **Location:** `src/features/variable_walls.odin:39, 69-70`
- **Issue:** Checks `len(src.points) < 4` and iterates `vi in 0..<n`, then indexes `src.line_widths[vi]` without checking `len(src.line_widths) == n`. Any source with a shorter `line_widths` slice panics.
- **Resolution:** Added `len(src.line_widths) != len(src.points)` to the loop guard.

### [CR-15] `plate_object_lay_flat` Missing Triangle Vertex Index Bounds Checks — **RESOLVED**
- **Location:** `src/pipeline/build_plate.odin:162-168`
- **Issue:** Indexes `obj.mesh.vertex_x[ia/ib/ic]` without checking `ia, ib, ic < u32(len(obj.mesh.vertex_x))`, risking an out-of-bounds panic on malformed meshes (same class as `CR-08`).
- **Resolution:** Added `ia >= nverts || ib >= nverts || ic >= nverts` validation before indexing.

### [CR-16] `tree_supports_generate` Heap Memory Leak in `tips_per_layer` — **RESOLVED**
- **Location:** `src/features/tree_supports.odin:89, 121`
- **Issue:** `tips_per_layer := make([][dynamic][2]f64, layer_count, context.temp_allocator)` allocates the outer slice on `temp_allocator`, leaving each inner `[dynamic][2]f64` zero-initialized with `context.allocator` (heap). Every `append(&tips_per_layer[li], ...)` allocates on the heap and is never freed before returning, leaking up to `layer_count` heap allocations per tree-support slice. Also lacks `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()`.
- **Resolution:** Added `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` and initialized each `tips_per_layer[li]` on `context.temp_allocator` before appending.

### Medium Severity (Pass 2)

### [CR-17] `scarf_seam.odin` Ramps Inner Perimeters Instead of Outer Perimeters Only — **RESOLVED**
- **Location:** `src/features/scarf_seam.odin:76-84`
- **Issue:** Comment states scarf ramps apply to outer perimeter loops, but line 76 filters only on `op.role != .Perimeter`, applying scarf Z/E ramps to inner perimeter walls as well.
- **Resolution:** `motion_plan_apply_z_ramps` takes the unified path plan and perimeter result, collects the planned path IDs whose perimeter source has `perimeter_index == 0`, and ramps only those paths (matching `CR-06`).

### [CR-18] `modifiers.odin` Prevents `fan=0` From Turning Fan Off & Quantizes Speed Before Clamping — **RESOLVED**
- **Location:** `src/pipeline/modifiers.odin:109-117`
- **Issue:**
  1. `clamp(ppm, profile.material.minimum_fan_ratio, profile.material.maximum_fan_ratio)` forces `fan=0` up to `minimum_fan_ratio` (e.g. 35% for PLA), making it impossible to disable the fan in a modifier zone.
  2. Speed quantization `(raw_v / 50) * 50` runs before `clamp(qv, minimum_print_speed, maximum_speed)`, which can break the `% 50` Klipper invariant if either bound is not divisible by 50.
- **Resolution:** Allowed `ppm == 0` to set `op.fan_ratio = 0`, and moved speed quantization after clamping while preserving `>= minimum_print_speed`.

### [CR-19] `ironing_paths_generate` Unbounded `temp_allocator` Growth Across Top-Skin Masks — **RESOLVED**
- **Location:** `src/features/surface_finish.odin:78-121`
- **Issue:** Allocates `pts`, `paths`, and `tmp_infill` from `context.temp_allocator` inside the per-mask loop without a per-iteration temp guard, accumulating temp memory linearly with top-skin mask count.
- **Resolution:** Added `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` inside the per-mask loop.

### [CR-20] `motion_plan_estimate_klipper_time` Uses Straight Chord Length for `G2`/`G3` Arcs — **RESOLVED**
- **Location:** `src/features/time_estimate.odin:41-44`
- **Issue:** Computes `dist := math.hypot(dx, dy)` for all `.Extrude` operations, ignoring `op.arc != .None`. For curved `G2`/`G3` arcs, chord length underestimates true arc length `r * |sweep|` (severely for large-sweep arcs).
- **Resolution:** Computed true arc length `r * sweep` and entry/exit tangent unit vectors for `G2`/`G3` arcs around `op.arc_center`.

---

## Pass 3 Findings (as of `c21f9c0`)

Scope: G-code emission and validation (`src/gcode/`), pipeline orchestration, modifiers, plate arrangement and sequential printing (`src/pipeline/`), the CLI (`src/cli/`), design export (`src/design_export.odin`), arc fitting, time estimation, scarf/vase Z ramps, and the parallel extrusion pass. Not covered in this pass: `src/evidence/`, `src/formats/`, `src/slicing/`, the UI, and most of `src/features/`.

### High Severity (Pass 3)

### [CR-21] `--sequential` Drops the Nozzle Into the Previous Object at Each Transition — **RESOLVED**
- **Locations:** `src/pipeline/sequential.odin:116-130`, `src/gcode/klipper.odin:270-342`
- **Issue:** For objects after the first, `plate_slice_sequential` writes `G0 Z<max_z + 2 mm>` and then appends the object's stream from `EXCLUDE_OBJECT_START`. Each per-object stream comes from `klipper_emit`, which emits `G0 Z<layer 0 z>` before the first `G0 X.. Y..` positioning move. The nozzle therefore descends to first-layer height at the last XY position of the previous object, which is above that finished object, before it travels to the next object.
- **Resolution:** Each transition now lifts to clearance height, travels in XY to the next object's first point at that height (`G0 X.. Y..`), and only then runs the object's body. The body's first-layer `G0 Z` therefore descends at the next object's position.

### Medium Severity (Pass 3)

### [CR-22] Concatenated Sequential Streams Break Emitter State Assumptions — **RESOLVED**
- **Location:** `src/pipeline/sequential.odin:111-136`
- **Issue:** Objects after the first skip their own header, so:
  1. Each emitter assumes the fan is off after its header `M107`, but the fan keeps the previous object's last PWM. A first extrusion with `fan_ratio` 0 emits no `M107`, so the fan runs during the next object's first layer.
  2. `START_PRINT X0 Y0 X1 Y1` covers only the first object's extrusion area, so adaptive meshing and priming ignore the other objects.
  3. `SET_PRINT_STATS_INFO TOTAL_LAYER` reports only the first object's layer count, and `CURRENT_LAYER` restarts at 1 for each object.
  4. The combined stream is not passed through `klipper_validate`, unlike every single-object stream.
- **Resolution:** `plate_slice_sequential` slices every object first and then assembles one stream. It uses the first object's header with `START_PRINT X0 Y0 X1 Y1` set to the union of all objects' extrusion areas and `TOTAL_LAYER` set to the plate total, writes every object's `EXCLUDE_OBJECT_DEFINE`, renumbers `CURRENT_LAYER` continuously, and emits `M107` at each transition to match the emitter's fan-off assumption. Remaining limitation: `klipper_validate` checks each object's stream when it is emitted, but not the assembled plate stream, because the validator requires one strictly increasing layer Z sequence.

### [CR-23] Auto-Arranged Plates Always Fail Sequential Clearance Validation — **RESOLVED**
- **Locations:** `src/pipeline/build_plate.odin:219`, `src/cli/main.odin:432-440`, `src/pipeline/sequential.odin:31-44`
- **Issue:** `plate_auto_arrange` packs objects with an 8 mm gap. `plate_validate_sequential` then requires 35 mm extruder clearance (`DEFAULT_SEQUENTIAL_CLEARANCE.extruder_radius_mm`) in both X and Y. Neighbours in the same row are 8 mm apart, so `--sequential` with clones or several inputs reports a collision for almost any plate that the CLI arranged itself.
- **Resolution:** With `--sequential`, the CLI arranges with a gap of `DEFAULT_SEQUENTIAL_CLEARANCE.extruder_radius_mm + 1 mm`, so neighbours pass the strict clearance comparison.

### [CR-24] Spiral Vase Mode Lifts Z by One Layer Height at Every Layer Start — **RESOLVED**
- **Locations:** `src/gcode/klipper.odin:270-290`, `src/features/scarf_seam.odin:57-80`
- **Issue:** `klipper_emit` emits `G0 Z<layer.z>` at the start of every layer and sets `physical_z = layer.z`. In vase layers, the first perimeter operation has `z_offset_um ≈ -lh`, so the nozzle rises by one layer height and then drops back on the first extrusion. This defeats the continuous helix and leaves a seam blob or gap at the layer start. The validator encodes the same sequence (`klipper_validator.odin`, `layer_z_emitted`), so validation does not catch it.
- **Resolution:** `klipper_layer_start_z` sets the layer-start `G0 Z` to the layer Z plus the Z offset of the layer's first travel or extrusion. Travels now honour `z_offset_um` (with and without z-hop), and the vase ramp gives travels their current helix offset. The emitter and validator apply the same rules. Scarf layers that start with a ramped extrusion now descend directly to the ramp start height.

### [CR-25] Object Names With Spaces Produce G-code That Klipper Rejects — **RESOLVED**
- **Locations:** `src/cli/main.odin:384-385`, `src/gcode/klipper.odin:195, 221, 359`, `src/pipeline/sequential.odin:91, 120`
- **Issue:** The object name is the input file stem, written unquoted into `EXCLUDE_OBJECT_DEFINE NAME=%s`, `EXCLUDE_OBJECT_START` and `EXCLUDE_OBJECT_END`. Klipper splits extended G-code parameters on whitespace (`shlex.split` in `klippy/gcode.py`), so a file named `my part.stl` yields a token without `=`. Klipper reports a malformed command on that token, so the print does not start.
- **Resolution:** `klipper_object_name` replaces every byte outside `[A-Za-z0-9_.-]` with `_` (an empty name becomes `object`). `klipper_emit` applies it to every `EXCLUDE_OBJECT_*` command, and the sequential transition comment uses it too.

### Low Severity (Pass 3)

### [CR-26] `klipper_write_literal` Records Every Literal Command as `.Set_Acceleration` — **RESOLVED**
- **Location:** `src/gcode/klipper.odin:802-822`
- **Issue:** The procedure takes a `kind` parameter but passes the constant `.Set_Acceleration` to `klipper_command_end`. `G21`, `G90`, `M83`, `M107`, `PAUSE`, `M600` and `END_PRINT` are therefore recorded with the wrong kind. These kinds are written to the Klipper evidence artifact (`klipper_artifact.odin:124`) and hashed (`klipper_hashes.odin:113`).
- **Resolution:** `klipper_write_literal` passes its `kind` through. No golden Klipper hashes are recorded in the repository, so none needed updating.

### [CR-27] Modifier `fan=0` Fails G-code Emission for Materials With a Nonzero Minimum Fan — **RESOLVED**
- **Locations:** `src/pipeline/modifiers.odin:117-124`, `src/gcode/klipper.odin:792`
- **Issue:** CR-18 lets `fan=0` set `fan_ratio = 0`, but `klipper_operation_numeric_valid` still requires `fan_ratio >= material.minimum_fan_ratio`. For a material with `min_fan_percent > 0`, `klipper_emit` returns `.Invalid_Motion` and the slice fails. The shipped PLA, PETG and ABS profiles use `min_fan_percent: 0`, so they are not affected; the 35% PLA premise in CR-18 does not match `resources/profiles/materials/pla.json`.
- **Resolution:** The material fan bounds are hard limits. A modifier fan value, including `fan=0`, is clamped to `[minimum_fan_ratio, maximum_fan_ratio]`. This reverts part 1 of the CR-18 resolution; with the shipped profiles (`min_fan_percent: 0`), `fan=0` still turns the fan off.

### [CR-28] Modifier Speed Scaling Leaves Operation Durations Stale — **RESOLVED**
- **Location:** `src/pipeline/modifiers.odin:108-116`
- **Issue:** `speed_scale` changes `op.speed` but not `op.duration_us`, the layer duration totals, or the minimum-layer-time slowdown. Motion evidence and layer timing then disagree with the emitted feed rates, and a `speed_scale > 1` zone can violate `minimum_layer_time`. `klipper_motion_valid` still passes because it checks only that the stale sums agree with each other.
- **Resolution:** A speed change rescales the operation's `duration_us` in proportion to the speed ratio, and updates the layer `motion_duration_us` and `planned_duration_us` and the plan totals. A layer whose speed-up would end below `minimum_layer_time` keeps its original speeds; its fan and flow changes still apply.

### [CR-29] Time Estimate Uses Inconsistent Junction Speeds Between Moves — **RESOLVED**
- **Location:** `src/features/time_estimate.odin:83-111`
- **Issue:** Each move sets `v_exit := v_entry`, while the next move's entry is computed from `prev_v` (the previous cruise speed). One move's exit speed therefore differs from the next move's entry speed. For example, a straight chain after a stop decelerates the first segment to 0 at its end, but the second segment starts at full cruise speed. The estimate is not a consistent trapezoid model and its error depends on how paths are segmented.
- **Resolution:** The estimator now runs three passes: junction limits, a backward pass for deceleration, and a forward pass for acceleration. Each junction then has one speed, used as the exit speed of one move and the entry speed of the next. Dwell, retraction, recovery and z-hop travels stop the toolhead.

### [CR-30] Trace JSON Writes Unescaped Strings — **RESOLVED**
- **Location:** `src/cli/main.odin:123-126`
- **Issue:** The input file name and profile names are written with `"%s"` without JSON escaping. A name that contains `"` or `\` produces invalid JSON.
- **Resolution:** `write_json_string` escapes quote, backslash and control characters for all string values in the trace JSON.

---

## Pass 4 Findings (as of `0d40440`)

Scope: newer slicing code (`adaptive_layers.odin`, `simplify.odin`, `layers.odin`), tree supports, and grid supports, checked by slicing generated models (box, cylinder, T-shape, 30° frustum) and Benchy. Not yet covered: `src/formats/`, `src/evidence/`, the remaining `src/slicing/` core, adhesion, ironing, gap fill, and infill patterns.

### High Severity (Pass 4)

### [CR-31] Every Model Prints One Layer Short — **RESOLVED**
- **Locations:** `src/slicing/layers.odin:48-54`, `src/pipeline/spine.odin:314-345`
- **Issue:** The layer Z is also the slicing plane, and the fixed schedule creates planes from `minimum_z + first_layer_height` strictly below `maximum_z`. The model top is never reached: a 5 mm box prints to 4.8 mm and a 6 mm cylinder to 5.8 mm (0.20 mm layers). A plane at exactly `maximum_z` would only touch the top face, so the gap cannot be closed by adding one plane.
- **Resolution:** Each layer is sectioned at its mid-height (`layer_z`) and printed at its top (`print_z`, new schedule field). A layer exists while its section plane lies below `maximum_z`, so the printed height is the model height rounded to the nearest layer: the 5 mm box, 6 mm cylinder, and Benchy now print to 5.000, 6.000, and 48.000 mm. The schedule stores `first_layer_height`. The schedule hash moves to schema 2 and covers `print_z`, and the layer-schedule artifact moves to schema 2 with the first-layer height in its header. Motion planning, layer heights, tree supports, and pattern infill use `print_z`. Pinned fixture hashes derived from the schedule (for example `testdata/feature-probes/stanford-bunny-v1.json` and the hashes in `notes/hw-slicer-roadmap-progress.md`) are stale until the fixtures are regenerated.

### [CR-32] Tree Supports Ignore the Overhang Angle — **RESOLVED**
- **Location:** `src/features/tree_supports.odin`
- **Issue:** `overhang_angle_deg` was never read. Any contour vertex outside the layer below spawned a support tip, so a 30° overhang (threshold 45°) received 608 support lines on its first layer.
- **Resolution:** A vertex is an overhang tip only when its distance outside the layer below exceeds `layer height * tan(overhang angle)`. The 30° frustum now gets no supports; a T-shape with 15 mm horizontal wings keeps them.

### [CR-33] Tree Support Rings Overlap the Model — **RESOLVED**
- **Location:** `src/features/tree_supports.odin`
- **Issue:** `xy_clearance_um` was never read, and a ring was emitted when only its centre was outside the model. Rings up to 6 mm in radius overlapped the part: on the frustum, 27 of 448 support points lay inside the model outline.
- **Resolution:** Each ring's radius is limited to the centre's distance from the model boundary minus the XY clearance and half the line width. A ring that would be thinner than one line width is skipped. Benchy, the T-shape and the frustum show no support inside a perimeter loop.

### Medium Severity (Pass 4)

### [CR-34] Tree Support Trunks Have Gaps — **RESOLVED**
- **Location:** `src/features/tree_supports.odin`
- **Issue:** A branch whose centre is inside the model, or whose ring no longer fits the clearance, emits nothing on that layer but continues downward. Its ring sections above the gap rest on nothing.
- **Resolution:** A branch that cannot keep the clearance first moves away from the nearest model boundary: by up to one branch-angle step per layer, or by the full clearance on a new branch's first layer, since a tip starts on the overhang edge. If it still does not fit, or its ring would leave the bed, the branch ends. A ring emitted on the same layer that overlaps the blocked branch's footprint carries it, and its rings are then removed only if that carrier later dies. Without a carrier its rings are removed at once. Measured with a harness over every layer: no ring lacks an overlapping ring below on Benchy, the Stanford Bunny, the all-in-one model, or the T-shape. Interface rings directly under overhangs rose from 1 to 81 (Benchy), 25 to 324 (Bunny), and 67 to 199 (all-in-one): the old code usually could not place a new tip's ring at the overhang edge, so supports started below the overhang. Redundant trunk sections under carrying rings are gone (Benchy 3,999 → 2,426 rings above the first layer).

### [CR-35] Inconsistent Triangle Winding Is Not Repaired — **RESOLVED**
- **Location:** mesh audit and `src/repair/mesh_repair.odin`
- **Issue:** A mesh with mixed face orientation (signed volume −603 mm³ for a 1,810 mm³ part) slices with `repairs=0`. The mesh audit reports inconsistent winding, but the slice pipeline neither repairs nor rejects it. Support classification then reads downward faces as upward, and grid supports silently produce nothing.
- **Cause:** `mesh_auto_repair` paired edges by vertex index, but the STL decoder gives every triangle its own three vertices, so no STL mesh was ever "closed" and even the CR-08 global flip never ran for STL input.
- **Resolution:** `mesh_auto_repair` matches vertices by exact coordinates, propagates orientation across edges shared by exactly two faces, and turns each component outward: by signed volume when at most 10% of its edge uses are unpaired, otherwise by requiring the steepest face at the component's highest vertex to face up. A tee with every other face flipped and a fully inverted tee now slice to G-code identical to the valid tee (545 grid support paths each, previously 0). Benchy, the Stanford Bunny, the all-in-one model, and the other test meshes are unchanged (0 flips).

### [CR-36] Skin Extruded Outside the Layer Outline on Benchy — Root Cause CR-43
- **Issue:** A harness that runs the production pipeline and tests every extrusion midpoint against the layer's own model outline (`build_model_polygon_sets`) finds, on Benchy, 598 top/bottom-skin, 356 top-skin, 345 bottom-skin, and 8 sparse-infill segments outside the outline by more than 0.05 mm (worst 1.47 mm), spread over most layers.
- **Cause:** The native polygon provider (CR-43). With `use_native_polygon = false` (Clipper2), the same harness finds no skin or infill outside the outline, and the top/bottom-skin classification changes from 1,614 to 70 segments.

### Low Severity (Pass 4)

### [CR-37] Adaptive Layers Choose the Step From the Layer Bottom Only — **RESOLVED**
- **Location:** `src/slicing/adaptive_layers.odin:120-125`
- **Issue:** The step is taken from the slope bin at the current Z, not the smallest target height over the span the new layer covers, so a coarse layer can step over the start of a shallow-slope region.
- **Resolution:** The step is the smallest target height over every slope bin between the current top and the provisional next top. Adaptive Benchy now has 472 layers (457 before), finer where shallow slopes begin.

### [CR-38] Contour Simplification Is Independent per Loop
- **Location:** `src/slicing/simplify.odin`
- **Issue:** Each loop is simplified alone (12 µm default tolerance) with only an area-sign guard, so neighbouring loops closer than the tolerance can cross. Kept segment indices no longer describe the simplified edges, so segment lineage becomes approximate.

### [CR-39] Tree Support Trunks Cross the Skirt on the First Layer — **RESOLVED** (with CR-43 open)
- **Location:** `src/features/tree_supports.odin`
- **Issue:** The skirt surrounded the model's first layer only and was built before supports, so first-layer supports crossed it (0.001 mm on Benchy).
- **Resolution:** Adhesion is built after supports. The skirt offsets the union of the model's first layer and the first-layer support area (tree rings or grid support masks), keeps only outer boundaries, and drops hole loops from the offset. The brim stays on the model. With Clipper2, every first-layer support point on Benchy, the Stanford Bunny, the all-in-one model, and the T-shape lies inside the skirt, at least 2.0 mm from it. With the native provider, the Bunny (1 point) and the all-in-one model (11 points) still end up within 0.2 mm of the skirt because of CR-43.

### [CR-40] `sim-verify.sh` Used a Stale Release Binary — **RESOLVED**
- **Location:** `scripts/sim-verify.sh`
- **Issue:** The script preferred `build/release/hw-slicer-cli` whenever it existed, so simulator runs after a debug build tested old code.
- **Resolution:** The script uses whichever of the debug and release CLIs was built most recently and prints which one it uses.

### [CR-41] Sparse Infill Printed Under Solid Skin — **RESOLVED**
- **Severity:** High
- **Locations:** `src/pipeline/orchestrator.odin` (stage 7), `src/features/infill_patterns.odin`
- **Issue:** Role-overlap resolution reconciled skin against bridges only, and sparse infill was generated over the whole region. Every top, bottom, and solid layer printed sparse infill on top of its solid skin: on Benchy's first layer, all 86 sparse segments lay on the bottom skin. Every infill pattern was affected (gyroid, the default, most visibly).
- **Resolution:** The orchestrator builds one polygon set per layer from the role-overlap masks (skin and bridge areas), and `infill_pattern_generate` subtracts it from each region's infill boundary. Rectilinear infill now runs through the pattern generator as well, so every pattern gets the exclusion; the exact `infill_generate` path remains for the evidence probes. Full-skin layers now carry no sparse infill for all seven patterns, and interior layers keep theirs.

### [CR-42] `hw_printer` Shuts Down After a Long Dwell ("Timer too close") — **RESOLVED** in `hw_printer`
- **Location:** `../hw_printer/host/motion.odin` (`motion_dwell`, `motion_begin_sequence`)
- **Issue:** The vase-mode simulator run fails at the same position on every run. The slicer G-code is valid: with its `G4` dwells removed the whole print completes, and adding two `G4 P3000` dwells to the box G-code (which otherwise passes) reproduces the shutdown. `motion_dwell` sets `print_time = last_move_time + seconds` and blocks until the MCU reaches it, but leaves the motion system non-idle. `motion_begin_sequence` restores the `BUFFER_TIME_START` lead only when the system is idle, so moves after a dwell are scheduled from a start time that has already passed.
- **Resolution (`hw_printer` `a27d5a4`):** `motion_dwell` calls `motion_get_last_move_time` after its wait, which flushes kinematics and restores the `BUFFER_TIME_START` lead. The two-dwell box and the full vase print (15 dwells, 244.21 mm filament matching the G-code) complete in `hw-printer-sim`, and `homing-check.sh` and `motion-check.sh` still match klippy.

### [CR-43] The Native Polygon Provider Returns Wrong Boolean and Offset Results
- **Severity:** High
- **Location:** `src/polygon/odin_vatti.odin`, `src/polygon/odin_offset.odin` (default provider since `9a814cc`, `use_native_polygon = true`)
- **Issue:** For some inputs with several overlapping polygons, the native engine returns geometry that Clipper2 does not:
  1. Offsetting a 40 mm square plus 1 mm rings at 0.5–12 mm from it by +3 mm or +5 mm returns a spurious hole loop (0.34 mm² at x 43.00–43.45, y 16.45–18.50) inside an area covered by both offsets. Clipper2 returns none. Unioning the square's offset with one ring's offset alone is correct, so the error needs more than two overlapping inputs.
  2. On Benchy, about 1,300 skin and infill segments are extruded outside the layer outline (CR-36); with Clipper2 there are none.
  3. A +5 mm skirt offset of the all-in-one model's first layer and its support rings passes within 0.08 mm of two rings; with Clipper2 the closest approach is 5.18 mm.
- **Fix:** Find the defect in the native union (its handling of three or more overlapping inputs) using the square-and-rings reproduction, or make Clipper2 the default again until the native engine matches it. Both providers remain linked (`--polygon-provider=clipper2`).
