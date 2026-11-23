# Long-Term Proposal: Procedural (Math-Function) Infill on `hw_printer`

*Status: Future experiment / architectural note (not yet scheduled for implementation).*

## Motivation

On high-volume models such as `stanford-bunny.stl` (`539` layers, `31.2 m` filament), Gyroid infill accounts for roughly `~1.2 million` `G1` moves (~40 MB of ASCII G-code) solely to represent a simple analytic function (`y = y0 + A * sin(2π x / λ)`) clipped against 2D layer boundary polygons. Serializing, validating, transferring, and re-parsing tens of megabytes of piecewise-linear G-code is unnecessary when both the slicer (`hw_slicer`) and the printer host (`hw_printer`) are controlled native Odin programs.

## Proposed Architecture

Instead of expanding procedural infill into `G1` chords during slicing when targeting `hw_printer`:

1. **`hw_slicer` emits compact procedural infill regions:**
   - Per-layer 2D infill boundary polygon(s) (~50–200 vertices per layer, ~200 KB total across 539 layers — **~200× smaller** than G-code).
   - A compact math descriptor per region/layer: pattern kind (`gyroid`, `cubic`, `honeycomb`, `grid`, `triangles`), period/spacing (`µm`), line width (`µm`), `z` (`µm`), speed, acceleration, and flow multiplier.
2. **`hw_printer` evaluates the analytic infill on the fly:**
   - Reuses `hw_printer/job/`'s native Odin layer evaluator to clip and stream the infill wave layer-by-layer directly into `motion/lookahead.odin` → `TrapQ` → `stepcompress`, bypassing G-code ASCII formatting and parsing altogether.
3. **Stock Klipper compatibility remains intact:**
   - Standard Klipper G-code export continues emitting regular `G1` moves; procedural infill blocks are emitted only in `hw_printer`-native job format.

## Why `hw_printer` Rather Than Stock Klipper (`klippy`)

- **Stock Klipper (`klippy`):** Runs in Python on the printer host; performing 2D polygon clipping of analytic waves in Python during live printing risks host CPU saturation and `Timer too close` MCU shutdowns.
- **Native Odin `hw_printer`:** Compiled native ARM64 Odin with an existing live upcoming-layer regeneration pipeline (`hw_printer/job/` for `.hwsdesign`).

## Capabilities Unlocked

- **~100×–200× smaller print payloads** and near-zero slicer emit/validate time for infill.
- **Live mid-print infill adjustments:** Change infill density, speed, or pattern for upcoming layers mid-print without re-slicing.
- **Analytic kinematics:** The host has exact curve tangents and curvature rather than quantized chords, enabling smoother junction-velocity and Pressure Advance scheduling.
- **Closed-loop verification path:** Executed STM32F446 stepper pulses from `hw-printer-sim` can be compared directly against traditional G-code execution for identical bounding geometry and filament totals.
