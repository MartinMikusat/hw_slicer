# Stack ownership plan

This plan covers how the project takes control of the path from a design to the
printer's motion, including a Klipper fork. It records the boundary, the current
stack, the order of work, and the decisions that remain open. It is a plan, not
a description of the current implementation.

## Goal and boundary

The operator wants to understand and control every layer from the design to the
printer firmware. The boundary is the motor driver signal. The project owns:

1. The design language and its evaluation (`src/design/`).
2. The slicer's toolpath, simulation, and G-code output (`hw_slicer`).
3. The printer application and its Moonraker client (`hw_ratos`).
4. The Klipper host process, `klippy`, through a fork.

The project does not modify the microcontroller firmware in Klipper's `src/`.
That firmware executes timed step commands and runs heaters, so it stays
upstream. The host-side step compression in `klippy/chelper/` belongs to the
fork, but it changes only when a stage below requires it.

## Current stack

The facts below come from the clones in `hw_ratos/research/reference-projects/`
and the captured printer configuration in `hw_ratos/research/captured-config/`.

- RatOS builds its image from upstream Klipper: `KLIPPER_REPO_SHIP` is
  `https://github.com/Klipper3d/klipper.git`, branch `master`
  (`RatOS/src/modules/klipper/config`, lines 19–20). RatOS adds its
  configuration, macros, and Klipper extension modules on top.
- `klippy` loads a module from `klippy/extras/` for each configuration section
  (`klippy/klippy.py`, `load_object`, lines 90–103). New host behaviour can
  therefore ship as an extension module without changes to core files.
- Each `Move` copies the current acceleration and junction deviation when it
  is created (`klippy/toolhead.py`, lines 14–20). `SET_VELOCITY_LIMIT` affects
  the moves queued after it, so per-feature acceleration already works without
  a fork.
- `SET_PRESSURE_ADVANCE` changes pressure advance at run time
  (`klippy/kinematics/extruder.py`, line 98). `gcode_move` holds a speed
  factor that an extension can change (`klippy/extras/gcode_move.py`).
- `klippy` has a batch mode that converts G-code into the exact
  microcontroller command stream without a printer
  (`docs/Debugging.md`, lines 45–66).
- The printer runs START_PRINT and END_PRINT from RatOS. The slicer's Klipper
  output depends on them; see [docs/design-format.md](design-format.md).
- `hw_ratos` already reads `printer.info` through Moonraker
  (`moonraker/client.odin`), which reports the running Klipper version.

## Principles

- Use an extension module before a core change. Fork core files only when an
  extension cannot reach the behaviour.
- Keep every fork change on a branch that rebases on upstream `master`.
  Record each core change and its reason in the fork's `docs/adr/`.
- Verify motion changes in batch mode before they reach the printer. Compare
  the microcontroller command stream before and after each change.
- Keep the stock microcontroller firmware. A change that needs new firmware
  commands is out of scope until the operator decides otherwise.
- The operator accepts each stage on the physical printer.

## Stages

Each stage ends with a result the operator can see. A later stage starts only
after the operator accepts the earlier one.

### Stage 0: reproduce the printer's Klipper

1. Read the running Klipper version from `printer.info` through `hw_ratos`.
2. Create the fork repository at that commit, with upstream as a second remote.
3. Run the fork in batch mode on the Mac with the captured `printer.cfg`
   and its RatOS includes.
4. Run a design's G-code through batch mode and keep the command stream as
   evidence.

Result: the project can show what Klipper does with a design's G-code,
without the printer.

### Stage 1: compare the slicer simulation with Klipper

1. Parse the batch-mode command stream into per-move timing.
2. Show Klipper's timing next to the slicer's print-time estimate in the
   design view.

Result: the simulation matches the printer's timing, or the difference is
visible. The current estimate ignores acceleration and cornering.

### Stage 2: feature-aware printing through an extension module

1. Add `klippy/extras/hw_feature.py` to the fork.
2. Have the slicer emit `HW_FEATURE ID=<n>` before each feature's moves.
3. Let the module apply per-feature overrides of speed factor, acceleration,
   fan, and pressure advance.
4. Expose the overrides through Moonraker so `hw_ratos` can change them
   during a print.

Result: the operator changes "this cylinder's fan" during a print, and the
change applies from that feature's next occurrence.

### Stage 3: re-evaluate the design during a print

1. Build the design evaluator for `linux_arm64` so the printer host can run it.
2. Replace file streaming with a print job that keeps the design and
   generates the next layers on the printer host.
3. Allow parameter changes only where they do not contradict printed layers.
   Define these rules before implementation.

Result: the operator changes a design parameter during a print, and the
following layers use it. This covers the TODO item about abstract motion
behaviours such as z-hop.

### Stage 4: core changes where extensions stop

Candidates, each with batch-mode evidence:

- Per-feature cornering and lookahead behaviour in `toolhead.py`.
- Pressure advance changes without flushing step generation.
- Feature-aware moves that carry their settings, which removes the
  `SET_VELOCITY_LIMIT` churn between travel and print moves.

## Licensing

Klipper is GPLv3 (`COPYING`). A private fork has no publication duty.
Distribution of the modified fork requires distribution of its source under
GPLv3. The slicer and `hw_ratos` communicate with Klipper through files,
G-code, and Moonraker, so they remain separate programs.

## Open decisions

The operator decides these before Stage 0 starts:

1. The fork's location. Proposal: a new repository `hw_klipper` next to
   `hw_ratos`.
2. How the fork reaches the printer. RatOS's update manager tracks upstream,
   so the printer must point to the fork, with a documented way back to
   upstream.
3. Whether the Mac batch-mode setup uses a Python virtual environment in the
   fork repository. Global instructions limit tool installation, so this
   needs approval.
4. The language for the extension modules. Klipper extensions are Python.
   Stage 3 adds an Odin program on the printer host that `klippy` calls.
