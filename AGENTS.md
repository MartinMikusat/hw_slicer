# AGENTS.md — hw_slicer

An Apple Silicon macOS slicer that converts 3D models into deterministic FFF toolpaths and exposes visual evidence for every pipeline stage.

## Architecture and Platform

- **Platform:** Apple Silicon (macOS ARM64). Target native Apple Silicon features and Neon/SIMD explicitly.
- **G-code:** Klipper only. The printer's `START_PRINT` and `END_PRINT` macros own homing, heating, meshing, priming, parking, and shutdown.
- **Languages:** Odin for engine, pipeline, geometry, and UI logic; Objective-C (`host/HWSlicerHost.m`) for AppKit window lifecycle and platform events; C++ (`third_party/clipper2/`) for planar polygon boolean/offset operations.
- **Graphics & UI:** Direct Metal rendering (`CAMetalLayer`) and custom shaders for the 3D scene. The 2D interface is an immediate-mode UI with a typed control registry, drawn with `hw_odin_rune` (`rune:gpu` draw list, `rune:text`) into the same command buffer. `HWSlicerHost.m` keeps the window, events, accessibility, and open panel.
- **Rendering Model:** Demand-driven rendering. Only render frames upon user interaction, state mutations, animation ticks, or window resize.

## Development & Toolchain Rules

