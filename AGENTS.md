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
