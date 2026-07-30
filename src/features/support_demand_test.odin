package features

import "core:testing"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

@(test)
support_demand_intersects_layer_projection_with_mesh_overhang_test :: proc(
	t: ^testing.T,
) {
	mesh := support_demand_test_mesh(500)
	defer geometry.canonical_mesh_destroy(&mesh)
	process := support_face_test_process(45_000)
	faces, face_error := support_faces_classify(mesh, process)
	defer support_face_result_destroy(&faces)
	testing.expect_value(t, face_error, Support_Face_Error.None)
	schedule, topology, regions := support_demand_test_layers(t)
	defer slicing.fixed_layer_schedule_destroy(&schedule)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	result, error := support_demand_build(
		schedule,
		topology,
		regions,
		faces,
		process,
		polygon.CLIPPER2_PROVIDER,
		support_demand_test_config(),
	)
	defer support_demand_result_destroy(&result)
	testing.expect_value(t, error, Support_Demand_Error.None)
	testing.expect_value(t, len(result.layers), 2)
	testing.expect_value(
		t,
		result.layers[1].allowed_lateral_margin,
		contracts.Micrometres(200),
	)
	testing.expect_value(t, len(result.masks), 1)
	testing.expect_value(t, len(result.source_face_references), 2)
	if len(result.masks) != 1 {return}
	mask := result.masks[0]
	testing.expect_value(t, mask.layer_index, u32(1))
	testing.expect_value(
		t,
		mask.allowed_lateral_margin,
		contracts.Micrometres(200),
	)
	testing.expect_value(t, mask.source_reference_count, u32(2))
	testing.expect_value(
		t,
		support_demand_test_mask_area_2(result, 0),
		i128(600_000),
	)
	minimum_x := contracts.Micrometres(max(i64))
	maximum_x := contracts.Micrometres(min(i64))
	start := int(mask.point_offset)
	end := start+int(mask.point_count)
	for point in result.points[start:end] {
		minimum_x = min(minimum_x, point.x)
		maximum_x = max(maximum_x, point.x)
	}
	testing.expect_value(t, minimum_x, contracts.Micrometres(700))
	testing.expect_value(t, maximum_x, contracts.Micrometres(1_000))
	schedule_hash, schedule_hash_ok :=
		slicing.fixed_layer_schedule_hash(schedule)
	region_hash, region_hash_ok :=
		slicing.region_result_hash({}, topology, regions)
	mesh_hash, mesh_hash_ok := geometry.canonical_mesh_hash(mesh)
	testing.expect(
		t,
		schedule_hash_ok && region_hash_ok && mesh_hash_ok,
	)
	process_hash: contracts.Content_Hash
	process_hash[0] = 0x50
	face_hash, face_hash_ok := support_face_result_hash(
		mesh_hash,
		process_hash,
		mesh,
		process,
		faces,
	)
	testing.expect(t, face_hash_ok)
	hash, hash_ok := support_demand_result_hash(
		schedule_hash,
		region_hash,
		face_hash,
		process_hash,
		schedule,
		topology,
		regions,
		faces,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0xeb, 0xe8, 0x4b, 0x99, 0xf1, 0x5f, 0xa9, 0xcd,
		0x8c, 0x64, 0x61, 0xbb, 0xd4, 0x5a, 0xfc, 0xaf,
		0xeb, 0x81, 0x38, 0xdd, 0xbc, 0x85, 0x4c, 0xad,
		0x52, 0xd9, 0x45, 0x6d, 0x71, 0x0d, 0xcc, 0xdd,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
support_demand_requires_overhang_projection_overlap_test :: proc(
	t: ^testing.T,
) {
	mesh := support_demand_test_mesh(2_000)
	defer geometry.canonical_mesh_destroy(&mesh)
	process := support_face_test_process(45_000)
	faces, face_error := support_faces_classify(mesh, process)
	defer support_face_result_destroy(&faces)
	testing.expect_value(t, face_error, Support_Face_Error.None)
	schedule, topology, regions := support_demand_test_layers(t)
	defer slicing.fixed_layer_schedule_destroy(&schedule)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	result, error := support_demand_build(
		schedule,
		topology,
		regions,
		faces,
		process,
		polygon.CLIPPER2_PROVIDER,
		support_demand_test_config(),
	)
	defer support_demand_result_destroy(&result)
	testing.expect_value(t, error, Support_Demand_Error.None)
	testing.expect_value(t, len(result.masks), 0)
	testing.expect_value(t, len(result.paths), 0)
}

@(test)
support_demand_allowed_margin_uses_fixed_angle_vector_test :: proc(
	t: ^testing.T,
) {
	x, y, direction_ok := bridge_direction_vector(45_000)
	testing.expect(t, direction_ok)
	margin, margin_ok := support_demand_allowed_margin(200, x, y)
	testing.expect(t, margin_ok)
	testing.expect_value(t, margin, contracts.Micrometres(200))
	x, y, direction_ok = bridge_direction_vector(30_000)
	testing.expect(t, direction_ok)
	margin, margin_ok = support_demand_allowed_margin(200, x, y)
	testing.expect(t, margin_ok)
	testing.expect_value(t, margin, contracts.Micrometres(115))
}

@(test)
support_demand_hash_rejects_mutated_source_references_test :: proc(
	t: ^testing.T,
) {
	mesh := support_demand_test_mesh(500)
	defer geometry.canonical_mesh_destroy(&mesh)
	process := support_face_test_process(45_000)
	faces, face_error := support_faces_classify(mesh, process)
	defer support_face_result_destroy(&faces)
	testing.expect_value(t, face_error, Support_Face_Error.None)
	schedule, topology, regions := support_demand_test_layers(t)
	defer slicing.fixed_layer_schedule_destroy(&schedule)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	result, error := support_demand_build(
		schedule,
		topology,
		regions,
		faces,
		process,
		polygon.CLIPPER2_PROVIDER,
		support_demand_test_config(),
	)
	defer support_demand_result_destroy(&result)
	testing.expect_value(t, error, Support_Demand_Error.None)
	if len(result.source_face_references) == 0 {return}
	result.source_face_references[0] += 1
	schedule_hash, schedule_hash_ok :=
		slicing.fixed_layer_schedule_hash(schedule)
	region_hash, region_hash_ok :=
		slicing.region_result_hash({}, topology, regions)
	testing.expect(t, schedule_hash_ok && region_hash_ok)
	_, hash_ok := support_demand_result_hash(
		schedule_hash,
		region_hash,
		{},
		{},
		schedule,
		topology,
		regions,
		faces,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, !hash_ok)
}

support_demand_test_layers :: proc(
	t: ^testing.T,
) -> (
	slicing.Fixed_Layer_Schedule,
	slicing.Topology_Result,
	slicing.Region_Result,
) {
	schedule := slicing.Fixed_Layer_Schedule{
		minimum_z = 0,
		maximum_z = 600,
		first_plane_z = 200,
		layer_step = 200,
		layer_z = make([]contracts.Micrometres, 2),
		layer_ids = make([]contracts.Stable_ID, 2),
	}
	schedule.layer_z[0] = 200
	schedule.layer_z[1] = 400
	schedule.layer_ids[0] = 10
	schedule.layer_ids[1] = 11
	layer_counts := []u32{1, 1}
	path_points := [][4]slicing.Snapped_Point{
		{{0, 0}, {500, 0}, {500, 1_000}, {0, 1_000}},
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
	}
	topology := surface_rect_topology(layer_counts, path_points)
	regions, region_error := slicing.regions_build(topology)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	return schedule, topology, regions
}

support_demand_test_mesh :: proc(
	minimum_x_um: i64,
) -> geometry.Canonical_Mesh {
	minimum_x := f64(minimum_x_um)/1_000
	maximum_x := minimum_x+0.5
	positions := [2][3][3]f64{
		{
			{minimum_x, 0, 0.4},
			{minimum_x, 1, 0.4},
			{maximum_x, 0, 0.4},
		},
		{
			{minimum_x, 1, 0.4},
			{maximum_x, 1, 0.4},
			{maximum_x, 0, 0.4},
		},
	}
	mesh := geometry.Canonical_Mesh{
		source = {
			byte_count = 1,
			format = .Binary_STL,
			units = .Millimetres,
		},
		coordinate_units = .Millimetres,
		source_root_id = 1,
		bounds = {
			minimum = {
				contracts.Millimetres(minimum_x),
				0,
				0.4,
			},
			maximum = {
				contracts.Millimetres(maximum_x),
				1,
				0.4,
			},
		},
	}
	mesh.vertex_x = make([]f64, 6)
	mesh.vertex_y = make([]f64, 6)
	mesh.vertex_z = make([]f64, 6)
	mesh.vertex_ids = make([]contracts.Stable_ID, 6)
	mesh.triangle_a = make([]u32, 2)
	mesh.triangle_b = make([]u32, 2)
	mesh.triangle_c = make([]u32, 2)
	mesh.triangle_ids = make([]contracts.Stable_ID, 2)
	mesh.source_record_offsets = make([]u64, 2)
	for triangle, triangle_index in positions {
		offset := triangle_index*3
		for point, local_index in triangle {
			index := offset+local_index
			mesh.vertex_x[index] = point[0]
			mesh.vertex_y[index] = point[1]
			mesh.vertex_z[index] = point[2]
			mesh.vertex_ids[index] = contracts.Stable_ID(index+1)
		}
		mesh.triangle_a[triangle_index] = u32(offset)
		mesh.triangle_b[triangle_index] = u32(offset+1)
		mesh.triangle_c[triangle_index] = u32(offset+2)
		mesh.triangle_ids[triangle_index] =
			contracts.Stable_ID(100+triangle_index)
	}
	return mesh
}

support_demand_test_config :: proc() -> Support_Demand_Config {
	return {
		fill_rule = .Even_Odd,
		join_type = .Miter,
		miter_limit = 2,
		arc_tolerance = 0,
	}
}

support_demand_test_mask_area_2 :: proc(
	result: Support_Demand_Result,
	mask_index: int,
) -> i128 {
	mask := result.masks[mask_index]
	area_2: i128
	start := int(mask.path_offset)
	end := start+int(mask.path_count)
	for path in result.paths[start:end] {
		area_2 += path.signed_area_2
	}
	return area_2
}
