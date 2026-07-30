package pipeline

import "core:os"
import "core:testing"

import contracts "../contracts"
import formats "../formats"

@(test)
binary_stl_slice_spine_runs_all_implemented_stages_test :: proc(
	t: ^testing.T,
) {
	bytes := formats.binary_stl_test_triangle()
	result, error := slice_spine_binary_stl(bytes[:], {
		source_units = .Millimetres,
		first_layer_height = 2000,
		layer_height = 2000,
		max_layer_count = 10,
	})
	defer slice_spine_result_destroy(&result)
	testing.expect_value(t, error, Slice_Spine_Error.None)
	testing.expect_value(t, len(result.schedule.layer_z), 4)
	testing.expect_value(t, len(result.snapped.segments.segment_ids), 4)
	testing.expect_value(t, len(result.topology.paths), 4)
	testing.expect_value(t, result.topology.open_chain_count, u64(4))
	testing.expect_value(t, result.topology.non_manifold_vertex_count, u64(0))
	testing.expect_value(
		t,
		result.mesh_audit.degenerate_triangle_count,
		u64(0),
	)
	testing.expect_value(t, result.mesh_audit.boundary_edge_count, u64(3))
	testing.expect_value(
		t,
		result.planar_ownership.unresolved_group_count,
		u64(0),
	)
	testing.expect(t, result.hashes.decoded_mesh != contracts.Content_Hash{})
	testing.expect(t, result.hashes.mesh_audit != contracts.Content_Hash{})
	testing.expect(t, result.hashes.topology != contracts.Content_Hash{})
	expected_topology_hash := contracts.Content_Hash{
		0xf7, 0x47, 0x6a, 0x50, 0x4e, 0xbc, 0x26, 0x39,
		0xc6, 0x18, 0xa8, 0xea, 0xef, 0x05, 0x28, 0xcc,
		0x42, 0xcc, 0x27, 0xf8, 0x71, 0xc1, 0xf6, 0x29,
		0xd3, 0xb8, 0xfb, 0x64, 0x8b, 0x9f, 0x23, 0x9d,
	}
	testing.expect_value(
		t,
		result.hashes.topology,
		expected_topology_hash,
	)
}

@(test)
binary_stl_slice_spine_rejects_unresolved_units_and_invalid_schedule_test :: proc(
	t: ^testing.T,
) {
	bytes := formats.binary_stl_test_triangle()
	_, units_error := slice_spine_binary_stl(bytes[:], {
		source_units = .Unspecified,
		first_layer_height = 200,
		layer_height = 200,
		max_layer_count = 10,
	})
	_, height_error := slice_spine_binary_stl(bytes[:], {
		source_units = .Millimetres,
		first_layer_height = 0,
		layer_height = 200,
		max_layer_count = 10,
	})
	testing.expect_value(t, units_error, Slice_Spine_Error.Invalid_Config)
	testing.expect_value(t, height_error, Slice_Spine_Error.Invalid_Config)
}

@(test)
ascii_stl_slice_spine_uses_the_shared_geometry_stages_test :: proc(
	t: ^testing.T,
) {
	bytes := transmute([]u8)formats.ASCII_STL_TEST_TRIANGLE
	result, error := slice_spine_stl(bytes, {
		source_units = .Millimetres,
		first_layer_height = 200,
		layer_height = 200,
		max_layer_count = 10,
	})
	defer slice_spine_result_destroy(&result)
	testing.expect_value(t, error, Slice_Spine_Error.None)
	testing.expect_value(
		t,
		result.mesh.source.format,
		contracts.Source_Format.ASCII_STL,
	)
	testing.expect_value(t, len(result.mesh.triangle_ids), 1)
	testing.expect_value(t, len(result.schedule.layer_z), 4)
	testing.expect_value(t, result.topology.open_chain_count, u64(4))
	testing.expect(t, result.hashes.decoded_mesh != contracts.Content_Hash{})
	testing.expect(t, result.hashes.topology != contracts.Content_Hash{})
}

@(test)
obj_slice_spine_triangulates_faces_then_uses_shared_geometry_stages_test :: proc(
	t: ^testing.T,
) {
	source :=
		`v 0 0 0
v 10 0 0
v 0 10 0
v 0 0 10
f 1 3 2
f 1 2 4
f 2 3 4
f 3 1 4
`
	bytes := transmute([]u8)source
	result, error := slice_spine_mesh(bytes, {
		source_units = .Millimetres,
		first_layer_height = 1000,
		layer_height = 1000,
		max_layer_count = 20,
	})
	defer slice_spine_result_destroy(&result)
	testing.expect_value(t, error, Slice_Spine_Error.None)
	testing.expect_value(
		t,
		result.mesh.source.format,
		contracts.Source_Format.OBJ,
	)
	testing.expect_value(t, len(result.mesh.triangle_ids), 4)
	testing.expect_value(t, len(result.schedule.layer_z), 9)
	testing.expect_value(t, len(result.topology.paths), 9)
	testing.expect_value(t, result.topology.open_chain_count, u64(0))
	testing.expect_value(t, result.mesh_audit.boundary_edge_count, u64(0))
	testing.expect_value(
		t,
		result.mesh_audit.inconsistent_winding_count,
		u64(0),
	)
	testing.expect(t, result.hashes.decoded_mesh != contracts.Content_Hash{})
	testing.expect(t, result.hashes.topology != contracts.Content_Hash{})
}

