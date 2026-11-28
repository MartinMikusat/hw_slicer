# Toolpath Design file format (`.hwsdesign`)

Toolpath Design is the workflow for designing parts by defining how the printer
lays down material. A `.hwsdesign` program uses printer inputs such as nozzle
diameter to generate toolpaths directly. See the
[Toolpath Design decision](adr/0001-printer-parametric-toolpath-design.md).

The application shows the most recently modified design in
`resources/designs/` and follows it when another design there changes.
`--design=<path>` or `1` (Open) pins one file instead. The shown design
reloads when its file changes.

Each successful load writes `build/gcode/<name>-<nozzle>mm.gcode` through the
Klipper emitter. The machine values in `src/design_export.odin` come from the
RatOS V-Core 3 configuration captured in `../references/ratos-captured-config/`: a 500 × 500 × 500 mm bed,
300 mm/s and 3000 mm/s² limits, 120 mm/s and 800 mm/s² extruder limits, and
0.5 mm retraction. Nozzle and bed temperature ranges, density, the volumetric
flow limit, and fan limits come from the shared material profiles in
`resources/profiles/materials/`, which default to `pla`. Acceleration defaults
are design values. Coordinates are mm from the bed centre, and the export fails
when a move leaves the bed.

The file calls the printer's `START_PRINT` macro with the RatOS parameters
(`EXTRUDER_TEMP`, `EXTRUDER_OTHER_LAYER_TEMP`, `BED_TEMP`, and the extrusion
area `X0 Y0 X1 Y1`), which homes, heats, meshes, and primes. It ends with
`END_PRINT`.

## Statements

One statement per line. A statement inside parentheses can continue on the
next lines. `#` starts a comment.

```text
material = NAME
let NAME = EXPRESSION
let NAME = box(KEY = EXPRESSION, ...)
box(KEY = EXPRESSION, ...)
cylinder(KEY = EXPRESSION, ...)
tube(KEY = EXPRESSION, ...)
cone(KEY = EXPRESSION, ...)
polygon(KEY = EXPRESSION, ...)
let NAME = profile(height = LENGTH, walls = COUNT, outer = loop(...), hole = loop(...))
bevel(OBJECT_A, OBJECT_B, size = LENGTH)
fillet(OBJECT_A, OBJECT_B, radius = LENGTH)
```

`material` selects a shared material profile: `pla`, `petg`, or `abs`,
case-insensitive. It is optional and defaults to `pla`.

A `let` cannot redefine a name. A name must be defined before it is used.
Objects bound with `let NAME = ...` can be referenced by `bevel` and `fillet`
to add a 45° linear chamfer or concave circular root fillet where two stacked
objects meet on a Z plane. The evaluator verifies that the two objects meet and
that the flared footprint stays within the supporting face below; beveled
layers automatically add inward loops so upper walls remain fully supported.

## Values and units

- A number without a unit is a scalar: `5`, `1.1`.
- A number with `mm` is a length: `2.6mm`, `0.2mm`.
- `+` and `-` need operands of the same kind. `*` accepts at most one length.
  `length / length` is a scalar, `length / scalar` is a length, and
  `scalar / length` is an error.

## Printer inputs

The application defines these names from the selected printer:

| Name | Kind | Meaning |
| --- | --- | --- |
| `nozzle` | length | Nozzle diameter. The left sidebar switches 0.25, 0.4, 0.6, and 0.8 mm. |
| `filament` | length | Filament diameter, 1.75 mm. |

## Process parameters

| Name | Kind | Required | Default |
| --- | --- | --- | --- |
| `line_width` | length | yes | |
| `layer_height` | length | yes | |
| `first_layer_height` | length | no | `layer_height` |
| `first_layer_fan` | scalar, percent | no | 0 |
| `nozzle_temperature` | scalar, °C | no | material midpoint |
| `bed_temperature` | scalar, °C | no | material midpoint |
| `print_speed` | scalar, mm/s | no | 40 |
| `print_acceleration` | scalar, mm/s² | no | 1000 |
| `fan` | scalar, percent | no | 100 |
| `travel_speed` | scalar, mm/s | no | 150 |
| `travel_acceleration` | scalar, mm/s² | no | 3000 |

