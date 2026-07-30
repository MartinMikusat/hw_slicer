package formats

import "core:testing"

import contracts "../contracts"

THREE_MF_TEST_TETRAHEDRON ::
	`<mesh><vertices><vertex x="0" y="0" z="-0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/></vertices><triangles><triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/><triangle v1="1" v2="2" v3="3"/><triangle v1="2" v2="0" v3="3"/></triangles></mesh>`

THREE_MF_TEST_PROPERTY_TETRAHEDRON ::
	`<mesh><vertices><vertex x="0" y="0" z="-0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/></vertices><triangles><triangle v1="0" v2="2" v3="1" p1="5" p2="6" p3="7"/><triangle v1="0" v2="1" v3="3"/><triangle v1="1" v2="2" v3="3"/><triangle v1="2" v2="0" v3="3"/></triangles></mesh>`

THREE_MF_TEST_SCENE_MODEL ::
	`<model unit="centimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:x="urn:test"><resources><x:properties id="1"/><object id="2" type="model" pid="1" pindex="4">` +
	THREE_MF_TEST_PROPERTY_TETRAHEDRON +
	`</object><object id="3"><components><component objectid="2" transform="1 0 0 0 1 0 0 0 1 2 3 4"/></components></object></resources><build><item objectid="3" transform="2 0 0 0 1 0 0 0 1 5 6 7"/></build></model>`

@(test)
three_mf_model_decodes_meshes_components_properties_and_build_test :: proc(
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
	testing.expect_value(
		t,
		scene.source.units,
		contracts.Source_Units.Centimetres,
	)
	testing.expect_value(t, len(scene.objects), 2)
	testing.expect_value(t, len(scene.vertices.x), 4)
	testing.expect_value(t, len(scene.triangles.a), 4)
	testing.expect_value(t, len(scene.components), 1)
	testing.expect_value(t, len(scene.build_items), 1)
	testing.expect_value(t, scene.model_part_path, "3D/3dmodel.model")
	testing.expect_value(t, len(scene.extension_resources), 1)
	extension := scene.extension_resources[0]
	testing.expect_value(t, extension.resource_id, u32(1))
	testing.expect_value(t, extension.property_group_index, u32(0))
	testing.expect_value(t, extension.namespace_uri, "urn:test")
	testing.expect_value(t, extension.qualified_name, "x:properties")
	testing.expect_value(
		t,
		extension.payload_schema_version,
		THREE_MF_EXTENSION_PAYLOAD_SCHEMA_VERSION,
	)
	testing.expect(t, len(extension.payload) > 12)
	testing.expect(
		t,
		extension.payload_hash != contracts.Content_Hash{},
	)
	testing.expect_value(t, scene.objects[0].resource_id, u32(2))
	testing.expect_value(t, scene.objects[0].kind, Three_MF_Object_Kind.Mesh)
	testing.expect_value(
		t,
		scene.objects[1].kind,
		Three_MF_Object_Kind.Components,
	)
	testing.expect_value(t, scene.triangles.a[0], u32(0))
	testing.expect_value(t, scene.triangles.b[0], u32(2))
	testing.expect_value(t, scene.triangles.c[0], u32(1))
	testing.expect_value(t, scene.triangles.property_resource[0], u32(1))
	testing.expect_value(t, scene.triangles.property_a[0], u32(5))
	testing.expect_value(t, scene.triangles.property_b[0], u32(6))
	testing.expect_value(t, scene.triangles.property_c[0], u32(7))
	testing.expect_value(t, scene.triangles.property_a[1], u32(4))
	testing.expect_value(t, scene.components[0].object_index, u32(0))
	testing.expect_value(t, scene.components[0].transform[9], f64(2))
	testing.expect_value(t, scene.build_items[0].object_index, u32(1))
	testing.expect_value(t, scene.build_items[0].transform[11], f64(7))
	testing.expect_value(t, transmute(u64)scene.vertices.z[0], u64(0))
	testing.expect(
		t,
		scene.objects[0].stable_id != contracts.INVALID_STABLE_ID,
	)
	testing.expect(
		t,
		scene.vertices.stable_ids[0] != scene.vertices.stable_ids[1],
	)
}

