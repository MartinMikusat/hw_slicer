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

### [CR-21] `--sequential` Drops the Nozzle Into the Previous Object at Each Transition
- **Locations:** `src/pipeline/sequential.odin:116-130`, `src/gcode/klipper.odin:270-342`
- **Issue:** For objects after the first, `plate_slice_sequential` writes `G0 Z<max_z + 2 mm>` and then appends the object's stream from `EXCLUDE_OBJECT_START`. Each per-object stream comes from `klipper_emit`, which emits `G0 Z<layer 0 z>` before the first `G0 X.. Y..` positioning move. The nozzle therefore descends to first-layer height at the last XY position of the previous object, which is above that finished object, before it travels to the next object.
- **Fix:** At each transition, travel in XY to the next object's first point at clearance height before any Z descent. For example, emit `G0 X<first point_a> Y<first point_a>` after the clearance lift, or give `klipper_emit` an option to position XY before the first layer Z move.

### Medium Severity (Pass 3)

### [CR-22] Concatenated Sequential Streams Break Emitter State Assumptions
- **Location:** `src/pipeline/sequential.odin:111-136`
- **Issue:** Objects after the first skip their own header, so:
  1. Each emitter assumes the fan is off after its header `M107`, but the fan keeps the previous object's last PWM. A first extrusion with `fan_ratio` 0 emits no `M107`, so the fan runs during the next object's first layer.
  2. `START_PRINT X0 Y0 X1 Y1` covers only the first object's extrusion area, so adaptive meshing and priming ignore the other objects.
  3. `SET_PRINT_STATS_INFO TOTAL_LAYER` reports only the first object's layer count, and `CURRENT_LAYER` restarts at 1 for each object.
  4. The combined stream is not passed through `klipper_validate`, unlike every single-object stream.
- **Fix:** Emit the sequential plate as one stream: one header with the union area and total layer count, an explicit fan and acceleration reset per object, and validation of the result.

### [CR-23] Auto-Arranged Plates Always Fail Sequential Clearance Validation
- **Locations:** `src/pipeline/build_plate.odin:219`, `src/cli/main.odin:432-440`, `src/pipeline/sequential.odin:31-44`
- **Issue:** `plate_auto_arrange` packs objects with an 8 mm gap. `plate_validate_sequential` then requires 35 mm extruder clearance (`DEFAULT_SEQUENTIAL_CLEARANCE.extruder_radius_mm`) in both X and Y. Neighbours in the same row are 8 mm apart, so `--sequential` with clones or several inputs reports a collision for almost any plate that the CLI arranged itself.
- **Fix:** When `--sequential` is set, arrange with a gap of at least the extruder clearance radius, and validate with the same clearance.

### [CR-24] Spiral Vase Mode Lifts Z by One Layer Height at Every Layer Start
- **Locations:** `src/gcode/klipper.odin:270-290`, `src/features/scarf_seam.odin:57-80`
- **Issue:** `klipper_emit` emits `G0 Z<layer.z>` at the start of every layer and sets `physical_z = layer.z`. In vase layers, the first perimeter operation has `z_offset_um ≈ -lh`, so the nozzle rises by one layer height and then drops back on the first extrusion. This defeats the continuous helix and leaves a seam blob or gap at the layer start. The validator encodes the same sequence (`klipper_validator.odin`, `layer_z_emitted`), so validation does not catch it.
- **Fix:** For a layer whose first motion carries a Z offset, emit the layer start Z at the effective target Z (`layer.z + first z_offset_um`), or omit the layer Z move in vase layers. Update the emitter and the validator together.

### [CR-25] Object Names With Spaces Produce G-code That Klipper Rejects
- **Locations:** `src/cli/main.odin:384-385`, `src/gcode/klipper.odin:195, 221, 359`, `src/pipeline/sequential.odin:91, 120`
- **Issue:** The object name is the input file stem, written unquoted into `EXCLUDE_OBJECT_DEFINE NAME=%s`, `EXCLUDE_OBJECT_START` and `EXCLUDE_OBJECT_END`. Klipper splits extended G-code parameters on whitespace (`shlex.split` in `klippy/gcode.py`), so a file named `my part.stl` yields a token without `=`. Klipper reports a malformed command on that token, so the print does not start.
- **Fix:** Sanitize names to `[A-Za-z0-9_.-]` (Klipper's convention is to replace spaces with `_`) in one helper used by every emitter of object names.

### Low Severity (Pass 3)

### [CR-26] `klipper_write_literal` Records Every Literal Command as `.Set_Acceleration`
- **Location:** `src/gcode/klipper.odin:802-822`
- **Issue:** The procedure takes a `kind` parameter but passes the constant `.Set_Acceleration` to `klipper_command_end`. `G21`, `G90`, `M83`, `M107`, `PAUSE`, `M600` and `END_PRINT` are therefore recorded with the wrong kind. These kinds are written to the Klipper evidence artifact (`klipper_artifact.odin:124`) and hashed (`klipper_hashes.odin:113`).
- **Fix:** Pass `kind` through. The evidence hash changes, so update any recorded golden hashes in the same change.

### [CR-27] Modifier `fan=0` Fails G-code Emission for Materials With a Nonzero Minimum Fan
- **Locations:** `src/pipeline/modifiers.odin:117-124`, `src/gcode/klipper.odin:792`
- **Issue:** CR-18 lets `fan=0` set `fan_ratio = 0`, but `klipper_operation_numeric_valid` still requires `fan_ratio >= material.minimum_fan_ratio`. For a material with `min_fan_percent > 0`, `klipper_emit` returns `.Invalid_Motion` and the slice fails. The shipped PLA, PETG and ABS profiles use `min_fan_percent: 0`, so they are not affected; the 35% PLA premise in CR-18 does not match `resources/profiles/materials/pla.json`.
- **Fix:** Decide whether a modifier may go below the material minimum. If it may, relax the emitter check for modifier-marked operations. If it may not, clamp `fan=0` to the material minimum and report the clamp.

### [CR-28] Modifier Speed Scaling Leaves Operation Durations Stale
- **Location:** `src/pipeline/modifiers.odin:108-116`
- **Issue:** `speed_scale` changes `op.speed` but not `op.duration_us`, the layer duration totals, or the minimum-layer-time slowdown. Motion evidence and layer timing then disagree with the emitted feed rates, and a `speed_scale > 1` zone can violate `minimum_layer_time`. `klipper_motion_valid` still passes because it checks only that the stale sums agree with each other.
- **Fix:** Recompute the duration of each modified operation and its layer totals, or apply modifiers before motion planning and minimum-layer-time enforcement.

### [CR-29] Time Estimate Uses Inconsistent Junction Speeds Between Moves
- **Location:** `src/features/time_estimate.odin:83-111`
- **Issue:** Each move sets `v_exit := v_entry`, while the next move's entry is computed from `prev_v` (the previous cruise speed). One move's exit speed therefore differs from the next move's entry speed. For example, a straight chain after a stop decelerates the first segment to 0 at its end, but the second segment starts at full cruise speed. The estimate is not a consistent trapezoid model and its error depends on how paths are segmented.
- **Fix:** Use a two-pass lookahead (a forward and a backward pass over junction speed limits, as Klipper's lookahead queue does) so that each junction has one speed.

### [CR-30] Trace JSON Writes Unescaped Strings
- **Location:** `src/cli/main.odin:123-126`
- **Issue:** The input file name and profile names are written with `"%s"` without JSON escaping. A name that contains `"` or `\` produces invalid JSON.
- **Fix:** Escape string values (quote, backslash and control characters) before writing them.
