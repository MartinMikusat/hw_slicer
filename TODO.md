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
9. Solid areas
10. Solid paths
11. Sparse infill
12. Gap fill
13. Supports and adhesion
14. Path plan
15. Motion
16. G-code, including simulation when implemented

Show each stage's purpose, input, output, and implementation status in the workspace.
Label unimplemented stages as placeholders. Do not imply that their results exist.

## Workspace decisions

- Use a full-window workspace with the stage graph and the 3D view split by a draggable divider, and the attribute editor of the selected stage on the right. See the [stage graph](docs/stage-graph.md).
- Keep the attribute editor consistent across stages. For an empty attribute editor, state what the stage will configure or produce. Do not invent controls or measurements.
- Show one graph node per engine stage. A click selects the stage and shows its result in the 3D view. Stale and failed stages stay selectable.
- Preserve the selected layer across applicable stages. The layer selector belongs to the 3D view. Show the layer in model context and provide an isolated view for detailed inspection.
- Put each setting at the first stage that it affects. Show inherited values as context in later stages without duplicate editable controls.
- Run stages automatically when their operations are known to be fast. Provide a Run or Recompute action for operations that can take noticeably longer. Choose this behavior per stage until actual use justifies another approach.
- When earlier inputs change, retain available later results and mark them stale. Identify the earlier change that invalidated them.
- Preserve model viewing and evidence-bundle inspection. Map evidence to its stage where possible and retain access to unmapped records.

## Slicer completion

Done means: the app loads a model, slices it with printer, material, and process profiles, shows every stage with its evidence, and exports G-code that prints correctly on the V-Core 3 through `hw_printer`. The CLI and the app run the same pipeline and produce the same evidence.

1. [x] Correctness gaps (`src/formats/` and `src/evidence/` reviewed and confirmed defects fixed; vase top-skin/Z-start `CR-44`, adaptive `max_lh` `CR-45`, and skirt fallback `CR-46` fixed).
2. [ ] One pipeline with evidence. Remaining: serialize per-stage binary primitive payloads for all 16 pipeline stages so bundles pass strict `bundle_replay.odin` validation without loosening checks (summary counters + G-code export and `--evidence-bundle` CLI wiring exist).
3. [x] The app slices.
4. [x] Geometric rendering, cross-stage selection, and 3D G-code preview views.
5. [ ] Physical validation. Remaining: calibration prints on the V-Core 3 (closed-loop simulator matrix is done).
6. [x] Tuning tools (settings sweep and click-to-edit settings from the 3D preview).

Open decisions:

- When the app interface switches from Toolpath Design to the slicer workspace (step 3) — currently defaults to Slicer workspace with Toolpath Design in its tab.
- Whether vase mode omits top solid layers — currently omits top solid layers.
- Whether the probe tools are removed or become thin wrappers over the production slice — standalone probe binaries were removed; confirm or restore wrappers.
- Whether step 5 requires physical prints or accepts simulator verification for now.

## Work

- [x] Stage workspace ([stage graph](docs/stage-graph.md), [staged pipeline](docs/staged-pipeline.md)).
- [ ] Connect engine stages in subsequent bounded changes. Develop early stages in depth before committing to detailed later-stage designs.
- [x] Geometric rendering and cross-stage selection; remaining intermediate evidence graphs tracked under Slicer completion step 2.
- [x] Settings sweep for tuning.
- [x] Configure settings directly from the sliced preview.
- [ ] Add MCP servers for the slicer and for the printer, so an AI agent can change slicer settings and control the printer directly (read-only printer MCP is already in `src/printer_mcp/`; add slicer MCP and any authorized printer controls here).
- [ ] Toolpath Design ([ADR 0001](docs/adr/0001-printer-parametric-toolpath-design.md), [format](docs/design-format.md)). Done: `.hwsdesign` text with derived parameters over the physical nozzle and filament, `fit` counts, boxes and cylinders as concentric loops, material profiles, first-layer cooling, a time-revealed bead simulation with nozzle switching and live reload, and Klipper G-code export through `START_PRINT` and `END_PRINT`. Next: a shared node-graph profile, more primitives and explicit paths, then re-evaluation during a print.
- [ ] Integrate FullControl-style explicit toolpath design: user-defined paths with per-point state such as speed, extrusion, and temperature, previewed and exported through the pipeline. See [references](docs/references.md).
- [ ] Keep abstract motion behaviors, such as z-hop, in the sliced file instead of baking in their values. The printer resolves them while it streams the file, so the user can change them during a running print (larger z-hop, no z-hop) along with as many other abstracted settings as practical, beyond simple overrides like flow multiplier. Pairs with the printer MCP and `hw_printer`.
- [ ] Own the stack as one native Odin "golden" setup: a printer host that replaces Klipper's host, Moonraker, Mainsail, and RatOS, and talks to the stock Klipper microcontroller firmware. The host is `../hw_printer`; see its [plan](../hw_printer/docs/plan.md).
- [ ] GPU-accelerated coarse-grid supports and overhang/orientation scoring: evaluate a Metal exact Euclidean Distance Transform (`PBA`, Cao et al. 2010) with a top-down morphological sweep (Hornus et al. 2015) at 100–200 µm grid pitch for support volumes and build-orientation optimization, where sub-millimetre discretization is acceptable. See [GPU slicing notes](research/notes/gpu-slicing.md).
- [ ] GPU interactive slice/overhang preview: evaluate an IceSL-style GPU ray-rep/slice preview for non-authoritative live feedback (overhang heatmaps, CSG/Toolpath Design edits) while keeping the exact CPU vector pipeline as the G-code authority. See [GPU slicing notes](research/notes/gpu-slicing.md).
- [x] Document the stages and their current implementation status as the workspace develops.

## Deferred

Cross-project Apple-platform interaction work is tracked in the [workspace
TODO](../TODO.md).
