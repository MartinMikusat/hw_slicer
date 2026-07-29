# HW Slicer

An Apple Silicon macOS slicer that converts 3D models into deterministic FFF
toolpaths and exposes visual evidence for every pipeline stage.

## AI-assisted development disclosure

Models used:

- **gpt-5.6-sol**
- **gpt-image-2**

## Status

The project is in the architecture and planning phase. No implementation exists
yet.

The [technical implementation plan](PLAN.md) defines the subsystem contracts,
CPU and Metal execution paths, visual-debug protocol, delivery gates,
benchmarks, and research curriculum.

The [research library](research/README.md) stores verified citations, engineering
notes, PDF snapshots, provenance, checksums, and explicit project use decisions.

The SvelteKit research site in `research-site/` presents the catalog through
search, filters, summaries, limitations, and use-state views.

## Project TODO

Execute the staged plan through the release gate. Preserve the versioned stage
contracts and debug-evidence protocol when an implementation is replaced.
