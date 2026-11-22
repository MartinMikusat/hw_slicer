# Stack ownership plan

This plan covers how the project replaces the printer-side software with its
own native stack. It records the target, the current stack, the order of work,
and the decisions that remain open. It is a plan, not a description of the
current implementation.

## Target

The goal is one "golden" setup for one printer: the operator's RatOS V-Core 3
now, and possibly a custom printer later. The setup is complete and fixed. It
has no plugin system and no general printer support.

Every program that the project writes is Odin and runs natively:

1. The design language, slicer, simulation, and G-code output (`hw_slicer`).
2. The printer application on the Mac (`hw_ratos`).
3. A printer host on the printer's Linux computer. It replaces Klipper's
   `klippy`, Moonraker, Mainsail, the RatOS Configurator, and the RatOS
   macros.

The boundary is the motor driver signal. The stock Klipper firmware on the
printer's microcontrollers stays. It executes timed step commands, reads
sensors, drives heaters, and shuts the machine down on faults. The Odin host
speaks its documented serial protocol.

## Current stack

These facts come from the clones in `hw_ratos/research/reference-projects/`
and the captured configuration in `hw_ratos/research/captured-config/`.

| Component | Role on the printer | Implementation |
| --- | --- | --- |
| Klipper firmware (`src/`) | Step timing, sensors, heaters, fault shutdown | C on the microcontrollers |
| `klippy` | G-code, macros, motion planning, kinematics, homing, probing, heaters | Python: about 9,600 lines of core and kinematics, 29,700 lines in 138 `extras` modules |
| `klippy/chelper` | Step generation and compression, serial queue | C, about 4,500 lines, called from Python |
| Moonraker | HTTP and WebSocket API, file storage, updates | Python |
| Mainsail | Web interface | Vue, built with Vite; served as static files |
| RatOS Configurator | Configuration server | Node.js, `npm run start` on port 3000 (`RatOS/src/modules/ratos/start_chroot_script`) |
| RatOS configuration | Printer configuration and Jinja macros such as `START_PRINT` | Klipper configuration files |

RatOS installs upstream Klipper `master` unmodified
(`RatOS/src/modules/klipper/config`, lines 19–20).

Performance is not the main gain of a native host. `klippy` already generates
and compresses steps in C. The gains are one language and toolchain across
the stack, shared code between the slicer and the printer, deterministic
behaviour that the project can inspect, and a small fixed system image.

## Sources of truth

- Klipper's serial protocol: `docs/Protocol.md` and `docs/MCU_Commands.md`.
- Klipper's host structure: `docs/Code_Overview.md` and `docs/Kinematics.md`.
- Reference output: `klippy` batch mode converts G-code into the exact
  microcontroller command stream (`docs/Debugging.md`, lines 45–66). The
  printer's Linux computer already has `klippy` installed, so batch mode runs
  there without new installs on the Mac.
- The printer's configuration: the captured `configfile.json`.

## Verification

- Compare the Odin host's microcontroller command stream with `klippy` batch
  mode for the same G-code and configuration. Motion, homing, and heater
  commands must match, or the difference must be explained and accepted.
- Connect to the real microcontrollers only after the command stream matches.
- The operator accepts each stage on the physical printer.

## Stages

Each stage ends with a result the operator can see. A stage starts only after
the operator accepts the stage before it.

### Stage 0: pin the reference

1. Read the running Klipper version and the microcontroller firmware versions
   through `hw_ratos`.
2. Copy the microcontrollers' data dictionaries from the printer. They define
   the command and response formats that the firmware accepts.
3. Record a batch-mode command stream on the printer for one design's G-code.

Result: a fixed reference for every later comparison.

### Stage 1: protocol and connection

1. Implement message framing, variable-length integers, the CRC, and the data
   dictionary in Odin.
2. Implement clock synchronization with the microcontrollers.
3. Connect to the real microcontrollers with `klippy` stopped. Read
   identification and temperatures only. Command no motion and no heat.

Result: the Odin host reports live temperatures from the printer.

### Stage 2: heaters, fans, and safety

1. Implement heater control and the safety checks before any motion:
   heater verification, minimum and maximum temperature, and the
   microcontroller's fault shutdown.
2. Implement part cooling and controller fans.

Result: the Odin host heats the bed and nozzle safely and holds temperature.

### Stage 3: motion

1. Implement the CoreXY kinematics, the move queue with lookahead, step
   generation and compression, pressure advance, and input shaping.
2. Implement the TMC driver configuration, sensorless homing, the BLTouch
   probe, and bed mesh.
3. Match the batch-mode command stream for homing and test moves, then for a
   full design.

Result: the Odin host homes the printer and runs a design's moves.

### Stage 4: print jobs

1. Replace the RatOS `START_PRINT` and `END_PRINT` macros with native start
   and end procedures.
2. Run designs as feature-aware print jobs. Each feature carries its own
   motion and cooling, so the host needs no `SET_VELOCITY_LIMIT` churn.
3. Let `hw_ratos` change feature settings during a print.

Result: the printer prints a design from the slicer through the Odin host.

### Stage 5: re-evaluate the design during a print

1. Build the design evaluator into the printer host.
2. Generate the next layers on the printer from the current parameters.
3. Define which parameter changes are valid after layers are printed.

Result: the operator changes a design parameter during a print, and the
following layers use it.

### Stage 6: the golden image

1. Replace the Moonraker API with the Odin host's own interface for
   `hw_ratos`.
2. Build a minimal Linux image with the Odin host and no Python or Node.js.
3. Keep a documented way back to the current RatOS image.

Result: the printer runs only the project's native stack and the stock
microcontroller firmware.

## Licensing

The project accepts the licences of the code it uses. An Odin host that ports
`klippy` or `chelper` code is a derivative work of Klipper and is GPLv3. A
host written only from the protocol and kinematics documentation can use
another licence. The stock microcontroller firmware stays GPLv3 and is a
separate program.

## Open decisions

The operator decides these before Stage 0 starts:

1. The repository for the printer host. Proposal: `hw_printer`, separate from
   `hw_ratos`, which stays the Mac application.
2. Whether the host ports Klipper's algorithms (GPLv3) or reimplements them
   from documentation.
3. Access to the printer's Linux computer for Stage 0 and later stages.
4. The interface between the printer host and `hw_ratos` in Stage 6.
