# Design format (`.hwsdesign`)

A design file is a printer-parametric toolpath program. See
[ADR 0001](adr/0001-printer-parametric-toolpath-design.md).

The application shows the most recently modified design in
`resources/designs/` and follows it when another design there changes.
`--design=<path>` or `1` (Open) pins one file instead. The shown design
reloads when its file changes.

Each successful load writes `build/gcode/<name>-<nozzle>mm.gcode` through the
Marlin emitter. The printer, PLA temperatures (210 °C nozzle, 60 °C bed), the
220 × 220 × 250 mm bed, retraction, and accelerations are development
placeholders in `src/design_export.odin`. Coordinates are mm from the bed
centre, and the export fails when a move leaves the bed.

## Statements

One statement per line. A statement inside parentheses can continue on the
next lines. `#` starts a comment.

```text
let NAME = EXPRESSION
box(KEY = EXPRESSION, ...)
cylinder(KEY = EXPRESSION, ...)
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
| `travel_speed` | scalar, mm/s | no | 150 |

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

| Key | `box` | `cylinder` | Kind |
| --- | --- | --- | --- |
| `x`, `y` | optional, 0 | optional, 0 | length, centre |
| `width`, `depth` | required | | length |
| `diameter` | | required | length |
| `height` | required | required | length |
| `walls` | required | required | whole scalar, at least 1 |
| `floor` | optional, 0 | optional, 0 | whole scalar, solid bottom layers |

Each layer prints concentric loops from the outside in. A wall layer prints
`walls` loops. A floor layer prints loops until the shape is full. Set
`floor` to at least the layer count for a solid object. The object has
`1 + round((height - first_layer_height) / layer_height)` layers.
