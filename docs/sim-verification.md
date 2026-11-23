# Closed-Loop `hw_slicer` -> `hw_printer` / `hw-printer-sim` Verification

This document records end-to-end closed-loop verification of G-code produced by `hw-slicer-cli` executed through the native Odin printer host (`hw-printer`) against the simulated BTT Octopus 1.1 STM32F446 microcontroller (`hw-printer-sim`).

## Safety Boundary

All verification runs strictly on a local pseudo-terminal (`/tmp/hw-slicer-verify*`) against `hw-printer-sim` with `--skip-heat`. No network connection is opened and no real printer hardware is touched.

## Reproducing

```bash
./scripts/sim-verify.sh [optional-model.stl|obj] [extra hw-slicer-cli flags...]
```

When no model path is passed, `scripts/sim-verify.sh` generates a `12 x 12 x 1.2 mm` calibration pad (`sim-pad.obj`), slices it for `vcore3` / `pla` / `0.28-draft` with `--arcs --zhop=0.4`, boots `hw-printer-sim`, streams the full G-code job through `hw-printer`, and verifies zero host/MCU faults and per-pin stepper pulse execution.

## Verified Closed-Loop Run (`sim-pad.obj`)

### Slicer Output (`hw-slicer-cli`)

- **Model:** `12 x 12 x 1.2 mm` pad (`12` triangles, `4` layers at `0.28 mm` draft profile)
- **Flags:** `--printer=vcore3 --material=pla --process=0.28-draft --arcs --zhop=0.4`
- **Features exercised:** `START_PRINT`, `END_PRINT`, `EXCLUDE_OBJECT_DEFINE`/`START`/`END`, `SET_PRINT_STATS_INFO`, `SET_VELOCITY_LIMIT`, `G2`/`G3` arc fitting (`7` arcs replacing `27` segments), Z-hop (`0.4 mm`), part fan control, retraction/unretraction
- **Predicted filament:** `77.22 mm`
- **Predicted print time (`time_estimate.odin`):** `00:00:30` (`30 s`)
- **Validated Klipper commands:** `721` (`22,541` bytes)
- **Slice time:** `33.62 ms`

### Simulated Printer Execution (`hw-printer` + `hw-printer-sim`)

- **Host exit status:** `0` (zero errors, zero warnings, zero MCU shutdowns, zero timer-too-close faults)
- **Firmware config CRC:** `288378529` (`30` OIDs, `6` TMC2209 UART drivers, BLTouch verified, stored `ratos` bed mesh loaded)
- **Lifecycle:**
  - Sensorless X/Y homing + BLTouch Z homing (`START_PRINT`): `0.0 s -> 30.5 s`
  - Active 4-layer print execution: `30.5 s -> 60.8 s` (**`30.3 s` actual simulated print time** vs. **`30 s` predicted**, ~1% delta)
  - `END_PRINT` retract, Z-hop, rear park `(250.00, 480.00, 21.12)`, fan off, motors disabled: `60.8 s -> 64.6 s`
- **Final extruded filament:** `E 77.22 mm` (exact match to `77.22 mm` slicer estimate)

### Recorded STM32F446 Stepper Pulses (`3,186,594` total)

| MCU Pin | Axis / Function | Executed Steps |
|---|---|---:|
| `PF13` | `stepper_x` (CoreXY A) | `1,216,725` |
| `PG0` | `stepper_y` (CoreXY B) | `858,479` |
| `PC13` | `stepper_z` (front-left Z) | `293,967` |
| `PE2` | `stepper_z1` (rear Z) | `293,967` |
| `PE6` | `stepper_z2` (front-right Z) | `293,967` |
| `PF11` | `extruder` | `229,489` |

All three independent Z steppers (`PC13`, `PE2`, `PE6`) executed in exact lockstep (`293,967` steps each), confirming clean bed-mesh compensation, Z-hop, and layer transitions through `hw-printer`'s motion planner and step compressor.
