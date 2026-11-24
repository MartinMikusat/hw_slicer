# Stage graph workspace plan

Plan for replacing the stage list with a node graph like the Meshroom graph editor. Status: proposal, nothing implemented.

## What Meshroom does

Sources: [Meshroom manual, graph editor](https://meshroom-manual.readthedocs.io/en/latest/feature-documentation/gui/graph-editor.html), [nodes](https://meshroom-manual.readthedocs.io/en/latest/feature-documentation/core/nodes.html), [start](https://meshroom-manual.readthedocs.io/en/latest/feature-documentation/gui/start.html), [graph editor UX pull request](https://github.com/alicevision/meshroom/pull/612).

- **Graph.** One node per processing step. Each node has a colored title bar and typed pins: inputs on the left, outputs on the right. Edges are bezier curves from an output pin to an input pin. A node runs only after the nodes it is connected to have succeeded.
- **Node status.** A progress bar inside the node shows green for computed, orange for running, blue for submitted, red for error. Running a branch locks its nodes: attributes are read-only and edges cannot change.
- **Attributes.** Selecting a node opens an attribute editor beside the graph. Changed values are bold and reset by right-click. Advanced and debug attributes are hidden behind a toggle. Further tabs show log, statistics, status and node documentation.
- **Cache by hash.** Each node hashes its attributes and its inputs' hashes. Output goes to a folder named by the hash. A changed setting gives a new hash for the node and everything downstream. Reverting a setting reuses the old folder, so nothing is recomputed.
- **Duplicates and branches.** The graph may hold several nodes of one kind with different settings, fed from the same upstream node. The screenshot compares four Meshing nodes with minimum observation angle 10 and 40 on two filtered inputs, each with its own result. A duplicate icon marks nodes whose attributes equal another node's.
- **Results.** Double-click on a node shows its result in the 3D or image viewer, loaded when it becomes available. Ctrl-double-click shows only that result. Result visibility is a toggle per media item in the viewer.
- **Controls.** Right-click on empty space adds a node. Middle mouse or shift-drag pans, wheel zooms, `f` fits the view, delete removes the selection.

## Fit with hw_slicer

Already present ([staged pipeline](staged-pipeline.md)): the stage dependency tables (`stage_upstream`, `stage_downstream`), per-stage settings hashes, stale tracking with a cause, background runs of the dependency closure, per-stage setting rows, and stage descriptors with inputs and counts. The graph needs a presentation of these, not new engine logic, except for the items marked below.

Differences to decide:

| Topic | Meshroom | hw_slicer proposal |
|---|---|---|
| Topology | User edits edges and adds nodes. | Fixed: the 15 stages and their dependencies. No user edge editing at first. |
| Cache | Every hash kept on disk. | Latest result only, in memory. Keeping variants is phase 4. |
| Branches | Duplicate any node. | Phase 4: a variant of a stage and everything downstream of it. |
| Node unit | One per step. | One per engine stage (15), not per group (11). Groups become frames around their stages. |

The existing workspace decisions in `TODO.md` (stage list, Previous and Next) are replaced by the graph. The settings-on-first-affecting-stage rule, stale retention with a named cause, auto-run of quick stages and the Run action for slow ones stay.

## Design

**Layout.** Full-window graph canvas. Right panel: attribute editor for the selected node (settings, purpose, inputs, counts, log, timing). The 3D view stays and shows the selected or double-clicked node's result; it can dock beside the graph or switch with it (open decision). Left-to-right columns follow the stage order; a stage sits in the column after its deepest upstream stage, so parallel stages stack vertically (Perimeters, Bridges, Gap fill and Supports).

**Node.** Title bar with the stage name and a state color. Body lists output pins named after the stage's result (for example Layers, Contours, Regions, Toolpaths) and input pins named after upstream results. Below the title: a thin progress bar, last run time, and a stale badge naming the changed upstream stage on hover. Placeholders (unimplemented stages) are drawn dimmed with a "placeholder" label and no output pin, as the current rule requires.

**State colors.** Not run: grey. Complete: green. Stale: green with an orange outline and badge. Running: orange with progress. Queued: blue. Error: red. Cancelled: grey with a mark. This maps to `Stage_State` plus the run flag, so the UI needs a queued state exposed from the workspace.

**Edges.** Bezier from output pin to input pin. An edge is highlighted when either end is selected. An edge whose upstream is stale is drawn dashed. Edges are not editable in phases 1 to 3.

**Interaction.**
- Click selects, double-click shows the result in the 3D view and selects it as the active result.
- Right-click opens Run to here, Run only, Reset to default, Open evidence, Copy settings.
- Pan with middle mouse or space-drag, zoom with the wheel, `f` fits, arrow keys move the selection along edges.
- Changed settings are bold, with reset on right-click, as in Meshroom. An Advanced toggle hides debug and rarely used settings.
- While a run is active, nodes in the running closure are locked read-only. The existing edit queue stays for edits to other nodes.

**Results.** Double-click maps to the existing per-stage result slots. The 3D drawing of stage results is already an open item in `TODO.md` and is a prerequisite for the double-click behavior; until it lands, the right panel shows the counts and evidence that exist today.

## Phases

1. **Graph view of the existing stages.** Layout from `stage_upstream`, nodes with state colors, edges, selection, pan, zoom, fit, attribute editor reusing the current setting rows, run controls. Done when the graph shows all 15 stages live during an edit-and-rerun, matching the headless script states, and the old stage list is removed.
2. **Result viewing.** Double-click shows the stage result in the 3D view (depends on stage result drawing). Visibility toggles per result. Evidence bundle records map to nodes.
3. **Polish and inspection.** Per-node log and timing tab, bold changed values with reset, advanced toggle, node documentation tab from the stage descriptor, minimap if the graph outgrows the window.
4. **Variants.** Duplicate a stage with different settings and carry it and its downstream chain as a branch, with its own session slots and hashes. Optionally keep results per hash so reverting a setting reuses the earlier result. This serves the settings sweep in `TODO.md` and needs an ADR: it changes the session from one result per stage to a keyed store and raises memory cost.

## Engine changes needed

- Expose a queued state and per-stage progress and duration through `Workspace_View`.
- Phase 4 only: parameterize `Slice_Session` by variant id and key results by stage hash.

## Open decisions

- Whether the 3D view docks beside the graph or alternates with it.
- Whether the graph nodes are per stage (15) or per group (11) at the default zoom, with stages shown on expansion.
- Whether phase 4 keeps every hash's result or only the latest per variant.
- Whether users may eventually edit the topology (insert their own stages), which Meshroom allows and the fixed pipeline does not.