`print_speed`, `print_acceleration`, and `fan` are defaults. Each feature can
set its own values; see [Feature settings](#feature-settings).

`nozzle_temperature` and `bed_temperature` default to the midpoint of the
material's ranges. Layer 0 runs at `first_layer_fan` clamped to the material's
maximum fan. Later layers clamp each feature's `fan` to the material's minimum
and maximum fan limits.

## Functions

| Function | Result |
| --- | --- |
| `min(a, b)`, `max(a, b)` | The smaller or larger value. Kinds must match. |
| `clamp(v, low, high)` | `v` limited to `[low, high]`. Kinds must match. |
| `floor(v)`, `ceil(v)`, `round(v)` | Rounded value, same kind. |
| `fit(count, unit, minimum, maximum)` | A whole count of `unit`. Raises `count` to cover `minimum`, then lowers it to stay within `maximum`. A bound of `0mm` is not applied. The maximum wins over the minimum. |

Example: with `line_width = 0.66mm`, `fit(5, line_width, 0mm, 2.6mm)` is 3,
because 4 lines are 2.64 mm.

## Objects

Objects print in file order on each layer. Coordinates are in millimetres
from the bed centre.

| Key | `box` | `cylinder` / `tube` / `cone` / `polygon` | Kind |
| --- | --- | --- | --- |
| `x`, `y` | optional, 0 | optional, 0 | length, centre |
| `z` | optional, 0 | optional, 0 | length, base Z height |
| `width`, `depth` | required | | length |
| `radius` | optional, 0 | | length, default radius for all four corners |
| `radius_south`, `radius_north` | optional, `radius` | | length, radius of both corners at the lower or higher Y end |
| `diameter` | | required | length, base outer diameter |
| `top_diameter` | | required on `cone`, optional otherwise | length, top outer diameter (defaults to `diameter`) |
| `inner_diameter` | | required on `tube`, optional otherwise | length, central bore diameter (defaults to 0) |
| `sides` | | required on `polygon`, optional otherwise | whole scalar ≥ 3, regular polygon sides |
| `height` | required | required | length, vertical span above `z` |
| `walls` | required | required | whole scalar, at least 1 |
| `floor` | optional, 0 | optional, 0 | whole scalar, solid bottom layers of this feature |
| `speed` | optional | optional | scalar, mm/s |
| `acceleration` | optional | optional | scalar, mm/s² |
| `fan` | optional | optional | scalar, percent |

Each box corner radius must be between zero and half the smaller of `width`
and `depth`. Zero produces square corners. When either end override is
present, each rounded end has a separate radius slider in the viewport.

Boxes and radial objects print concentric loops from the outside in. When `inner_diameter > 0`,
floor layers fill the annular ring down to `inner_diameter`, and wall layers print
`walls` outer loops inward and `walls` inner bore loops outward. A wall layer prints
`walls` loops. A floor layer prints loops until the shape is full. Set
`floor` to at least the layer count for a solid object. A feature starting at
`z = 0mm` spans `1 + round((height - first_layer_height) / layer_height)` layers;
a stacked feature (`z > 0mm`) spans the layers from `z` to `z + height`.

## Closed Bézier profiles

A `profile` repeats a closed XY cross-section through its `height`. The outline
defines the finished material boundary. The feature accepts the existing `x`,
`y`, `z`, `walls`, `floor`, speed, acceleration, and fan settings.
The [asymmetric mounting plate](../resources/designs/asymmetric-mounting-plate.hwsdesign)
defines a 2 mm waist between two lobes and a 6.4 mm bolt hole in each lobe.

Give the outer loop first. Add one `hole = loop(...)` argument for each
through-hole. Name each loop within the profile and each anchor within its loop.
A loop joins consecutive anchors with cubic Béziers and joins the last anchor
back to the first. Each loop needs at least two anchors.

```text
smooth(name, x, y, tangent_x, tangent_y, incoming_length, outgoing_length)
corner(name, x, y, incoming_x, incoming_y, outgoing_x, outgoing_y)
```

Coordinates are local to the profile and accept length expressions. For
`smooth`, the two unitless tangent components give the outgoing direction.
The incoming handle points the other way. Both lengths are nonnegative.
For `corner`, each handle is an independent vector in millimetres from the
anchor. Winding is inferred from the loop's role. Crossing, touching, and
nested holes produce a design error.

The generator subdivides cubics to a 0.009 mm chord tolerance before rounding
the boundary to the 0.001 mm polygon grid. It places the first bead centre
half a line width inside the material. Further wall passes advance by one line
width. Each separate loop starts with travel. Floor layers use a boundary pass
around the outline and each hole, then horizontal fill clipped to the printable
region. The preview and Klipper export use the same linear extrusion moves.
If the first pass splits at a waist or merges a hole with another boundary,
the editor reports the location and blocks Save.

### Edit a profile

Select **Edit profile** to open the XY view. Select an anchor to show its two
handles. Drag the anchor to move both handles with it. Drag a handle to change
the curve. **Next point** cycles through the anchors and handles. The arrow
keys move the selection by 0.1 mm. Shift increases the step to 1 mm.

The editor validates the curve and updates the bead preview as it moves. If
validation fails, the editor shows the error and keeps the last valid toolpaths
visible. Escape restores the draft and preview from before the drag.

**Save** or Command-S writes the design and its G-code. **Discard** reloads the
file from disk. An external edit blocks Save until the file is reloaded.

Save records local edits in an optional final `shift(...)` on each edited
anchor. For a smooth anchor the fields are XY displacement, tangent rotation
in degrees, and the two handle-length changes. For a corner they are XY
displacements for the anchor, incoming handle vector, and outgoing handle
vector. Authored expressions continue to evaluate when their parameters change.

## Feature settings

Motion and cooling belong to the feature, not to a role such as "perimeter".
Every object prints with its own `speed`, `acceleration`, and `fan`. An unset
value uses the design default. Evaluation rejects a feature, with its line,
when its speed or acceleration exceeds the printer's limit or when
`line_width × layer height × speed` exceeds the volumetric flow limit. The
G-code sets `M204` and `M106` whenever the next feature
needs another value. The results panel lists each feature's resolved values.
