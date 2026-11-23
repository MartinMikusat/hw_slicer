# `hw_slicer` Code Review Findings

Comprehensive static & architectural code review of `/Users/martin/projects/hw_slicer` (as of `2bc76b1`). Findings are recorded incrementally as discovered, ranked by severity.

---

## High Severity

### [CR-01] `i64` Overflow Risk for Valid Coordinates Near `MAX_PLANAR_COORDINATE_UM`
- **Locations:**
  - `src/polygon/odin_vatti.odin`: `vatti_seg_intersect`, `vatti_segs_collinear`
  - `src/features/bridge_directions.odin`: `bridge_polygon_contains_twice`
  - `src/features/infill_patterns.odin`: `band_edges_contains_twice`
  - `shaders/slicer_compute.metal`: `int64_t` cross products
- **Issue:** `geometry.MAX_PLANAR_COORDINATE_UM` is `1_000_000_000_000` (`1e12 µm`). While physical printer beds (`<= 500 mm = 5e5 µm`) stay well within `i64` (`(2 * 5e5)^2 = 1e12 << 9.22e18`), any API caller or test passing coordinates `> 3e9 µm` passes `polygon_set_validate` and silently overflows `i64` in `dx * dy` cross products.
- **Fix:** Either enforce a smaller `i64`-safe coordinate ceiling on polygon inputs (`<= 1_000_000_000 µm` = 1 km, still 2,000× larger than any printer) or guard the `i64` fast path with a bounds check falling back to `i128`.

### [CR-02] Nozzle Z State Not Restored After `z_offset_um` Moves (Scarf Seam / Vase Mode)
- **Locations:**
  - `src/features/scarf_seam.odin:60-61, 96-97`
  - `src/gcode/klipper.odin:515-531`
- **Issue:** When `op.z_offset_um != 0`, `klipper_emit_operation` emits `G1 X... Y... Z<state.z + z_offset_um> E...` without updating `state.z` or tracking that physical Z diverged from `state.z`. If the next move has `op.z_offset_um == 0` (e.g., after a scarf ramp ends before `z_off == 0`, or on a travel/infill move), no `Z<state.z>` is emitted to restore the nozzle to the nominal layer height.
- **Fix:** Track `state.physical_z` separately from `state.layer_z` in `Klipper_State`; whenever an operation's target Z (`state.layer_z + op.z_offset_um`) differs from `state.physical_z`, emit `Z<target>` and update `state.physical_z`.

---

## Medium Severity

### [CR-03] Worker Thread `temp_allocator` Leaks & Allocator Thread-Safety Assumptions
- **Locations:**
  - `src/features/parallel.odin:36-42` (`parallel_for`)
  - `src/slicing/cpu_intersections.odin:35-42` (`slicing_parallel_for`)
  - Callers passing arbitrary `allocator` into parallel workers (`skin.odin`, `role_overlap.odin`, `gap_samples.odin`, `solid_paths.odin`, `bridge_evidence.odin`, `bridge_directions.odin`)
- **Issue:**
  1. Spawned worker threads in `parallel_for` and `slicing_parallel_for` never call `free_all(context.temp_allocator)` before exiting, leaking any temp allocations made by worker bodies that lack a `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()`.
  2. Callers passing a non-thread-safe custom `mem.Allocator` (e.g. a tracking or arena allocator) into these functions will hit data races on concurrent `make`/`delete`.
- **Fix:** Add `defer free_all(context.temp_allocator)` inside `worker_fn` in both helpers (and document that parallel entry points require a thread-safe allocator or fall back to 1 thread when a non-heap allocator is supplied).

### [CR-04] Non-Thread-Safe Lazy Initialization & Silent Shader Failure in `HWSlicerMetalCompute.m`
- **Location:** `host/HWSlicerMetalCompute.m:54-83`
- **Issue:** `hw_metal_compute_init` uses an unsynchronized `static bool g_initialized` (race if called concurrently), discards `NSError *err` on shader/pipeline compilation failure without logging, and returns `true` even if `g_trv_pso` or `g_tri_pso` failed to compile.
- **Fix:** Guard initialization with `dispatch_once`, log `err.localizedDescription` on failure, and verify all required PSOs.

### [CR-05] `odin_offset` Single-Pass `.Positive` Union Can Create Ghost Islands on Collapsed Holes (and Contributes to `-3.1%` Filament Delta)
- **Location:** `src/polygon/odin_offset.odin:90-108, 191-193`
- **Issue:**
  1. All offset outer rings (CCW, `+1`) and hole rings (CW, `-1`) are fed into one `odin_vatti_boolean(raw_set, {}, .Union, .Positive)` pass. When a positive offset (`d > 0`) shrinks a small CW hole past its medial axis, the hole inverts to CCW (`+1`) and `.Positive` retains it as a spurious solid island.
  2. At sharp concave corners (`denom <= 0.05`), emitting `p0 -> v -> p1` places the un-offset vertex `v` onto the offset path.
  3. This divergence from Clipper2's separate outer/hole offset + miter handling is the primary cause of the ~`-3.1%` filament difference on `benchy.stl` and `stanford-bunny.stl`.
