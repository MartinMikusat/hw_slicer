# `hw_slicer` Optimization Ledger

Living engineering ledger of every performance bottleneck identified across the slicing pipeline, its primary-source location, expected impact, and current status.

## Baseline Before `/goal` Audit (`2e8f3c2`, 100% Pure Odin + Metal, `--threads=8 --gpu`)

- `all-in-one-test.stl`: `760.15 ms` (OrcaSlicer 2.5.1: `1,032.32 ms`, `0.74×`)
- `benchy.stl`: `708.21 ms` (OrcaSlicer 2.5.1: `810.64 ms`, `0.87×`)
- `stanford-bunny.stl`: `2,305.22 ms` (OrcaSlicer 2.5.1: `2,134.05 ms`, `1.08×`)
- **Combined 3-Model Suite:** `3,773.58 ms` (OrcaSlicer 2.5.1: `3,977.01 ms`, `0.95×`)

---

## Discovered Optimization Opportunities

| ID | Stage / File | Finding | Expected Impact | Status |
|---|---|---|---|---|
| **OPT-01** | `perimeters.odin`, `surfaces.odin`, `skin.odin`, `bridge_evidence.odin`, `bridge_directions.odin`, `role_overlap.odin`, `gap_evidence.odin`, `motion_plan.odin`, `infill.odin` | 10+ full-model SHA-256 `*_hash()` calls whose hash output is immediately discarded (`_`), used only as validation guards. | -50 to -120 ms across all models | `DONE` (Wave 1) |
| **OPT-02** | `bridge_evidence.odin`, `bridge_directions.odin` | Both stages are 100% single-threaded; `bridge_directions_score` recomputes `expanded_supports` offsets for **all** layers even when 90%+ of layers have zero eligible bridge masks. | `bridges`: `157 ms → 27.5 ms` on bunny (`5.73×`) | `DONE` (Wave 1) |
| **OPT-03** | `infill_patterns.odin`, `bridge_directions.odin` | `infill_pat_emit_clipped_polyline` scans all ~300 boundary edges per Gyroid wave segment (`~360M` edge tests on bunny). Pre-filtering edges to the row's `[y - amp, y + amp]` band + `i64` ray-cast. | `infill`: `182 ms → 14.35 ms` on bunny (`12.68×`) | `DONE` (Wave 1) |
| **OPT-04** | `extrusion.odin`, `motion_plan.odin` | `extrusion_calculate` and `motion_plan_build` iterate `1.1M+` moves single-threaded on bunny (`361 ms`). Parallelizing per-layer calculations across `parallel_for`. | `extrusion_and_motion`: `361 ms → ~140 ms` on bunny | `IN_PROGRESS` (Wave 2) |
| **OPT-05** | `klipper_validator.odin` | Validates `1.14M` emitted G-code lines single-threaded with `strings.fields` / `strconv.parse_f64` allocations (`196 ms` on bunny). Fast zero-alloc line scanning + fixed-point parse. | `klipper_emit_validate`: `196 ms → ~70 ms` on bunny | `IN_PROGRESS` (Wave 2) |
| **OPT-06** | `odin_vatti.odin` | Full-AET scan on every scanbeam + `y_mid` recomputation even when AET order is unchanged; `vatti_seg_intersect` endpoint check before 128-bit cross products; AABB pre-check in `skins_propagate` before calling `provider.boolean`. | `surfaces_and_skin` / `solid_paths` / `gap_fill`: `-250 to -450 ms` on bunny | `PENDING` (Wave 3) |
| **OPT-07** | `cpu_intersections.odin`, `topology.odin`, `snapped_segments.odin` | `slice_spine` (`155 ms` on bunny, `160 ms` on benchy) is single-threaded across all layers. Parallelizing per-layer intersection & topology reconstruction. | `slice_spine`: `155 ms → ~45 ms` (`-110 ms`) | `PENDING` (Wave 3) |
| **OPT-08** | `solid_paths.odin` | Pass 1 & Pass 2 scanline hatching (`solid_path_scan_boundary`) are single-threaded (`42,799` paths on bunny). Parallelizing per-mask scanline hatching. | `solid_paths`: `-40 to -80 ms` on bunny | `PENDING` (Wave 3) |
| **OPT-09** | `gap_evidence.odin` | On thick solid regions with all concentric perimeters intact and identical topology, computing `coverage` still runs 6 offsets + 3 unions. | `gap_fill`: `-150 to -250 ms` on bunny | `PENDING` (Wave 3) |
| **OPT-10** | `hw_slicer` + `hw_printer` | Procedural (math-function) infill evaluated natively on `hw_printer` instead of serializing 40 MB of Gyroid `G1` moves. | Architectural (`docs/procedural-infill-proposal.md`) | `DEFERRED` |
