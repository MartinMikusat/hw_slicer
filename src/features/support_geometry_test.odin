package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

@(test)
support_geometry_propagates_and_splits_interface_layers_test :: proc(
	t: ^testing.T,
) {
	schedule, topology, regions :=
		support_geometry_test_layers(t, false)
	defer slicing.fixed_layer_schedule_destroy(&schedule)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	demand := support_geometry_test_demand(schedule)
	defer support_demand_result_destroy(&demand)
	process := support_geometry_test_process(.Everywhere, 200)
	result, error := support_geometry_build(
		schedule,
		topology,
		regions,
		demand,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer support_geometry_result_destroy(&result)
	testing.expect_value(t, error, Support_Geometry_Error.None)
	testing.expect_value(t, len(result.masks), 4)
	testing.expect_value(t, result.regular_mask_count, u64(2))
	testing.expect_value(t, result.interface_mask_count, u64(2))
	testing.expect_value(t, result.unresolved_demand_count, u64(0))
	testing.expect_value(
		t,
		result.layers[0].mask_count,
		u32(1),
	)
	testing.expect_value(
		t,
		result.masks[result.layers[0].mask_offset].kind,
		Support_Geometry_Kind.Regular,
	)
	testing.expect_value(
		t,
		result.masks[result.layers[1].mask_offset].kind,
		Support_Geometry_Kind.Regular,
	)
	testing.expect_value(
		t,
		result.masks[result.layers[2].mask_offset].kind,
		Support_Geometry_Kind.Interface,
	)
	testing.expect_value(
		t,
		result.masks[result.layers[3].mask_offset].kind,
		Support_Geometry_Kind.Interface,
	)
	testing.expect_value(t, result.layers[4].mask_count, u32(0))
	for mask in result.masks {
		expected_role := profiles.Printable_Role.Support
		if mask.kind == .Interface {
			expected_role = .Support_Interface
		}
		testing.expect_value(t, mask.role, expected_role)
		testing.expect_value(t, mask.source_reference_count, u32(1))
	}
	schedule_hash, schedule_hash_ok :=
		slicing.fixed_layer_schedule_hash(schedule)
	region_hash, region_hash_ok :=
		slicing.region_result_hash({}, topology, regions)
	testing.expect(t, schedule_hash_ok && region_hash_ok)
	process_hash: contracts.Content_Hash
	process_hash[0] = 0x50
	hash, hash_ok := support_geometry_result_hash(
		schedule_hash,
		region_hash,
		{},
		process_hash,
		schedule,
		topology,
		regions,
		demand,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0x8c, 0x0d, 0x6c, 0x41, 0x43, 0x92, 0x59, 0x70,
		0xd6, 0x28, 0xdc, 0x86, 0xef, 0x27, 0x7b, 0xf6,
		0xd3, 0x46, 0x9d, 0x03, 0xa1, 0xb4, 0xb0, 0xb8,
		0xeb, 0x22, 0xa1, 0xe4, 0x45, 0x89, 0xa4, 0x31,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
support_geometry_applies_physical_z_clearance_test :: proc(t: ^testing.T) {
	schedule, topology, regions :=
		support_geometry_test_layers(t, false)
	defer slicing.fixed_layer_schedule_destroy(&schedule)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	demand := support_geometry_test_demand(schedule)
	defer support_demand_result_destroy(&demand)
	process := support_geometry_test_process(.Everywhere, 500)
	result, error := support_geometry_build(
		schedule,
		topology,
		regions,
		demand,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer support_geometry_result_destroy(&result)
	testing.expect_value(t, error, Support_Geometry_Error.None)
	testing.expect_value(t, len(result.masks), 2)
	testing.expect_value(t, result.regular_mask_count, u64(0))
	testing.expect_value(t, result.interface_mask_count, u64(2))
	testing.expect_value(t, result.layers[0].mask_count, u32(1))
	testing.expect_value(t, result.layers[1].mask_count, u32(1))
	testing.expect_value(t, result.layers[2].mask_count, u32(0))
}

@(test)
support_geometry_reports_demand_without_z_clearance_target_test :: proc(
	t: ^testing.T,
) {
	schedule, topology, regions :=
		support_geometry_test_layers(t, false)
	defer slicing.fixed_layer_schedule_destroy(&schedule)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	demand := support_geometry_test_demand(schedule)
	defer support_demand_result_destroy(&demand)
	process := support_geometry_test_process(.Everywhere, 900)
	result, error := support_geometry_build(
		schedule,
		topology,
		regions,
		demand,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer support_geometry_result_destroy(&result)
	testing.expect_value(t, error, Support_Geometry_Error.None)
	testing.expect_value(t, len(result.masks), 0)
	testing.expect_value(t, result.unresolved_demand_count, u64(1))
}

@(test)
support_geometry_build_plate_mode_filters_trapped_columns_test :: proc(
	t: ^testing.T,
) {
	schedule, topology, regions :=
		support_geometry_test_layers(t, true)
	defer slicing.fixed_layer_schedule_destroy(&schedule)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	demand := support_geometry_test_demand(schedule)
	defer support_demand_result_destroy(&demand)
	everywhere, everywhere_error := support_geometry_build(
		schedule,
		topology,
		regions,
		demand,
		support_geometry_test_process(.Everywhere, 200),
		polygon.CLIPPER2_PROVIDER,
	)
	defer support_geometry_result_destroy(&everywhere)
	testing.expect_value(
		t,
		everywhere_error,
		Support_Geometry_Error.None,
	)
	build_plate, build_plate_error := support_geometry_build(
		schedule,
		topology,
		regions,
		demand,
		support_geometry_test_process(.Build_Plate_Only, 200),
		polygon.CLIPPER2_PROVIDER,
	)
	defer support_geometry_result_destroy(&build_plate)
	testing.expect_value(
		t,
		build_plate_error,
		Support_Geometry_Error.None,
	)
	testing.expect(t, len(everywhere.masks) > 0)
	testing.expect_value(t, len(build_plate.masks), 0)
}

@(test)
support_geometry_hash_rejects_mutated_roles_test :: proc(t: ^testing.T) {
	schedule, topology, regions :=
		support_geometry_test_layers(t, false)
	defer slicing.fixed_layer_schedule_destroy(&schedule)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	demand := support_geometry_test_demand(schedule)
	defer support_demand_result_destroy(&demand)
	process := support_geometry_test_process(.Everywhere, 200)
	result, error := support_geometry_build(
		schedule,
		topology,
		regions,
		demand,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer support_geometry_result_destroy(&result)
	testing.expect_value(t, error, Support_Geometry_Error.None)
	if len(result.masks) == 0 {return}
	result.masks[0].role = .Bridge
	schedule_hash, schedule_hash_ok :=
		slicing.fixed_layer_schedule_hash(schedule)
	region_hash, region_hash_ok :=
		slicing.region_result_hash({}, topology, regions)
	testing.expect(t, schedule_hash_ok && region_hash_ok)
	_, hash_ok := support_geometry_result_hash(
		schedule_hash,
		region_hash,
		{},
		{},
		schedule,
		topology,
		regions,
		demand,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, !hash_ok)
}

support_geometry_test_layers :: proc(
	t: ^testing.T,
	block_plate: bool,
) -> (
	slicing.Fixed_Layer_Schedule,
	slicing.Topology_Result,
	slicing.Region_Result,
) {
	layer_count := 5
	schedule := slicing.Fixed_Layer_Schedule{
		minimum_z = 0,
		maximum_z = 1_200,
		first_plane_z = 200,
		layer_step = 200,
		layer_z = make([]contracts.Micrometres, layer_count),
		layer_ids = make([]contracts.Stable_ID, layer_count),
	}
	for layer_index in 0..<layer_count {
		schedule.layer_z[layer_index] =
			contracts.Micrometres((layer_index+1)*200)
		schedule.layer_ids[layer_index] =
			contracts.Stable_ID(10+layer_index)
	}
	layer_counts := []u32{1, 1, 1, 1, 1}
	path_points := [][4]slicing.Snapped_Point{
		{{0, 0}, {500, 0}, {500, 1_000}, {0, 1_000}},
		{{0, 0}, {500, 0}, {500, 1_000}, {0, 1_000}},
		{{0, 0}, {500, 0}, {500, 1_000}, {0, 1_000}},
		{{0, 0}, {500, 0}, {500, 1_000}, {0, 1_000}},
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
	}
	if block_plate {
		path_points[0] = {
			{0, -500},
			{1_500, -500},
			{1_500, 1_500},
			{0, 1_500},
		}
	}
	topology := surface_rect_topology(layer_counts, path_points)
	regions, region_error := slicing.regions_build(topology)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	return schedule, topology, regions
}

support_geometry_test_demand :: proc(
	schedule: slicing.Fixed_Layer_Schedule,
) -> Support_Demand_Result {
	result := Support_Demand_Result{
		config = support_demand_test_config(),
		policy = .Mesh_And_Layer_Projection,
		overhang_angle = 45_000,
		angle_direction_x = 707_107,
		angle_direction_y = 707_107,
		layers = make([]Support_Demand_Layer, len(schedule.layer_z)),
		masks = make([]Support_Demand_Mask, 1),
		paths = make([]Support_Demand_Path, 1),
		points = make([]polygon.Polygon_Point, 4),
	}
	mask_id := contracts.stable_id_child(
		schedule.layer_ids[4],
		.Feature,
		feature_support_demand_ordinal(),
	)
	result.layers[4] = {
		mask_offset = 0,
		mask_count = 1,
		path_offset = 0,
		path_count = 1,
		allowed_lateral_margin = 200,
	}
	result.masks[0] = {
		stable_id = mask_id,
		layer_id = schedule.layer_ids[4],
		layer_index = 4,
		allowed_lateral_margin = 200,
		path_offset = 0,
		path_count = 1,
		point_offset = 0,
		point_count = 4,
	}
	result.paths[0] = {
		stable_id = contracts.stable_id_child(mask_id, .Path, 0),
		mask_id = mask_id,
		mask_path_index = 0,
		point_offset = 0,
		point_count = 4,
		signed_area_2 = 600_000,
		winding = .Positive,
	}
	copy(
		result.points,
		[]polygon.Polygon_Point{
			{700, 0},
			{1_000, 0},
			{1_000, 1_000},
			{700, 1_000},
		},
	)
	return result
}

support_geometry_test_process :: proc(
	mode: profiles.Support_Mode,
	clearance_z: contracts.Micrometres,
) -> profiles.Resolved_Process_Profile {
	result := support_face_test_process(45_000)
	result.source.support_mode = mode
	result.source.support_clearance_xy = 300
	result.source.support_clearance_z = clearance_z
	result.source.support_expansion = 200
	result.source.support_interface_layers = 2
	return result
}
