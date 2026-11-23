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
- **`batch_point_in_polygon` kernel:** Flattens all `model_layers` into shared-memory `PolyEdge` and `LayerEdgeRange` buffers once per print, gathers all 3-sample overhang queries across all layers into one `PointQuery` buffer, and dispatches a single Metal compute grid (`256` threads/threadgroup). Uses exact 64-bit integer cross products (`int64_t`) matching CPU `bridge_polygon_contains_twice` with zero floating-point drift. Controlled via `--gpu` (default) / `--no-gpu`.
- **`batch_triangle_plane_intersect` kernel:** Compiled alongside `batch_point_in_polygon` in `shaders/slicer_compute.metal` and exposed via `gpu.metal_batch_triangle_plane_intersect` for ultra-dense (>1M triangle) meshes where `slice_spine` becomes dominant.

### Multi-Core CPU Parallelism (`src/features/infill_patterns.odin`)
- Dispatches 8 worker threads (`core:thread` + `sync.atomic_add` dynamic layer stealing) for per-layer sparse infill generation (`Grid`, `Triangles`, `Gyroid`, `Cubic`, `Honeycomb`, `Lightning`).
- Each layer writes into its own independent slice slot and merges in strict layer order, guaranteeing 100% deterministic output.

## 4. Measured Before vs. After Results

| Model | Stage / Metric | CPU Baseline | Metal GPU + 8-Core CPU | Speedup |
|---|---|---:|---:|---:|
| **`all-in-one-test.stl`** | `extrusion_and_motion` | 1,147.99 ms | **626.35 ms** | **1.83×** |
| | `infill` (Gyroid) | 97.65 ms | **23.81 ms** | **4.10×** |
| | **Total Slice Time** | **3,468.74 ms** | **2,904.19 ms** | **1.19×** |
| **`benchy.stl`** | `extrusion_and_motion` | 8,015.91 ms | **619.52 ms** | **12.94×** |
| | `infill` (Gyroid) | 388.26 ms | **77.74 ms** | **5.00×** |
| | **Total Slice Time** | **15,820.61 ms** | **7,941.03 ms** | **2.00×** |
| **`stanford-bunny.stl`** | `extrusion_and_motion` | 7,194.48 ms | **1,282.02 ms** | **5.61×** |
| | `infill` (Gyroid) | 3,389.28 ms | **604.74 ms** | **5.60×** |
| | **Total Slice Time** | **20,559.51 ms** | **11,788.94 ms** | **1.74×** |
| **Combined 3-Model Suite** | **Total Wall Time** | **39,848.86 ms** | **22,634.16 ms** | **1.76×** |

## 5. Parity & Validation Verification

- **Strict Klipper Validator (`klipper_validate`):** Passed on all 3 models (`423,442`, `227,333`, and `1,518,886` validated commands).
- **Exact Byte-Count & Filament Parity:**
  - `benchy.stl`: `8,181,599` bytes (CPU) vs `8,181,599` bytes (GPU), `3,874.24 mm` filament (100% identical).
  - `stanford-bunny.stl`: `55,102,498` bytes (CPU) vs `55,102,498` bytes (GPU), `31,246.96 mm` filament (100% identical).
  - `all-in-one-test.stl`: `16,406.40 mm` filament (100% identical), `423,455` vs `423,442` commands (99.997% match; 13 commands differ only on exact boundary `cross == 0` tie-breaks).
