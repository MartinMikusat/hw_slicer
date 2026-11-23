# Pure-Odin Vatti Polygon Engine (`NATIVE_PROVIDER`)

`src/polygon/odin_vatti.odin` and `src/polygon/odin_offset.odin` implement a pure-Odin polygon boolean and offsetting engine behind `polygon.NATIVE_PROVIDER`, now the **default polygon provider** for `hw-slicer-cli` and `Slice_Run_Options` (`--polygon-provider=clipper2` remains available as an optional reference).

## Architecture
- **Vatti Scanbeam Active-Edge-Table (`odin_vatti.odin`):**
  - X-sweep segment-segment intersection and collinear overlap splitting with exact `i128` cross-product predicates.
  - Flat CSR scanbeam edge bucketing (`start_offsets`/`start_items`, `horiz_offsets`/`horiz_items`) with zero per-scanbeam heap allocations.
  - Persistent insertion-sorted Active Edge Table (AET) tracking running `(w_subj, w_clip)` winding across `Union`, `Intersection`, `Difference`, and `Xor` under `Non_Zero`, `Even_Odd`, `Positive`, and `Negative` fill rules.
  - Per-slab verdict runs (`run_verdict`, `run_s_start`) and endpoint-evaluated horizontal edge classification (`x_top` below, `x_bot` above).
  - Fixed-point collinear/spike cleanup and canonical Booth rotation + `polygon_canonical_path_less` ordering matching `CLIPPER2_PROVIDER`.
- **Offsetting (`odin_offset.odin`):**
  - Supports `Miter`, `Round`, `Square`, and `Bevel` joins for both CCW outer contours and CW holes, followed by a `.Positive` self-union pass to trim inverted negative-offset loops.

## Verified Parity & Speed (`cli-release`, `-o:speed`, `--process=0.20-standard`, `--threads=8 --gpu`)

With closed-ring Douglas-Peucker contour simplification (`12 µm`), `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()`, identical/disjoint AABB fast paths, flat split arrays, subject-vs-clip pair filtering, precomputed slopes, and flat degree-1 loop tracing, **100% pure Odin + Metal (zero C++ executed)** passes the full 3-model suite and all 12 checks in `scripts/accept.sh`:

| Model | Pure Odin + Metal (`OdinVatti 2.0`) | OrcaSlicer 2.5.1 | `Odin / Orca` | Filament (`--threads=1..8`, CPU/GPU) | `klipper_validate` |
|---|---:|---:|---:|---:|---|
| `cube.obj` | ~35 ms | — | — | `1376.06 mm` (`0.00%` vs Clipper2) | PASS |
| `all-in-one-test.stl` | **656.56 ms** | 1,016.99 ms | **0.65× (1.55× faster)** | `16630.10 mm` (bit-exact) | PASS |
| `benchy.stl` | **581.05 ms** | 791.00 ms | **0.73× (1.36× faster)** | `3753.50 mm` (bit-exact) | PASS |
| `stanford-bunny.stl` | **1,411.57 ms** | 1,825.93 ms | **0.77× (1.29× faster)** | `30164.85 mm` (bit-exact) | PASS |
| **Combined 3-Model Suite** | **2,649.18 ms** | **3,633.92 ms** | **0.73× (1.37× faster)** | **100% bit-exact** | **PASS** |

## Status
- `NATIVE_PROVIDER` (`OdinVatti 2.0`) is the default polygon engine (`use_native_polygon = true`).
- Zero C++ code executes during default slicing; `--polygon-provider=clipper2` remains available for A/B parity checks.
