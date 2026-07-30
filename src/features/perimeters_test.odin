package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

@(test)
perimeters_generate_two_centerlines_around_a_region_with_a_hole_test :: proc(
	t: ^testing.T,
) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := perimeters_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			count = 2,
			line_width = 100,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = 0,
		},
	)
	defer perimeter_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Perimeter_Error.None)
	testing.expect_value(t, len(result.layers), 1)
	testing.expect_value(t, len(result.groups), 2)
	testing.expect_value(t, len(result.paths), 4)
	testing.expect_value(t, len(result.points), 16)
	testing.expect_value(t, result.groups[0].delta, contracts.Micrometres(-50))
	testing.expect_value(
		t,
		result.groups[1].delta,
		contracts.Micrometres(-150),
	)
	testing.expect_value(
		t,
		perimeter_test_group_area_2(result, 0),
		i128(1_440_000),
	)
	testing.expect_value(
		t,
		perimeter_test_group_area_2(result, 1),
		i128(480_000),
	)
	region_hash, region_hash_ok := slicing.region_result_hash(
		contracts.Content_Hash{},
		topology,
		regions,
	)
	result_hash, hash_ok := perimeter_result_hash(region_hash, result)
	testing.expect(t, region_hash_ok)
	testing.expect(t, hash_ok)
	testing.expect(t, result_hash != contracts.Content_Hash{})
}

@(test)
perimeters_keep_collapsed_inner_groups_explicit_test :: proc(
	t: ^testing.T,
) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := perimeters_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			count = 6,
			line_width = 100,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = 0,
		},
	)
	defer perimeter_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Perimeter_Error.None)
	testing.expect_value(t, len(result.groups), 6)
	testing.expect(t, result.groups[5].path_count == 0)
	testing.expect_value(t, result.layers[0].group_count, u32(6))
}

@(test)
perimeters_reject_ambiguous_widths_and_work_limits_test :: proc(
	t: ^testing.T,
) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	odd_result, odd_error := perimeters_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			count = 2,
			line_width = 101,
			join_type = .Miter,
			miter_limit = 2,
		},
	)
	defer perimeter_result_destroy(&odd_result)
	limited_result, limited_error := perimeters_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			count = 2,
			line_width = 100,
			join_type = .Miter,
			miter_limit = 2,
		},
		{
			max_groups = 1,
			max_paths = 10,
			max_points = 100,
			polygon = polygon.DEFAULT_POLYGON_LIMITS,
		},
	)
	defer perimeter_result_destroy(&limited_result)
	namespace_result, namespace_error := perimeters_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			count = FEATURE_PERIMETER_COUNT_LIMIT+1,
			line_width = 100,
			join_type = .Miter,
			miter_limit = 2,
		},
	)
	defer perimeter_result_destroy(&namespace_result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, odd_error, Perimeter_Error.Invalid_Config)
	testing.expect_value(t, limited_error, Perimeter_Error.Group_Limit)
	testing.expect_value(
		t,
		namespace_error,
		Perimeter_Error.Invalid_Config,
	)
}

@(test)
perimeter_hash_rejects_mutated_group_spans_test :: proc(t: ^testing.T) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := perimeters_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			count = 1,
			line_width = 100,
			join_type = .Miter,
			miter_limit = 2,
		},
	)
	defer perimeter_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Perimeter_Error.None)
	if len(result.groups) == 0 {return}
	result.groups[0].path_offset = 1
	_, hash_ok := perimeter_result_hash(contracts.Content_Hash{}, result)
	testing.expect(t, !hash_ok)
}

@(test)
perimeters_normalize_negative_zero_arc_tolerance_test :: proc(
	t: ^testing.T,
) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	negative_zero := transmute(f64)(u64(1)<<63)
	result, error := perimeters_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			count = 1,
			line_width = 100,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = negative_zero,
		},
	)
	defer perimeter_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Perimeter_Error.None)
	testing.expect_value(
		t,
		transmute(u64)result.config.arc_tolerance,
		u64(0),
	)
	_, hash_ok := perimeter_result_hash(contracts.Content_Hash{}, result)
	testing.expect(t, hash_ok)
}

