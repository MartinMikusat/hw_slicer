package features

import "core:testing"
import "core:mem"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

@(test)
surfaces_classify_exposed_roofs_floors_and_step_rims_test :: proc(
	t: ^testing.T,
) {
	topology := surface_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Surface_Error.None)
	testing.expect_value(t, len(result.layers), 3)
	testing.expect_value(t, len(result.masks), 3)
	testing.expect_value(t, result.bottom_mask_count, u64(1))
	testing.expect_value(t, result.top_mask_count, u64(2))
	testing.expect_value(
		t,
		result.masks[0].kind,
		Surface_Kind.Bottom_Exposed,
	)
	testing.expect_value(t, result.masks[0].layer_index, u32(0))
	testing.expect_value(t, result.masks[1].kind, Surface_Kind.Top_Exposed)
	testing.expect_value(t, result.masks[1].layer_index, u32(1))
	testing.expect_value(t, result.masks[1].path_count, u32(2))
	testing.expect_value(t, result.masks[2].kind, Surface_Kind.Top_Exposed)
	testing.expect_value(t, result.masks[2].layer_index, u32(2))
	testing.expect_value(
		t,
		surface_test_mask_area_2(result, 0),
		i128(2_000_000),
	)
	testing.expect_value(
		t,
		surface_test_mask_area_2(result, 1),
		i128(1_280_000),
	)
	testing.expect_value(
		t,
		surface_test_mask_area_2(result, 2),
		i128(720_000),
	)
	region_hash, region_hash_ok := slicing.region_result_hash(
		contracts.Content_Hash{},
		topology,
		regions,
	)
	hash, hash_ok := surface_result_hash(region_hash, result)
	testing.expect(t, region_hash_ok)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0x43, 0xa6, 0x48, 0x04, 0x6f, 0x8e, 0xb4, 0x02,
		0x0e, 0xdd, 0xc2, 0xb5, 0xee, 0x48, 0x4f, 0x04,
		0x24, 0x5f, 0xa4, 0x11, 0x57, 0x8a, 0xad, 0xb2,
		0x4b, 0x13, 0xc8, 0x3d, 0x59, 0x5e, 0x2f, 0x8f,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
surfaces_preserve_both_exposures_on_a_single_layer_test :: proc(
	t: ^testing.T,
) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Surface_Error.None)
	testing.expect_value(t, len(result.masks), 2)
	testing.expect_value(t, result.bottom_mask_count, u64(1))
	testing.expect_value(t, result.top_mask_count, u64(1))
	testing.expect_value(
		t,
		surface_test_mask_area_2(result, 0),
		i128(1_920_000),
	)
	testing.expect_value(
		t,
		surface_test_mask_area_2(result, 1),
		i128(1_920_000),
	)
}

@(test)
surfaces_classify_a_hole_opening_against_a_solid_layer_test :: proc(
	t: ^testing.T,
) {
	layer_path_counts := [?]u32{1, 2}
	path_points := [?][4]slicing.Snapped_Point{
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
		{{400, 400}, {400, 600}, {600, 600}, {600, 400}},
	}
	topology := surface_rect_topology(
		layer_path_counts[:],
		path_points[:],
	)
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Surface_Error.None)
	testing.expect_value(t, len(result.masks), 3)
	testing.expect_value(t, result.bottom_mask_count, u64(1))
	testing.expect_value(t, result.top_mask_count, u64(2))
	testing.expect_value(
		t,
		surface_test_mask_area_2(result, 0),
		i128(2_000_000),
	)
	testing.expect_value(
		t,
		surface_test_mask_area_2(result, 1),
		i128(80_000),
	)
	testing.expect_value(
		t,
		surface_test_mask_area_2(result, 2),
		i128(1_920_000),
	)
}

