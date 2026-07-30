package polygon

import "core:testing"

import contracts "../contracts"
import geometry "../geometry"

@(test)
clipper2_boolean_operations_match_rectangle_areas_test :: proc(
	t: ^testing.T,
) {
	subject_points := [?]Polygon_Point{
		{0, 0}, {100, 0}, {100, 100}, {0, 100},
	}
	clip_points := [?]Polygon_Point{
		{50, 0}, {150, 0}, {150, 100}, {50, 100},
	}
	path := [?]Polygon_Path{{0, 4}}
	subjects := Polygon_Set{subject_points[:], path[:]}
	clips := Polygon_Set{clip_points[:], path[:]}
	operations := [?]Polygon_Operation{
		.Intersection,
		.Union,
		.Difference,
		.Xor,
	}
	expected_areas := [?]i128{10_000, 30_000, 10_000, 20_000}
	expected_paths := [?]int{1, 1, 1, 2}
	for operation, index in operations {
		result, error := clipper2_boolean(
			subjects,
			clips,
			operation,
			.Non_Zero,
		)
		testing.expect_value(t, error, Polygon_Error.None)
		testing.expect_value(t, len(result.paths), expected_paths[index])
		testing.expect_value(
			t,
			polygon_test_signed_area_2(result),
			expected_areas[index],
		)
		result_hash, hash_ok := polygon_set_hash(result)
		testing.expect(t, hash_ok)
		testing.expect(
			t,
			result_hash != contracts.Content_Hash{},
		)
		if index == 0 {
			expected_hash := contracts.Content_Hash{
				0xe5, 0xa7, 0x48, 0x13, 0x03, 0xf9, 0xa5, 0xc4,
				0xd3, 0x37, 0xe2, 0x08, 0x3d, 0x91, 0xbf, 0xcd,
				0x37, 0xc2, 0x04, 0x1b, 0x59, 0x0d, 0xb4, 0xf8,
				0x5e, 0x86, 0xf3, 0x6c, 0xb6, 0xee, 0xfe, 0x58,
			}
			testing.expect_value(
				t,
				result_hash,
				expected_hash,
			)
		}
		polygon_set_destroy(&result)
	}
}

@(test)
clipper2_provider_contract_exposes_pinned_operations_test :: proc(
	t: ^testing.T,
) {
	points := [?]Polygon_Point{
		{0, 0}, {100, 0}, {100, 100}, {0, 100},
	}
	paths := [?]Polygon_Path{{0, 4}}
	empty: Polygon_Set
	result, error := CLIPPER2_PROVIDER.boolean(
		{points[:], paths[:]},
		empty,
		.Union,
		.Non_Zero,
		DEFAULT_POLYGON_LIMITS,
		context.allocator,
	)
	defer polygon_set_destroy(&result)
	testing.expect_value(t, CLIPPER2_PROVIDER.name, "Clipper2")
	testing.expect_value(
		t,
		CLIPPER2_PROVIDER.version,
		contracts.Semantic_Version{2, 0, 1},
	)
	testing.expect_value(t, error, Polygon_Error.None)
	testing.expect_value(
		t,
		polygon_test_signed_area_2(result),
		i128(20_000),
	)
}

@(test)
clipper2_canonicalizes_rotated_and_reordered_inputs_test :: proc(
	t: ^testing.T,
) {
	points_a := [?]Polygon_Point{
		{10, 10}, {0, 10}, {0, 0}, {10, 0},
		{30, 0}, {40, 0}, {40, 10}, {30, 10},
	}
	points_b := [?]Polygon_Point{
		{40, 10}, {30, 10}, {30, 0}, {40, 0},
		{0, 0}, {10, 0}, {10, 10}, {0, 10},
	}
	paths := [?]Polygon_Path{{0, 4}, {4, 4}}
	empty: Polygon_Set
	result_a, error_a := clipper2_boolean(
		{points_a[:], paths[:]},
		empty,
		.Union,
		.Non_Zero,
	)
	defer polygon_set_destroy(&result_a)
	result_b, error_b := clipper2_boolean(
		{points_b[:], paths[:]},
		empty,
		.Union,
		.Non_Zero,
	)
	defer polygon_set_destroy(&result_b)
	testing.expect_value(t, error_a, Polygon_Error.None)
	testing.expect_value(t, error_b, Polygon_Error.None)
	testing.expect_value(t, len(result_a.points), len(result_b.points))
	testing.expect_value(t, len(result_a.paths), len(result_b.paths))
	if len(result_a.points) == len(result_b.points) {
		for point, index in result_a.points {
			testing.expect_value(t, result_b.points[index], point)
		}
	}
	if len(result_a.paths) == len(result_b.paths) {
		for path, index in result_a.paths {
			testing.expect_value(t, result_b.paths[index], path)
		}
	}
}

