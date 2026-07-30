package geometry

import "core:math"
import "core:testing"

import contracts "../contracts"
import formats "../formats"

@(test)
mesh_normalization_resolves_units_bounds_and_stable_ids_test :: proc(
	t: ^testing.T,
) {
	bytes := formats.binary_stl_test_triangle()
	decoded, decode_error := formats.binary_stl_decode(bytes[:], .Inches)
	defer formats.decoded_mesh_destroy(&decoded)
	testing.expect_value(t, decode_error, formats.Decode_Error.None)
	mesh, normalize_error := mesh_normalize_units(decoded)
	defer canonical_mesh_destroy(&mesh)
	testing.expect_value(t, normalize_error, Normalize_Error.None)
	testing.expect_value(
		t,
		mesh.coordinate_units,
		contracts.Source_Units.Millimetres,
	)
	testing.expect(
		t,
		math.abs(mesh.vertex_x[0]-(-50.8)) < 0.0000000001,
	)
	testing.expect(
		t,
		math.abs(f64(mesh.bounds.maximum.z)-254) < 0.0000000001,
	)
	testing.expect_value(t, mesh.vertex_ids[0], decoded.vertex_ids[0])
	testing.expect_value(t, mesh.triangle_ids[0], decoded.triangle_ids[0])
	testing.expect_value(t, transmute(u64)mesh.vertex_z[0], u64(0))
}

@(test)
mesh_normalization_rejects_unresolved_units_test :: proc(t: ^testing.T) {
	bytes := formats.binary_stl_test_triangle()
	decoded, decode_error := formats.binary_stl_decode(bytes[:], .Unspecified)
	defer formats.decoded_mesh_destroy(&decoded)
	testing.expect_value(t, decode_error, formats.Decode_Error.None)
	_, normalize_error := mesh_normalize_units(decoded)
	testing.expect_value(
		t,
		normalize_error,
		Normalize_Error.Unsupported_Units,
	)
}

@(test)
mesh_normalization_rejects_non_finite_stage_input_test :: proc(t: ^testing.T) {
	decoded := formats.Decoded_Mesh{
		source = {units = .Millimetres},
		vertex_x = []f64{math.inf_f64(1)},
		vertex_y = []f64{0},
		vertex_z = []f64{0},
		vertex_ids = []contracts.Stable_ID{1},
		triangle_a = []u32{0},
		triangle_b = []u32{0},
		triangle_c = []u32{0},
		triangle_ids = []contracts.Stable_ID{1},
		source_record_offsets = []u64{84},
	}
	_, error := mesh_normalize_units(decoded)
	testing.expect_value(t, error, Normalize_Error.Non_Finite)
}
