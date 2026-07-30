package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

@(test)
unified_path_plan_orders_roles_and_preserves_variable_widths_test :: proc(
	t: ^testing.T,
) {
	layer_ids := []contracts.Stable_ID{10}
	sources := unified_path_plan_test_sources()
	defer unified_path_plan_test_sources_destroy(sources)
	result, error := unified_path_plan_build(
		layer_ids,
		sources,
		unified_path_plan_test_config(),
	)
	defer unified_path_plan_result_destroy(&result)
	testing.expect_value(t, error, Unified_Path_Plan_Error.None)
	testing.expect_value(t, len(result.paths), 6)
	testing.expect_value(t, result.layers[0].path_count, u32(6))
	testing.expect_value(t, result.extrude_move_count, u64(10))
	testing.expect_value(t, result.travel_move_count, u64(6))
	expected_roles := []profiles.Printable_Role{
		.Perimeter,
		.Bridge,
		.Gap,
		.Top_Skin,
		.Sparse_Infill,
		.Support,
	}
	for path, path_index in result.paths {
		testing.expect_value(t, path.role, expected_roles[path_index])
		testing.expect_value(t, path.priority, u8(path_index+1))
		testing.expect_value(
			t,
			path.path_set_id,
			contracts.stable_id_child(
				path.source_id,
				.Feature,
				0,
			),
		)
		testing.expect_value(
			t,
			path.stable_id,
			contracts.stable_id_child(
				path.path_set_id,
				.Path,
				0,
			),
		)
	}
	gap_path := result.paths[2]
	testing.expect(t, gap_path.reversed)
	gap_moves := result.moves[
		gap_path.move_offset:
		gap_path.move_offset+u64(gap_path.move_count)
	]
	gap_extrude_start := 0
	if gap_moves[0].kind == .Travel {gap_extrude_start = 1}
	first := gap_moves[gap_extrude_start]
	second := gap_moves[gap_extrude_start+1]
	testing.expect_value(t, first.point_a, polygon.Polygon_Point{400, 100})
	testing.expect_value(t, first.point_b, polygon.Polygon_Point{400, 50})
	testing.expect_value(t, first.line_width_a, contracts.Micrometres(120))
	testing.expect_value(t, first.line_width_b, contracts.Micrometres(100))
	testing.expect_value(t, first.source_edge_index, u32(1))
	testing.expect_value(t, second.line_width_a, contracts.Micrometres(100))
	testing.expect_value(t, second.line_width_b, contracts.Micrometres(80))
	testing.expect_value(t, second.source_edge_index, u32(0))
	for move in result.moves {
		if move.kind == .Travel {
			testing.expect_value(t, move.role, profiles.Printable_Role.Invalid)
			testing.expect_value(t, move.line_width_a, contracts.Micrometres(0))
			testing.expect_value(t, move.line_width_b, contracts.Micrometres(0))
		} else {
			testing.expect(t, move.role != .Invalid)
			testing.expect(t, i64(move.line_width_a) > 0)
			testing.expect(t, i64(move.line_width_b) > 0)
		}
	}
}

@(test)
unified_path_plan_uses_source_order_within_one_priority_test :: proc(
	t: ^testing.T,
) {
	layer_ids := []contracts.Stable_ID{10}
	sources := make([]Unified_Path_Source, 2)
	sources[0] = unified_path_plan_test_line(
		1,
		.Gap,
		.Gap_Centerline,
		10,
		100,
		100,
	)
	sources[1] = unified_path_plan_test_line(
		2,
		.Thin_Wall,
		.Gap_Centerline,
		0,
		200,
		100,
	)
	defer unified_path_plan_test_sources_destroy(sources)
	result, error := unified_path_plan_build(
		layer_ids,
		sources,
		unified_path_plan_test_config(),
	)
	defer unified_path_plan_result_destroy(&result)
	testing.expect_value(t, error, Unified_Path_Plan_Error.None)
	testing.expect_value(t, result.paths[0].source_id, contracts.Stable_ID(2))
	testing.expect_value(t, result.paths[1].source_id, contracts.Stable_ID(1))
}