1. **Odin Toolchain:** Always invoke the compiler via `scripts/odin.sh` (or `hw-odin`). Do not invoke raw Homebrew/system Odin compilers directly. `scripts/odin.sh` first compiles the Metal compute kernels into `build/compute/slicer_compute.metallib`, which `src/gpu` embeds; a direct `hw-odin` build needs `scripts/compute-metallib.sh` run first.
2. **Dependencies:** `dependencies.lock` locks sibling dependencies (`hw_odin_ui_flash`, `hw_odin_devlog`, `hw_odin_rune`). Verify dependencies with `./scripts/dependencies.sh check`.
3. **Clipper2 Library:** Rebuild the native Clipper2 static library with `./scripts/clipper2-build.sh [debug|asan|release]`.
4. **Validation & Autonomous Acceptance:** Run `./scripts/accept.sh` to execute full autonomous acceptance verification (debug + release builds, `dependencies.lock`, CLI feature matrix, pure-Odin Vatti parity, 4-way CPU/Metal determinism and speedup, and closed-loop `hw-printer-sim` execution). Pass `--skip-sim` for fast iteration without the ~65 s simulator print. Run `./scripts/sim-verify.sh [model]` for standalone closed-loop simulator verification. `./test.sh` runs unit tests, feature probes, artifact codecs, and verification gates.
5. **Development Watcher:** Use `./dev.sh [debug|asan|release]` as the default development loop. The watcher maintains a single-instance lock and handles hot builds.
6. **Surgical Changes:** Modify only files directly required for the task. Match existing code formatting, naming conventions, and lifetime management (explicit allocators, defer cleanups).
7. **Commit Style:** Use Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`, `perf:`, `test:`, `chore:`). Commit complete units of work autonomously.
8. **Deleting Commands or Scripts:** Whenever a command, binary, or script is deleted, search `README.md`, `AGENTS.md`, `docs/`, `test.sh`, and `scripts/` for references to the removed names and update or remove them in the same commit.
9. **Open Decisions:** Propose answers to open product decisions (such as the "Open decisions" list in `TODO.md`) rather than resolving, removing, or implementing them without explicit operator confirmation.

## UI styling

Follow the shared visual rules in `../hw_delta_support/DESIGN.md` for applicable controls and surfaces. Implement them in `src/ui.odin`.

## Performance

The project aims for the highest possible performance in every part. Record every identified optimization in the [optimization ledger](docs/optimization-ledger.md) with its measured or estimated gain. A small gain or a high cost orders an optimization later; it is not a reason to drop it. Reject an optimization only when evidence shows it cannot pay off, and record that evidence in the ledger.

## OrcaSlicer Output Comparison

After changes to slicing geometry, infill/skin, supports/adhesion, path planning, motion, or profile options, compare both output geometry and speed against the local OrcaSlicer CLI:

- `./scripts/orca-compare.py --suite=core --build` checks layer count, max Z, body XY span, net filament, extrude/travel lengths, retractions, G2/G3 arcs, estimated print time, Z-layer filament correlation (`r`), and 2D silhouette IoU on the core models.
- Pass `--scenarios` (or `--scenario=<name>`) to compare feature-enabled presets (`default`, `quality_speed`, `ironing`, `concentric_combing`, `supports_adhesion`, `raft_fuzzy`). Pass `--strict` to exit non-zero on warnings.
- `./slice-benchmark.sh --suite=core --compare-orca` runs the speed benchmark and includes the G-code output comparison in the same report.

## Pipeline workspace

For pipeline workspace design and development priorities, follow [TODO.md](TODO.md).

## Model placement

Lay on face uses one placement transform for rendering, face selection, and layer sections. The imported mesh stays unchanged.

## Toolpath Design

`.hwsdesign` files generate toolpaths directly from physical printer inputs and bypass mesh slicing (`src/design/`, simulation in `src/design_view.odin`, G-code in `src/design_export.odin`). The format is [docs/design-format.md](docs/design-format.md). The app shows the newest design in `resources/designs/` without input and writes its G-code to `build/gcode/`. `--design=<path>` pins a file, and `--design-time=<0..1>` sets the captured moment.

## Development interface

While the backend is in development, the interface shows only the feature under work, and it shows it on launch without operator input. Update the interface with each change so that it stays in sync with that feature. Hide unrelated controls; do not build general interface features. Exception: the [stage graph](docs/stage-graph.md) is the workspace frame that the feature under work lives in.

## Printer boundary

- The operator authorizes automatic monitoring at `http://ratos.local/`, heater-target changes, homing (`G28`, all axes or one), motor disengagement (`M84`), single-axis jog/absolute moves, the `STOP` button (Moonraker emergency stop), Restart/Firmware restart, read-only configuration queries, and operator-submitted upload of `printer.cfg` user overrides through the UI.
- Agents must not send heater, homing, motor disengagement, motion, emergency, restart, or configuration-upload commands to the real printer. Extrusion, arbitrary G-code, macros, print actions, G-code upload, and deletion remain blocked.
- Agents read the live configuration of the real printer only through the `printer_config` tool of the read-only MCP server (`src/printer_mcp/`, built to `build/hw-slicer-printer-mcp`, registered in `.mcp.json`).

## Diagnostics

Every run writes the shared dev log. `./dev.sh` exports
`HW_DEVLOG_DIR=.dev-logs/<mode>` and `HW_DEVLOG_PROFILE=dev`. Read the journal
before guessing about a misbehaving run:

```sh
../odin_libraries/hw_odin_devlog/build/hw-devlog --dir .dev-logs/debug summary
../odin_libraries/hw_odin_devlog/build/hw-devlog --dir .dev-logs/debug tail 40
```

The journal records startup, model and evidence loads, renderer presentation,
window visibility and activation, and handled failures. `hw-devlog check`
reports whether a run ended cleanly. `./test.sh` runs the devlog lint.

Capture the app's own render output without screen recording:

```sh
./scripts/capture.sh /tmp/hw-slicer.png
```

The capture renders the first frame to an offscreen Metal texture and writes a
PNG, so it works with the window hidden and without screen-recording permission.
Arguments after the path go to the app. `--tabs=slicer,design` switches the demo
tabs in order on the first frame and runs the design watcher after each switch,
so a capture covers tab-switch paths without computer control. `--stage-run`
slices before the first frame; set `CAPTURE_TIMEOUT` (seconds, default 10) for it.
After a capture, `hw-devlog --dir .dev-logs/capture summary` shows any `fatal` record.