@(test)
clipper2_applies_even_odd_and_non_zero_fill_rules_test :: proc(
	t: ^testing.T,
) {
	points := [?]Polygon_Point{
		{0, 0}, {100, 0}, {100, 100}, {0, 100},
		{0, 0}, {100, 0}, {100, 100}, {0, 100},
	}
	paths := [?]Polygon_Path{{0, 4}, {4, 4}}
	input := Polygon_Set{points[:], paths[:]}
	empty: Polygon_Set
	even_odd, even_odd_error := clipper2_boolean(
		input,
		empty,
		.Union,
		.Even_Odd,
	)
	defer polygon_set_destroy(&even_odd)
	non_zero, non_zero_error := clipper2_boolean(
		input,
		empty,
		.Union,
		.Non_Zero,
	)
	defer polygon_set_destroy(&non_zero)
	testing.expect_value(t, even_odd_error, Polygon_Error.None)
	testing.expect_value(t, non_zero_error, Polygon_Error.None)
	testing.expect_value(t, len(even_odd.paths), 0)
	testing.expect_value(t, len(non_zero.paths), 1)
	testing.expect_value(
		t,
		polygon_test_signed_area_2(non_zero),
		i128(20_000),
	)
}

@(test)
clipper2_handles_shared_edges_and_touching_vertices_test :: proc(
	t: ^testing.T,
) {
	subject_points := [?]Polygon_Point{
		{0, 0}, {100, 0}, {100, 100}, {0, 100},
	}
	shared_edge_points := [?]Polygon_Point{
		{100, 0}, {200, 0}, {200, 100}, {100, 100},
	}
	touching_vertex_points := [?]Polygon_Point{
		{100, 100}, {200, 100}, {200, 200}, {100, 200},
	}
	path := [?]Polygon_Path{{0, 4}}
	empty_intersection, shared_error := clipper2_boolean(
		{subject_points[:], path[:]},
		{shared_edge_points[:], path[:]},
		.Intersection,
		.Non_Zero,
	)
	defer polygon_set_destroy(&empty_intersection)
	touching_intersection, touching_error := clipper2_boolean(
		{subject_points[:], path[:]},
		{touching_vertex_points[:], path[:]},
		.Intersection,
		.Non_Zero,
	)
	defer polygon_set_destroy(&touching_intersection)
	shared_union, union_error := clipper2_boolean(
		{subject_points[:], path[:]},
		{shared_edge_points[:], path[:]},
		.Union,
		.Non_Zero,
	)
	defer polygon_set_destroy(&shared_union)
	testing.expect_value(t, shared_error, Polygon_Error.None)
	testing.expect_value(t, touching_error, Polygon_Error.None)
	testing.expect_value(t, union_error, Polygon_Error.None)
	testing.expect_value(t, len(empty_intersection.paths), 0)
	testing.expect_value(t, len(touching_intersection.paths), 0)
	testing.expect_value(t, len(shared_union.paths), 1)
	testing.expect_value(
		t,
		polygon_test_signed_area_2(shared_union),
		i128(40_000),
	)
}

