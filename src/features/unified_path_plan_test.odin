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
		{start = {0, 0}},
	)
	defer unified_path_plan_result_destroy(&result)
	testing.expect_value(t, error, Unified_Path_Plan_Error.None)
	testing.expect_value(t, len(result.paths), 6)
	testing.expect_value(t, result.layers[0].path_count, u32(6))
	testing.expect_value(t, result.extrude_move_count, u64(10))
	testing.expect_value(t, result.travel_move_count, u64(5))
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
		{start = {0, 0}},
	)
	defer unified_path_plan_result_destroy(&result)
	testing.expect_value(t, error, Unified_Path_Plan_Error.None)
	testing.expect_value(t, result.paths[0].source_id, contracts.Stable_ID(2))
	testing.expect_value(t, result.paths[1].source_id, contracts.Stable_ID(1))
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
		{start = {0, 0}},
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
		{start = {0, 0}},
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
		0x4d, 0x0d, 0x1b, 0xdc, 0x5d, 0xc6, 0xf3, 0x18,
		0x84, 0xce, 0x63, 0x26, 0xf6, 0xa1, 0xf0, 0x28,
		0xe1, 0x59, 0x87, 0x49, 0x0f, 0x3b, 0x12, 0xfd,
		0xbc, 0x01, 0x16, 0xfa, 0x27, 0x5e, 0x50, 0xde,
	}
	testing.expect_value(t, hash, expected_hash)
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
