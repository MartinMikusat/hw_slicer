# Metal GPU Compute & Multi-Core Acceleration Report

This document records the measured release-mode (`-o:speed`) CPU profiling baseline for `hw-slicer-cli`, ranks the slicing bottlenecks, describes the headless Metal compute and multi-core CPU optimizations implemented in Milestone 6, and reports the verified before/after speedups and CPU-vs-GPU parity results.

## 1. Test Corpus & Configuration

- **Hardware:** Apple Silicon macOS (headless `MTLCreateSystemDefaultDevice()`, unified `MTLResourceStorageModeShared` memory, 8 worker threads).
- **Binary:** `./build.sh cli-release` (`build/release/hw-slicer-cli`, `-o:speed`, zero AppKit dependency).
- **Profile:** `--printer=vcore3 --material=pla --process=0.20-standard` (Gyroid infill, monotonic skin, variable walls, aligned seams, wipe-on-retract, 0.4 mm Z-hop, overhang slowdown & fan boost, `G2`/`G3` arc fitting, strict `klipper_validate`).
- **Models:**
  1. `resources/models/all-in-one-test.stl` — 51,092 triangles, 499 layers, 1 automatic contour repair.
  2. `resources/models/benchy.stl` — 225,706 triangles, 239 layers, 5 automatic contour repairs.
  3. `resources/models/stanford-bunny.stl` — 112,402 triangles, 539 layers, 1.96M extrude moves.

## 2. Baseline CPU Release Profile & Bottleneck Ranking

| Rank | Stage | `all-in-one-test.stl` | `benchy.stl` | `stanford-bunny.stl` | Combined | Share |
|---:|---|---:|---:|---:|---:|---:|
| 1 | `extrusion_and_motion` | 1,147.99 ms | 8,015.91 ms | 7,194.48 ms | **16,358.38 ms** | **41.1%** |
| 2 | `gap_fill` | 548.87 ms | 2,649.86 ms | 5,410.15 ms | **8,608.88 ms** | **21.6%** |
| 3 | `infill` (Gyroid) | 97.65 ms | 388.26 ms | 3,389.28 ms | **3,875.19 ms** | **9.7%** |
| 4 | `surfaces_and_skin` | 742.73 ms | 1,424.52 ms | 1,397.05 ms | **3,564.30 ms** | **8.9%** |
| 5 | `solid_paths` | 257.21 ms | 764.84 ms | 614.92 ms | **1,636.97 ms** | **4.1%** |
| 6 | `slice_spine` | 251.34 ms | 750.31 ms | 479.05 ms | **1,480.70 ms** | **3.7%** |
| 7 | `regions_and_repair` | 75.18 ms | 660.27 ms | 178.73 ms | 914.18 ms | 2.3% |
| 8 | `arc_fitting` | 29.69 ms | 162.61 ms | 693.30 ms | 885.60 ms | 2.2% |
| 9 | `perimeters` | 80.35 ms | 503.86 ms | 298.72 ms | 882.93 ms | 2.2% |
| 10 | `klipper_emit_validate` | 141.23 ms | 95.84 ms | 645.31 ms | 882.38 ms | 2.2% |
| — | **Total** | **3,468.74 ms** | **15,820.61 ms** | **20,559.51 ms** | **39,848.86 ms** | **100%** |

### Root-Cause Analysis
- **`extrusion_and_motion` (41.1%):** Per-segment overhang detection (`motion_segment_is_overhang`) runs 3 exact integer point-in-polygon tests per perimeter/thin-wall segment against the previous layer's polygon set—millions of independent `(point, polygon_edges)` queries per model.
- **`infill` (9.7%, up to 3.39 s on Bunny):** Gyroid/Honeycomb polyline clipping runs point-in-polygon checks independently across every layer, making it embarrassingly parallel across CPU cores.
- **`gap_fill` (21.6%) and `surfaces_and_skin` (8.9%):** Dominated by Clipper2 polygon boolean/offset chains across layers; prime targets for per-layer CPU thread-pool parallelization in follow-up work.

## 3. Implemented Acceleration Architecture

### Headless Metal Compute (`shaders/slicer_compute.metal`, `host/HWSlicerMetalCompute.m`, `src/gpu/metal_compute.odin`)
- Initializes `MTLCreateSystemDefaultDevice()` without AppKit or any window server dependency (`-framework Foundation -framework Metal` only).
- **`batch_point_in_polygon` kernel:** Flattens all `model_layers` into shared-memory `PolyEdge` and `LayerEdgeRange` buffers once per print, gathers all 3-sample overhang queries across all layers into one `PointQuery` buffer, and dispatches a single Metal compute grid (`256` threads/threadgroup). Uses exact 64-bit integer cross products (`int64_t`) matching CPU `bridge_polygon_contains_twice`.
- **`batch_travel_crosses_exterior` kernel:** Reuses the exact same flattened `PolyEdge`/`LayerEdgeRange` buffers to test all travel move endpoints, midpoints, and polygon-edge intersections on the GPU in one batch (`256` threads/threadgroup).
- **`batch_triangle_plane_intersect` kernel:** Compiled alongside the polygon kernels in `shaders/slicer_compute.metal` and exposed via `gpu.metal_batch_triangle_plane_intersect`.

### Multi-Core CPU Parallelism (`src/features/parallel.odin`)
- Dispatches up to `--threads=N` (default `8`) worker threads (`core:thread` + `sync.atomic_add` dynamic work-stealing) across `perimeters_generate`, `surfaces_classify`, `gap_evidence_build`, `infill_pattern_generate`, and CPU-mode `motion_cpu_mt_compute_overhangs`.
- Every stage writes into disjoint per-region/per-layer slots and merges in strict index order for 100% deterministic output.

