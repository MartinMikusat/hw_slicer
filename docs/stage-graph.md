# Stage graph

The slicer tab shows the 16 engine stages as a node graph, after the Meshroom graph editor ([manual](https://meshroom-manual.readthedocs.io/en/latest/feature-documentation/gui/graph-editor.html)). The graph presents the [staged pipeline](staged-pipeline.md). The topology is fixed: users do not add stages or edit edges.

Code: `src/stage_graph.odin` (layout, drawing, attribute editor), `src/workspace_panel.odin` (actions, input, evidence mapping), `src/pipeline/stage_geometry.odin` (stage results for the 3D view).

## Layout

The graph sits on the left and the 3D view on the right in a 50/50 split separated by a draggable vertical divider. View actions (Frame, Wireframe, Mesh, Result, Lay on face), execution controls (Run, Auto), and the layer slider float inside the 3D view. A stage's column is one past its deepest input (`stage_columns`), and stages in one column stack vertically using each node's current height so expanded nodes never overlap. Positions are computed and never saved.

## Nodes and edges

Each node shows the stage name in a title bar coloured by state, the first stage count (or purpose before running), and the last run time. Nodes that own settings display their basic settings inline inside the node body (Blender-style), with a `▾`/`▸` collapse toggle in the title bar and an inline `+N advanced` toggle at the bottom when the stage has advanced settings. Modified values are highlighted; right-clicking a setting row resets it to its default. The colours are: grey for not run, green for complete, green with an orange outline and a `stale` badge for stale, orange with a moving bar and elapsed time for running, blue for queued, red for failed, and grey with `×` for cancelled. Cancelled applies only to a stage that the cancelled run left without any result. Hovering over a stale or failed node names the cause. An `E` marks a stage that has records in the loaded evidence bundle.

Edges are drawn as curves from an input to the stage that reads it. They are highlighted when either end is selected and dashed when the input is stale. Hovering over an edge names both ends.

## Interaction

- A click selects a stage and shows its result in the 3D view. Double-click has no function.
- Inline setting controls inside a node edit that setting directly; right-clicking a setting row resets it to its default.
- A right-click on a node header or summary opens Run to here, Run only, Reset to default, Open evidence, and Copy settings. Run only recomputes this stage alone from the current results of its inputs. It is available only when every stage it needs is complete. Copy settings puts the stage's `key=value` lines on the clipboard.
- Drag empty canvas with the left or middle button to pan. The host sends no key-up events, so space-drag is not available. The wheel zooms around the pointer. `f` or **Fit** fits the graph. The arrow keys move the selection: left to the deepest input, right to the first reader, up and down within the column.
- The overview in the lower-right corner appears when part of the graph is outside the canvas. Click or drag in it to move the view.
- Edits to a running or queued stage go to the edit queue. Nodes are never locked.

## 3D view

The layer toggle and slider are in the 3D view. They choose the layer whose section plane is nearest to the slider height. The view draws the selected stage's result on that layer as lines. If the stage has no planar result (Model) or no result on the layer, the view falls back to the mesh section. **Mesh** and **Result** toggle the model and the stage result.

Results are drawn in the slice frame, shifted so that the footprint centre is at the origin. Lay-on-face placement forwards its rotation to the workspace slice. Individual stages expose contextual 3D-view controls on the second toolbar row when relevant: **Path plan** renders perimeter seam markers with a `Seam` size control (`−`/`+`), and **Motion** / **G-code** render full 3D extruded beads with selectable preview color schemes, a single-layer toggle, and a color legend.

## Evidence

Evidence-bundle stages map to workspace stages in `evidence_stage_nodes`. `generate-features` maps to all feature stages, `plan-paths` maps to Path plan and Motion, and `resolve` maps to none. The evidence list shows the mapping after each record.
