# Staged pipeline

The slice runs as 16 engine stages over one `Slice_Session` (`src/pipeline/session.odin`). Each stage keeps its result. The stage table, graph columns and settings hashes are in `src/pipeline/stages.odin`. The CLI and the application slice through the same session.

## Stages and status

All 16 stages are implemented and dispatched by the session; each retains its result in its slot. The evidence bundle collapses them into 11 stage kinds and adds a layer-span acceleration stage that is not an engine stage. Full primitives are written only in primitives-level bundles; summary-level bundles carry the counters alone.

| Stage | Dependencies | Output | Status | Evidence export |
|---|---|---|---|---|
| Model | — | Repaired, centred, unit-normalised mesh | Implemented; counters only | Stages Decode, Resolve, Normalize: source and mesh-repair counters, no primitive |
| Layer schedule | Model | Per-layer Z heights, fixed or adaptive | Implemented; replayable | `stages/04-schedule-layers/primitives/layer-schedule.bin` and replay hash; fixed schedules only, adaptive falls back to counters |
| Mesh intersections | Layer schedule | Raw layer segments and merged snapped segments | Implemented; replayable | `stages/06-intersect/primitives/cpu-intersections.bin` and replay hash |
| Contours and topology | Mesh intersections | Closed, simplified contours with path indices | Implemented; replayable | `stages/07-reconstruct-topology/primitives/topology.bin` and replay hash |
| Regions | Contours and topology | Nested outer and hole regions per layer | Implemented; replayable | `stages/08-calculate-regions/primitives/regions.bin`; written only alongside the topology primitive |
| Surfaces and skin | Layer schedule, Regions | Surface and skin masks, skin depth | Implemented; replayable | `stages/09-generate-features/primitives/surfaces.bin` and surface replay hash |
| Perimeters | Regions | Perimeter loops per region | Implemented; counters only | Generate-features counters |
| Bridges | Regions | Bridge masks, directions and paths | Implemented; counters only | Generate-features counters |
| Solid areas | Layer schedule, Regions, Surfaces and skin, Bridges | Disjoint solid masks and contours | Implemented; counters only | Generate-features counters |
| Solid paths | Layer schedule, Solid areas | Hatched solid fill and ironing paths | Implemented; counters only | Generate-features counters |
| Sparse infill | Layer schedule, Regions, Surfaces and skin, Solid areas | Infill paths at the chosen pattern and density | Implemented; counters only | Generate-features counters |
| Gap fill | Regions, Perimeters | Gap centreline paths | Implemented; counters only | Generate-features counters |
| Supports and adhesion | Model, Layer schedule, Regions | Support paths, skirt, brim, raft | Implemented; counters only | Generate-features counters |
| Path plan | Layer schedule, Perimeters, Bridges, Solid paths, Sparse infill, Gap fill, Supports | Ordered paths with seams and travel moves | Implemented; counters only | Plan-paths counters; the plan and extrusion results are not retained, so no primitive |
| Motion | Layer schedule, Regions, Path plan | Operations with extrusion, speeds, arcs, modifiers | Implemented; counters only | Plan-paths counters, merged with Path plan; no primitive |
| G-code | Motion | Validated Klipper G-code | Implemented; replayable | `stages/11-emit-gcode/output.gcode`, `primitives/klipper-gcode.bin` and replay hash |

## Stale tracking

Each stage hashes the settings it reads and the hashes of the stages it needs. A settings change recomputes the hashes. A stage whose hash differs becomes stale, keeps its result, and names the earliest stage whose settings changed. A run recomputes only the stale or missing stages among the target and its dependencies. Settings that reach a stage through the whole process document are covered by the profile feature hash, so a stage can be marked stale without a real change, never the reverse. A rerun that produces an identical result still invalidates its dependents; there is no early cutoff.

## Running stages

A run starts each stage on its own thread as soon as every stage it needs is complete, so independent stages (for example Perimeters beside Surfaces and skin) run side by side. All stages share one worker pool (`src/workers`) for their per-layer loops. Each stage reads only results of stages that finished before it and writes only its own, so the result does not depend on the order. When a stage fails, stages already running finish, nothing that needs the failed stage starts, and the run reports the earliest failed stage. Cancel starts no further stage and lets running stages finish. A stage's recorded time is its wall time, which includes sharing cores with stages running beside it.

## Workspace controller

`src/pipeline/workspace.odin` owns the configuration and the session, starts runs on a background thread, queues edits made during a run, and reports stage state (including queued, cancelled and elapsed time), stale causes, per-stage settings with their defaults, and a short event log per stage. It also resets settings, recomputes a single stage (Run only), and extracts stage results per layer for the 3D view. A setting belongs to the first stage it affects and appears read-only in later stages that read it. After a change, stale stages that last ran in under 750 ms start by themselves unless automatic refresh is off. A stage that has never run starts only on Run.

## Headless use

```sh
build/release/hw-slicer-cli --input=resources/models/benchy.stl --then=infill_density=40 --out=build/x.gcode
build/release/hw-slicer-cli --input=resources/models/benchy.stl --workspace-script=docs/workspace-scripts/edit-and-rerun.txt
```

`--then` lists the stages each change reruns and writes the G-code of each step. `--workspace-script` drives the controller the way the window does; its `check` lines exit 1 on a mismatch. The application opens on stage N (0–15) with `--stage=N`, runs every stage with `--stage-run`, selects a G-code preview view with `--gcode-view=N`, and edits a setting with `--stage-set=key=value`.

## Limits

Intermediate stages (Model through Path plan) draw stage results as planar lines on one layer; Motion and G-code render full 3D shaded extruded beads with per-move color schemes.