@(test)
feature_generation_requires_explicit_diagnostic_topology_policy_test :: proc(
	t: ^testing.T,
) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	topology.open_chain_count = 1
	strict_perimeters, strict_perimeter_error := perimeters_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			count = 1,
			line_width = 100,
			topology_policy = .Strict_Printable,
			join_type = .Miter,
			miter_limit = 2,
		},
	)
	defer perimeter_result_destroy(&strict_perimeters)
	diagnostic_perimeters, diagnostic_perimeter_error :=
		perimeters_generate(
			topology,
			regions,
			polygon.CLIPPER2_PROVIDER,
			{
				count = 1,
				line_width = 100,
				topology_policy = .Diagnostic_Closed_Regions,
				join_type = .Miter,
				miter_limit = 2,
			},
		)
	defer perimeter_result_destroy(&diagnostic_perimeters)
	strict_infill, strict_infill_error := infill_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			spacing = 200,
			boundary_inset = 100,
			phase = 0,
			base_axis = .Vertical,
			topology_policy = .Strict_Printable,
			join_type = .Miter,
			miter_limit = 2,
		},
	)
	defer infill_result_destroy(&strict_infill)
	diagnostic_infill, diagnostic_infill_error := infill_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			spacing = 200,
			boundary_inset = 100,
			phase = 0,
			base_axis = .Vertical,
			topology_policy = .Diagnostic_Closed_Regions,
			join_type = .Miter,
			miter_limit = 2,
		},
	)
	defer infill_result_destroy(&diagnostic_infill)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(
		t,
		strict_perimeter_error,
		Perimeter_Error.Invalid_Input,
	)
	testing.expect_value(
		t,
		diagnostic_perimeter_error,
		Perimeter_Error.None,
	)
	testing.expect_value(
		t,
		strict_infill_error,
		Infill_Error.Invalid_Input,
	)
	testing.expect_value(
		t,
		diagnostic_infill_error,
		Infill_Error.None,
	)
}

perimeter_test_topology :: proc() -> slicing.Topology_Result {
	points := [?]slicing.Snapped_Point{
		{0, 0},
		{1_000, 0},
		{1_000, 1_000},
		{0, 1_000},
		{400, 400},
		{400, 600},
		{600, 600},
		{600, 400},
	}
	result: slicing.Topology_Result
	result.layers = make([]slicing.Topology_Layer, 1)
	result.vertices = make([]slicing.Topology_Vertex, len(points))
	result.paths = make([]slicing.Topology_Path, 2)
	result.path_vertex_indices = make([]u32, len(points))
	result.path_segment_indices = make([]u32, len(points))
	result.layers[0] = {0, 8, 0, 2}
	for point, index in points {
		result.vertices[index] = {
			id = contracts.Stable_ID(index+1),
			layer_index = 0,
			point = point,
			degree = 2,
		}
		result.path_vertex_indices[index] = u32(index)
		result.path_segment_indices[index] = u32(index)
	}
	result.paths[0] = {
		id = 100,
		layer_index = 0,
		kind = .Loop,
		vertex_offset = 0,
		vertex_count = 4,
		segment_offset = 0,
		segment_count = 4,
		signed_area_2 = 2_000_000,
		winding = .Positive,
	}
	result.paths[1] = {
		id = 101,
		layer_index = 0,
		kind = .Loop,
		vertex_offset = 4,
		vertex_count = 4,
		segment_offset = 4,
		segment_count = 4,
		signed_area_2 = -80_000,
		winding = .Negative,
	}
	return result
}

perimeter_test_group_area_2 :: proc(
	result: Perimeter_Result,
	group_index: int,
) -> i128 {
	group := result.groups[group_index]
	area: i128
	start := int(group.path_offset)
	end := start+int(group.path_count)
	for path in result.paths[start:end] {
		area += path.signed_area_2
	}
	return area
}
