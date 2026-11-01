# AGENTS.md — hw_slicer

An Apple Silicon macOS slicer that converts 3D models into deterministic FFF toolpaths and exposes visual evidence for every pipeline stage.

## Architecture and Platform

- **Platform:** Apple Silicon (macOS ARM64). Target native Apple Silicon features and Neon/SIMD explicitly.
- **Languages:** Odin for engine, pipeline, geometry, and UI logic; Objective-C (`host/HWSlicerHost.m`) for AppKit window lifecycle and platform events; C++ (`third_party/clipper2/`) for planar polygon boolean/offset operations.
- **Graphics & UI:** Direct Metal rendering (`CAMetalLayer`), custom shaders, and immediate-mode UI with a typed control registry. No external GUI framework.
- **Rendering Model:** Demand-driven rendering. Only render frames upon user interaction, state mutations, animation ticks, or window resize.

## Development & Toolchain Rules

1. **Odin Toolchain:** Always invoke the compiler via `scripts/odin.sh` (or `hw-odin`). Do not invoke raw Homebrew/system Odin compilers directly.
2. **Dependencies:** `dependencies.lock` locks sibling dependencies (such as `hw_odin_ui_flash`). Verify dependencies with `./scripts/dependencies.sh check`.
3. **Clipper2 Library:** Rebuild the native Clipper2 static library with `./scripts/clipper2-build.sh [debug|asan|release]`.
4. **Validation:** Run `./test.sh` to execute unit tests, feature probes, artifact codecs, and verification gates.
5. **Development Watcher:** Use `./dev.sh [debug|asan|release]` as the default development loop. The watcher maintains a single-instance lock and handles hot builds.
6. **Surgical Changes:** Modify only files directly required for the task. Match existing code formatting, naming conventions, and lifetime management (explicit allocators, defer cleanups).
7. **Commit Style:** Use Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`, `perf:`, `test:`, `chore:`). Commit complete units of work autonomously.

## UI styling

Follow the shared visual rules in `../hw_delta_support/DESIGN.md` for applicable controls and surfaces. Implement them in `src/ui.odin`.

## Pipeline workspace

The application is a development workspace for inspecting each stage of the slicing pipeline.
Prioritize deep development of the early stages. A complete slicer and external users are long-term goals.
Leave detailed decisions for later stages open until their development requires them.

- Use a full-window workspace with stage settings on the left, a 3D view in the center, and stage results on the right.
- Give each meaningful slicing operation a distinct stage when its output can be inspected. Group internal operations that have no useful independent result.
- Combine model loading and placement in the first stage. Combine motion and G-code in the final stage, including G-code simulation when implemented.
- Use this provisional sequence to guide the workspace: model and placement, layer schedule, mesh intersections, contours and topology, regions, surfaces and skin, perimeters, infill, supports and bridges, path plan, motion and G-code. Refine boundaries against the actual pipeline.
- Show each stage's purpose, input, output, and implementation status. Label unimplemented stages as placeholders and do not imply that their results exist.
- Keep the sidebars consistent across stages. For an empty sidebar, state what the stage will configure or produce. Do not invent controls or measurements.
- Provide a persistent stage list and Previous and Next controls. Allow direct navigation to placeholders and stale results. Enable Next when the current stage has a valid required result; visiting a placeholder must remain possible.
- Preserve the selected layer across applicable stages. Show the layer in model context and provide an isolated view for detailed inspection.
- Put each setting at the first stage that it affects. Show inherited values as context in later stages without duplicate editable controls.
- Run stages automatically when their operations are known to be fast. Provide a Run or Recompute action for operations that can take noticeably longer. Choose this behavior per stage until actual use justifies another approach.
- When earlier inputs change, retain available later results and mark them stale. Identify the earlier change that invalidated them.
- Preserve model viewing and evidence-bundle inspection. Map evidence to its stage where possible and retain access to unmapped records.

Establish the stage workspace with existing viewer and evidence features first. Connect engine stages in subsequent bounded changes.
Maintain a separate authoritative pipeline document with stage descriptions and current implementation status.

## Model placement

Lay on face uses one placement transform for rendering, face selection, and layer sections. The imported mesh stays unchanged.

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
