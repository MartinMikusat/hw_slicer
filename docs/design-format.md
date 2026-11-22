# Design format (`.hwsdesign`)

A design file is a printer-parametric toolpath program. See
[ADR 0001](adr/0001-printer-parametric-toolpath-design.md).

The application shows the most recently modified design in
`resources/designs/` and follows it when another design there changes.
`--design=<path>` or `1` (Open) pins one file instead. The shown design
reloads when its file changes.

Each successful load writes `build/gcode/<name>-<nozzle>mm.gcode` through the
Klipper emitter. The machine values in `src/design_export.odin` come from the
RatOS V-Core 3 configuration captured in `hw_ratos`: a 500 × 500 × 500 mm bed,
300 mm/s and 3000 mm/s² limits, 120 mm/s and 800 mm/s² extruder limits, and
0.5 mm retraction. PLA temperatures (210 °C nozzle, 60 °C bed), the 15 mm³/s
flow limit, and print accelerations are assumptions. Coordinates are mm from
the bed centre, and the export fails when a move leaves the bed.

The file calls the printer's `START_PRINT` macro with the RatOS parameters
(`EXTRUDER_TEMP`, `EXTRUDER_OTHER_LAYER_TEMP`, `BED_TEMP`, and the extrusion
area `X0 Y0 X1 Y1`), which homes, heats, meshes, and primes. It ends with
`END_PRINT`.

## Statements

One statement per line. A statement inside parentheses can continue on the
next lines. `#` starts a comment.

```text
let NAME = EXPRESSION
box(KEY = EXPRESSION, ...)
cylinder(KEY = EXPRESSION, ...)
tube(KEY = EXPRESSION, ...)
cone(KEY = EXPRESSION, ...)
polygon(KEY = EXPRESSION, ...)
```

A `let` cannot redefine a name. A name must be defined before it is used.

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
| `print_speed` | scalar, mm/s | no | 40 |
| `print_acceleration` | scalar, mm/s² | no | 1000 |
| `fan` | scalar, percent | no | 100 |
| `travel_speed` | scalar, mm/s | no | 150 |
| `travel_acceleration` | scalar, mm/s² | no | 3000 |

`print_speed`, `print_acceleration`, and `fan` are defaults. Each feature can
set its own values; see [Feature settings](#feature-settings).

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
| `radius` | optional, 0 | | length, corner fillet radius |
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

Each layer prints concentric loops from the outside in. When `inner_diameter > 0`,
floor layers fill the annular ring down to `inner_diameter`, and wall layers print
`walls` outer loops inward and `walls` inner bore loops outward. A wall layer prints
`walls` loops. A floor layer prints loops until the shape is full. Set
`floor` to at least the layer count for a solid object. A feature starting at
`z = 0mm` spans `1 + round((height - first_layer_height) / layer_height)` layers;
a stacked feature (`z > 0mm`) spans the layers from `z` to `z + height`.

## Feature settings

Motion and cooling belong to the feature, not to a role such as "perimeter".
Every object prints with its own `speed`, `acceleration`, and `fan`. An unset
value uses the design default. Evaluation rejects a feature, with its line,
when its speed or acceleration exceeds the printer's limit or when
`line_width × layer height × speed` exceeds the volumetric flow limit. The
G-code sets `SET_VELOCITY_LIMIT ACCEL` and `M106` whenever the next feature
needs another value. The results panel lists each feature's resolved values.
