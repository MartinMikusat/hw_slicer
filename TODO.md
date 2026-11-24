# TODO — hw_slicer

## Direction

The application is a development workspace for print preparation and inspection of the slicing pipeline.
Develop the early stages in depth. A complete slicer and external users are long-term goals.
Leave detailed decisions for later stages open until their development requires them.
Preserve versioned stage contracts and debug-evidence protocols.

## Pipeline stages

Give each meaningful slicing operation a distinct stage when its output can be inspected.
Group internal operations that have no useful independent result.
The engine stages (`Stage_Id`) are, in execution order:

1. Model
2. Layer schedule
3. Mesh intersections
4. Contours and topology
5. Regions
6. Surfaces and skin
7. Perimeters
8. Bridges
9. Solid skin
10. Sparse infill
11. Gap fill
12. Supports and adhesion
13. Path plan
14. Motion
15. G-code, including simulation when implemented

Show each stage's purpose, input, output, and implementation status in the workspace.
Label unimplemented stages as placeholders. Do not imply that their results exist.

## Workspace decisions

- Use a full-window workspace with the stage graph and the 3D view split by a draggable divider, and the attribute editor of the selected stage on the right. See the [stage graph plan](docs/stage-graph-plan.md).
- Keep the attribute editor consistent across stages. For an empty attribute editor, state what the stage will configure or produce. Do not invent controls or measurements.
- Show one graph node per engine stage. A click selects the stage and shows its result in the 3D view. Stale and failed stages stay selectable.
- Preserve the selected layer across applicable stages. The layer selector belongs to the 3D view. Show the layer in model context and provide an isolated view for detailed inspection.
- Put each setting at the first stage that it affects. Show inherited values as context in later stages without duplicate editable controls.
- Run stages automatically when their operations are known to be fast. Provide a Run or Recompute action for operations that can take noticeably longer. Choose this behavior per stage until actual use justifies another approach.
- When earlier inputs change, retain available later results and mark them stale. Identify the earlier change that invalidated them.
- Preserve model viewing and evidence-bundle inspection. Map evidence to its stage where possible and retain access to unmapped records.

## Slicer completion

Done means: the app loads a model, slices it with printer, material, and process profiles, shows every stage with its evidence, and exports G-code that prints correctly on the V-Core 3 through `hw_printer`. The CLI and the app run the same pipeline and produce the same evidence.

1. [ ] Correctness gaps. Diagnose the vase-mode `hw-printer-sim` failure ("Timer too close"). Validate the assembled sequential G-code, not only each object. Review `src/slicing/`, `src/formats/`, `src/evidence/`, and the feature stages that the review passes did not cover. Done when vase, scarf, and sequential `sim-verify.sh` runs pass and the review findings are fixed and tested.
2. [ ] One pipeline with evidence. Add an evidence level to the production slice so that the orchestrator writes a `.hwsdebug` bundle for every stage. Add evidence for bridges, gap fill, supports, adhesion, ironing, Z ramps, arc fitting, and modifiers. Replace the separate probe pipeline. Done when a CLI Benchy slice produces a bundle that covers every stage and passes the bundle validator.
3. [ ] The app slices. Connect the stage workspace (Work, first two items) to the production pipeline on a background thread. Done when the app slices Benchy and the Stanford Bunny, steps through every stage, and exports G-code identical to the CLI output.
4. [ ] Geometric rendering and cross-stage selection for every stage (Work, third item).
5. [ ] Physical validation. Run `sim-verify.sh` over the feature matrix on Benchy, the Stanford Bunny, and the all-in-one model, then calibration prints on the V-Core 3. Compare filament and time estimates with the result.
6. [ ] Tuning tools: the settings sweep and settings from the sliced preview (Work, fourth and fifth items).

Open decisions:

- When the app interface switches from Toolpath Design to the slicer workspace (step 3).
- Whether vase mode omits top solid layers.
- Whether the probe tools are removed or become thin wrappers over the production slice.
- Whether step 5 requires physical prints or accepts simulator verification for now.

## Work

- [ ] Stage workspace: stage list, per-stage settings, stale tracking and background runs exist ([staged pipeline](docs/staged-pipeline.md)). Remaining: draw stage results in the 3D view, apply the lay-on-face placement to the slice, connect the evidence bundles to the stages.
- [ ] Replace the stage list with a Meshroom-style node graph after Slicer completion step 3: [plan](docs/stage-graph-plan.md).
- [ ] Connect engine stages in subsequent bounded changes. Develop early stages in depth before committing to detailed later-stage designs.
- [ ] Extend retained evidence through the remaining intermediate feature graphs. Add geometric rendering and cross-stage selection. Connect these stages to the production slice action before physical printer calibration. See [project details](README.md#project-details).
- [ ] Add a settings sweep for tuning. Define ranges for relevant settings on a test model, such as a bridging test. Place several copies on the build plate, each with a different combination of the sampled settings, to compare configurations in one print.
- [ ] Allow configuring settings directly from the sliced preview. Selecting a feature in the preview, such as a bridge, shows the settings that govern it and allows changing them there, so the user does not have to search for the right setting.
- [ ] Add MCP servers for the slicer and for the printer, so an AI agent can change slicer settings and control the printer directly. Implement the slicer side here and the printer side in `hw_ratos`.
- [ ] Toolpath Design ([ADR 0001](docs/adr/0001-printer-parametric-toolpath-design.md), [format](docs/design-format.md)). Done: `.hwsdesign` text with derived parameters over the physical nozzle and filament, `fit` counts, boxes and cylinders as concentric loops, and a time-revealed bead simulation with nozzle switching and live reload, and Klipper G-code export through `START_PRINT` and `END_PRINT`. Next: material profiles instead of the PLA assumptions, first-layer cooling, a shared node-graph profile, more primitives and explicit paths, then re-evaluation during a print.
- [ ] Integrate FullControl-style explicit toolpath design: user-defined paths with per-point state such as speed, extrusion, and temperature, previewed and exported through the pipeline. See [references](docs/references.md).
- [ ] Keep abstract motion behaviors, such as z-hop, in the sliced file instead of baking in their values. The printer resolves them while it streams the file, so the user can change them during a running print (larger z-hop, no z-hop) along with as many other abstracted settings as practical, beyond simple overrides like flow multiplier. Pairs with the printer MCP and `hw_ratos`.
- [ ] Own the stack as one native Odin "golden" setup: a printer host that replaces Klipper's host, Moonraker, Mainsail, and RatOS, and talks to the stock Klipper microcontroller firmware. The host is `../hw_printer`; see its [plan](../hw_printer/docs/plan.md).
- [ ] Document the stages and their current implementation status as the workspace develops.

## Deferred

Cross-project Apple-platform interaction work is tracked in the [workspace
TODO](../TODO.md).
