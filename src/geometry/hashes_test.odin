package geometry

import "core:testing"

import contracts "../contracts"
import formats "../formats"

@(test)
canonical_mesh_hash_is_stable_after_unit_resolution_test :: proc(
	t: ^testing.T,
) {
	bytes := formats.binary_stl_test_triangle()
	decoded, decode_error := formats.binary_stl_decode(bytes[:], .Inches)
	defer formats.decoded_mesh_destroy(&decoded)
	testing.expect_value(t, decode_error, formats.Decode_Error.None)
	mesh, normalize_error := mesh_normalize_units(decoded)
	defer canonical_mesh_destroy(&mesh)
	testing.expect_value(t, normalize_error, Normalize_Error.None)
	actual, hash_ok := canonical_mesh_hash(mesh)
	testing.expect(t, hash_ok)
	expected := contracts.Content_Hash{
		0x84, 0x77, 0x3d, 0x16, 0x1b, 0x40, 0x77, 0xaf,
		0xab, 0x4c, 0x64, 0xfb, 0x3a, 0x4a, 0xf4, 0x6d,
		0x4e, 0xa3, 0xea, 0x3a, 0x26, 0xaa, 0xbe, 0x5a,
		0x68, 0x54, 0x2a, 0xe7, 0xed, 0xf5, 0x50, 0x31,
	}
	testing.expect_value(t, actual, expected)
}

@(test)
canonical_mesh_hash_rejects_noncanonical_coordinates_test :: proc(
	t: ^testing.T,
) {
	bytes := formats.binary_stl_test_triangle()
	decoded, decode_error := formats.binary_stl_decode(bytes[:], .Millimetres)
	defer formats.decoded_mesh_destroy(&decoded)
	testing.expect_value(t, decode_error, formats.Decode_Error.None)
	mesh, normalize_error := mesh_normalize_units(decoded)
	defer canonical_mesh_destroy(&mesh)
	testing.expect_value(t, normalize_error, Normalize_Error.None)
	mesh.vertex_z[0] = -0.0
	_, negative_zero_ok := canonical_mesh_hash(mesh)
	testing.expect(t, !negative_zero_ok)
	mesh.vertex_z[0] = 0
	mesh.coordinate_units = .Inches
	_, units_ok := canonical_mesh_hash(mesh)
	testing.expect(t, !units_ok)
}
