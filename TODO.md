# TODO — hw_slicer

## Direction

The application is a development workspace for print preparation and inspection of the slicing pipeline.
Develop the early stages in depth. A complete slicer and external users are long-term goals.
Leave detailed decisions for later stages open until their development requires them.
Preserve versioned stage contracts and debug-evidence protocols.

## Pipeline stages

Give each meaningful slicing operation a distinct stage when its output can be inspected.
Group internal operations that have no useful independent result.
Use this provisional sequence and refine it against the actual pipeline:

1. Model loading and placement
2. Layer schedule
3. Mesh intersections
4. Contours and topology
5. Regions
6. Surfaces and skin
7. Perimeters
8. Infill
9. Supports and bridges
10. Path plan
11. Motion and G-code, including simulation when implemented

Show each stage's purpose, input, output, and implementation status in the workspace.
Label unimplemented stages as placeholders. Do not imply that their results exist.

## Workspace decisions

- Use a full-window workspace with stage settings on the left, a 3D view in the center, and stage results on the right.
- Keep the sidebars consistent across stages. For an empty sidebar, state what the stage will configure or produce. Do not invent controls or measurements.
- Provide a persistent stage list and Previous and Next controls. Allow direct navigation to placeholders and stale results. Enable Next when the current stage has a valid required result. Keep placeholders directly accessible.
- Preserve the selected layer across applicable stages. Show the layer in model context and provide an isolated view for detailed inspection.
- Put each setting at the first stage that it affects. Show inherited values as context in later stages without duplicate editable controls.
- Run stages automatically when their operations are known to be fast. Provide a Run or Recompute action for operations that can take noticeably longer. Choose this behavior per stage until actual use justifies another approach.
- When earlier inputs change, retain available later results and mark them stale. Identify the earlier change that invalidated them.
- Preserve model viewing and evidence-bundle inspection. Map evidence to its stage where possible and retain access to unmapped records.

## Work

- [ ] Establish the stage workspace with the existing viewer and evidence features. Represent unconnected stages as placeholders.
- [ ] Connect engine stages in subsequent bounded changes. Develop early stages in depth before committing to detailed later-stage designs.
- [ ] Extend retained evidence through the remaining intermediate feature graphs. Add geometric rendering and cross-stage selection. Connect these stages to the production slice action before physical printer calibration. See [project details](README.md#project-details).
- [ ] Document the stages and their current implementation status as the workspace develops.

## Deferred

Cross-project Apple-platform interaction work is tracked in the [workspace
TODO](../TODO.md).
