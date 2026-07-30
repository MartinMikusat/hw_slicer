package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

@(test)
path_plan_orders_inner_perimeters_before_zigzag_infill_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters, infill :=
		path_plan_test_features(t)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer infill_result_destroy(&infill)
	result, error := path_plan_build(
		perimeters,
		infill,
		{
			start = {0, 0},
			inner_perimeters_first = true,
		},
	)
	defer path_plan_result_destroy(&result)
	testing.expect_value(t, error, Path_Plan_Error.None)
	testing.expect_value(t, len(result.layers), 1)
	testing.expect_value(t, len(result.paths), 10)
	testing.expect_value(
		t,
		result.topology_policy,
		Feature_Topology_Policy.Strict_Printable,
	)
	testing.expect_value(t, result.extrude_move_count, u64(22))
	testing.expect(t, result.travel_move_count <= u64(len(result.paths)))
	inner_group := perimeters.groups[1]
	testing.expect_value(
		t,
		result.paths[0].source_index,
		u32(inner_group.path_offset),
	)
	for path in result.paths[:4] {
		testing.expect_value(
			t,
			path.source_kind,
			Planned_Source_Kind.Perimeter,
		)
		testing.expect(t, path.closed)
	}
	for path in result.paths[4:] {
		testing.expect_value(
			t,
			path.source_kind,
			Planned_Source_Kind.Infill,
		)
		testing.expect(t, !path.closed)
	}
	perimeter_hash, perimeter_hash_ok := perimeter_result_hash(
		contracts.Content_Hash{},
		perimeters,
	)
	infill_hash, infill_hash_ok := infill_result_hash(
		contracts.Content_Hash{},
		infill,
	)
	result_hash, hash_ok := path_plan_result_hash(
		perimeter_hash,
		infill_hash,
		result,
	)
	testing.expect(t, perimeter_hash_ok)
	testing.expect(t, infill_hash_ok)
	testing.expect(t, hash_ok)
	testing.expect(t, result_hash != contracts.Content_Hash{})
}

@(test)
path_plan_uses_canonical_ties_for_starts_and_directions_test :: proc(
	t: ^testing.T,
) {
	points := [?]polygon.Polygon_Point{
		{-10, 0},
		{10, 0},
	}
	testing.expect_value(
		t,
		path_plan_nearest_point(points[:], {0, 0}),
		0,
	)
	source := Infill_Segment{
		stable_id = 10,
		region_id = 20,
		point_a = {-10, 0},
		point_b = {10, 0},
	}
	paths: [1]Planned_Path
	moves: [2]Planned_Move
	path_write, move_write := 0, 0
	current := polygon.Polygon_Point{0, 0}
	result: Path_Plan_Result
	path_plan_emit_infill(
		source,
		0,
		&current,
		paths[:],
		moves[:],
		&path_write,
		&move_write,
		&result,
	)
	testing.expect(t, !paths[0].reversed)
	testing.expect_value(t, paths[0].start_index, u32(0))
}

@(test)
path_plan_enforces_path_and_move_limits_test :: proc(t: ^testing.T) {
	topology, regions, perimeters, infill :=
		path_plan_test_features(t)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer infill_result_destroy(&infill)
	path_limited, path_error := path_plan_build(
		perimeters,
		infill,
		{},
		{max_paths = 1, max_moves = 100},
	)
	defer path_plan_result_destroy(&path_limited)
	move_limited, move_error := path_plan_build(
		perimeters,
		infill,
		{},
		{max_paths = 100, max_moves = 1},
	)
	defer path_plan_result_destroy(&move_limited)
	testing.expect_value(t, path_error, Path_Plan_Error.Path_Limit)
	testing.expect_value(t, move_error, Path_Plan_Error.Move_Limit)
}

@(test)
path_plan_rejects_mixed_topology_policies_test :: proc(t: ^testing.T) {
	topology, regions, perimeters, infill :=
		path_plan_test_features(t)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer infill_result_destroy(&infill)
	infill.config.topology_policy = .Diagnostic_Closed_Regions
	result, error := path_plan_build(perimeters, infill, {})
	defer path_plan_result_destroy(&result)
	testing.expect_value(t, error, Path_Plan_Error.Invalid_Input)
}

@(test)
path_plan_hash_rejects_broken_move_continuity_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters, infill :=
		path_plan_test_features(t)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer infill_result_destroy(&infill)
	result, error := path_plan_build(
		perimeters,
		infill,
		{inner_perimeters_first = true},
	)
	defer path_plan_result_destroy(&result)
	testing.expect_value(t, error, Path_Plan_Error.None)
	if len(result.moves) == 0 {return}
	result.moves[0].point_a.x += 1
	_, hash_ok := path_plan_result_hash(
		contracts.Content_Hash{},
		contracts.Content_Hash{},
		result,
	)
	testing.expect(t, !hash_ok)
}

path_plan_test_features :: proc(t: ^testing.T) -> (
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	perimeters: Perimeter_Result,
	infill: Infill_Result,
) {
	topology = perimeter_test_topology()
	region_error: slicing.Region_Error
	regions, region_error = slicing.regions_build(topology)
	perimeter_error: Perimeter_Error
	perimeters, perimeter_error = perimeters_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			count = 2,
			line_width = 100,
			join_type = .Miter,
			miter_limit = 2,
		},
	)
	infill_error: Infill_Error
	infill, infill_error = infill_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			spacing = 200,
			boundary_inset = 100,
			phase = 0,
			base_axis = .Vertical,
			join_type = .Miter,
			miter_limit = 2,
		},
	)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, perimeter_error, Perimeter_Error.None)
	testing.expect_value(t, infill_error, Infill_Error.None)
	return
}