@(test)
clipper2_preserves_holes_and_splits_thin_channels_test :: proc(
	t: ^testing.T,
) {
	donut_points := [?]Polygon_Point{
		{0, 0}, {200, 0}, {200, 200}, {0, 200},
		{50, 50}, {50, 150}, {150, 150}, {150, 50},
	}
	donut_paths := [?]Polygon_Path{{0, 4}, {4, 4}}
	strip_points := [?]Polygon_Point{
		{100, 0}, {250, 0}, {250, 200}, {100, 200},
	}
	strip_path := [?]Polygon_Path{{0, 4}}
	intersection, intersection_error := clipper2_boolean(
		{donut_points[:], donut_paths[:]},
		{strip_points[:], strip_path[:]},
		.Intersection,
		.Non_Zero,
	)
	defer polygon_set_destroy(&intersection)

	channel_subject_points := [?]Polygon_Point{
		{0, 0}, {200, 0}, {200, 100}, {0, 100},
	}
	channel_clip_points := [?]Polygon_Point{
		{80, 0}, {120, 0}, {120, 100}, {80, 100},
	}
	split, split_error := clipper2_boolean(
		{channel_subject_points[:], strip_path[:]},
		{channel_clip_points[:], strip_path[:]},
		.Difference,
		.Non_Zero,
	)
	defer polygon_set_destroy(&split)
	testing.expect_value(t, intersection_error, Polygon_Error.None)
	testing.expect_value(t, split_error, Polygon_Error.None)
	testing.expect_value(t, len(intersection.paths), 1)
	testing.expect_value(
		t,
		polygon_test_signed_area_2(intersection),
		i128(30_000),
	)
	testing.expect_value(t, len(split.paths), 2)
	testing.expect_value(
		t,
		polygon_test_signed_area_2(split),
		i128(32_000),
	)
}

@(test)
clipper2_resolves_self_intersections_under_both_fill_rules_test :: proc(
	t: ^testing.T,
) {
	bow_tie_points := [?]Polygon_Point{
		{0, 0}, {100, 100}, {0, 100}, {100, 0},
	}
	path := [?]Polygon_Path{{0, 4}}
	empty: Polygon_Set
	fill_rules := [?]Polygon_Fill_Rule{.Even_Odd, .Non_Zero}
	for fill_rule in fill_rules {
		result, error := clipper2_boolean(
			{bow_tie_points[:], path[:]},
			empty,
			.Union,
			fill_rule,
		)
		testing.expect_value(t, error, Polygon_Error.None)
		testing.expect_value(t, len(result.paths), 2)
		testing.expect_value(
			t,
			polygon_test_signed_area_2(result),
			i128(10_000),
		)
		_, hash_ok := polygon_set_hash(result)
		testing.expect(t, hash_ok)
		polygon_set_destroy(&result)
	}
}

@(test)
clipper2_offsets_outer_and_hole_contours_test :: proc(t: ^testing.T) {
	points := [?]Polygon_Point{
		{0, 0}, {100, 0}, {100, 100}, {0, 100},
		{30, 30}, {30, 70}, {70, 70}, {70, 30},
	}
	paths := [?]Polygon_Path{{0, 4}, {4, 4}}
	input := Polygon_Set{points[:], paths[:]}
	expanded, expanded_error := clipper2_offset(
		input,
		10,
		.Miter,
		2,
		0,
	)
	defer polygon_set_destroy(&expanded)
	contracted, contracted_error := clipper2_offset(
		input,
		-10,
		.Miter,
		2,
		0,
	)
	defer polygon_set_destroy(&contracted)
	testing.expect_value(t, expanded_error, Polygon_Error.None)
	testing.expect_value(t, contracted_error, Polygon_Error.None)
	testing.expect_value(t, len(expanded.paths), 2)
	testing.expect_value(t, len(contracted.paths), 2)
	testing.expect_value(
		t,
		polygon_test_signed_area_2(expanded),
		i128(28_000),
	)
	testing.expect_value(
		t,
		polygon_test_signed_area_2(contracted),
		i128(5_600),
	)
}

@(test)
clipper2_applies_all_closed_polygon_join_types_test :: proc(
	t: ^testing.T,
) {
	points := [?]Polygon_Point{
		{0, 0}, {100, 0}, {100, 100}, {0, 100},
	}
	paths := [?]Polygon_Path{{0, 4}}
	areas: [4]i128
	join_types := [?]Polygon_Join_Type{
		.Square,
		.Bevel,
		.Round,
		.Miter,
	}
	for join_type in join_types {
		result, error := clipper2_offset(
			{points[:], paths[:]},
			10,
			join_type,
			2,
			1,
		)
		testing.expect_value(t, error, Polygon_Error.None)
		testing.expect_value(t, len(result.paths), 1)
		areas[int(join_type)] = polygon_test_signed_area_2(result)
		_, hash_ok := polygon_set_hash(result)
		testing.expect(t, hash_ok)
		polygon_set_destroy(&result)
	}
	testing.expect_value(t, areas[int(Polygon_Join_Type.Miter)], i128(28_800))
	testing.expect_value(t, areas[int(Polygon_Join_Type.Bevel)], i128(28_400))
	testing.expect(
		t,
		areas[int(Polygon_Join_Type.Square)] >
			areas[int(Polygon_Join_Type.Bevel)] &&
		areas[int(Polygon_Join_Type.Square)] <
			areas[int(Polygon_Join_Type.Miter)],
	)
	testing.expect(
		t,
		areas[int(Polygon_Join_Type.Round)] >
			areas[int(Polygon_Join_Type.Bevel)] &&
		areas[int(Polygon_Join_Type.Round)] <
			areas[int(Polygon_Join_Type.Miter)],
	)
}

