package formats

import "core:testing"

import contracts "../contracts"

OBJ_TEST_TRIANGLE: string :
	`# independent OBJ indexes
o triangle
v 0 0 -0
v 2 0 1
v 0 3 0
vt 0 0
vt 1 0
vt 0 1
vn 0 0 1
usemtl material
f 1/1/1 2/2/1 3/3/1
`

@(test)
obj_decoder_preserves_attributes_indices_and_face_provenance_test :: proc(
	t: ^testing.T,
) {
	result, error := obj_decode(
		transmute([]u8)OBJ_TEST_TRIANGLE,
		.Millimetres,
	)
	defer obj_decoded_mesh_destroy(&result)
	testing.expect_value(t, error, Decode_Error.None)
	testing.expect_value(t, result.mesh.source.format, contracts.Source_Format.OBJ)
	testing.expect_value(t, len(result.position_x), 3)
	testing.expect_value(t, len(result.texcoord_u), 3)
	testing.expect_value(t, len(result.normal_x), 1)
	testing.expect_value(t, len(result.mesh.triangle_ids), 1)
	testing.expect_value(t, len(result.mesh.vertex_x), 3)
	testing.expect_value(t, transmute(u64)result.position_z[0], u64(0))
	testing.expect_value(t, result.mesh.vertex_x[1], f64(2))
	expected_position_indices := [?]u32{0, 1, 2}
	expected_texcoord_indices := [?]u32{0, 1, 2}
	expected_normal_indices := [?]u32{0, 0, 0}
	for index in 0..<3 {
		testing.expect_value(
			t,
			result.source_position_indices[index],
			expected_position_indices[index],
		)
		testing.expect_value(
			t,
			result.source_texcoord_indices[index],
			expected_texcoord_indices[index],
		)
		testing.expect_value(
			t,
			result.source_normal_indices[index],
			expected_normal_indices[index],
		)
	}
	testing.expect(
		t,
		result.triangle_face_ids[0] != contracts.INVALID_STABLE_ID,
	)
	testing.expect_value(t, len(result.state_records), 2)
	testing.expect_value(t, result.state_records[0].kind, OBJ_State_Kind.Object)
	testing.expect_value(
		t,
		result.state_records[1].kind,
		OBJ_State_Kind.Material,
	)
	testing.expect_value(t, len(result.faces), 1)
	testing.expect_value(t, result.faces[0].object_state, u32(0))
	testing.expect_value(t, result.faces[0].material_state, u32(1))
	testing.expect_value(
		t,
		result.faces[0].group_state,
		OBJ_INVALID_INDEX,
	)
	testing.expect_value(
		t,
		result.mesh.source_record_offsets[0],
		u64(108),
	)
}

@(test)
obj_source_detection_separates_obj_from_ascii_stl_test :: proc(
	t: ^testing.T,
) {
	obj_text: string = "\xef\xbb\xbf# comment\n\nv 0 0 0\n"
	obj_source := transmute([]u8)obj_text
	ascii_stl := transmute([]u8)ASCII_STL_TEST_TRIANGLE
	testing.expect(t, obj_source_likely(obj_source))
	testing.expect(t, !obj_source_likely(ascii_stl))
	testing.expect(t, !obj_source_likely([]u8{}))
}

@(test)
obj_decoder_preserves_state_transitions_and_accepts_utf8_bom_test :: proc(
	t: ^testing.T,
) {
	source :=
		"\xef\xbb\xbfv 0 0 0\n" +
		"v 1 0 0\n" +
		"v 0 1 0\n" +
		"o first\n" +
		"g shell printable\n" +
		"s 3\n" +
		"mtllib colors.mtl\n" +
		"usemtl red\n" +
		"f 1 2 3\n" +
		"o second\n" +
		"g\n" +
		"s off\n" +
		"usemtl blue\n" +
		"f 1 3 2\n"
	result, error := obj_decode(
		transmute([]u8)source,
		.Millimetres,
	)
	defer obj_decoded_mesh_destroy(&result)
	testing.expect_value(t, error, Decode_Error.None)
	testing.expect_value(t, len(result.state_records), 9)
	testing.expect_value(t, len(result.faces), 2)
	first := result.faces[0]
	testing.expect_value(t, first.object_state, u32(0))
	testing.expect_value(t, first.group_state, u32(1))
	testing.expect_value(t, first.smoothing_group_state, u32(2))
	testing.expect_value(t, first.material_state, u32(4))
	testing.expect_value(
		t,
		result.state_records[3].kind,
		OBJ_State_Kind.Material_Library,
	)
	testing.expect_value(
		t,
		result.state_records[3].source_text,
		"mtllib colors.mtl\n",
	)
	second := result.faces[1]
	testing.expect_value(t, second.object_state, u32(5))
	testing.expect_value(t, second.group_state, u32(6))
	testing.expect_value(t, second.smoothing_group_state, u32(7))
	testing.expect_value(t, second.material_state, u32(8))
	testing.expect_value(t, second.first_triangle, u32(1))
	testing.expect_value(t, second.triangle_count, u32(1))
	testing.expect(
		t,
		result.state_records[8].id != contracts.INVALID_STABLE_ID,
	)
}

