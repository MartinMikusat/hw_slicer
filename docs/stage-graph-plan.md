# Stage graph workspace plan

Plan for replacing the stage list with a node graph like the Meshroom graph editor. Status: decided, not implemented. Work starts after Slicer completion step 3 in `TODO.md` ("the app slices"), so the graph shows production pipeline states from the start.

## What Meshroom does

Sources: [Meshroom manual, graph editor](https://meshroom-manual.readthedocs.io/en/latest/feature-documentation/gui/graph-editor.html), [nodes](https://meshroom-manual.readthedocs.io/en/latest/feature-documentation/core/nodes.html), [start](https://meshroom-manual.readthedocs.io/en/latest/feature-documentation/gui/start.html), [graph editor UX pull request](https://github.com/alicevision/meshroom/pull/612).

- **Graph.** One node per processing step. Each node has a colored title bar and typed pins: inputs on the left, outputs on the right. Edges are bezier curves from an output pin to an input pin. A node runs only after the nodes it is connected to have succeeded.
- **Node status.** A progress bar inside the node shows green for computed, orange for running, blue for submitted, red for error. Running a branch locks its nodes: attributes are read-only and edges cannot change.
- **Attributes.** Selecting a node opens an attribute editor beside the graph. Changed values are bold and reset by right-click. Advanced and debug attributes are hidden behind a toggle. Further tabs show log, statistics, status and node documentation.
- **Cache by hash.** Each node hashes its attributes and its inputs' hashes. Output goes to a folder named by the hash. A changed setting gives a new hash for the node and everything downstream. Reverting a setting reuses the old folder, so nothing is recomputed.
- **Duplicates and branches.** The graph may hold several nodes of one kind with different settings, fed from the same upstream node.
- **Results.** Double-click on a node shows its result in the 3D or image viewer.
- **Controls.** Right-click on empty space adds a node. Middle mouse or shift-drag pans, wheel zooms, `f` fits the view, delete removes the selection.

## Fit with hw_slicer

Already present ([staged pipeline](staged-pipeline.md)): the stage dependency tables (`stage_upstream`, `stage_downstream`), per-stage settings hashes, stale tracking with a cause, background runs of the dependency closure, per-stage setting rows, and stage descriptors with inputs and counts. The graph is a presentation of these. The engine changes are listed below.

Differences from Meshroom:

| Topic | Meshroom | hw_slicer |
|---|---|---|
| Topology | User edits edges and adds nodes. | Fixed: the 15 engine stages (`Stage_Id`) and their descriptor inputs. Users do not edit edges or add stages. |
| Cache | Every hash kept on disk. | Latest result only, in memory. |
| Branches | Duplicate any node. | None. See open decisions. |
| Node unit | One per step. | One per `Stage_Id`. `Stage_Group` is retired, and no group frames are drawn. |
| Pins | Typed pins per input and output. | No pins. Edges attach to the node sides. |
| Run lock | Running nodes are read-only. | No lock. Edits during a run go to the existing edit queue. |

The workspace decisions in `TODO.md` stay: settings on the first stage they affect, stale retention with a named cause, auto-run of stages below `WORKSPACE_AUTO_RUN_LIMIT_MS` and the Run action for slower ones.

## Design

**Layout.** The window splits into the graph and the 3D view, with a draggable divider. The attribute editor for the selected node is on the right. Node positions are computed from the descriptor inputs, and the user cannot drag nodes. Nothing about the layout is saved. A stage sits in the column after its deepest input:

| Column | Stages |
|---|---|
| 0 | Model |
| 1 | Layer schedule |
| 2 | Mesh intersections |
| 3 | Contours and topology |
| 4 | Regions |
| 5 | Surfaces and skin, Perimeters, Bridges, Supports and adhesion |
| 6 | Solid skin, Gap fill |
| 7 | Sparse infill |
| 8 | Path plan |
| 9 | Motion |
| 10 | G-code |

**Node.** A title bar with the stage name and a state color. Below it: the two stage counts, the last run time, and a stale badge. Hovering over the badge names the stage whose change made the result stale (`changed_by`).

**State colors.** Not run: grey. Complete: green. Stale: green with an orange outline and badge. Running: orange with a busy indicator and elapsed time. Queued: blue. Failed: red. Cancelled: grey with a mark.

**Edges.** Bezier curves from the right side of the input stage to the left side of the dependent stage. An edge is highlighted when either end is selected. An edge from a stale stage is dashed. Hovering over an edge names the input. The attribute editor lists all inputs of the selected stage.

**Interaction.**
- A click selects the node and shows its result in the 3D view. The selection and the shown result are one state. Double-click has no function yet.
- Right-click opens Run to here, Run only, Reset to default, Open evidence, and Copy settings.
- Pan with the middle mouse button or space-drag. Zoom with the wheel. `f` fits the graph. Arrow keys move the selection along edges.
- Changed settings are bold and reset by right-click. An Advanced toggle hides debug and rarely used settings.
- An edit to a stage that is running or queued is queued, as edits are today. The node shows its running state but stays editable.

**Layer.** The layer selector belongs to the 3D view. It applies to the result that is shown and does not change when the selection changes.

**Results.** A click maps to the per-stage result slot. The 3D drawing of stage results is an open item in `TODO.md` and must land before the click shows geometry. Until then, the attribute editor shows the counts and the evidence that exist.

## Phases

1. **Graph view of the existing stages.** Re-key the workspace from `Stage_Group` to `Stage_Id` and remove `Stage_Group`, `stage_group_names`, and `Group_View`. Build the computed layout, the nodes with state colors, the edges, and selection, plus pan, zoom, and fit. Reuse the current setting rows in the attribute editor and keep the run controls. Done when the graph shows all 15 stages live during an edit-and-rerun, the states match the headless script, and the stage list with Previous and Next is removed.
2. **Result viewing.** A click shows the stage result in the 3D view, which depends on stage result drawing. Add visibility toggles per result and map evidence bundle records to nodes.
3. **Polish and inspection.** Add a per-node log and timing tab, bold changed values with reset, the Advanced toggle, a documentation tab from the stage descriptor, and a minimap if the graph outgrows the window.

## Engine changes needed

- Re-key workspace selection, settings rows, and the first-affecting-stage rule from `Stage_Group` to `Stage_Id`.
- Expose a queued state and the elapsed run time per stage through `Workspace_View`. Stages do not report progress within a run.

## Open decisions

- Variants (former phase 4): several results of one stage with different settings, kept per hash. It has no defined purpose yet. It is separate from the settings sweep in `TODO.md`, which places copies with different settings on one plate. Plan it, with an ADR for a keyed result store, when a concrete comparison need appears.