@(test)
unified_path_plan_scores_corner_then_rear_then_travel_for_seams_test :: proc(
	t: ^testing.T,
) {
	layer_ids := []contracts.Stable_ID{10}
	source := unified_path_plan_test_perimeter()
	defer {
		delete(source.points)
		delete(source.line_widths)
	}
	result, error := unified_path_plan_build(
		layer_ids,
		[]Unified_Path_Source{source},
		unified_path_plan_test_config(),
	)
	defer unified_path_plan_result_destroy(&result)
	testing.expect_value(t, error, Unified_Path_Plan_Error.None)
	testing.expect_value(t, result.paths[0].start_index, u32(3))
	testing.expect_value(
		t,
		result.moves[0].point_b,
		polygon.Polygon_Point{0, 50},
	)
}

@(test)
unified_path_plan_rejects_duplicate_source_ids_test :: proc(t: ^testing.T) {
	layer_ids := []contracts.Stable_ID{10}
	sources := make([]Unified_Path_Source, 2)
	sources[0] = unified_path_plan_test_line(
		1,
		.Bridge,
		.Bridge,
		0,
		100,
		100,
	)
	sources[1] = unified_path_plan_test_line(
		1,
		.Support,
		.Support,
		0,
		200,
		100,
	)
	defer unified_path_plan_test_sources_destroy(sources)
	result, error := unified_path_plan_build(
		layer_ids,
		sources,
		unified_path_plan_test_config(),
	)
	defer unified_path_plan_result_destroy(&result)
	testing.expect_value(t, error, Unified_Path_Plan_Error.Invalid_Input)
}

@(test)
unified_path_plan_hash_rejects_mutated_move_width_test :: proc(
	t: ^testing.T,
) {
	layer_ids := []contracts.Stable_ID{10}
	sources := unified_path_plan_test_sources()
	defer unified_path_plan_test_sources_destroy(sources)
	result, error := unified_path_plan_build(
		layer_ids,
		sources,
		unified_path_plan_test_config(),
	)
	defer unified_path_plan_result_destroy(&result)
	testing.expect_value(t, error, Unified_Path_Plan_Error.None)
	hash, hash_ok := unified_path_plan_result_hash(
		{},
		layer_ids,
		sources,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0x78, 0x4b, 0xd6, 0x1f, 0x4a, 0x95, 0x20, 0x2c,
		0xaf, 0xe2, 0x82, 0x65, 0xc3, 0xe3, 0x0a, 0x82,
		0x90, 0x29, 0x27, 0xb3, 0x40, 0xbc, 0x34, 0x94,
		0x53, 0xc6, 0xa3, 0x33, 0x42, 0xf8, 0xce, 0xb2,
	}
	testing.expect_value(t, hash, expected_hash)
	content_hash, content_hash_ok :=
		unified_path_plan_result_content_hash({}, result)
	testing.expect(t, content_hash_ok)
	testing.expect_value(t, content_hash, expected_hash)
	for &move in result.moves {
		if move.kind != .Extrude {continue}
		move.line_width_a += 1
		break
	}
	_, mutated_hash_ok := unified_path_plan_result_hash(
		{},
		layer_ids,
		sources,
		result,
	)
	testing.expect(t, !mutated_hash_ok)
	_, mutated_content_hash_ok :=
		unified_path_plan_result_content_hash({}, result)
	testing.expect(t, !mutated_content_hash_ok)
}

