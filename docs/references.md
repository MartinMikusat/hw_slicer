# References

External projects that inform the design. Entries are for study only. Check each license before reusing code.

## Explicit toolpath design

Projects where the user designs the print path directly instead of slicing a model.

| Project | Notes |
| --- | --- |
| [FullControl](https://github.com/FullControlXYZ/fullcontrol) ([models](https://fullcontrol.xyz/#/models), [site](https://fullcontrolgcode.com/)) | Python library. A design is a stream of points and state changes (speed, temperature, fan, extrusion). Includes parametric demo models and a preview. GPL-3.0. |
| [fullcontrol-js](https://github.com/kylegrover/fullcontrol-js) | Third-party TypeScript port of FullControl for the browser, tested against the Python reference. GPL-3.0. |
| [TOOLPATHS](https://github.com/KonradJuenger/TOOLPATHS/) | Grasshopper plugin. A Toolpath carries geometry and settings, with inheritance and local overrides. Simulates deposition volume. Licensed plugin. |
| [gcoordinator](https://github.com/tomohiron907/gcoordinator) | Python library. Paths are coordinate sequences, with preview and G-code export. |
| [p5.fab](https://doi.org/10.1145/3532106.3533496) | JavaScript library. Generates toolpaths and streams them to a Marlin printer from the browser. |

## G-code generation libraries

| Project | Notes |
| --- | --- |
| [mecode](https://github.com/jminardi/mecode) | Python. Readable layer over G-code: lines, arcs, meanders. Not a slicer. |
| [Gscrib](https://gscrib.readthedocs.io/en/latest/) | Python. Structured G-code with transforms, hooks, and output to files or serial and network devices. |
| [pygdk](https://github.com/cilynx/pygdk) | Python. Generates CNC G-code from object features. |