- **Fix:** Offset outer rings and hole rings into separate sets (discarding inverted loops whose area flipped sign) and combine via `outer_union - hole_union` (for `d < 0`) or `outer_union - surviving_holes` (for `d > 0`).

### [CR-06] `fuzzy_skin_apply` Perturbs All Perimeters Instead of Only the Outer Perimeter
- **Location:** `src/features/fuzzy_skin.odin:35-38`
- **Issue:** Filters only on `src.source_kind != .Perimeter`, perturbing inner and middle perimeter loops in addition to the outermost perimeter. This causes inner walls to overlap infill/adjacent walls.
- **Fix:** Carry `is_outer_perimeter: bool` (or `perimeter_index: u32`) on `Unified_Path_Source` and apply fuzzy skin only when `perimeter_index == 0`.

### [CR-07] `--sequential` Validates Clearance but Still Slices Objects Layer-by-Layer
- **Locations:** `src/pipeline/sequential.odin:17-43`, `src/cli/main.odin:435-445`
- **Issue:** `plate_validate_sequential` validates extruder/gantry clearance and sorts objects front-to-back, but `main.odin` then merges all objects via `plate_merge_to_mesh` and runs a single layer-by-layer slice. The emitted G-code prints all objects simultaneously rather than object-by-object.
- **Fix:** When `--sequential` is enabled, slice each `Plate_Object` independently in sorted front-to-back order and concatenate their per-object motion/G-code blocks (with safe Z-clearance travel between objects).

### [CR-08] `mesh_auto_repair` Missing Vertex Bounds Checks & Open-Mesh Signed Volume Risk
- **Location:** `src/repair/mesh_repair.odin:14-17, 30-48, 76-89`
- **Issue:**
  1. `mesh.vertex_x[ib]` is indexed without checking `ia, ib, ic < u32(len(mesh.vertex_x))`, risking an out-of-bounds panic on malformed OBJ/3MF meshes.
  2. Global signed-volume flipping (`vol6 < -1e-6`) can invert an open (non-watertight) mesh whose unclosed boundary happens to produce a negative signed tetrahedron sum.
  3. Doc comment claims BFS manifold winding propagation and boundary hole filling (`holes_filled`), neither of which is implemented.
- **Fix:** Add vertex index bounds validation, gate signed-volume inversion on watertight/closed-manifold check (or implement per-component BFS winding), and align comments with actual behavior.

---

## Low Severity

### [CR-09] Missing `allocator` Parameter in `fuzzy_skin_apply` Cleanup Path
- **Location:** `src/features/fuzzy_skin.odin:85-86`
- **Issue:** `delete(new_pts)` and `delete(new_ws)` omit `allocator` (allocated on lines 40–41 with `allocator`); safe only with the default heap allocator.
- **Fix:** Dynamic arrays in Odin store their allocator internally, so `delete(new_pts)` is valid, **however** `owned_points` stores slices `new_pts[:]` which callers free with `delete(slice, allocator)` — verify caller uses the identical `allocator` and never shrinks/reallocates with a different one.

### [CR-10] CLI `filament=` Summary Ignores Post-Extrusion Filament Changes (`--scarf-seam`, `--modifier=...:flow=...`)
- **Locations:** `src/features/scarf_seam.odin:99-102`, `src/pipeline/modifiers.odin`, `src/cli/main.odin:465`
- **Issue:** `scarf_seam` and flow-scaling modifiers mutate `motion.operations[k].filament_delta_nm` after `extrusion_calculate` has already run, so `klipper.positive_filament_nm` reflects the true emitted filament while the CLI summary (`filament=... mm`) prints the stale pre-modifier `extrusion.total_filament_nm`.
- **Fix:** Report `res.klipper.positive_filament_nm` (or recompute `res.extrusion.total_filament_nm` after post-motion passes).

### [CR-11] `gap_evidence` Single-Loop Fast Path Can Omit Acute-Corner Inter-Perimeter Gaps
- **Location:** `src/features/gap_evidence.odin:523-548`
- **Issue:** On a single-contour region where all `N` concentric perimeters survive with `path_count == 1`, approximating uncovered area as `offset(innermost, -half_w)` assumes zero inter-perimeter gaps. At very acute corners (`< 30°`), miter beveling can leave small triangular gaps between perimeter bands that are skipped by the fast path.
- **Fix:** Either accept the tradeoff for default slicing (verified `< 0.21%` filament delta across the benchmark suite) or add an acute-corner check before taking the fast path.

### [CR-12] Build Hygiene: Deprecated `zlib.inflate` & Always-Linked C++ Clipper2
- **Locations:** `src/formats/bounded_zip.odin:378`, `build.sh:57, 103, 120`
- **Issue:**
  1. `bounded_zip.odin:378` calls deprecated `zlib.inflate`, emitting a compiler warning on every build.
  2. `build.sh` unconditionally builds and links C++ `libhw_clipper2.a` (`6,769` LOC) even though `OdinVatti 2.0` is now the default provider.
- **Fix:** Migrate `bounded_zip.odin:378` to `core:compress/deflate` (`deflate.inflate_zlib`), and optionally gate `libhw_clipper2.a` behind a build flag once A/B reference parity checks are no longer needed.
