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

## Stage graph review (2026-11-24)

Workspace slice of `benchy.stl`, release CLI, `--threads=1|4|8|10`, faster of two runs, run-to-run spread at 8 threads at most 5 ms. Full slice: 2,400 ms on 1 thread, 849 ms on 4, 641 ms on 8, 602 ms on 10. The feature stages already scale about 6× on 8 threads. The single-threaded stages on the longest chain (Model, Mesh intersections, Contours and topology, Regions, Path plan, Motion, G-code) take about 280 ms, 44 % of the 8-thread slice. Debug builds inflate the single-threaded stages about 8× (Model 415 ms, Contours and topology 397 ms).

| ID | Stage / File | Finding | Gain (Benchy, release, 8 threads) | Status |
|---|---|---|---|---|
| **OPT-12** | `configuration.odin`, `orchestrator.odin`, `cli/main.odin`, `session.odin` | `worker_threads` defaulted to 8 on a 10-core machine (4 performance, 6 efficiency). It now defaults to 0, which `resolved_worker_threads` turns into every logical core (at most 16); `--threads=N` still overrides it. G-code is byte-identical to `--threads=8`. | Full slice `679 ms → 651 ms` (best of three alternating runs each; 4 %). An earlier, quieter run measured `641 → 602 ms` with `--threads=10` (6 %). | `DONE` |
| **OPT-13** | `cpu_intersections.odin`, `session.odin` (`stage_intersections`) | Mesh intersections scale only 1.2× (102 → 83 ms) although both intersection passes are parallel; snapping, planar ownership or span indexing appear to run single-threaded. Profile, then parallelize the dominant part. | Up to ~70 ms on the longest chain (estimate) | `OPEN` |
| **OPT-14** | `motion_plan.odin`, `extrusion.odin`, `session.odin` (`stage_motion`) | Motion scales only 1.3× (83 → 65 ms). Profile the single-threaded part. | Up to ~55 ms on the longest chain (estimate) | `OPEN` |
| **OPT-15** | `slicing/topology.odin` | Contour reconstruction has no `parallel_for`; layers are independent. Parallelize per layer. | ~40 ms of 53 ms (estimate) | `OPEN` |
| **OPT-16** | `session.odin`, `workspace.odin` | Run independent stages concurrently (Perimeters, Bridges and Gap fill beside the Surfaces and skin → Solid skin chain). Needs a dependency scheduler, a shared thread budget, and cancel and failure rules for branches. Each stage reads only results of earlier stages, so concurrent runs are data-safe. | Up to 97 ms in theory; less in practice because those stages already use ~6 cores. Larger after edits that make several branches stale. | `OPEN` (measure core idle time first) |
| **OPT-17** | `session.odin` (`stage_solid_skin`), `stages.odin` | Sparse infill reads only the solid areas (`s.overlap`), not the solid paths or ironing. Split Solid skin into Solid areas and Solid paths so Sparse infill runs beside Solid paths. | Up to 28 ms (Sparse infill off the longest chain); also shows solid areas as their own graph node | `OPEN` |
| **OPT-18** | `session.odin` (`stage_model`), `repair/` | Mesh repair and normalization run single-threaded (48 ms). | Not estimated | `OPEN` (profile) |