@(test)
surfaces_keep_empty_layers_and_expose_both_sides_of_a_gap_test :: proc(
	t: ^testing.T,
) {
	layer_path_counts := [?]u32{1, 0, 1}
	path_points := [?][4]slicing.Snapped_Point{
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
	}
	topology := surface_rect_topology(
		layer_path_counts[:],
		path_points[:],
	)
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Surface_Error.None)
	testing.expect_value(t, len(result.layers), 3)
	testing.expect_value(t, result.layers[1].mask_count, u32(0))
	testing.expect_value(t, result.layers[1].path_count, u32(0))
	testing.expect_value(t, len(result.masks), 4)
	testing.expect_value(t, result.bottom_mask_count, u64(2))
	testing.expect_value(t, result.top_mask_count, u64(2))
	for mask_index in 0..<len(result.masks) {
		testing.expect_value(
			t,
			surface_test_mask_area_2(result, mask_index),
			i128(2_000_000),
		)
	}
}

@(test)
surfaces_preserve_an_empty_schedule_as_a_valid_empty_result_test :: proc(
	t: ^testing.T,
) {
	layer_path_counts := [?]u32{0, 0}
	topology := surface_rect_topology(layer_path_counts[:], nil)
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&result)
	region_hash, region_hash_ok := slicing.region_result_hash(
		{},
		topology,
		regions,
	)
	_, surface_hash_ok := surface_result_hash(region_hash, result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Surface_Error.None)
	testing.expect_value(t, len(result.layers), 2)
	testing.expect_value(t, len(result.masks), 0)
	testing.expect_value(t, len(result.paths), 0)
	testing.expect_value(t, len(result.points), 0)
	testing.expect(t, region_hash_ok)
	testing.expect(t, surface_hash_ok)
}

@(test)
surfaces_subtract_the_aggregate_of_split_adjacent_regions_test :: proc(
	t: ^testing.T,
) {
	layer_path_counts := [?]u32{2, 1}
	path_points := [?][4]slicing.Snapped_Point{
		{{0, 0}, {400, 0}, {400, 1_000}, {0, 1_000}},
		{{600, 0}, {1_000, 0}, {1_000, 1_000}, {600, 1_000}},
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
	}
	topology := surface_rect_topology(
		layer_path_counts[:],
		path_points[:],
	)
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Surface_Error.None)
	testing.expect_value(t, len(regions.regions), 3)
	testing.expect_value(t, len(result.masks), 4)
	testing.expect_value(t, result.bottom_mask_count, u64(3))
	testing.expect_value(t, result.top_mask_count, u64(1))
	expected_areas := [?]i128{
		800_000,
		800_000,
		400_000,
		2_000_000,
	}
	for expected, mask_index in expected_areas {
		testing.expect_value(
			t,
			surface_test_mask_area_2(result, mask_index),
			expected,
		)
	}
}

@(test)
surfaces_skip_boolean_work_for_identical_adjacent_regions_test :: proc(
	t: ^testing.T,
) {
	layer_path_counts := [?]u32{1, 1, 1}
	path_points := [?][4]slicing.Snapped_Point{
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
	}
	topology := surface_rect_topology(
		layer_path_counts[:],
		path_points[:],
	)
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	provider := polygon.Polygon_Provider{
		name = "identity-shortcut-test",
		version = {1, 0, 0},
		boolean = surface_identity_test_boolean,
	}
	result, error := surfaces_classify(
		topology,
		regions,
		provider,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Surface_Error.None)
	testing.expect_value(t, len(result.masks), 2)
	testing.expect_value(t, result.bottom_mask_count, u64(1))
	testing.expect_value(t, result.top_mask_count, u64(1))
}

