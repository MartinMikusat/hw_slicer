package formats

import "core:testing"

import contracts "../contracts"

@(test)
three_mf_flatten_composes_instances_and_preserves_provenance_test :: proc(
	t: ^testing.T,
) {
	source := three_mf_test_package(model = THREE_MF_TEST_SCENE_MODEL)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	scene, model_error := three_mf_model_decode(package_result)
	defer three_mf_scene_destroy(&scene)
	flattened, flatten_error := three_mf_scene_flatten(scene)
	defer three_mf_flattened_mesh_destroy(&flattened)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(t, model_error, Three_MF_Model_Error.None)
	testing.expect_value(t, flatten_error, Three_MF_Flatten_Error.None)
	testing.expect_value(t, len(flattened.mesh.vertex_x), 4)
	testing.expect_value(t, len(flattened.mesh.triangle_a), 4)
	testing.expect_value(t, flattened.mesh.vertex_x[0], f64(9))
	testing.expect_value(t, flattened.mesh.vertex_y[0], f64(9))
	testing.expect_value(t, flattened.mesh.vertex_z[0], f64(11))
	testing.expect_value(t, flattened.mesh.vertex_x[1], f64(29))
	testing.expect_value(
		t,
		flattened.source_vertex_ids[0],
		scene.vertices.stable_ids[0],
	)
	testing.expect_value(
		t,
		flattened.source_triangle_ids[0],
		scene.triangles.stable_ids[0],
	)
	testing.expect_value(t, flattened.source_object_indices[0], u32(0))
	testing.expect_value(
		t,
		flattened.object_types[0],
		Three_MF_Object_Type.Model,
	)
	testing.expect_value(t, flattened.property_resource[0], u32(1))
	testing.expect_value(t, flattened.property_a[0], u32(5))
	testing.expect_value(
		t,
		flattened.mesh.source_record_offsets[0],
		THREE_MF_SOURCE_OFFSET_UNAVAILABLE,
	)
	testing.expect(
		t,
		flattened.mesh.triangle_ids[0] !=
			flattened.source_triangle_ids[0],
	)
	_, decoded_hash_ok := decoded_mesh_hash(flattened.mesh)
	testing.expect(t, decoded_hash_ok)
}

@(test)
three_mf_flatten_reverses_winding_and_vertex_properties_test :: proc(
	t: ^testing.T,
) {
	model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:x="urn:test"><resources><x:properties id="1"/><object id="2" pid="1" pindex="4">` +
		THREE_MF_TEST_PROPERTY_TETRAHEDRON +
		`</object></resources><build><item objectid="2" transform="-1 0 0 0 1 0 0 0 1 0 0 0"/></build></model>`
	source := three_mf_test_package(model = model)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	scene, model_error := three_mf_model_decode(package_result)
	defer three_mf_scene_destroy(&scene)
	flattened, flatten_error := three_mf_scene_flatten(scene)
	defer three_mf_flattened_mesh_destroy(&flattened)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(t, model_error, Three_MF_Model_Error.None)
	testing.expect_value(t, flatten_error, Three_MF_Flatten_Error.None)
	testing.expect_value(t, flattened.mesh.triangle_a[0], u32(1))
	testing.expect_value(t, flattened.mesh.triangle_b[0], u32(2))
	testing.expect_value(t, flattened.mesh.triangle_c[0], u32(0))
	testing.expect_value(t, flattened.property_a[0], u32(7))
	testing.expect_value(t, flattened.property_b[0], u32(6))
	testing.expect_value(t, flattened.property_c[0], u32(5))
	testing.expect_value(t, flattened.mesh.vertex_x[1], f64(-10))
}

@(test)
three_mf_flatten_enforces_instance_and_output_limits_test :: proc(
	t: ^testing.T,
) {
	source := three_mf_test_package(model = THREE_MF_TEST_SCENE_MODEL)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	scene, model_error := three_mf_model_decode(package_result)
	defer three_mf_scene_destroy(&scene)
	_, instance_error := three_mf_scene_flatten(
		scene,
		{
			max_instances = 1,
			max_vertices = 4,
			max_triangles = 4,
			max_component_depth = 1,
		},
	)
	_, vertex_error := three_mf_scene_flatten(
		scene,
		{
			max_instances = 2,
			max_vertices = 3,
			max_triangles = 4,
			max_component_depth = 1,
		},
	)
	_, triangle_error := three_mf_scene_flatten(
		scene,
		{
			max_instances = 2,
			max_vertices = 4,
			max_triangles = 3,
			max_component_depth = 1,
		},
	)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(t, model_error, Three_MF_Model_Error.None)
	testing.expect_value(
		t,
		instance_error,
		Three_MF_Flatten_Error.Instance_Limit,
	)
	testing.expect_value(
		t,
		vertex_error,
		Three_MF_Flatten_Error.Vertex_Limit,
	)
	testing.expect_value(
		t,
		triangle_error,
		Three_MF_Flatten_Error.Triangle_Limit,
	)
}

@(test)
three_mf_model_enforces_component_depth_before_flattening_test :: proc(
	t: ^testing.T,
) {
	source := three_mf_test_package(model = THREE_MF_TEST_SCENE_MODEL)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	limits := DEFAULT_THREE_MF_MODEL_LIMITS
	limits.max_component_depth = 0
	scene, model_error := three_mf_model_decode(package_result, limits)
	defer three_mf_scene_destroy(&scene)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(
		t,
		model_error,
		Three_MF_Model_Error.Component_Depth_Limit,
	)
}

@(test)
three_mf_flatten_assigns_distinct_ids_to_repeated_instances_test :: proc(
	t: ^testing.T,
) {
	model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</object></resources><build><item objectid="1"/><item objectid="1" transform="1 0 0 0 1 0 0 0 1 20 0 0"/></build></model>`
	source := three_mf_test_package(model = model)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	scene, model_error := three_mf_model_decode(package_result)
	defer three_mf_scene_destroy(&scene)
	flattened, flatten_error := three_mf_scene_flatten(scene)
	defer three_mf_flattened_mesh_destroy(&flattened)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(t, model_error, Three_MF_Model_Error.None)
	testing.expect_value(t, flatten_error, Three_MF_Flatten_Error.None)
	testing.expect_value(t, len(flattened.mesh.vertex_x), 8)
	testing.expect_value(t, len(flattened.mesh.triangle_a), 8)
	testing.expect(
		t,
		flattened.mesh.triangle_ids[0] !=
			flattened.mesh.triangle_ids[4],
	)
	testing.expect_value(t, flattened.mesh.vertex_x[4], f64(20))
	testing.expect_value(
		t,
		flattened.source_triangle_ids[0],
		flattened.source_triangle_ids[4],
	)
	testing.expect(
		t,
		flattened.triangle_instance_ids[0] !=
			flattened.triangle_instance_ids[4],
	)
	testing.expect(
		t,
		flattened.mesh.source_root_id != contracts.INVALID_STABLE_ID,
	)
}