@(test)
three_mf_model_preserves_nested_optional_extension_payloads_test :: proc(
	t: ^testing.T,
) {
	model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:v="urn:vendor"><resources><v:properties id="1" mode="print"><v:item key="speed">fast &amp; stable</v:item></v:properties><object id="2" pid="1" pindex="0">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</object></resources><build><item objectid="2"/></build></model>`
	source := three_mf_test_package(model = model)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	scene, model_error := three_mf_model_decode(package_result)
	defer three_mf_scene_destroy(&scene)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(t, model_error, Three_MF_Model_Error.None)
	testing.expect_value(t, len(scene.extension_resources), 1)
	resource := scene.extension_resources[0]
	testing.expect_value(t, resource.namespace_uri, "urn:vendor")
	testing.expect_value(t, resource.qualified_name, "v:properties")
	testing.expect_value(t, resource.resource_id, u32(1))
	testing.expect(t, len(resource.payload) > 100)

	limits := DEFAULT_THREE_MF_MODEL_LIMITS
	limits.max_extension_payload_bytes = 32
	_, limit_error := three_mf_model_decode(package_result, limits)
	testing.expect_value(
		t,
		limit_error,
		Three_MF_Model_Error.Extension_Payload_Limit,
	)
}

@(test)
three_mf_model_accepts_the_default_unit_and_identity_transform_test :: proc(
	t: ^testing.T,
) {
	model :=
		`<m:model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:m="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><m:resources><m:object id="1">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</m:object></m:resources><m:build><m:item objectid="1"/></m:build></m:model>`
	source := three_mf_test_package(model = model)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	scene, model_error := three_mf_model_decode(package_result)
	defer three_mf_scene_destroy(&scene)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(t, model_error, Three_MF_Model_Error.None)
	testing.expect_value(
		t,
		scene.source.units,
		contracts.Source_Units.Millimetres,
	)
	testing.expect_value(
		t,
		scene.build_items[0].transform,
		three_mf_identity_transform(),
	)
}

@(test)
three_mf_model_rejects_forward_component_references_test :: proc(
	t: ^testing.T,
) {
	model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1"><components><component objectid="2"/></components></object><object id="2">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</object></resources><build><item objectid="1"/></build></model>`
	source := three_mf_test_package(model = model)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	scene, model_error := three_mf_model_decode(package_result)
	defer three_mf_scene_destroy(&scene)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(
		t,
		model_error,
		Three_MF_Model_Error.Reference_Invalid,
	)
}

@(test)
three_mf_model_rejects_invalid_triangle_indices_test :: proc(
	t: ^testing.T,
) {
	model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/><vertex x="0" y="0" z="1"/></vertices><triangles><triangle v1="0" v2="0" v3="4"/><triangle v1="0" v2="1" v3="2"/><triangle v1="0" v2="1" v3="3"/><triangle v1="0" v2="2" v3="3"/></triangles></mesh></object></resources><build><item objectid="1"/></build></model>`
	source := three_mf_test_package(model = model)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	scene, model_error := three_mf_model_decode(package_result)
	defer three_mf_scene_destroy(&scene)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(
		t,
		model_error,
		Three_MF_Model_Error.Triangle_Invalid,
	)
}

@(test)
three_mf_model_rejects_nonfinite_coordinates_and_transforms_test :: proc(
	t: ^testing.T,
) {
	coordinate_model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1"><mesh><vertices><vertex x="NaN" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/><vertex x="0" y="0" z="1"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/><triangle v1="0" v2="1" v3="3"/><triangle v1="1" v2="2" v3="3"/><triangle v1="2" v2="0" v3="3"/></triangles></mesh></object></resources><build><item objectid="1"/></build></model>`
	coordinate_source := three_mf_test_package(model = coordinate_model)
	defer delete(coordinate_source)
	coordinate_package, coordinate_package_error :=
		three_mf_package_open(coordinate_source[:])
	defer three_mf_package_destroy(&coordinate_package)
	coordinate_scene, coordinate_error :=
		three_mf_model_decode(coordinate_package)
	defer three_mf_scene_destroy(&coordinate_scene)

	transform_model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</object></resources><build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 Infinity"/></build></model>`
	transform_source := three_mf_test_package(model = transform_model)
	defer delete(transform_source)
	transform_package, transform_package_error :=
		three_mf_package_open(transform_source[:])
	defer three_mf_package_destroy(&transform_package)
	transform_scene, transform_error :=
		three_mf_model_decode(transform_package)
	defer three_mf_scene_destroy(&transform_scene)

	testing.expect_value(
		t,
		coordinate_package_error,
		Three_MF_Package_Error.None,
	)
	testing.expect_value(
		t,
		coordinate_error,
		Three_MF_Model_Error.Vertex_Invalid,
	)
	testing.expect_value(
		t,
		transform_package_error,
		Three_MF_Package_Error.None,
	)
	testing.expect_value(
		t,
		transform_error,
		Three_MF_Model_Error.Transform_Invalid,
	)
}

