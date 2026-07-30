package formats

import "core:testing"

import contracts "../contracts"

@(test)
decoded_mesh_hash_is_stable_test :: proc(t: ^testing.T) {
	bytes := binary_stl_test_triangle()
	mesh, error := binary_stl_decode(bytes[:], .Millimetres)
	defer decoded_mesh_destroy(&mesh)
	testing.expect_value(t, error, Decode_Error.None)
	actual, hash_ok := decoded_mesh_hash(mesh)
	testing.expect(t, hash_ok)
	expected := contracts.Content_Hash{
		0xc2, 0xb8, 0xc4, 0x0e, 0x8c, 0x96, 0x8e, 0x45,
		0x66, 0x97, 0x64, 0x27, 0x1e, 0x00, 0x93, 0x02,
		0x86, 0x01, 0xca, 0x94, 0x5b, 0x72, 0xc3, 0x41,
		0x7f, 0xee, 0x8f, 0xbf, 0x9c, 0xa1, 0xe6, 0x55,
	}
	testing.expect_value(t, actual, expected)
}

@(test)
decoded_mesh_hash_rejects_negative_zero_and_invalid_indices_test :: proc(
	t: ^testing.T,
) {
	bytes := binary_stl_test_triangle()
	mesh, error := binary_stl_decode(bytes[:], .Millimetres)
	defer decoded_mesh_destroy(&mesh)
	testing.expect_value(t, error, Decode_Error.None)
	mesh.vertex_z[0] = -0.0
	_, negative_zero_ok := decoded_mesh_hash(mesh)
	testing.expect(t, !negative_zero_ok)
	mesh.vertex_z[0] = 0
	mesh.triangle_c[0] = 3
	_, index_ok := decoded_mesh_hash(mesh)
	testing.expect(t, !index_ok)
}

@(test)
three_mf_scene_hash_is_stable_test :: proc(t: ^testing.T) {
	source := three_mf_test_package(model = THREE_MF_TEST_SCENE_MODEL)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	scene, model_error := three_mf_model_decode(package_result)
	defer three_mf_scene_destroy(&scene)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(t, model_error, Three_MF_Model_Error.None)
	actual, hash_ok := three_mf_scene_hash(scene)
	testing.expect(t, hash_ok)
	expected := contracts.Content_Hash{
		0xa3, 0x67, 0xd8, 0xc2, 0x83, 0x2a, 0x0d, 0x34,
		0xe8, 0x10, 0xed, 0x35, 0x43, 0x2c, 0xc6, 0xe6,
		0x39, 0x0e, 0x62, 0x5f, 0x31, 0x16, 0x54, 0xeb,
		0x72, 0x9f, 0xed, 0x70, 0x91, 0x26, 0x19, 0xe5,
	}
	testing.expect_value(t, actual, expected)
}

@(test)
three_mf_scene_hash_rejects_invalid_numeric_spans_and_extension_payload_test :: proc(
	t: ^testing.T,
) {
	source := three_mf_test_package(model = THREE_MF_TEST_SCENE_MODEL)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	scene, model_error := three_mf_model_decode(package_result)
	defer three_mf_scene_destroy(&scene)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(t, model_error, Three_MF_Model_Error.None)
	scene.components[0].transform[0] = -0.0
	_, negative_zero_ok := three_mf_scene_hash(scene)
	testing.expect(t, !negative_zero_ok)
	scene.components[0].transform[0] = 1
	scene.objects[0].vertex_count = u32(len(scene.vertices.x)+1)
	_, span_ok := three_mf_scene_hash(scene)
	testing.expect(t, !span_ok)
	scene.objects[0].vertex_count = u32(len(scene.vertices.x))
	scene.extension_resources[0].payload[0] ~= 1
	_, payload_ok := three_mf_scene_hash(scene)
	testing.expect(t, !payload_ok)
}