@(test)
equivalent_mesh_formats_emit_identical_snapped_geometry_test :: proc(
	t: ^testing.T,
) {
	ascii, ascii_read_ok :=
		os.read_entire_file("testdata/ascii-stl/tetrahedron.stl")
	defer delete(ascii)
	obj, obj_read_ok :=
		os.read_entire_file("testdata/obj/tetrahedron.obj")
	defer delete(obj)
	binary := pipeline_test_binary_tetrahedron()
	model :=
		`<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1">` +
		formats.THREE_MF_TEST_TETRAHEDRON +
		`</object></resources><build><item objectid="1"/></build></model>`
	three_mf := formats.three_mf_test_package(model = model)
	defer delete(three_mf)
	testing.expect(t, ascii_read_ok)
	testing.expect(t, obj_read_ok)
	if !ascii_read_ok || !obj_read_ok {return}
	config := Slice_Spine_Config{
		source_units = .Millimetres,
		first_layer_height = 1000,
		layer_height = 1000,
		max_layer_count = 20,
	}
	binary_result, binary_error :=
		slice_spine_binary_stl(binary[:], config)
	defer slice_spine_result_destroy(&binary_result)
	ascii_result, ascii_error := slice_spine_ascii_stl(ascii, config)
	defer slice_spine_result_destroy(&ascii_result)
	obj_result, obj_error := slice_spine_obj(obj, config)
	defer slice_spine_result_destroy(&obj_result)
	three_mf_result, three_mf_error := slice_spine_three_mf(
		three_mf[:],
		{
			first_layer_height = config.first_layer_height,
			layer_height = config.layer_height,
			max_layer_count = config.max_layer_count,
		},
	)
	defer slice_spine_result_destroy(&three_mf_result)
	testing.expect_value(t, binary_error, Slice_Spine_Error.None)
	testing.expect_value(t, ascii_error, Slice_Spine_Error.None)
	testing.expect_value(t, obj_error, Slice_Spine_Error.None)
	testing.expect_value(t, three_mf_error, Slice_Spine_Error.None)
	results := [?]^Slice_Spine_Result{
		&ascii_result,
		&obj_result,
		&three_mf_result,
	}
	for result in results {
		pipeline_test_expect_equivalent_geometry(
			t,
			&binary_result,
			result,
		)
	}
}

@(test)
three_mf_slice_spine_runs_the_same_geometry_stages_test :: proc(
	t: ^testing.T,
) {
	bytes := formats.three_mf_test_package(
		model = formats.THREE_MF_TEST_SCENE_MODEL,
	)
	defer delete(bytes)
	result, error := slice_spine_three_mf(bytes[:], {
		first_layer_height = 10_000,
		layer_height = 10_000,
		max_layer_count = 100,
	})
	defer slice_spine_result_destroy(&result)
	testing.expect_value(t, error, Slice_Spine_Error.None)
	testing.expect_value(
		t,
		result.mesh.source.format,
		contracts.Source_Format.Three_MF,
	)
	testing.expect_value(
		t,
		result.mesh.source.units,
		contracts.Source_Units.Centimetres,
	)
	testing.expect_value(
		t,
		result.mesh.coordinate_units,
		contracts.Source_Units.Millimetres,
	)
	testing.expect_value(t, f64(result.mesh.bounds.minimum.x), f64(90))
	testing.expect_value(t, f64(result.mesh.bounds.minimum.y), f64(90))
	testing.expect_value(t, f64(result.mesh.bounds.minimum.z), f64(110))
	testing.expect_value(t, f64(result.mesh.bounds.maximum.x), f64(290))
	testing.expect_value(t, f64(result.mesh.bounds.maximum.y), f64(190))
	testing.expect_value(t, f64(result.mesh.bounds.maximum.z), f64(210))
	testing.expect_value(t, len(result.schedule.layer_z), 9)
	testing.expect(t, result.hashes.three_mf_scene != contracts.Content_Hash{})
	testing.expect(t, result.hashes.decoded_mesh != contracts.Content_Hash{})
	testing.expect(t, result.hashes.topology != contracts.Content_Hash{})
}

