# Odin slicer and computational geometry course

This document records the agreed direction. It does not describe the current implementation.

## Purpose and scope

The application is an expert slicer and a computational geometry course for macOS. It targets the operator's workflow and uses Odin. The slicer and its learning material must work offline. Printer networking and other platforms are outside the current scope.

The operator directs the work and decides when each part is complete. A complete slicing pipeline is not a prerequisite for progress. One stage can receive extended research, implementation, and optimization before work starts on the next stage.

## Algorithms and learning

For each area, the work studies existing implementations and relevant research with the operator. The application then implements and optimizes its own algorithms in Odin. PrusaSlicer is a reference and a possible source of algorithms. Its output and behavior are not parity targets. The operator judges the results.

Existing libraries can be reused when they fit and their correctness is established. `hw_polygon` is a candidate, not an assumed correct implementation.

The application includes a computational geometry course. Its content follows the operator's learning and can reach research-level subjects. It also explains algorithms that the slicer does not implement. The course adapts research and other sources for the application and provides source references. Interactive demonstrations are part of the direction. Some explanations can appear beside the relevant stage; their placement remains open.

## Slicing stages

The interface presents slicing as separate stages. The final boundaries and dependencies follow the algorithms and remain open. The operator starts a full slicing run explicitly. More control over individual stages can follow. If a stage fails, the rest of the run stops.

Each stage shows its state: complete, running, stale, or failed. The operator can inspect intermediate results and details of the process. The stage view presents the settings that affect the stage on the left and its output in a 3D view on the right. Detailed diagnostics and output controls are decided with each implementation.

When an input changes, the application marks each affected result as stale. Valid results remain available for reuse. Stale results remain visible and must be identified as stale. Stage dependencies can form a graph. A setting can affect more than one stage, and a change must invalidate every affected result.

## Configuration networks

Each stage has a separate node network for its configuration. The interface shows which settings affect the stage. Configuration nodes and slicing stages have distinct roles: nodes define configuration, and stages perform computation.

A shared setting has one authoritative value. Each affected stage shows that value and its source. A change to the shared value invalidates all affected results. The exact node types, network topology, and representation of shared settings remain open. Conditions and calculations are not yet defined.

The application validates effective configuration before a stage uses it. A running job uses a stable configuration snapshot.

## Interface and automation

Every delivered part requires a polished interface, including model loading. A terminal-like appearance is the starting direction; the visual style can evolve during the work.

A CLI or MCP interface and natural-language operation are on the roadmap. AI is optional and can be disabled. The model, operation semantics, and integration are not yet selected.

## Open decisions

- The first stage and the boundaries of subsequent stages.
- The configuration network model and the storage of projects and profiles.
- The integration boundary with existing C++ code during development.
- The intermediate data, diagnostic views, and controls for each stage.
- The treatment of invalid or ambiguous geometry.
- Whether intermediate results persist across restarts. In-memory reuse is the current expectation, subject to result size.
- How the course is organized and how its material connects to the stage views.
