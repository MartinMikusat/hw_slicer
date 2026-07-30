package formats

import "core:os"
import "core:testing"

import contracts "../contracts"

OBJ_Assimp_Valid_Case :: struct {
	path:            string,
	source_bytes:    int,
	position_count:  int,
	triangle_count:  int,
	state_count:     int,
	content_hash:    contracts.Content_Hash,
}

@(test)
obj_assimp_bsd_fixtures_decode_with_pinned_counts_and_hashes_test :: proc(
	t: ^testing.T,
) {
	cases := [?]OBJ_Assimp_Valid_Case{
		{
			path = "testdata/assimp-obj/box.obj",
			source_bytes = 410,
			position_count = 8,
			triangle_count = 12,
			state_count = 2,
			content_hash = {
				0x65, 0xad, 0x6e, 0xd5, 0x18, 0xb8, 0xc0, 0x59,
				0x2a, 0x6f, 0x6f, 0x80, 0x77, 0x3b, 0x8f, 0x65,
				0xc1, 0x7b, 0x80, 0xd6, 0xd1, 0x72, 0x35, 0x44,
				0x74, 0x22, 0xa4, 0xec, 0xd4, 0x74, 0x66, 0x38,
			},
		},
		{
			path = "testdata/assimp-obj/box_without_lineending.obj",
			source_bytes = 394,
			position_count = 8,
			triangle_count = 12,
			state_count = 2,
			content_hash = {
				0xdf, 0x2d, 0xc9, 0x8b, 0xac, 0xc8, 0xcb, 0x65,
				0xf8, 0xec, 0x63, 0xa0, 0x87, 0x34, 0x2b, 0x80,
				0x3a, 0x21, 0x44, 0x69, 0x39, 0x74, 0xc7, 0x33,
				0x60, 0x47, 0xda, 0xf6, 0xf6, 0x9d, 0x6d, 0xe4,
			},
		},
		{
			path = "testdata/assimp-obj/multiple_spaces.obj",
			source_bytes = 167,
			position_count = 4,
			triangle_count = 1,
			state_count = 0,
			content_hash = {
				0x3f, 0xde, 0x51, 0xf8, 0x0c, 0x49, 0x1a, 0x1b,
				0x54, 0x42, 0x0e, 0x65, 0x13, 0x53, 0x36, 0x0c,
				0xf2, 0xa7, 0xb9, 0x58, 0x6d, 0xe5, 0x6d, 0xa8,
				0x6a, 0x25, 0x88, 0x4f, 0xcc, 0xbf, 0x20, 0xbf,
			},
		},
		{
			path = "testdata/assimp-obj/cube_mtllib_after_g.obj",
			source_bytes = 588,
			position_count = 8,
			triangle_count = 12,
			state_count = 3,
			content_hash = {
				0x75, 0x83, 0x36, 0x7a, 0x46, 0xf9, 0x6c, 0x68,
				0x24, 0xdd, 0xaa, 0xa8, 0x70, 0x62, 0x76, 0x9c,
				0xfe, 0x4e, 0x81, 0x2d, 0xa5, 0x8c, 0x91, 0xf0,
				0xc6, 0x86, 0x0d, 0x8b, 0xfb, 0x0d, 0xeb, 0x5f,
			},
		},
	}
	for test_case in cases {
		bytes, read_ok := os.read_entire_file(test_case.path)
		testing.expect(t, read_ok)
		if !read_ok {continue}
		result, error := obj_decode(bytes, .Millimetres)
		testing.expect_value(t, error, Decode_Error.None)
		testing.expect_value(t, len(bytes), test_case.source_bytes)
		testing.expect_value(
			t,
			len(result.position_x),
			test_case.position_count,
		)
		testing.expect_value(
			t,
			len(result.mesh.triangle_ids),
			test_case.triangle_count,
		)
		testing.expect_value(
			t,
			len(result.state_records),
			test_case.state_count,
		)
		testing.expect_value(
			t,
			result.mesh.source.content_hash,
			test_case.content_hash,
		)
		obj_decoded_mesh_destroy(&result)
		delete(bytes)
	}
}

@(test)
obj_assimp_non_simple_and_malformed_numeric_fixtures_are_documented_rejections_test :: proc(
	t: ^testing.T,
) {
	paths := [?]string{
		"testdata/assimp-obj/concave_polygon.obj",
		"testdata/assimp-obj/number_formats.obj",
	}
	for path in paths {
		bytes, read_ok := os.read_entire_file(path)
		testing.expect(t, read_ok)
		if !read_ok {continue}
		result, error := obj_decode(bytes, .Millimetres)
		testing.expect_value(t, error, Decode_Error.Invalid_Syntax)
		obj_decoded_mesh_destroy(&result)
		delete(bytes)
	}
}
