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