@(test)
obj_decoder_triangulates_a_concave_relative_index_face_test :: proc(
	t: ^testing.T,
) {
	source :=
		`v 0 0 0
v 2 0 0
v 2 2 0
v 1 1 0
v 0 2 0
g concave
f -5 -4 -3 \
  -2 -1
`
	result, error := obj_decode(transmute([]u8)source, .Millimetres)
	defer obj_decoded_mesh_destroy(&result)
	testing.expect_value(t, error, Decode_Error.None)
	testing.expect_value(t, len(result.mesh.triangle_ids), 3)
	testing.expect_value(t, len(result.mesh.vertex_x), 9)
	testing.expect_value(
		t,
		result.triangle_face_ids[0],
		result.triangle_face_ids[1],
	)
	testing.expect_value(
		t,
		result.triangle_face_ids[1],
		result.triangle_face_ids[2],
	)
	for position_index in result.source_position_indices {
		testing.expect(t, position_index < 5)
	}
}

@(test)
obj_decoder_resolves_homogeneous_positions_and_missing_texcoords_test :: proc(
	t: ^testing.T,
) {
	source :=
		`v 0 0 0 2
v 4 0 0 2
v 0 4 0 2
vn 0 0 1
f 1//1 2//1 3//1
`
	result, error := obj_decode(transmute([]u8)source, .Millimetres)
	defer obj_decoded_mesh_destroy(&result)
	testing.expect_value(t, error, Decode_Error.None)
	testing.expect_value(t, result.position_x[1], f64(2))
	testing.expect_value(t, result.position_y[2], f64(2))
	for index in 0..<3 {
		testing.expect_value(
			t,
			result.source_texcoord_indices[index],
			OBJ_INVALID_INDEX,
		)
		testing.expect_value(
			t,
			result.source_normal_indices[index],
			u32(0),
		)
	}
}

@(test)
obj_decoder_rejects_nonplanar_self_intersecting_and_invalid_faces_test :: proc(
	t: ^testing.T,
) {
	nonplanar :=
		`v 0 0 0
v 1 0 0
v 1 1 1
v 0 1 0
f 1 2 3 4
`
	_, nonplanar_error := obj_decode(
		transmute([]u8)nonplanar,
		.Millimetres,
	)
	self_intersecting :=
		`v 0 0 0
v 1 1 0
v 0 1 0
v 1 0 0
f 1 2 3 4
`
	_, intersection_error := obj_decode(
		transmute([]u8)self_intersecting,
		.Millimetres,
	)
	invalid_index :=
		`v 0 0 0
v 1 0 0
v 0 1 0
f 0 2 3
`
	_, index_error := obj_decode(
		transmute([]u8)invalid_index,
		.Millimetres,
	)
	freeform :=
		`v 0 0 0
v 1 0 0
v 0 1 0
curv 0 1 1 2 3
f 1 2 3
`
	_, freeform_error := obj_decode(
		transmute([]u8)freeform,
		.Millimetres,
	)
	testing.expect_value(
		t,
		nonplanar_error,
		Decode_Error.Invalid_Syntax,
	)
	testing.expect_value(
		t,
		intersection_error,
		Decode_Error.Invalid_Syntax,
	)
	testing.expect_value(t, index_error, Decode_Error.Invalid_Syntax)
	testing.expect_value(t, freeform_error, Decode_Error.Invalid_Syntax)
}

@(test)
obj_decoder_enforces_source_face_and_triangle_limits_test :: proc(
	t: ^testing.T,
) {
	source := transmute([]u8)OBJ_TEST_TRIANGLE
	source_limits := DEFAULT_OBJ_LIMITS
	source_limits.max_source_bytes = 1
	_, source_error := obj_decode(source, .Millimetres, source_limits)
	face_limits := DEFAULT_OBJ_LIMITS
	face_limits.max_face_vertices = 2
	_, face_error := obj_decode(source, .Millimetres, face_limits)
	triangle_limits := DEFAULT_OBJ_LIMITS
	triangle_limits.max_triangles = 0
	_, triangle_error := obj_decode(source, .Millimetres, triangle_limits)
	state_limits := DEFAULT_OBJ_LIMITS
	state_limits.max_state_records = 1
	_, state_error := obj_decode(source, .Millimetres, state_limits)
	testing.expect_value(t, source_error, Decode_Error.Source_Limit)
	testing.expect_value(t, face_error, Decode_Error.Triangle_Limit)
	testing.expect_value(t, triangle_error, Decode_Error.Triangle_Limit)
	testing.expect_value(t, state_error, Decode_Error.Triangle_Limit)
}
