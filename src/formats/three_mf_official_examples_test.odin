package formats

import "core:os"
import "core:testing"

import contracts "../contracts"

Three_MF_Official_Example_Case :: struct {
	path:           string,
	source_bytes:   u64,
	vertex_count:   int,
	triangle_count: int,
	scene_hash:     contracts.Content_Hash,
}

@(test)
three_mf_official_core_examples_decode_and_flatten_test :: proc(
	t: ^testing.T,
) {
	cases := [?]Three_MF_Official_Example_Case{
		{
			path = "testdata/3mf-consortium/core/box.3mf",
			source_bytes = 1176,
			vertex_count = 8,
			triangle_count = 12,
			scene_hash = {
				0x20, 0x9d, 0xd2, 0xb7, 0xea, 0xd9, 0x68, 0x49,
				0xa3, 0xc6, 0x48, 0x00, 0xb9, 0x43, 0xa4, 0x3f,
				0xbf, 0xe1, 0xa6, 0x77, 0x2b, 0xdd, 0x51, 0xef,
				0x38, 0xd3, 0x03, 0x40, 0x39, 0x49, 0x1a, 0xdd,
			},
		},
		{
			path = "testdata/3mf-consortium/core/cylinder.3mf",
			source_bytes = 1833,
			vertex_count = 46,
			triangle_count = 88,
			scene_hash = {
				0xa3, 0x46, 0xe3, 0x64, 0x4a, 0xc0, 0xe8, 0x17,
				0xc8, 0x56, 0x4b, 0xe3, 0xc8, 0xe7, 0xe9, 0x66,
				0x6c, 0x71, 0x07, 0x02, 0x49, 0x8a, 0x01, 0xe9,
				0xfc, 0xa3, 0x27, 0xb2, 0x92, 0xae, 0xb4, 0x12,
			},
		},
	}
	for test_case in cases {
		bytes, read_ok := os.read_entire_file(test_case.path)
		testing.expect(t, read_ok)
		if !read_ok {continue}

		package_result, package_error := three_mf_package_open(bytes)
		scene, model_error := three_mf_model_decode(package_result)
		scene_hash, hash_ok := three_mf_scene_hash(scene)
		flattened, flatten_error := three_mf_scene_flatten(scene)

		testing.expect_value(t, package_error, Three_MF_Package_Error.None)
		testing.expect_value(t, model_error, Three_MF_Model_Error.None)
		testing.expect(t, hash_ok)
		testing.expect_value(t, flatten_error, Three_MF_Flatten_Error.None)
		testing.expect_value(
			t,
			package_result.source.byte_count,
			test_case.source_bytes,
		)
		testing.expect_value(t, len(scene.vertices.x), test_case.vertex_count)
		testing.expect_value(
			t,
			len(scene.triangles.a),
			test_case.triangle_count,
		)
		testing.expect_value(
			t,
			len(flattened.mesh.triangle_a),
			test_case.triangle_count,
		)
		testing.expect_value(t, scene_hash, test_case.scene_hash)

		three_mf_flattened_mesh_destroy(&flattened)
		three_mf_scene_destroy(&scene)
		three_mf_package_destroy(&package_result)
		delete(bytes)
	}
}

@(test)
three_mf_official_archived_must_pass_cases_decode_and_flatten_test :: proc(
	t: ^testing.T,
) {
	paths := [?]string{
		"testdata/3mf-consortium/archive-must-pass/MUSTPASS_Chapter2.1_PartsRelationships.3mf",
		"testdata/3mf-consortium/archive-must-pass/MUSTPASS_Chapter2.3a_IgnorableMarkup.3mf",
		"testdata/3mf-consortium/archive-must-pass/MUSTPASS_Chapter3.2c_MultipleItemsTransform.3mf",
		"testdata/3mf-consortium/archive-must-pass/MUSTPASS_Chapter3.4.1c_MustIgnoreUndefinedMetadataName.3mf",
		"testdata/3mf-consortium/archive-must-pass/MUSTPASS_Chapter3.4.3a_MustNotOutputNonReferencedObjects.3mf",
		"testdata/3mf-consortium/archive-must-pass/MUSTPASS_Chapter4.2_Components.3mf",
		"testdata/3mf-consortium/archive-must-pass/MUSTPASS_Chapter5.1c_MaterialResources_sRGB_RGB_Colors.3mf",
	}
	expected_triangle_counts := [?]int{12, 12, 60, 12, 12, 60, 12}
	for path, case_index in paths {
		bytes, read_ok := os.read_entire_file(path)
		testing.expect(t, read_ok)
		if !read_ok {continue}

		package_result, package_error := three_mf_package_open(bytes)
		scene, model_error := three_mf_model_decode(package_result)
		flattened, flatten_error := three_mf_scene_flatten(scene)

		testing.expect_value(t, package_error, Three_MF_Package_Error.None)
		testing.expect_value(t, model_error, Three_MF_Model_Error.None)
		testing.expect_value(t, flatten_error, Three_MF_Flatten_Error.None)
		testing.expect_value(
			t,
			len(flattened.mesh.triangle_a),
			expected_triangle_counts[case_index],
		)

		three_mf_flattened_mesh_destroy(&flattened)
		three_mf_scene_destroy(&scene)
		three_mf_package_destroy(&package_result)
		delete(bytes)
	}
}

@(test)
three_mf_official_archived_must_fail_cases_are_rejected_test :: proc(
	t: ^testing.T,
) {
	external_bytes, external_read_ok := os.read_entire_file(
		"testdata/3mf-consortium/archive-must-fail/MUSTFAIL_Chapter2.1.1b_PartsRelationships_LinkToExternal.3mf",
	)
	defer delete(external_bytes)
	testing.expect(t, external_read_ok)
	external_package, external_error :=
		three_mf_package_open(external_bytes)
	defer three_mf_package_destroy(&external_package)
	testing.expect_value(
		t,
		external_error,
		Three_MF_Package_Error.External_Relationship,
	)

	roots_bytes, roots_read_ok := os.read_entire_file(
		"testdata/3mf-consortium/archive-must-fail/MUSTFAIL_Chapter3.4a_MoreThanOneModel.3mf",
	)
	defer delete(roots_bytes)
	testing.expect(t, roots_read_ok)
	roots_package, roots_error := three_mf_package_open(roots_bytes)
	defer three_mf_package_destroy(&roots_package)
	testing.expect_value(
		t,
		roots_error,
		Three_MF_Package_Error.XML_Invalid,
	)

	metadata_bytes, metadata_read_ok := os.read_entire_file(
		"testdata/3mf-consortium/archive-must-fail/MUSTFAIL_Chapter3.4.1b_DuplicatedMetadataName.3mf",
	)
	defer delete(metadata_bytes)
	testing.expect(t, metadata_read_ok)
	metadata_package, metadata_package_error :=
		three_mf_package_open(metadata_bytes)
	defer three_mf_package_destroy(&metadata_package)
	metadata_scene, metadata_error :=
		three_mf_model_decode(metadata_package)
	defer three_mf_scene_destroy(&metadata_scene)
	testing.expect_value(
		t,
		metadata_package_error,
		Three_MF_Package_Error.None,
	)
	testing.expect_value(
		t,
		metadata_error,
		Three_MF_Model_Error.Metadata_Duplicate,
	)
}