@(test)
surfaces_enforce_strict_topology_and_output_limits_test :: proc(
	t: ^testing.T,
) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	topology.non_manifold_vertex_count = 1
	strict_result, strict_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&strict_result)
	diagnostic_result, diagnostic_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Diagnostic_Closed_Regions,
		},
	)
	defer surface_result_destroy(&diagnostic_result)
	limited_result, limited_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Diagnostic_Closed_Regions,
		},
		{
			max_masks = 1,
			max_paths = 10,
			max_points = 100,
			polygon = polygon.DEFAULT_POLYGON_LIMITS,
		},
	)
	defer surface_result_destroy(&limited_result)
	path_limited_result, path_limited_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Diagnostic_Closed_Regions,
		},
		{
			max_masks = 10,
			max_paths = 1,
			max_points = 100,
			polygon = polygon.DEFAULT_POLYGON_LIMITS,
		},
	)
	defer surface_result_destroy(&path_limited_result)
	point_limited_result, point_limited_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Diagnostic_Closed_Regions,
		},
		{
			max_masks = 10,
			max_paths = 10,
			max_points = 7,
			polygon = polygon.DEFAULT_POLYGON_LIMITS,
		},
	)
	defer surface_result_destroy(&point_limited_result)
	invalid_result, invalid_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = transmute(polygon.Polygon_Fill_Rule)u8(255),
			topology_policy = .Diagnostic_Closed_Regions,
		},
	)
	defer surface_result_destroy(&invalid_result)
	missing_provider_result, missing_provider_error := surfaces_classify(
		topology,
		regions,
		{},
		{
			fill_rule = .Even_Odd,
			topology_policy = .Diagnostic_Closed_Regions,
		},
	)
	defer surface_result_destroy(&missing_provider_result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, strict_error, Surface_Error.Invalid_Input)
	testing.expect_value(t, diagnostic_error, Surface_Error.None)
	testing.expect_value(t, limited_error, Surface_Error.Mask_Limit)
	testing.expect_value(t, path_limited_error, Surface_Error.Path_Limit)
	testing.expect_value(t, point_limited_error, Surface_Error.Point_Limit)
	testing.expect_value(t, invalid_error, Surface_Error.Invalid_Config)
	testing.expect_value(
		t,
		missing_provider_error,
		Surface_Error.Invalid_Config,
	)
}

@(test)
surfaces_reject_negative_fill_for_positive_region_inputs_test :: proc(
	t: ^testing.T,
) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	even_odd, even_odd_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&even_odd)
	non_zero, non_zero_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Non_Zero,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&non_zero)
	positive, positive_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Positive,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&positive)
	negative, negative_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Negative,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&negative)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, even_odd_error, Surface_Error.None)
	testing.expect_value(t, non_zero_error, Surface_Error.None)
	testing.expect_value(t, positive_error, Surface_Error.None)
	testing.expect_value(t, negative_error, Surface_Error.Invalid_Config)
	testing.expect_value(t, len(even_odd.masks), 2)
	testing.expect_value(t, len(non_zero.masks), 2)
	testing.expect_value(t, len(positive.masks), 2)
	for mask_index in 0..<len(even_odd.masks) {
		expected_area := surface_test_mask_area_2(even_odd, mask_index)
		testing.expect_value(
			t,
			surface_test_mask_area_2(non_zero, mask_index),
			expected_area,
		)
		testing.expect_value(
			t,
			surface_test_mask_area_2(positive, mask_index),
			expected_area,
		)
	}
}

@(test)
surface_hash_rejects_mutated_mask_spans_test :: proc(t: ^testing.T) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	defer surface_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Surface_Error.None)
	if len(result.masks) == 0 {return}
	result.masks[0].point_offset += 1
	_, hash_ok := surface_result_hash(contracts.Content_Hash{}, result)
	testing.expect(t, !hash_ok)
}

surface_test_topology :: proc() -> slicing.Topology_Result {
	layer_points := [3][4]slicing.Snapped_Point{
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
		{{200, 200}, {800, 200}, {800, 800}, {200, 800}},
	}
	result: slicing.Topology_Result
	result.layers = make([]slicing.Topology_Layer, len(layer_points))
	result.vertices = make([]slicing.Topology_Vertex, len(layer_points)*4)
	result.paths = make([]slicing.Topology_Path, len(layer_points))
	result.path_vertex_indices = make([]u32, len(layer_points)*4)
	result.path_segment_indices = make([]u32, len(layer_points)*4)
	for points, layer_index in layer_points {
		offset := layer_index*4
		result.layers[layer_index] = {
			vertex_offset = u64(offset),
			vertex_count = 4,
			path_offset = u64(layer_index),
			path_count = 1,
		}
		for point, local_index in points {
			index := offset+local_index
			result.vertices[index] = {
				id = contracts.Stable_ID(index+1),
				layer_index = u32(layer_index),
				point = point,
				degree = 2,
			}
			result.path_vertex_indices[index] = u32(index)
			result.path_segment_indices[index] = u32(index)
		}
		result.paths[layer_index] = {
			id = contracts.Stable_ID(100+layer_index),
			layer_index = u32(layer_index),
			kind = .Loop,
			vertex_offset = u64(offset),
			vertex_count = 4,
			segment_offset = u64(offset),
			segment_count = 4,
			signed_area_2 = 2_000_000,
			winding = .Positive,
		}
		if layer_index == 2 {
			result.paths[layer_index].signed_area_2 = 720_000
		}
	}
	return result
}

