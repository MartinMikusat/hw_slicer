# `hw_slicer` Optimization Ledger

Living engineering ledger of every performance bottleneck identified across the slicing pipeline, its primary-source location, measured impact, and status.

## Before vs. After `/goal` Optimization Pass (100% Pure Odin + Metal, Zero C++ Executed)

| Model | Before (`2e8f3c2`) | After (Final) | OrcaSlicer 2.5.1 | Final / Orca |
|---|---:|---:|---:|---:|
| `all-in-one-test.stl` | 760.15 ms | **656.56 ms** | 1,016.99 ms | **0.65× (1.55× faster)** |
| `benchy.stl` | 708.21 ms | **581.05 ms** | 791.00 ms | **0.73× (1.36× faster)** |
| `stanford-bunny.stl` | 2,305.22 ms | **1,411.57 ms** | 1,825.93 ms | **0.77× (1.29× faster)** |
| **Combined 3-Model Suite** | **3,773.58 ms** | **2,649.18 ms** | **3,633.92 ms** | **0.73× (1.37× faster)** |

---

## Optimization Ledger

| ID | Stage / File | Finding & Resolution | Measured Impact (on `stanford-bunny.stl`) | Status |
|---|---|---|---|---|
| **OPT-01** | `perimeters.odin`, `surfaces.odin`, `skin.odin`, `bridge_evidence.odin`, `bridge_directions.odin`, `role_overlap.odin`, `gap_evidence.odin`, `motion_plan.odin` | Replaced 10+ full-model SHA-256 `*_hash()` calls whose hash output was discarded (`_`) with lightweight structural validation. | Eliminated redundant SHA-256 passes across all stages | `DONE` (Wave 1) |
| **OPT-02** | `bridge_evidence.odin`, `bridge_directions.odin` | Parallelized `bridge_evidence_build` and `bridge_direction_supports_build` via `parallel_for`; restricted support offsetting to layers with `.Eligible_Unsupported` masks. | `bridges`: `157.4 ms → 25.1 ms` (**6.28×**) | `DONE` (Wave 1) |
| **OPT-03** | `infill_patterns.odin`, `bridge_directions.odin` | Pre-filtered Gyroid boundary edges per wave row/column `[coord - amp, coord + amp]` and switched `bridge_polygon_contains_twice` to exact `i64` with early `qy` range reject. | `infill`: `181.9 ms → 13.2 ms` (**13.7×**) | `DONE` (Wave 1) |
| **OPT-04** | `extrusion.odin`, `motion_plan.odin` | Parallelized `extrusion_calculate` per-layer geometry/volume math (preserving bit-exact sequential remainder quantization) and eliminated `1.04M` redundant 128-bit `sqrt` calls in `motion_plan_build`. | `extrusion_and_motion`: `361.2 ms → 202.5 ms` (**1.78×**) | `DONE` (Wave 2) |
| **OPT-08** | `solid_paths.odin` | Parallelized both Pass 1 and Pass 2 scanline hatching (`solid_path_scan_boundary`) via `parallel_for`. | `solid_paths`: `291.0 ms → 237.2 ms` (**1.23×**) | `DONE` (Wave 2) |
| **OPT-06** | `odin_vatti.odin` | Fixed exact `yb == v.y0` / `yt == v.y1` endpoint checks (using precomputed `v.slope`) and switched `vatti_seg_intersect` / `vatti_segs_collinear` to exact `i64`. | `surfaces_and_skin`: `503.2 ms → 448.4 ms` | `DONE` (Wave 3) |
| **OPT-09** | `gap_evidence.odin` | Added single-loop concentric perimeter fast path (`offset(innermost, -half_w)`) under `uncovered_only` when all perimeters survive as a single ring. | `gap_fill`: `448.0 ms → 41.4 ms` (**10.8×**) | `DONE` (Wave 3) |
| **OPT-07** | `cpu_intersections.odin`, `orchestrator.odin` | Parallelized Pass 1 & Pass 2 of `cpu_intersections_build` via `slicing_parallel_for` (respecting `--threads=N`). | `slice_spine`: `165.0 ms → 127.0 ms` (**1.30×**) | `DONE` (Wave 3) |
| **OPT-05** | `klipper_validator.odin` | Validates `1.14M` emitted lines single-threaded (`168 ms` on bunny). Future option: zero-alloc direct fixed-point line parser or parallel per-layer stateless validation. | Future (`~80–100 ms` potential on bunny) | `DEFERRED` (future) |
| **OPT-10** | `odin_vatti.odin` | True incremental doubly-linked AET (updating only entering/leaving edges at `ys[s]` instead of scanning all active edges per slab). | Future (`~200–300 ms` potential on bunny `surfaces_and_skin` / `solid_paths`) | `DEFERRED` (future) |
| **OPT-11** | `hw_slicer` + `hw_printer` | Procedural (math-function) infill evaluated natively on `hw_printer` instead of serializing ~40 MB of Gyroid `G1` moves. | Architectural ([procedural-infill-proposal.md](procedural-infill-proposal.md)) | `DEFERRED` (future) |
