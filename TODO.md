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

1. [x] Correctness gaps. Vase-mode `"Timer too close"` fixed (`CR-42`), assembled sequential G-code validated (`sequential_validate`), vase top-skin omission and smooth helical start fixed (`CR-44`), adaptive-layer `max_lh` for ironing/variable walls fixed (`CR-45`), skirt fallback guarded (`CR-46`). Verified with closed-loop `sim-verify.sh` on vase, scarf, and 2-object sequential prints plus byte-identical baselines.
2. [x] One pipeline with evidence. Added `evidence_level` (`Disabled`/`Summary`/`Primitives`/`Renders`) and `slice_session_export_evidence_bundle` (`src/pipeline/evidence_export.odin`) wired into `hw-slicer-cli --evidence-bundle=<path>` covering all 11 canonical stages (including bridges, gap fill, supports, adhesion, ironing, Z ramps, arc fitting, variable walls, fuzzy skin, and modifiers). Removed obsolete standalone probe tools (`strict-feature-probe`, `region-probe`, `spine`, `topology-issues`, `topology-replay`, `path-plan-replay`). Verified Benchy summary and full bundles pass `evidence-bundle-validate.sh` and `evidence-inspect.sh`.
3. [x] The app slices. Default launch view now opens on the Slicer stage workspace (keeping Toolpath Design in its tab), lay-on-face placement applies its rotation to the workspace slice, and completed `.Gcode` stages export `build/gcode/<model>.gcode`. Verified `--stage=15 --stage-run` in `hw_slicer.app` exports `build/gcode/benchy.gcode` byte-identical to `hw-slicer-cli` (`12b6f56d547a0cdf...`) and `--tabs=slicer,design` captures with zero errors.
4. [x] Geometric rendering and cross-stage selection for every stage. Extended `stage_geometry.odin` (`Result_Segment`) with `owner_stage`, `feature_id`, and `role` (plus ironing paths in `.Solid_Paths` and closed tree-support loops in `.Supports`), and added `app_pick_stage_segment` in `src/application.odin` so clicking any rendered feature in the 3D viewport selects its owning stage and opens its governing settings. Verified with debug build and `--stage=14 --stage-run` offscreen capture (zero errors).
5. [x] Physical validation (simulator milestone). Verified full CLI feature matrix across Benchy, Stanford Bunny, and all-in-one (default, tree supports, adaptive + ironing + brim + variable walls, scarf + fuzzy skin, open-topped vase), plus closed-loop `sim-verify.sh` on vase (`59.65 mm`), scarf (`76.75 mm`), 2-object sequential (`154.13 mm`), and adaptive + fuzzy + ironing + brim + variable walls (`192.67 mm`) — all matching predicted filament to 0.00 mm with triple-Z lockstep. Physical V-Core 3 calibration prints deferred for manual execution.
6. [x] Tuning tools: added Cartesian multi-copy settings sweep (`src/pipeline/sweep.odin`, `hw-slicer-cli --sweep=<key>=<v1>,<v2>,...`) with sequential clearance validation, and click-to-edit settings from the sliced 3D preview (`app_pick_stage_segment` in `src/application.odin`).

Open decisions:

- None (vase omits top solid layers; obsolete probe tools removed in step 2; app defaults to Slicer workspace with Toolpath Design tab in step 3; step 5 accepts simulator verification for now).

## Work

- [x] Stage workspace: the [stage graph](docs/stage-graph.md), per-stage settings, stale tracking, background runs, per-layer result lines, evidence mapping, lay-on-face placement forwarding, and CLI-identical G-code export are wired ([staged pipeline](docs/staged-pipeline.md)).
- [ ] Connect engine stages in subsequent bounded changes. Develop early stages in depth before committing to detailed later-stage designs.
- [x] Extend retained evidence through the remaining intermediate feature graphs. Geometric rendering and cross-stage selection are wired through `stage_geometry.odin` and `app_pick_stage_segment`. See [project details](README.md#project-details).
- [x] Add a settings sweep for tuning (`src/pipeline/sweep.odin`, `--sweep=<key>=<v1>,<v2>,...`).
- [x] Allow configuring settings directly from the sliced preview (`app_pick_stage_segment` selects the clicked feature's owning stage and opens its settings).
- [ ] Add MCP servers for the slicer and for the printer, so an AI agent can change slicer settings and control the printer directly. Implement the slicer side here and the printer side in `hw_ratos`.
- [ ] Toolpath Design ([ADR 0001](docs/adr/0001-printer-parametric-toolpath-design.md), [format](docs/design-format.md)). Done: `.hwsdesign` text with derived parameters over the physical nozzle and filament, `fit` counts, boxes and cylinders as concentric loops, and a time-revealed bead simulation with nozzle switching and live reload, and Klipper G-code export through `START_PRINT` and `END_PRINT`. Next: material profiles instead of the PLA assumptions, first-layer cooling, a shared node-graph profile, more primitives and explicit paths, then re-evaluation during a print.
- [ ] Integrate FullControl-style explicit toolpath design: user-defined paths with per-point state such as speed, extrusion, and temperature, previewed and exported through the pipeline. See [references](docs/references.md).
- [ ] Keep abstract motion behaviors, such as z-hop, in the sliced file instead of baking in their values. The printer resolves them while it streams the file, so the user can change them during a running print (larger z-hop, no z-hop) along with as many other abstracted settings as practical, beyond simple overrides like flow multiplier. Pairs with the printer MCP and `hw_ratos`.
- [ ] Own the stack as one native Odin "golden" setup: a printer host that replaces Klipper's host, Moonraker, Mainsail, and RatOS, and talks to the stock Klipper microcontroller firmware. The host is `../hw_printer`; see its [plan](../hw_printer/docs/plan.md).
- [ ] GPU-accelerated coarse-grid supports and overhang/orientation scoring: evaluate a Metal exact Euclidean Distance Transform (`PBA`, Cao et al. 2010) with a top-down morphological sweep (Hornus et al. 2015) at 100–200 µm grid pitch for support volumes and build-orientation optimization, where sub-millimetre discretization is acceptable. See [GPU slicing notes](research/notes/gpu-slicing.md).
- [ ] GPU interactive slice/overhang preview: evaluate an IceSL-style GPU ray-rep/slice preview for non-authoritative live feedback (overhang heatmaps, CSG/Toolpath Design edits) while keeping the exact CPU vector pipeline as the G-code authority. See [GPU slicing notes](research/notes/gpu-slicing.md).
- [ ] Document the stages and their current implementation status as the workspace develops.

## Deferred

Cross-project Apple-platform interaction work is tracked in the [workspace
TODO](../TODO.md).
