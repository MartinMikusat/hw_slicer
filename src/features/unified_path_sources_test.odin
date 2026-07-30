package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

@(test)
unified_path_sources_adapt_all_generated_path_stages_test :: proc(
	t: ^testing.T,
) {
	perimeters, bridges, gaps, solids, infill, supports, process :=
		unified_path_source_test_inputs()
	defer unified_path_source_test_inputs_destroy(
		&perimeters,
		&bridges,
		&gaps,
		&solids,
		&infill,
		&supports,
	)
	layer_ids := []contracts.Stable_ID{10}
	result, error := unified_path_sources_build(
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		true,
	)
	defer unified_path_source_result_destroy(&result)
	testing.expect_value(t, error, Unified_Path_Source_Error.None)
	testing.expect_value(t, len(result.sources), 7)
	testing.expect_value(t, len(result.points), 19)
	testing.expect_value(t, result.layers[0].source_count, u32(7))
	testing.expect_value(t, result.layers[0].point_count, u32(19))
	testing.expect_value(t, result.sources[0].role, profiles.Printable_Role.Perimeter)
	testing.expect_value(t, result.sources[0].source_index, u32(1))
	testing.expect_value(t, result.sources[1].source_index, u32(0))
	testing.expect_value(t, result.sources[2].role, profiles.Printable_Role.Bridge)
	testing.expect_value(t, result.sources[3].role, profiles.Printable_Role.Gap)
	testing.expect_value(t, result.sources[4].role, profiles.Printable_Role.Top_Skin)
	testing.expect_value(
		t,
		result.sources[5].role,
		profiles.Printable_Role.Sparse_Infill,
	)
	testing.expect_value(t, result.sources[6].role, profiles.Printable_Role.Support)
	testing.expect_value(
		t,
		result.sources[3].line_widths[0],
		contracts.Micrometres(80),
	)
	testing.expect_value(
		t,
		result.sources[3].line_widths[2],
		contracts.Micrometres(120),
	)
	plan, plan_error := unified_path_plan_build(
		layer_ids,
		result.sources,
		unified_path_plan_test_config(),
	)
	defer unified_path_plan_result_destroy(&plan)
	testing.expect_value(t, plan_error, Unified_Path_Plan_Error.None)
	testing.expect_value(t, len(plan.paths), 7)
	testing.expect_value(t, plan.extrude_move_count, u64(14))
	for path, path_index in plan.paths {
		testing.expect_value(
			t,
			path.source_id,
			result.sources[path_index].stable_id,
		)
	}
}

@(test)
unified_path_sources_reject_mismatched_stage_layer_test :: proc(
	t: ^testing.T,
) {
	perimeters, bridges, gaps, solids, infill, supports, process :=
		unified_path_source_test_inputs()
	defer unified_path_source_test_inputs_destroy(
		&perimeters,
		&bridges,
		&gaps,
		&solids,
		&infill,
		&supports,
	)
	bridges.paths[0].layer_index = 1
	result, error := unified_path_sources_build(
		[]contracts.Stable_ID{10},
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		true,
	)
	defer unified_path_source_result_destroy(&result)
	testing.expect_value(t, error, Unified_Path_Source_Error.Invalid_Input)
}

@(test)
unified_path_source_hash_rejects_mutated_point_test :: proc(t: ^testing.T) {
	perimeters, bridges, gaps, solids, infill, supports, process :=
		unified_path_source_test_inputs()
	defer unified_path_source_test_inputs_destroy(
		&perimeters,
		&bridges,
		&gaps,
		&solids,
		&infill,
		&supports,
	)
	layer_ids := []contracts.Stable_ID{10}
	result, error := unified_path_sources_build(
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		true,
	)
	defer unified_path_source_result_destroy(&result)
	testing.expect_value(t, error, Unified_Path_Source_Error.None)
	hash, hash_ok := unified_path_source_result_hash(
		{},
		{},
		{},
		{},
		{},
		{},
		{},
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0xdd, 0x71, 0xe5, 0x4c, 0x99, 0x28, 0x7f, 0xa4,
		0x47, 0x9b, 0x23, 0xab, 0x2c, 0x3b, 0x0e, 0xd1,
		0x13, 0x1b, 0x60, 0xb5, 0x16, 0x8f, 0x47, 0x02,
		0xe4, 0x30, 0x4e, 0x8f, 0x3c, 0xbf, 0xbf, 0x84,
	}
	testing.expect_value(t, hash, expected_hash)
	replayed_hash, replayed_hash_ok :=
		unified_path_source_result_content_hash({}, result)
	testing.expect(t, replayed_hash_ok)
	testing.expect_value(t, replayed_hash, hash)
	result.points[0].x += 1
	_, mutated_hash_ok := unified_path_source_result_hash(
		{},
		{},
		{},
		{},
		{},
		{},
		{},
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		result,
	)
	testing.expect(t, !mutated_hash_ok)
	mutated_content_hash, mutated_content_hash_ok :=
		unified_path_source_result_content_hash({}, result)
	testing.expect(t, mutated_content_hash_ok)
	testing.expect(t, mutated_content_hash != hash)
}

