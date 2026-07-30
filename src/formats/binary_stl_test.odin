package formats

import "core:math"
import "core:testing"

import contracts "../contracts"

binary_stl_test_write_u32 :: proc(bytes: []u8, offset: int, value: u32) {
	bytes[offset] = u8(value)
	bytes[offset+1] = u8(value>>8)
	bytes[offset+2] = u8(value>>16)
	bytes[offset+3] = u8(value>>24)
}

binary_stl_test_write_f32 :: proc(bytes: []u8, offset: int, value: f32) {
	binary_stl_test_write_u32(bytes, offset, transmute(u32)value)
}

binary_stl_test_triangle :: proc() -> [134]u8 {
	bytes: [134]u8
	binary_stl_test_write_u32(bytes[:], 80, 1)
	binary_stl_test_write_f32(bytes[:], 84+8, 1)
	positions := [3][3]f32{
		{-2, -1, -0.0},
		{2, -1, 10},
		{0, 3, 5},
	}
	for position, index in positions {
		offset := 84+12+index*12
		binary_stl_test_write_f32(bytes[:], offset, position[0])
		binary_stl_test_write_f32(bytes[:], offset+4, position[1])
		binary_stl_test_write_f32(bytes[:], offset+8, position[2])
	}
	return bytes
}

@(test)
binary_stl_decoder_emits_f64_soa_and_stable_provenance_test :: proc(
	t: ^testing.T,
) {
	bytes := binary_stl_test_triangle()
	mesh, error := binary_stl_decode(bytes[:], .Millimetres)
	defer decoded_mesh_destroy(&mesh)
	testing.expect_value(t, error, Decode_Error.None)
	testing.expect_value(t, mesh.source.format, contracts.Source_Format.Binary_STL)
	testing.expect_value(t, mesh.source.byte_count, u64(134))
	testing.expect_value(t, len(mesh.vertex_x), 3)
	testing.expect_value(t, len(mesh.triangle_ids), 1)
	testing.expect_value(t, mesh.triangle_a[0], u32(0))
	testing.expect_value(t, mesh.triangle_b[0], u32(1))
	testing.expect_value(t, mesh.triangle_c[0], u32(2))
	testing.expect_value(t, mesh.source_record_offsets[0], u64(84))
	testing.expect(t, mesh.source_root_id != contracts.INVALID_STABLE_ID)
	testing.expect_value(t, u64(mesh.source_root_id), u64(0x2842b55e7cc75e38))
	testing.expect(t, mesh.triangle_ids[0] != contracts.INVALID_STABLE_ID)
	testing.expect(t, mesh.vertex_ids[0] != mesh.vertex_ids[1])
	testing.expect_value(t, transmute(u64)mesh.vertex_z[0], u64(0))
	expected_hash := contracts.Content_Hash{
		0x8e, 0x6a, 0x0c, 0x1c, 0x16, 0xb1, 0x4e, 0x24,
		0xda, 0x77, 0x09, 0xb9, 0x6f, 0xed, 0xf3, 0xb9,
		0xe4, 0x0d, 0x73, 0x76, 0x10, 0xb9, 0x9c, 0x46,
		0x5d, 0xeb, 0x9b, 0xed, 0x4a, 0x65, 0x38, 0x15,
	}
	testing.expect_value(t, mesh.source.content_hash, expected_hash)
}

@(test)
binary_stl_decoder_rejects_malformed_and_limited_sources_test :: proc(
	t: ^testing.T,
) {
	bytes := binary_stl_test_triangle()
	empty: [84]u8
	_, short_error := binary_stl_decode(bytes[:83], .Millimetres)
	_, empty_error := binary_stl_decode(empty[:], .Millimetres)
	_, length_error := binary_stl_decode(bytes[:133], .Millimetres)
	_, source_limit_error := binary_stl_decode(
		bytes[:],
		.Millimetres,
		{max_source_bytes = 100, max_triangles = 1},
	)
	_, triangle_limit_error := binary_stl_decode(
		bytes[:],
		.Millimetres,
		{max_source_bytes = 134, max_triangles = 0},
	)
	testing.expect_value(t, short_error, Decode_Error.Truncated)
	testing.expect_value(t, empty_error, Decode_Error.Empty)
	testing.expect_value(t, length_error, Decode_Error.Length_Mismatch)
	testing.expect_value(t, source_limit_error, Decode_Error.Source_Limit)
	testing.expect_value(t, triangle_limit_error, Decode_Error.Triangle_Limit)
}

@(test)
binary_stl_decoder_rejects_non_finite_normal_or_position_test :: proc(
	t: ^testing.T,
) {
	normal_bytes := binary_stl_test_triangle()
	binary_stl_test_write_f32(normal_bytes[:], 84, math.nan_f32())
	_, normal_error := binary_stl_decode(normal_bytes[:], .Millimetres)
	position_bytes := binary_stl_test_triangle()
	binary_stl_test_write_f32(position_bytes[:], 84+12, math.inf_f32(1))
	_, position_error := binary_stl_decode(position_bytes[:], .Millimetres)
	testing.expect_value(t, normal_error, Decode_Error.Non_Finite)
	testing.expect_value(t, position_error, Decode_Error.Non_Finite)
}