@(test)
unified_path_plan_content_hash_rejects_broken_move_chain_test :: proc(
	t: ^testing.T,
) {
	layer_ids := []contracts.Stable_ID{10}
	sources := unified_path_plan_test_sources()
	defer unified_path_plan_test_sources_destroy(sources)
	result, error := unified_path_plan_build(
		layer_ids,
		sources,
		unified_path_plan_test_config(),
	)
	defer unified_path_plan_result_destroy(&result)
	testing.expect_value(t, error, Unified_Path_Plan_Error.None)
	_, hash_ok := unified_path_plan_result_content_hash({}, result)
	testing.expect(t, hash_ok)
	path := result.paths[1]
	move_index := int(path.move_offset)
	if result.moves[move_index].kind == .Travel {
		move_index += 1
	}
	result.moves[move_index].path_id =
		contracts.INVALID_STABLE_ID
	_, corrupt_hash_ok :=
		unified_path_plan_result_content_hash({}, result)
	testing.expect(t, !corrupt_hash_ok)
}

unified_path_plan_test_sources :: proc() -> []Unified_Path_Source {
	result := make([]Unified_Path_Source, 6)
	result[0] = unified_path_plan_test_line(
		6,
		.Support,
		.Support,
		0,
		1_000,
		100,
	)
	result[1] = unified_path_plan_test_line(
		5,
		.Sparse_Infill,
		.Sparse_Infill,
		0,
		800,
		100,
	)
	result[2] = unified_path_plan_test_line(
		4,
		.Top_Skin,
		.Solid,
		0,
		600,
		100,
	)
	result[3] = unified_path_plan_test_polyline(
		3,
		.Gap,
		.Gap_Centerline,
		0,
		400,
		[]contracts.Micrometres{80, 100, 120},
	)
	result[4] = unified_path_plan_test_line(
		2,
		.Bridge,
		.Bridge,
		0,
		200,
		100,
	)
	result[5] = unified_path_plan_test_perimeter()
	return result
}

unified_path_plan_test_perimeter :: proc() -> Unified_Path_Source {
	result := Unified_Path_Source{
		stable_id = 1,
		layer_id = 10,
		role = .Perimeter,
		source_kind = .Perimeter,
		closed = true,
	}
	result.points = make([]polygon.Polygon_Point, 4)
	result.line_widths = make([]contracts.Micrometres, 4)
	copy(
		result.points,
		[]polygon.Polygon_Point{
			{0, 0},
			{50, 0},
			{50, 50},
			{0, 50},
		},
	)
	for &width in result.line_widths {width = 100}
	return result
}

unified_path_plan_test_line :: proc(
	stable_id: contracts.Stable_ID,
	role: profiles.Printable_Role,
	kind: Unified_Path_Source_Kind,
	source_order: u64,
	x: contracts.Micrometres,
	width: contracts.Micrometres,
) -> Unified_Path_Source {
	return unified_path_plan_test_polyline(
		stable_id,
		role,
		kind,
		source_order,
		x,
		[]contracts.Micrometres{width, width},
	)
}

unified_path_plan_test_polyline :: proc(
	stable_id: contracts.Stable_ID,
	role: profiles.Printable_Role,
	kind: Unified_Path_Source_Kind,
	source_order: u64,
	x: contracts.Micrometres,
	widths: []contracts.Micrometres,
) -> Unified_Path_Source {
	result := Unified_Path_Source{
		stable_id = stable_id,
		layer_id = 10,
		role = role,
		source_kind = kind,
		source_order = source_order,
	}
	result.points = make([]polygon.Polygon_Point, len(widths))
	result.line_widths = make([]contracts.Micrometres, len(widths))
	for &point, point_index in result.points {
		point = {
			x,
			contracts.Micrometres(
				point_index*100/(len(widths)-1),
			),
		}
	}
	copy(result.line_widths, widths)
	return result
}

unified_path_plan_test_sources_destroy :: proc(
	sources: []Unified_Path_Source,
) {
	for &source in sources {
		delete(source.points)
		delete(source.line_widths)
	}
	delete(sources)
}

unified_path_plan_test_config :: proc() -> Unified_Path_Plan_Config {
	return {
		start = {0, 0},
		seam = .Deterministic_Cost,
		seam_visibility = .Rear_Maximum_Y,
	}
}