unified_path_source_test_inputs :: proc() -> (
	Perimeter_Result,
	Bridge_Path_Result,
	Gap_Centerline_Result,
	Solid_Path_Result,
	Infill_Result,
	Support_Path_Result,
	profiles.Resolved_Process_Profile,
) {
	perimeters := Perimeter_Result{
		config = {
			count = 2,
			line_width = 100,
			topology_policy = .Strict_Printable,
			join_type = .Miter,
			miter_limit = 2,
		},
		layers = make([]Perimeter_Layer, 1),
		groups = make([]Perimeter_Group, 2),
		paths = make([]Perimeter_Path, 2),
		points = make([]polygon.Polygon_Point, 8),
	}
	perimeters.layers[0] = {
		group_count = 2,
		path_count = 2,
	}
	for group_index in 0..<2 {
		path_id := contracts.Stable_ID(101+group_index)
		perimeters.groups[group_index] = {
			region_id = 50,
			perimeter_index = u32(group_index),
			path_offset = u64(group_index),
			path_count = 1,
		}
		perimeters.paths[group_index] = {
			stable_id = path_id,
			region_id = 50,
			perimeter_index = u32(group_index),
			point_offset = u64(group_index*4),
			point_count = 4,
			signed_area_2 = 20_000,
			winding = .Positive,
		}
		minimum := contracts.Micrometres(group_index*10)
		maximum := contracts.Micrometres(100-group_index*10)
		copy(
			perimeters.points[group_index*4:group_index*4+4],
			[]polygon.Polygon_Point{
				{minimum, minimum},
				{maximum, minimum},
				{maximum, maximum},
				{minimum, maximum},
			},
		)
	}

	bridges := Bridge_Path_Result{
		layers = make([]Bridge_Path_Layer, 1),
		paths = make([]Bridge_Path, 1),
	}
	bridges.layers[0] = {path_count = 1}
	bridges.paths[0] = {
		stable_id = 103,
		role = .Bridge,
		line_width = 100,
		point_a = {200, 0},
		point_b = {200, 100},
	}

	gaps := Gap_Centerline_Result{
		minimum_samples_per_path = 2,
		layers = make([]Gap_Centerline_Layer, 1),
		paths = make([]Gap_Centerline_Path, 1),
		vertices = make([]Gap_Centerline_Vertex, 3),
	}
	gaps.layers[0] = {path_count = 1, vertex_count = 3}
	gaps.paths[0] = {
		stable_id = 104,
		role = .Gap,
		vertex_count = 3,
	}
	for &vertex, vertex_index in gaps.vertices {
		vertex.point = {400, contracts.Micrometres(vertex_index*50)}
		vertex.line_width =
			contracts.Micrometres(80+vertex_index*20)
	}

	solids := Solid_Path_Result{
		layers = make([]Solid_Path_Layer, 1),
		paths = make([]Solid_Path, 1),
	}
	solids.layers[0] = {path_count = 1}
	solids.paths[0] = {
		stable_id = 105,
		role = .Top_Skin,
		line_width = 100,
		point_a = {600, 0},
		point_b = {600, 100},
	}

	infill := Infill_Result{
		config = {
			spacing = 200,
			boundary_inset = 50,
			base_axis = .Vertical,
			topology_policy = .Strict_Printable,
			join_type = .Miter,
			miter_limit = 2,
		},
		layers = make([]Infill_Layer, 1),
		segments = make([]Infill_Segment, 1),
	}
	infill.layers[0] = {segment_count = 1, axis = .Vertical}
	infill.segments[0] = {
		stable_id = 106,
		axis = .Vertical,
		point_a = {800, 0},
		point_b = {800, 100},
	}

	supports := Support_Path_Result{
		layers = make([]Support_Path_Layer, 1),
		paths = make([]Support_Path, 1),
	}
	supports.layers[0] = {path_count = 1}
	supports.paths[0] = {
		stable_id = 107,
		role = .Support,
		line_width = 100,
		point_a = {1_000, 0},
		point_b = {1_000, 100},
	}

	process := profiles.Resolved_Process_Profile{
		source = {
			nominal_line_width = 100,
		},
	}
	return perimeters, bridges, gaps, solids, infill, supports, process
}

unified_path_source_test_inputs_destroy :: proc(
	perimeters: ^Perimeter_Result,
	bridges: ^Bridge_Path_Result,
	gaps: ^Gap_Centerline_Result,
	solids: ^Solid_Path_Result,
	infill: ^Infill_Result,
	supports: ^Support_Path_Result,
) {
	perimeter_result_destroy(perimeters)
	bridge_path_result_destroy(bridges)
	gap_centerline_result_destroy(gaps)
	solid_path_result_destroy(solids)
	infill_result_destroy(infill)
	support_path_result_destroy(supports)
}
