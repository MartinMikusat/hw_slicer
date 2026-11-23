# Pure-Odin Vatti Polygon Engine (`NATIVE_PROVIDER`)

`src/polygon/odin_vatti.odin` and `src/polygon/odin_offset.odin` implement a pure-Odin polygon boolean and offsetting engine behind `polygon.NATIVE_PROVIDER` (`--polygon-provider=odin`).

## Architecture
- **Vatti Scanbeam Active-Edge-Table (`odin_vatti.odin`):**
  - X-sweep segment-segment intersection and collinear overlap splitting with exact `i128` cross-product predicates.
  - Flat CSR scanbeam edge bucketing (`start_offsets`/`start_items`, `horiz_offsets`/`horiz_items`) with zero per-scanbeam heap allocations.
  - Persistent insertion-sorted Active Edge Table (AET) tracking running `(w_subj, w_clip)` winding across `Union`, `Intersection`, `Difference`, and `Xor` under `Non_Zero`, `Even_Odd`, `Positive`, and `Negative` fill rules.
  - Per-slab verdict runs (`run_verdict`, `run_s_start`) and endpoint-evaluated horizontal edge classification (`x_top` below, `x_bot` above).
  - Fixed-point collinear/spike cleanup and canonical Booth rotation + `polygon_canonical_path_less` ordering matching `CLIPPER2_PROVIDER`.
- **Offsetting (`odin_offset.odin`):**
  - Supports `Miter`, `Round`, `Square`, and `Bevel` joins for both CCW outer contours and CW holes, followed by a `.Positive` self-union pass to trim inverted negative-offset loops.

## Verified Parity & Speed (`cli-release`, `-o:speed`, `--process=0.28-draft`)

| Model | Provider | Total Time | Surfaces (`a` / `b`) | Infill Paths | Gap Fill (`a` / `b`) | Filament | `klipper_validate` |
|---|---|---:|---:|---:|---:|---:|---|
| `cube.obj` (`0.20`) | Clipper2 | ~55 ms | 2 / 8 | 451 | 0 / 0 | 800.88 mm | PASS |
| | **Odin Vatti** | **63.26 ms** | **2 / 8** | **451** | **0 / 0** | **800.88 mm (0.00%)** | **PASS** |
| `all-in-one-test.stl` | Clipper2 | 1,710.91 ms | 1,199 / 1,626 | 5,822 | 1,222 / 42,208 | 13,361.39 mm | PASS |
| | **Odin Vatti** | **4,370.63 ms** | **1,199 / 1,647** | **5,855** | **1,204 / 42,089** | **13,452.74 mm (+0.68%)** | **PASS** |
| `stanford-bunny.stl` | **Odin Vatti** | **14,726.51 ms** | **911 / 1,315** | **5,452** | **0 / 0** | **16,748.83 mm** | **PASS** |

## Known Remaining Item Before Retiring C++ Clipper2
- `benchy.stl` layer 38 contour-repair currently fails `Lineage_Incomplete` (a 1-µm snap-rounding gap on a self-intersecting mesh contour). Keeping `CLIPPER2_PROVIDER` as the default until that edge case is closed; `--polygon-provider=odin` is available for all CLI runs.
