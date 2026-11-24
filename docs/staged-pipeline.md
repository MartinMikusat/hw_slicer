# Staged pipeline

The slice runs as 15 engine stages over one `Slice_Session` (`src/pipeline/session.odin`). Each stage keeps its result. The stage table, graph columns and settings hashes are in `src/pipeline/stages.odin`. The CLI and the application slice through the same session.

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

`--then` lists the stages each change reruns and writes the G-code of each step. `--workspace-script` drives the controller the way the window does; its `check` lines exit 1 on a mismatch. The application opens on stage N (0–14) with `--stage=N`, runs every stage with `--stage-run`, and edits a setting with `--stage-set=key=value`.

## Limits

The slice uses the model as stored on disk; the lay-on-face placement of the viewer does not reach it. The 3D view draws stage results only as lines on one layer, not as extruded paths.
