# Toolpath Design

## Status

Accepted. First milestone: boxes and cylinders, simulated in the 3D view.

## Context

Regular slicing converts a fixed-size model into toolpaths. The operator wants a second path in which the printer is the main source of dimensions. A wall is "5 lines, at most 2.6 mm", not "2 mm". With a 0.4 mm nozzle the wall is 5 lines. With a 0.6 mm nozzle it is 4 lines. The long-term goal is to change such parameters while a print runs.

## Decision

- A design is a text program that generates toolpaths directly, in the style of FullControl. It does not produce a mesh, and it bypasses mesh intersection, regions, perimeters, and infill. The regular slicing pipeline stays unchanged for STL input.
- The physical printer supplies the inputs: nozzle diameter and filament diameter. Process values such as line width and layer height are derived parameter nodes, for example `line_width = nozzle * 1.1`. In the first milestone, these nodes are `let` statements in the design file. A shared node-graph profile is a later step.
- Motion and cooling (speed, acceleration, part-cooling fan) belong to each design feature, not to a role. A design-wide value is only a default. The G-code checker bounds each extrusion by the machine and material limits instead of one target per role.
- Dimensions that depend on the printer are whole counts of a unit, limited by millimetre bounds through `fit`. The rounding is part of the design, so walls are always whole lines.
- Agents write most designs. The format is plain text with line-numbered errors. The application reloads the file when it changes.
- The simulation draws each extrusion move as a bead and reveals beads by print time in the existing 3D view. The simulation is the acceptance view before G-code goes to the printer.
- The toolpath is ordered by layer, and the design can be evaluated again for any printer. This keeps re-evaluation from a given layer possible for changes during a print.

## Consequences

- Designs do not need the mesh-slicing stages, and their evidence does not apply to designs.
- G-code goes through the Klipper emitter, the slicer's only G-code target: the design toolpath becomes a motion plan, so designs and regular slicing share one validated output path.
- A shared profile graph, real printer profiles, more primitives, and changes during a print are later milestones.
- The format specification is [docs/design-format.md](../design-format.md).