@(test)
three_mf_model_rejects_required_extensions_and_other_builds_test :: proc(
	t: ^testing.T,
) {
	extension_model :=
		`<model requiredextensions="x" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:x="urn:test"><resources/><build/></model>`
	extension_source := three_mf_test_package(model = extension_model)
	defer delete(extension_source)
	extension_package, extension_package_error :=
		three_mf_package_open(extension_source[:])
	defer three_mf_package_destroy(&extension_package)
	extension_scene, extension_error :=
		three_mf_model_decode(extension_package)
	defer three_mf_scene_destroy(&extension_scene)

	other_model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1" type="other">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</object><object id="2"><components><component objectid="1"/></components></object></resources><build><item objectid="2"/></build></model>`
	other_source := three_mf_test_package(model = other_model)
	defer delete(other_source)
	other_package, other_package_error :=
		three_mf_package_open(other_source[:])
	defer three_mf_package_destroy(&other_package)
	other_scene, other_error := three_mf_model_decode(other_package)
	defer three_mf_scene_destroy(&other_scene)

	testing.expect_value(
		t,
		extension_package_error,
		Three_MF_Package_Error.None,
	)
	testing.expect_value(
		t,
		extension_error,
		Three_MF_Model_Error.Required_Extension_Unsupported,
	)
	testing.expect_value(
		t,
		other_package_error,
		Three_MF_Package_Error.None,
	)
	testing.expect_value(
		t,
		other_error,
		Three_MF_Model_Error.Reference_Invalid,
	)
}

