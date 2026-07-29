# HW Slicer

An Apple Silicon macOS slicer that converts 3D models into deterministic FFF
toolpaths and exposes visual evidence for every pipeline stage.

## AI-assisted development disclosure

Models used:

- **gpt-5.6-sol**
- **gpt-image-2**

## Status

The native mesh viewer milestone is implemented. The slicing stages remain
planned work.

The [technical implementation plan](PLAN.md) defines the subsystem contracts,
CPU and Metal execution paths, visual-debug protocol, delivery gates,
benchmarks, and research curriculum.

The [research library](research/README.md) stores verified citations, engineering
notes, PDF snapshots, provenance, checksums, and explicit project use decisions.

The SvelteKit research site in `research-site/` presents the catalog through
search, filters, summaries, limitations, and use-state views.

## Viewer implementation

The viewer uses Apple system APIs and project-owned code:

- AppKit creates the window and sends input events.
- `CAMetalLayer` presents frames.
- Metal allocates the mesh buffers, depth texture, pipeline states, and command
  buffers directly.
- Core Text shapes the bundled Iosevka font.
- Project code parses STL files and constructs the camera, interface, and
  control registry.
- `hw_odin_ui_flash` selects keyboard targets. It does not render controls or
  own application actions.

The implementation does not use a rendering engine, scene library, MetalKit,
or GUI framework.

The viewer loads the three bundled reference models or an exact binary STL
selected through `01 OPEN`. It supports orbit, pan, zoom, frame-to-bounds,
wireframe rendering, light and dark themes, Flash navigation, and
Accessibility actions. The remaining numbered action slots stay visible and
disabled until their slicing stages exist.

Build and run the hot-reload development app:

```sh
./test.sh
./dev.sh debug
```

The watcher builds `build/HWSlicer.app`, launches it behind the active
application, and replaces only the Odin viewer module after a successful source
change. Use `./dev.sh asan` for AddressSanitizer development.

Capture or check the current live control registry:

```sh
./scripts/ui.sh snapshot
./scripts/ui.sh check
```

These commands require the running application. They keep detailed artifacts
under `.hw-slicer-runtime/` and return only the control count and artifact path.

## Development dependencies

The project requires Apple Silicon macOS, Xcode 26.6, and Odin
`dev-2026-01:393fec2f6`.

The build selects the pinned compiler from `HW_SLICER_ODIN`,
`/opt/homebrew/bin/odin`, or `PATH`, in that order. This keeps an older Odin
earlier in the interactive shell path from changing the build. Set
`HW_SLICER_ODIN=/path/to/odin` to use another installation of the pinned
version.

`dependencies.lock` pins `hw_odin_ui_flash` to repository
`https://github.com/MartinMikusat/hw_odin_ui_flash.git` at commit
`d06e98a40640b13eea5b979319022aad0a470d72`. The build rejects a different
sibling checkout.

## Bundled third-party assets

| Asset | Version | Source | SHA-256 | License |
| --- | --- | --- | --- | --- |
| Iosevka Regular TTF | 34.8.0 | [GitHub release](https://github.com/be5invis/Iosevka/releases/tag/v34.8.0) | `d1da5c2a3ce59781df12a4607f678e3f499d3483182329d14d8bad8cbf6e3c90` | [`resources/fonts/IOSEVKA-LICENSE.md`](resources/fonts/IOSEVKA-LICENSE.md) |
| Iconoir `xmark.svg` | 7.11.1, commit `3497016dcb93122b5a64a2df1221598a14ecf4f3` | [Official repository](https://github.com/iconoir-icons/iconoir/blob/v7.11.1/icons/regular/xmark.svg) | `61aa0a4913a440aaafcc45064a87e24fe8eb22ba4abc4c5ef020530928ed8daf` | [`resources/icons/iconoir/LICENSE`](resources/icons/iconoir/LICENSE) |
| Iconoir `minus.svg` | 7.11.1, commit `3497016dcb93122b5a64a2df1221598a14ecf4f3` | [Official repository](https://github.com/iconoir-icons/iconoir/blob/v7.11.1/icons/regular/minus.svg) | `babb05bca016bffdd38cbd1dcaeef6ccdf42fc8654124dee169a412eeed6d425` | [`resources/icons/iconoir/LICENSE`](resources/icons/iconoir/LICENSE) |
| Iconoir `maximize.svg` | 7.11.1, commit `3497016dcb93122b5a64a2df1221598a14ecf4f3` | [Official repository](https://github.com/iconoir-icons/iconoir/blob/v7.11.1/icons/regular/maximize.svg) | `3a3048cdc0e8e4aef5d68353b5434f0c0e074dc672b6c0abf25a5a64bc5cc8f4` | [`resources/icons/iconoir/LICENSE`](resources/icons/iconoir/LICENSE) |
| Iconoir `help-circle.svg` | 7.11.1, commit `3497016dcb93122b5a64a2df1221598a14ecf4f3` | [Official repository](https://github.com/iconoir-icons/iconoir/blob/v7.11.1/icons/regular/help-circle.svg) | `3206fbecd152d26eb60d292d4a2ab3b1bad4da074f29d3d2879d076d1f30258b` | [`resources/icons/iconoir/LICENSE`](resources/icons/iconoir/LICENSE) |
| 3DBenchy STL | Retrieved 2026-07-29 | [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:3DBenchy.stl) | `6ab57f1c3f8e86bc3cbd302c6fa6270acf06277c6335454e922419c25d42e97e` | [`resources/models/licenses/CC0-1.0.txt`](resources/models/licenses/CC0-1.0.txt) |
| All In One 3D Printer Test STL | Retrieved 2026-07-29 | [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Thingiverse_-_3D_Printer_test_stl.stl) | `c44411c2d6652cc48da16f253f34937c14af5d9787ce2a632f76e7f523dce9b8` | [`resources/models/licenses/CC-BY-4.0.txt`](resources/models/licenses/CC-BY-4.0.txt) |
| Stanford Bunny STL | Retrieved 2026-07-29 | [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Stanford_Bunny.stl) | `e1ff1293a49eb066de3c02cde6ccd260835e9da8544d43b1411f83f2d55c2eba` | [`resources/models/licenses/CC-BY-3.0.txt`](resources/models/licenses/CC-BY-3.0.txt) |

See [`resources/models/LICENSES.md`](resources/models/LICENSES.md) for model
attribution and license checksums.

## Project TODO

Execute the staged plan through the release gate. Preserve the versioned stage
contracts and debug-evidence protocol when an implementation is replaced.
