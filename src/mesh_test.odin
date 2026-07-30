package main

import "core:testing"

write_u32_le_test :: proc(bytes: []u8, offset: int, value: u32) {
	bytes[offset+0] = u8(value)
	bytes[offset+1] = u8(value>>8)
	bytes[offset+2] = u8(value>>16)
	bytes[offset+3] = u8(value>>24)
}

write_f32_le_test :: proc(bytes: []u8, offset: int, value: f32) {
	write_u32_le_test(bytes, offset, transmute(u32)value)
}

single_triangle_stl_test_data :: proc() -> [134]u8 {
	bytes: [134]u8
	write_u32_le_test(bytes[:], 80, 1)
	write_f32_le_test(bytes[:], 84+8, 1)
	write_f32_le_test(bytes[:], 84+12, -2)
	write_f32_le_test(bytes[:], 84+16, -1)
	write_f32_le_test(bytes[:], 84+20, 0)
	write_f32_le_test(bytes[:], 84+24, 2)
	write_f32_le_test(bytes[:], 84+28, -1)
	write_f32_le_test(bytes[:], 84+32, 0)
	write_f32_le_test(bytes[:], 84+36, 0)
	write_f32_le_test(bytes[:], 84+40, 3)
	write_f32_le_test(bytes[:], 84+44, 0)
	return bytes
}

@(test)
mesh_parser_reads_binary_triangle_and_bounds_test :: proc(t: ^testing.T) {
	bytes := single_triangle_stl_test_data()
	mesh, error := mesh_parse_binary_stl(bytes[:])
	defer mesh_destroy(&mesh)
	testing.expect_value(t, error, Mesh_Error.None)
	testing.expect_value(t, mesh.triangle_count, u32(1))
	testing.expect_value(t, len(mesh.vertices), 3)
	testing.expect_value(t, mesh.bounds.minimum, Vec3{-2, -1, 0})
	testing.expect_value(t, mesh.bounds.maximum, Vec3{2, 3, 0})
	testing.expect_value(t, mesh.vertices[0].normal, Vec3{0, 0, 1})
}

@(test)
mesh_parser_rejects_length_that_disagrees_with_count_test :: proc(t: ^testing.T) {
	bytes := single_triangle_stl_test_data()
	_, error := mesh_parse_binary_stl(bytes[:len(bytes)-1])
	testing.expect_value(t, error, Mesh_Error.Unsupported_Format)
}

@(test)
mesh_parser_rejects_empty_triangle_stream_test :: proc(t: ^testing.T) {
	bytes: [84]u8
	_, error := mesh_parse_binary_stl(bytes[:])
	testing.expect_value(t, error, Mesh_Error.Invalid_Triangle_Count)
}

@(test)
mesh_file_loader_rejects_size_before_decode_test :: proc(t: ^testing.T) {
	_, error := mesh_load_stl(
		"testdata/evidence/invalid-short-path-plan.bin",
	)
	testing.expect_value(t, error, Mesh_Error.Source_Limit)
	testing.expect_value(
		t,
		mesh_error_text(error),
		"the file size is outside the source limit",
	)
}

@(test)
camera_matrices_keep_metal_depth_range_test :: proc(t: ^testing.T) {
	projection := mat4_perspective(1.0, 1.5, 0.1, 1000)
	testing.expect(t, projection[0] > 0)
	testing.expect(t, projection[5] > projection[0])
	testing.expect(t, projection[10] < 0)
	testing.expect_value(t, projection[11], f32(-1))
}

@(test)
bundled_reference_models_match_declared_triangle_counts_test :: proc(
	t: ^testing.T,
) {
	references := [3]struct {
		path: string,
		triangles: u32,
	}{
		{"resources/models/benchy.stl", 225706},
		{"resources/models/all-in-one-test.stl", 51092},
		{"resources/models/stanford-bunny.stl", 112402},
	}
	for reference in references {
		mesh, error := mesh_load_stl(reference.path)
		testing.expect_value(t, error, Mesh_Error.None)
		testing.expect_value(t, mesh.triangle_count, reference.triangles)
		size := mesh_size(mesh.bounds)
		testing.expect(t, size.x > 0 && size.y > 0 && size.z > 0)
		mesh_destroy(&mesh)
	}
}