## 4. Measured 4-Way Comparison (`(a)` vs `(b)` vs `(c)` vs `(d)`)

All four configurations were measured on the same `cli-release` (`-o:speed`) binary using `--threads=1|8` and `--no-gpu|--gpu`:

- **(a) Single-core CPU:** `--threads=1 --no-gpu`
- **(b) Multicore CPU (8 threads):** `--threads=8 --no-gpu`
- **(c) Single-core CPU + Metal:** `--threads=1 --gpu`
- **(d) Multicore CPU (8 threads) + Metal:** `--threads=8 --gpu`

### Total Slice Time (with Established Reference: OrcaSlicer 2.5.1)

External reference baseline: **OrcaSlicer 2.5.1** (C++, multi-threaded, native Apple Silicon) run headlessly on the same machine with matched settings (`gcode_flavor=klipper`, `0.20 mm` layer height, `3` wall loops, `4` top/bottom shells, `15%` Gyroid infill, supports off).

| Model | (a) 1-Core CPU | (b) 8-Core CPU | (c) 1-Core + Metal | (d) 8-Core + Metal | (d) vs (a) | (d) vs (b) | OrcaSlicer 2.5.1 | (d) / Orca |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `all-in-one-test.stl` | 3,439.74 ms | 2,333.52 ms | 2,467.76 ms | **1,804.80 ms** | **1.91×** | **1.29×** | 1,052.69 ms | 1.71× |
| `benchy.stl` | 15,057.83 ms | 6,615.45 ms | 7,845.97 ms | **5,056.34 ms** | **2.98×** | **1.31×** | 1,034.08 ms | 4.89× |
| `stanford-bunny.stl` | 20,319.75 ms | 8,609.76 ms | 13,794.78 ms | **6,987.01 ms** | **2.91×** | **1.23×** | 2,013.38 ms | 3.47× |
| **Combined 3-Model Suite** | **38,817.32 ms** | **17,558.73 ms** | **24,108.51 ms** | **13,848.15 ms** | **2.80×** | **1.27×** | **4,100.15 ms** | **3.38×** |

### Accelerated Stage Breakdown

| Model | Stage | (a) 1-Core CPU | (b) 8-Core CPU | (c) 1-Core + Metal | (d) 8-Core + Metal | Best Speedup |
|---|---|---:|---:|---:|---:|---:|
| `all-in-one-test.stl` | `perimeters` | 80.95 ms | 20.61 ms | 80.26 ms | **22.20 ms** | 3.93× (CPU MT) |
| | `gap_fill` | 540.74 ms | 168.24 ms | 537.86 ms | **163.32 ms** | 3.31× (CPU MT) |
| | `infill` (Gyroid) | 96.23 ms | 20.42 ms | 95.30 ms | **21.07 ms** | 4.71× (CPU MT) |
| | `extrusion_and_motion` | 1,179.57 ms | 650.31 ms | 204.59 ms | **125.60 ms** | **9.39× (5.18× vs 8-Core)** |
| `benchy.stl` | `perimeters` | 504.27 ms | 89.08 ms | 489.09 ms | **92.96 ms** | 5.66× (CPU MT) |
| | `gap_fill` | 2,527.58 ms | 533.99 ms | 2,522.21 ms | **545.17 ms** | 4.73× (CPU MT) |
| | `infill` (Gyroid) | 387.77 ms | 70.15 ms | 386.32 ms | **77.93 ms** | 5.53× (CPU MT) |
| | `extrusion_and_motion` | 7,488.05 ms | 1,855.88 ms | 297.69 ms | **253.68 ms** | **29.52× (7.32× vs 8-Core)** |
| `stanford-bunny.stl` | `perimeters` | 297.14 ms | 60.64 ms | 292.59 ms | **57.55 ms** | 5.16× (CPU MT) |
| | `gap_fill` | 5,326.67 ms | 1,513.23 ms | 5,329.97 ms | **1,568.77 ms** | 3.52× (CPU MT) |
| | `infill` (Gyroid) | 3,368.04 ms | 593.09 ms | 3,438.25 ms | **627.46 ms** | 5.68× (CPU MT) |
| | `extrusion_and_motion` | 7,119.78 ms | 2,233.72 ms | 533.52 ms | **601.17 ms** | **13.34× (4.19× vs 8-Core)** |

### Key Takeaway
- Offloading both overhang detection and travel exterior-crossing checks to Metal GPU cuts `extrusion_and_motion` by **7.32× vs. 8-core CPU** (`29.52×` vs. 1-core) on `benchy.stl`, **5.18× vs. 8-core CPU** on `all-in-one-test.stl`, and **4.19× vs. 8-core CPU** on `stanford-bunny.stl`.
- Combining **(d) 8-Core CPU + Metal** is **1.23×–1.31× faster end-to-end than 8-core CPU alone** and **2.80× faster overall than single-core CPU** (`38.82 s → 13.85 s`).

## 5. Parity & Validation Verification

- **Strict Klipper Validator (`klipper_validate`):** Passed on all 3 models (`423,442`, `227,333`, and `1,518,886` validated commands).
- **Exact Byte-Count & Filament Parity:**
  - `benchy.stl`: `8,181,599` bytes (CPU) vs `8,181,599` bytes (GPU), `3,874.24 mm` filament (100% identical).
  - `stanford-bunny.stl`: `55,102,498` bytes (CPU) vs `55,102,498` bytes (GPU), `31,246.96 mm` filament (100% identical).
  - `all-in-one-test.stl`: `16,406.40 mm` filament (100% identical), `423,455` vs `423,442` commands (99.997% match; 13 commands differ only on exact boundary `cross == 0` tie-breaks).
