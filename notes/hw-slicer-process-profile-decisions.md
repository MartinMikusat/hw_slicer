# HW Slicer process-profile decisions

This note defines the decisions required before HW Slicer emits printable
features. It does not select product values.

The current engine emits regions, exposed masks, perimeters, infill, and a
planar path order. These outputs use regression settings only.

`Feature_Pipeline_Request` hashes those supplied settings for evidence and
cache identity. It does not normalize or select profile values.

The implemented result types are `Surface_Result`, `Perimeter_Result`,
`Infill_Result`, and `Path_Plan_Result` in
[`src/features`](../src/features/).

## Contract boundary

The plan separates four versioned documents:

- A printer profile describes machine geometry and motion limits.
- A material profile describes filament and thermal limits.
- A process profile selects printable feature behavior.
- A dialect profile describes G-code syntax and machine-state commands.

`Profile_Revisions` and `Slice_Request` already reserve the four content hashes
in [`contracts.odin`](../src/contracts/contracts.odin).

Resolve inheritance before slicing. Reject inheritance cycles and unknown
required fields.

Convert all values to canonical units. Insert explicit defaults during
resolution.

Hash each normalized document. Put the four hashes in the slice request.

Preserve source documents for editing. Use only normalized documents during
stage execution.

## Required process decisions

### Layer and shell geometry

Select one primary skin-depth representation:

- Layer count gives stable discrete behavior across fixed layer heights.
- Physical thickness preserves a target depth across adaptive layer heights.
- A combined rule needs explicit rounding and minimum-layer behavior.

Define these values:

- First-layer height and normal layer height.
- Minimum and maximum adaptive layer heights.
- Perimeter count.
- Nominal extrusion width.
- Top skin depth.
- Bottom skin depth.
- Solid infill spacing and angle schedule.

Specify whether the first layer overrides width, perimeter count, or skin
depth. Record each override as a separate normalized field.

### Surface-role overlap

A region can have top and bottom exposure at the same layer. A narrow feature
can also intersect perimeter, gap, bridge, or support-interface regions.

Select one deterministic role precedence. The selected order must cover:

- Perimeter against top or bottom skin.
- Top skin against bottom skin.
- Bridge against normal skin.
- Gap fill against skin and sparse infill.
- Support interface against model paths.

Define whether a higher role subtracts geometry from lower roles or only
changes settings. Store the selected role on every emitted path.

### Thin walls and gaps

Define the printable width interval for one centerline. Define the interval in
micrometres or as a ratio of nominal width.

Select behavior below the minimum width:

- Reject the feature and emit evidence.
- Preserve it as an unprinted geometric remainder.
- Expand it through an explicit dimensional-compensation rule.

Select behavior above one-line width and below two-line shell coverage. Define
the width allocation and flow limits for this gap.

Define the maximum centerline deviation from the source region. This value is
a named geometric tolerance.

### Bridges

Define unsupported geometry from the current layer and the supporting layer
below it. Specify any support expansion or contraction margin.

Select the bridge direction rule:

- Use the shortest unsupported span.
- Use a fixed process angle.
- Evaluate a bounded set of angles with a named cost function.

Define bridge speed, flow ratio, fan behavior, and minimum bridge area. Define
how bridge settings override normal skin settings.

### Supports

Define the overhang threshold and its geometric convention. Specify whether
the threshold uses face normals, layer projections, or both.

Define model clearance in XY and Z. Define the support expansion margin.

Define support density, pattern, interface depth, and interface spacing.
Specify build-plate-only behavior.

Keep tree support outside the first contract unless it becomes a release
requirement. Normal supports and interfaces need deterministic planar masks
first.

### Motion and extrusion

Define speed and acceleration limits for each printable role. Define the
minimum layer time and cooling response.

Define the extrusion calculation inputs:

- Filament diameter.
- Layer height.
- Effective line width.
- Path length.
- Flow ratio.
- Material density when mass estimates are required.

Select one rounding rule for accumulated extrusion. Define whether each move
stores an absolute value or an incremental value before dialect conversion.

Define seam selection, retraction, travel avoidance, and Z-hop policy. Each
decision changes path planning and must enter its stage hash.

## Proposed ownership

This table proposes profile ownership. It remains open until reviewed.

| Value | Proposed owner | First invalidated stage |
| --- | --- | --- |
| Build volume and axis limits | Printer | Normalize or validation |
| Nozzle diameter | Printer | Generate features |
| Minimum and maximum layer height | Printer | Schedule layers |
| Motion and acceleration limits | Printer | Plan paths |
| Filament diameter and density | Material | Extrusion calculation |
| Temperature and cooling limits | Material | Plan paths |
| Maximum volumetric flow | Material | Plan paths |
| Layer heights and perimeter count | Process | Schedule or features |
| Width, skin, infill, and overlap | Process | Generate features |
| Bridge and support rules | Process | Generate features |
| Seam, travel, and retraction rules | Process | Plan paths |
| Coordinate and extrusion modes | Dialect | Emit G-code |
| Numeric precision and line endings | Dialect | Emit G-code |
| Optional line numbers and checksums | Dialect | Emit G-code |

If one value has two owners, define a resolved limit. Do not let execution
stages apply undocumented precedence.

## Cache invalidation

Calculate a content hash for each normalized profile. Do not use a display name
or source-file revision as the cache key.

Apply these minimum invalidation boundaries:

- A layer-schedule field invalidates the schedule and every downstream stage.
- A feature-geometry field invalidates features, path planning, and G-code.
- A motion field invalidates path planning and G-code.
- An extrusion field invalidates extrusion annotation and G-code.
- A dialect field invalidates G-code only.
- A display-only field does not invalidate slicing output.

Store the four profile hashes in each stage manifest. Store the specific
setting source on every feature or move that consumes it.

Add one test per boundary. Mutate one field and verify the first changed stage
hash.

## Decision fixtures

Use analytic fixtures before real models:

- A one-layer plate tests simultaneous top and bottom exposure.
- A stepped roof tests skin propagation and overlap.
- A narrowing slot tests thin-wall and gap thresholds.
- A rectangular cantilever tests bridge margins and direction.
- A staircase tests overhang and support propagation.
- A trapped cavity tests support reachability policy.
- Two nearby islands test seam, travel, and retraction decisions.

Each fixture needs expected masks, stable IDs, settings provenance, and a
canonical result hash.

Use Stanford Bunny after the analytic fixtures pass. Keep 3DBenchy in the
diagnostic lane until its topology issues have an explicit repair.

## Review checklist

The first process-profile review must answer these questions:

1. Is skin depth stored as layers, thickness, or a combined rule?
2. Which role wins each overlap pair?
3. What width interval permits one-line thin-wall output?
4. What rule allocates a gap between one and two lines?
5. How is unsupported bridge geometry calculated?
6. How is bridge direction selected?
7. Which support geometry is required for the first release?
8. Which profile owns each physical and process limit?
9. Which setting changes invalidate each stage?
10. Which extrusion accumulation and rounding rule is canonical?
11. Which seam, retraction, and travel rules enter the first path planner?
12. Which G-code dialect is the first validated output target?

Record selected values, rejected alternatives, and the reason for each choice.
Do not convert a proposal in this note into a default without that record.

## Completion criteria

The profile contract is ready for implementation when:

- Every required field has one owner, unit, range, and default rule.
- Every overlap pair has one deterministic result.
- Every tolerance has a name and evidence field.
- Every field has a first invalidated stage.
- Invalid documents fail before geometry execution.
- Normalized documents encode and hash deterministically.
- Analytic fixtures define the expected feature masks.