@(test)
clipper2_enforces_input_output_and_coordinate_limits_test :: proc(
	t: ^testing.T,
) {
	points := [?]Polygon_Point{
		{0, 0}, {100, 0}, {100, 100}, {0, 100},
	}
	paths := [?]Polygon_Path{{0, 4}}
	input := Polygon_Set{points[:], paths[:]}
	empty: Polygon_Set
	_, input_limit_error := clipper2_boolean(
		input,
		empty,
		.Union,
		.Non_Zero,
		{
			max_input_points = 3,
			max_input_paths = 1,
			max_output_points = 10,
			max_output_paths = 10,
		},
	)
	_, output_limit_error := clipper2_boolean(
		input,
		empty,
		.Union,
		.Non_Zero,
		{
			max_input_points = 4,
			max_input_paths = 1,
			max_output_points = 3,
			max_output_paths = 1,
		},
	)
	out_of_range_points := points
	out_of_range_points[0].x = contracts.Micrometres(
		geometry.MAX_PLANAR_COORDINATE_UM+1,
	)
	_, range_error := clipper2_boolean(
		{out_of_range_points[:], paths[:]},
		empty,
		.Union,
		.Non_Zero,
	)
	invalid_paths := [?]Polygon_Path{{1, 3}}
	_, span_error := clipper2_boolean(
		{points[:], invalid_paths[:]},
		empty,
		.Union,
		.Non_Zero,
	)
	_, delta_range_error := clipper2_offset(
		input,
		contracts.Micrometres(geometry.MAX_PLANAR_COORDINATE_UM+1),
		.Miter,
		2,
		0,
	)
	underflow_paths := [?]Polygon_Path{
		{0, 4},
		{u64(max(int))+1, 3},
	}
	_, underflow_span_error := clipper2_boolean(
		{points[:], underflow_paths[:]},
		empty,
		.Union,
		.Non_Zero,
	)
	testing.expect_value(t, input_limit_error, Polygon_Error.Input_Limit)
	testing.expect_value(t, output_limit_error, Polygon_Error.Output_Limit)
	testing.expect_value(t, range_error, Polygon_Error.Coordinate_Range)
	testing.expect_value(t, span_error, Polygon_Error.Invalid_Input)
	testing.expect_value(
		t,
		delta_range_error,
		Polygon_Error.Coordinate_Range,
	)
	testing.expect_value(
		t,
		underflow_span_error,
		Polygon_Error.Invalid_Input,
	)
	testing.expect(t, clipper2_version_valid())
}

@(test)
polygon_hash_rejects_noncanonical_and_invalid_spans_test :: proc(
	t: ^testing.T,
) {
	rotated_points := [?]Polygon_Point{
		{100, 0}, {100, 100}, {0, 100}, {0, 0},
	}
	valid_path := [?]Polygon_Path{{0, 4}}
	_, rotated_ok := polygon_set_hash({
		rotated_points[:],
		valid_path[:],
	})
	underflow_path := [?]Polygon_Path{{u64(max(int))+1, 3}}
	_, underflow_ok := polygon_set_hash({
		rotated_points[:],
		underflow_path[:],
	})
	repeated_minimum_points := [?]Polygon_Point{
		{0, 0}, {10, 0}, {0, 0}, {0, 10},
	}
	_, repeated_minimum_ok := polygon_set_hash({
		repeated_minimum_points[:],
		valid_path[:],
	})
	testing.expect(t, !rotated_ok)
	testing.expect(t, !underflow_ok)
	testing.expect(t, !repeated_minimum_ok)
}

polygon_test_signed_area_2 :: proc(set: Polygon_Set) -> i128 {
	area: i128
	for path in set.paths {
		start := int(path.offset)
		end := start+int(path.count)
		area += polygon_path_area_2(set.points[start:end])
	}
	return area
}