@(test)
three_mf_slice_spine_reports_package_and_model_boundaries_test :: proc(
	t: ^testing.T,
) {
	_, package_error := slice_spine_three_mf([]u8{1, 2, 3}, {
		first_layer_height = 200,
		layer_height = 200,
		max_layer_count = 100,
	})
	model :=
		`<model requiredextensions="x" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:x="urn:test"><resources/><build/></model>`
	bytes := formats.three_mf_test_package(model = model)
	defer delete(bytes)
	_, model_boundary_error := slice_spine_three_mf(bytes[:], {
		first_layer_height = 200,
		layer_height = 200,
		max_layer_count = 100,
	})
	testing.expect_value(
		t,
		package_error,
		Slice_Spine_Error.Three_MF_Package,
	)
	testing.expect_value(
		t,
		model_boundary_error,
		Slice_Spine_Error.Three_MF_Model,
	)
}

pipeline_test_binary_tetrahedron :: proc() -> [284]u8 {
	bytes: [284]u8
	pipeline_test_write_u32(bytes[:], 80, 4)
	positions := [4][3][3]f32{
		{{0, 0, 0}, {0, 10, 0}, {10, 0, 0}},
		{{0, 0, 0}, {10, 0, 0}, {0, 0, 10}},
		{{10, 0, 0}, {0, 10, 0}, {0, 0, 10}},
		{{0, 10, 0}, {0, 0, 0}, {0, 0, 10}},
	}
	for triangle, triangle_index in positions {
		record_offset := 84+triangle_index*50
		for vertex, vertex_index in triangle {
			position_offset := record_offset+12+vertex_index*12
			for coordinate, coordinate_index in vertex {
				pipeline_test_write_f32(
					bytes[:],
					position_offset+coordinate_index*4,
					coordinate,
				)
			}
		}
	}
	return bytes
}

pipeline_test_write_u32 :: proc(bytes: []u8, offset: int, value: u32) {
	bytes[offset] = u8(value)
	bytes[offset+1] = u8(value>>8)
	bytes[offset+2] = u8(value>>16)
	bytes[offset+3] = u8(value>>24)
}

pipeline_test_write_f32 :: proc(bytes: []u8, offset: int, value: f32) {
	pipeline_test_write_u32(bytes, offset, transmute(u32)value)
}

pipeline_test_expect_equivalent_geometry :: proc(
	t: ^testing.T,
	expected, actual: ^Slice_Spine_Result,
) {
	testing.expect_value(
		t,
		actual.mesh_audit.welded_vertex_count,
		expected.mesh_audit.welded_vertex_count,
	)
	testing.expect_value(
		t,
		actual.mesh_audit.degenerate_triangle_count,
		expected.mesh_audit.degenerate_triangle_count,
	)
	testing.expect_value(
		t,
		actual.mesh_audit.duplicate_face_group_count,
		expected.mesh_audit.duplicate_face_group_count,
	)
	testing.expect_value(
		t,
		actual.mesh_audit.boundary_edge_count,
		expected.mesh_audit.boundary_edge_count,
	)
	testing.expect_value(
		t,
		actual.mesh_audit.non_manifold_edge_count,
		expected.mesh_audit.non_manifold_edge_count,
	)
	testing.expect_value(
		t,
		actual.mesh_audit.inconsistent_winding_count,
		expected.mesh_audit.inconsistent_winding_count,
	)
	testing.expect_value(
		t,
		len(actual.schedule.layer_z),
		len(expected.schedule.layer_z),
	)
	testing.expect_value(
		t,
		len(actual.snapped.segments.segment_ids),
		len(expected.snapped.segments.segment_ids),
	)
	testing.expect_value(
		t,
		len(actual.topology.paths),
		len(expected.topology.paths),
	)
	if len(actual.schedule.layer_z) != len(expected.schedule.layer_z) ||
	   len(actual.snapped.segments.segment_ids) !=
	   	len(expected.snapped.segments.segment_ids) {
		return
	}
	for value, index in expected.schedule.layer_z {
		testing.expect_value(t, actual.schedule.layer_z[index], value)
	}
	for index in 0..<len(expected.snapped.segments.segment_ids) {
		testing.expect_value(
			t,
			actual.snapped.segments.layer_indices[index],
			expected.snapped.segments.layer_indices[index],
		)
		testing.expect_value(
			t,
			actual.snapped.segments.x0[index],
			expected.snapped.segments.x0[index],
		)
		testing.expect_value(
			t,
			actual.snapped.segments.y0[index],
			expected.snapped.segments.y0[index],
		)
		testing.expect_value(
			t,
			actual.snapped.segments.x1[index],
			expected.snapped.segments.x1[index],
		)
		testing.expect_value(
			t,
			actual.snapped.segments.y1[index],
			expected.snapped.segments.y1[index],
		)
	}
}
