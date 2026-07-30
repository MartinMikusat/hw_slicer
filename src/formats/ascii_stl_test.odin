package formats

import "core:testing"

import contracts "../contracts"

ASCII_STL_TEST_TRIANGLE: string :
	`solid triangle
facet normal 0 0 1
  outer loop
    vertex -0 0 0
    vertex 2 0 1
    vertex 0 3 0
  endloop
endfacet
endsolid triangle
`

@(test)
ascii_stl_decoder_emits_f64_soa_and_byte_provenance_test :: proc(
	t: ^testing.T,
) {
	mesh, error := ascii_stl_decode(
		transmute([]u8)ASCII_STL_TEST_TRIANGLE,
		.Millimetres,
	)
	defer decoded_mesh_destroy(&mesh)
	testing.expect_value(t, error, Decode_Error.None)
	testing.expect_value(t, mesh.source.format, contracts.Source_Format.ASCII_STL)
	testing.expect_value(
		t,
		mesh.source.byte_count,
		u64(len(ASCII_STL_TEST_TRIANGLE)),
	)
	testing.expect_value(t, len(mesh.vertex_x), 3)
	testing.expect_value(t, len(mesh.triangle_ids), 1)
	testing.expect_value(t, mesh.triangle_a[0], u32(0))
	testing.expect_value(t, mesh.triangle_b[0], u32(1))
	testing.expect_value(t, mesh.triangle_c[0], u32(2))
	testing.expect_value(t, mesh.source_record_offsets[0], u64(15))
	testing.expect_value(t, transmute(u64)mesh.vertex_x[0], u64(0))
	testing.expect_value(t, mesh.vertex_x[1], f64(2))
	testing.expect_value(t, mesh.vertex_y[2], f64(3))
	testing.expect(t, mesh.source_root_id != contracts.INVALID_STABLE_ID)
	testing.expect(t, mesh.triangle_ids[0] != contracts.INVALID_STABLE_ID)
}

@(test)
ascii_stl_decoder_accepts_a_utf8_bom_and_crlf_test :: proc(t: ^testing.T) {
	source := []u8{
		0xef, 0xbb, 0xbf,
		's', 'o', 'l', 'i', 'd', '\r', '\n',
		'f', 'a', 'c', 'e', 't', ' ',
		'n', 'o', 'r', 'm', 'a', 'l', ' ', '0', ' ', '0', ' ', '1', '\r', '\n',
		'o', 'u', 't', 'e', 'r', ' ', 'l', 'o', 'o', 'p', '\r', '\n',
		'v', 'e', 'r', 't', 'e', 'x', ' ', '0', ' ', '0', ' ', '0', '\r', '\n',
		'v', 'e', 'r', 't', 'e', 'x', ' ', '1', ' ', '0', ' ', '0', '\r', '\n',
		'v', 'e', 'r', 't', 'e', 'x', ' ', '0', ' ', '1', ' ', '0', '\r', '\n',
		'e', 'n', 'd', 'l', 'o', 'o', 'p', '\r', '\n',
		'e', 'n', 'd', 'f', 'a', 'c', 'e', 't', '\r', '\n',
		'e', 'n', 'd', 's', 'o', 'l', 'i', 'd', '\r', '\n',
	}
	mesh, error := ascii_stl_decode(source, .Millimetres)
	defer decoded_mesh_destroy(&mesh)
	testing.expect_value(t, error, Decode_Error.None)
	testing.expect_value(t, len(mesh.triangle_ids), 1)
}

@(test)
ascii_stl_decoder_rejects_malformed_and_limited_sources_test :: proc(
	t: ^testing.T,
) {
	empty := "solid empty\nendsolid empty\n"
	_, empty_error := ascii_stl_decode(
		transmute([]u8)empty,
		.Millimetres,
	)
	malformed := "solid x\nfacet normal 0 0 1\nendsolid x\n"
	_, syntax_error := ascii_stl_decode(
		transmute([]u8)malformed,
		.Millimetres,
	)
	source_limits := DEFAULT_ASCII_STL_LIMITS
	source_limits.max_source_bytes = 1
	_, source_error := ascii_stl_decode(
		transmute([]u8)ASCII_STL_TEST_TRIANGLE,
		.Millimetres,
		source_limits,
	)
	triangle_limits := DEFAULT_ASCII_STL_LIMITS
	triangle_limits.max_triangles = 0
	_, triangle_error := ascii_stl_decode(
		transmute([]u8)ASCII_STL_TEST_TRIANGLE,
		.Millimetres,
		triangle_limits,
	)
	token_limits := DEFAULT_ASCII_STL_LIMITS
	token_limits.max_token_bytes = 3
	_, token_error := ascii_stl_decode(
		transmute([]u8)ASCII_STL_TEST_TRIANGLE,
		.Millimetres,
		token_limits,
	)
	testing.expect_value(t, empty_error, Decode_Error.Empty)
	testing.expect_value(t, syntax_error, Decode_Error.Invalid_Syntax)
	testing.expect_value(t, source_error, Decode_Error.Source_Limit)
	testing.expect_value(t, triangle_error, Decode_Error.Triangle_Limit)
	testing.expect_value(t, token_error, Decode_Error.Invalid_Syntax)
}

@(test)
stl_decoder_selects_the_encoding_from_validated_structure_test :: proc(
	t: ^testing.T,
) {
	ascii_mesh, ascii_error := stl_decode(
		transmute([]u8)ASCII_STL_TEST_TRIANGLE,
		.Millimetres,
	)
	defer decoded_mesh_destroy(&ascii_mesh)

	binary_bytes := binary_stl_test_triangle()
	copy(binary_bytes[:5], "solid")
	binary_mesh, binary_error := stl_decode(
		binary_bytes[:],
		.Millimetres,
	)
	defer decoded_mesh_destroy(&binary_mesh)

	testing.expect_value(t, ascii_error, Decode_Error.None)
	testing.expect_value(
		t,
		ascii_mesh.source.format,
		contracts.Source_Format.ASCII_STL,
	)
	testing.expect_value(t, binary_error, Decode_Error.None)
	testing.expect_value(
		t,
		binary_mesh.source.format,
		contracts.Source_Format.Binary_STL,
	)
}