surface_identity_test_boolean :: proc(
	subjects, clips: polygon.Polygon_Set,
	operation: polygon.Polygon_Operation,
	fill_rule: polygon.Polygon_Fill_Rule,
	limits: polygon.Polygon_Limits,
	allocator: mem.Allocator,
) -> (polygon.Polygon_Set, polygon.Polygon_Error) {
	if len(clips.paths) > 0 {
		return {}, .Provider_Failed
	}
	return polygon.CLIPPER2_PROVIDER.boolean(
		subjects,
		clips,
		operation,
		fill_rule,
		limits,
		allocator,
	)
}

surface_rect_topology :: proc(
	layer_path_counts: []u32,
	path_points: [][4]slicing.Snapped_Point,
) -> slicing.Topology_Result {
	path_count: u64
	for count in layer_path_counts {
		path_count += u64(count)
	}
	if path_count != u64(len(path_points)) ||
	   path_count > u64(max(int))/4 {
		return {}
	}
	result: slicing.Topology_Result
	result.layers = make(
		[]slicing.Topology_Layer,
		len(layer_path_counts),
	)
	result.vertices = make(
		[]slicing.Topology_Vertex,
		int(path_count)*4,
	)
	result.paths = make([]slicing.Topology_Path, int(path_count))
	result.path_vertex_indices = make([]u32, int(path_count)*4)
	result.path_segment_indices = make([]u32, int(path_count)*4)
	path_write := 0
	for count, layer_index in layer_path_counts {
		vertex_offset := path_write*4
		result.layers[layer_index] = {
			vertex_offset = u64(vertex_offset),
			vertex_count = count*4,
			path_offset = u64(path_write),
			path_count = count,
		}
		for _ in 0..<count {
			points := path_points[path_write]
			signed_area_2: i128
			previous := points[len(points)-1]
			for point, local_index in points {
				vertex_index := path_write*4+local_index
				result.vertices[vertex_index] = {
					id = contracts.Stable_ID(vertex_index+1),
					layer_index = u32(layer_index),
					point = point,
					degree = 2,
				}
				result.path_vertex_indices[vertex_index] =
					u32(vertex_index)
				result.path_segment_indices[vertex_index] =
					u32(vertex_index)
				signed_area_2 +=
					i128(i64(previous.x))*i128(i64(point.y))-
					i128(i64(previous.y))*i128(i64(point.x))
				previous = point
			}
			winding := geometry.Predicate_Sign.Positive
			if signed_area_2 < 0 {
				winding = .Negative
			}
			result.paths[path_write] = {
				id = contracts.Stable_ID(100+path_write),
				layer_index = u32(layer_index),
				kind = .Loop,
				vertex_offset = u64(path_write*4),
				vertex_count = 4,
				segment_offset = u64(path_write*4),
				segment_count = 4,
				signed_area_2 = signed_area_2,
				winding = winding,
			}
			path_write += 1
		}
	}
	return result
}

surface_test_mask_area_2 :: proc(
	result: Surface_Result,
	mask_index: int,
) -> i128 {
	mask := result.masks[mask_index]
	area: i128
	start := int(mask.path_offset)
	end := start+int(mask.path_count)
	for path in result.paths[start:end] {
		area += path.signed_area_2
	}
	return area
}