@(test)
three_mf_model_validates_metadata_names_order_and_uniqueness_test :: proc(
	t: ^testing.T,
) {
	valid_model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:vendor="urn:test"><metadata name="Title">part</metadata><metadata name="vendor:setting" preserve="true">on</metadata><resources><object id="1">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</object></resources><build><item objectid="1"/></build></model>`
	valid_source := three_mf_test_package(model = valid_model)
	defer delete(valid_source)
	valid_package, valid_package_error :=
		three_mf_package_open(valid_source[:])
	defer three_mf_package_destroy(&valid_package)
	valid_scene, valid_error := three_mf_model_decode(valid_package)
	defer three_mf_scene_destroy(&valid_scene)

	unknown_model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><metadata>x</metadata><resources><object id="1">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</object></resources><build><item objectid="1"/></build></model>`
	unknown_source := three_mf_test_package(model = unknown_model)
	defer delete(unknown_source)
	unknown_package, unknown_package_error :=
		three_mf_package_open(unknown_source[:])
	defer three_mf_package_destroy(&unknown_package)
	unknown_scene, unknown_error := three_mf_model_decode(unknown_package)
	defer three_mf_scene_destroy(&unknown_scene)

	duplicate_model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><metadata name="Title">one</metadata><metadata name="Title">two</metadata><resources><object id="1">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</object></resources><build><item objectid="1"/></build></model>`
	duplicate_source := three_mf_test_package(model = duplicate_model)
	defer delete(duplicate_source)
	duplicate_package, duplicate_package_error :=
		three_mf_package_open(duplicate_source[:])
	defer three_mf_package_destroy(&duplicate_package)
	duplicate_scene, duplicate_error :=
		three_mf_model_decode(duplicate_package)
	defer three_mf_scene_destroy(&duplicate_scene)

	testing.expect_value(
		t,
		valid_package_error,
		Three_MF_Package_Error.None,
	)
	testing.expect_value(t, valid_error, Three_MF_Model_Error.None)
	testing.expect_value(t, len(valid_scene.metadata), 2)
	testing.expect_value(t, valid_scene.metadata[0].name, "Title")
	testing.expect_value(t, valid_scene.metadata[0].value, "part")
	testing.expect_value(
		t,
		valid_scene.metadata[1].namespace_uri,
		"urn:test",
	)
	testing.expect_value(t, valid_scene.metadata[1].value, "on")
	testing.expect(t, valid_scene.metadata[1].preserve)
	testing.expect_value(
		t,
		unknown_package_error,
		Three_MF_Package_Error.None,
	)
	testing.expect_value(
		t,
		unknown_error,
		Three_MF_Model_Error.Metadata_Invalid,
	)
	testing.expect_value(
		t,
		duplicate_package_error,
		Three_MF_Package_Error.None,
	)
	testing.expect_value(
		t,
		duplicate_error,
		Three_MF_Model_Error.Metadata_Duplicate,
	)
}

@(test)
three_mf_model_decodes_base_material_names_colors_and_defaults_test :: proc(
	t: ^testing.T,
) {
	model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><basematerials id="1"><base name="opaque" displaycolor="#112233"/><base name="alpha" displaycolor="#44556677"/></basematerials><object id="2" pid="1" pindex="1">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</object></resources><build><item objectid="2"/></build></model>`
	source := three_mf_test_package(model = model)
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	scene, model_error := three_mf_model_decode(package_result)
	defer three_mf_scene_destroy(&scene)
	testing.expect_value(t, package_error, Three_MF_Package_Error.None)
	testing.expect_value(t, model_error, Three_MF_Model_Error.None)
	testing.expect_value(t, len(scene.property_groups), 1)
	testing.expect_value(t, len(scene.base_materials), 2)
	testing.expect_value(
		t,
		scene.property_groups[0].kind,
		Three_MF_Property_Group_Kind.Base_Materials,
	)
	testing.expect_value(t, scene.property_groups[0].material_count, u32(2))
	testing.expect_value(t, scene.base_materials[0].name, "opaque")
	testing.expect_value(
		t,
		scene.base_materials[0].display_rgba,
		u32(0x1122_33ff),
	)
	testing.expect_value(
		t,
		scene.base_materials[1].display_rgba,
		u32(0x4455_6677),
	)
	testing.expect_value(t, scene.triangles.property_resource[0], u32(1))
	testing.expect_value(t, scene.triangles.property_a[0], u32(1))
	testing.expect(
		t,
		scene.base_materials[0].stable_id !=
			contracts.INVALID_STABLE_ID,
	)
}

@(test)
three_mf_model_rejects_invalid_base_materials_and_indices_test :: proc(
	t: ^testing.T,
) {
	color_model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><basematerials id="1"><base name="bad" displaycolor="#xyzxyz"/></basematerials><object id="2">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</object></resources><build><item objectid="2"/></build></model>`
	color_source := three_mf_test_package(model = color_model)
	defer delete(color_source)
	color_package, color_package_error :=
		three_mf_package_open(color_source[:])
	defer three_mf_package_destroy(&color_package)
	color_scene, color_error := three_mf_model_decode(color_package)
	defer three_mf_scene_destroy(&color_scene)

	index_model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><basematerials id="1"><base name="only" displaycolor="#ffffff"/></basematerials><object id="2" pid="1" pindex="1">` +
		THREE_MF_TEST_TETRAHEDRON +
		`</object></resources><build><item objectid="2"/></build></model>`
	index_source := three_mf_test_package(model = index_model)
	defer delete(index_source)
	index_package, index_package_error :=
		three_mf_package_open(index_source[:])
	defer three_mf_package_destroy(&index_package)
	index_scene, index_error := three_mf_model_decode(index_package)
	defer three_mf_scene_destroy(&index_scene)

	testing.expect_value(
		t,
		color_package_error,
		Three_MF_Package_Error.None,
	)
	testing.expect_value(
		t,
		color_error,
		Three_MF_Model_Error.Property_Invalid,
	)
	testing.expect_value(
		t,
		index_package_error,
		Three_MF_Package_Error.None,
	)
	testing.expect_value(
		t,
		index_error,
		Three_MF_Model_Error.Object_Invalid,
	)
}
