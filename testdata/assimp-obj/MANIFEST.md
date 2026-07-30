# Assimp OBJ fixture manifest

Source repository: <https://github.com/assimp/assimp>

Release: `v6.0.5`

Commit: `392a658f9c271be965271f45e7521a1b80ea4392`

License: [`LICENSE`](LICENSE), SHA-256
`21195d410708b82757d3e34c3a40c427f6e59339da862e9480d4fcdc79b7a1bd`.
The BSD-3-Clause terms apply to `test/models`. The exception applies only to the
separate `test/models-nonbsd` directory.

The files retain their source bytes, including CRLF records and missing final
line endings.

| File | Source path | SHA-256 | Expected result |
| --- | --- | --- | --- |
| `box.obj` | `test/models/OBJ/box.obj` | `65ad6ed518b8c0592a6f6f80773b8f65c17b80d6d17235447422a4ecd4746638` | Decode six quads into 12 triangles. |
| `box_without_lineending.obj` | `test/models/OBJ/box_without_lineending.obj` | `df2dc98bacc8cb65f8ec63a087342b803a2144693974c7336047daf6f69d6de4` | Decode without a final line ending. |
| `multiple_spaces.obj` | `test/models/OBJ/multiple_spaces.obj` | `3fde51f80c491a1b54420e651353360cf2a7b9586de56da86a25884fccbf20bf` | Decode repeated horizontal whitespace. |
| `cube_mtllib_after_g.obj` | `test/models/OBJ/cube_mtllib_after_g.obj` | `7583367a46f96c6824ddaaa87062769cfe4e812da58c91f0c6860d8bfb0deb5f` | Decode CRLF input and preserve group, material-library, and material state. |
| `concave_polygon.obj` | `test/models/OBJ/concave_polygon.obj` | `cce772ab32d58b141b96d2ed3f1955c44b5ddb544cf5d97734ae7c85742015a9` | Reject the repeated bridge indexes as a non-simple polygon boundary. |
| `number_formats.obj` | `test/models/OBJ/number_formats.obj` | `a88822457583d4b9262fdf6edfc5f17fa0ae06d3a8d8a9a549fcc2a72297214e` | Reject malformed exponent forms. |
