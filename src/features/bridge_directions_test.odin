package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

@(test)
bridge_directions_select_two_sided_short_span_test :: proc(t: ^testing.T) {
	topology, regions := bridge_direction_test_span(t)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	process := bridge_direction_test_process()
	evidence, evidence_error := bridge_evidence_build(
		topology,
		regions,
		process,
		polygon.CLIPPER2_PROVIDER,
		bridge_evidence_test_config(),
	)
	defer bridge_evidence_result_destroy(&evidence)
	testing.expect_value(
		t,
		evidence_error,
		Bridge_Evidence_Error.None,
	)
	result, error := bridge_directions_score(
		topology,
		regions,
		evidence,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer bridge_direction_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Direction_Error.None)
	testing.expect_value(t, len(result.selections), 1)
	testing.expect_value(t, len(result.candidates), 2)
	if len(result.selections) != 1 || len(result.candidates) != 2 {
		return
	}
	selection := result.selections[0]
	testing.expect_value(
		t,
		selection.status,
		Bridge_Direction_Status.Selected,
	)
	testing.expect_value(t, selection.selected_candidate_index, u32(0))
	horizontal := result.candidates[0]
	vertical := result.candidates[1]
	testing.expect_value(
		t,
		horizontal.angle,
		profiles.Angle_Millidegrees(0),
	)
	testing.expect_value(
		t,
		horizontal.direction_x,
		BRIDGE_DIRECTION_SCALE,
	)
	testing.expect_value(t, horizontal.direction_y, i64(0))
	testing.expect_value(
		t,
		horizontal.span_projection,
		i128(600)*i128(BRIDGE_DIRECTION_SCALE),
	)
	testing.expect_value(
		t,
		horizontal.positive_anchor_capacity,
		u128(1_000)*u128(BRIDGE_DIRECTION_SCALE),
	)
	testing.expect_value(
		t,
		horizontal.negative_anchor_capacity,
		u128(1_000)*u128(BRIDGE_DIRECTION_SCALE),
	)
	testing.expect_value(
		t,
		horizontal.bidirectional_anchor_capacity,
		u128(1_000)*u128(BRIDGE_DIRECTION_SCALE),
	)
	testing.expect_value(
		t,
		vertical.bidirectional_anchor_capacity,
		u128(0),
	)
	region_hash, region_hash_ok :=
		slicing.region_result_hash({}, topology, regions)
	testing.expect(t, region_hash_ok)
	process_hash: contracts.Content_Hash
	process_hash[0] = 0x50
	evidence_hash, evidence_hash_ok := bridge_evidence_result_hash(
		region_hash,
		process_hash,
		topology,
		regions,
		process,
		evidence,
	)
	testing.expect(t, evidence_hash_ok)
	hash, hash_ok := bridge_direction_result_hash(
		region_hash,
		evidence_hash,
		process_hash,
		topology,
		regions,
		evidence,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0x0b, 0xa9, 0x4b, 0x1e, 0x53, 0xc9, 0x51, 0x1e,
		0xbf, 0x73, 0x48, 0x3b, 0x9f, 0x68, 0xa9, 0x24,
		0xe1, 0x58, 0x50, 0x04, 0x4c, 0x98, 0xc6, 0x2a,
		0xde, 0xab, 0xc8, 0xe9, 0x28, 0x6f, 0x39, 0x1e,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
bridge_directions_report_one_sided_cantilevers_test :: proc(t: ^testing.T) {
	topology, regions := bridge_evidence_test_cantilever(t)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	process := bridge_direction_test_process()
	evidence, evidence_error := bridge_evidence_build(
		topology,
		regions,
		process,
		polygon.CLIPPER2_PROVIDER,
		bridge_evidence_test_config(),
	)
	defer bridge_evidence_result_destroy(&evidence)
	testing.expect_value(
		t,
		evidence_error,
		Bridge_Evidence_Error.None,
	)
	result, error := bridge_directions_score(
		topology,
		regions,
		evidence,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer bridge_direction_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Direction_Error.None)
	testing.expect_value(t, len(result.selections), 1)
	if len(result.selections) != 1 {return}
	testing.expect_value(
		t,
		result.selections[0].status,
		Bridge_Direction_Status.No_Bidirectional_Anchor,
	)
}

@(test)
bridge_direction_vectors_pin_cardinal_and_diagonal_angles_test :: proc(
	t: ^testing.T,
) {
	x, y, ok := bridge_direction_vector(45_000)
	testing.expect(t, ok)
	testing.expect_value(t, x, i64(707_106_781))
	testing.expect_value(t, y, i64(707_106_781))
	x, y, ok = bridge_direction_vector(90_000)
	testing.expect(t, ok)
	testing.expect_value(t, x, i64(0))
	testing.expect_value(t, y, BRIDGE_DIRECTION_SCALE)
}

@(test)
bridge_polygon_contains_doubled_boundary_points_test :: proc(t: ^testing.T) {
	set := polygon.Polygon_Set{
		paths = []polygon.Polygon_Path{{offset = 0, count = 4}},
		points = []polygon.Polygon_Point{
			{0, 0},
			{100, 0},
			{100, 100},
			{0, 100},
		},
	}
	testing.expect(t, bridge_polygon_contains_twice(set, 100, 100))
	testing.expect(t, bridge_polygon_contains_twice(set, 0, 100))
	testing.expect(t, !bridge_polygon_contains_twice(set, 202, 100))
}

@(test)
bridge_direction_hash_rejects_mutated_anchor_scores_test :: proc(
	t: ^testing.T,
) {
	topology, regions := bridge_direction_test_span(t)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	process := bridge_direction_test_process()
	evidence, evidence_error := bridge_evidence_build(
		topology,
		regions,
		process,
		polygon.CLIPPER2_PROVIDER,
		bridge_evidence_test_config(),
	)
	defer bridge_evidence_result_destroy(&evidence)
	testing.expect_value(
		t,
		evidence_error,
		Bridge_Evidence_Error.None,
	)
	result, error := bridge_directions_score(
		topology,
		regions,
		evidence,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer bridge_direction_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Direction_Error.None)
	if len(result.candidates) == 0 {return}
	result.candidates[0].positive_anchor_capacity += 1
	region_hash, region_hash_ok :=
		slicing.region_result_hash({}, topology, regions)
	testing.expect(t, region_hash_ok)
	_, hash_ok := bridge_direction_result_hash(
		region_hash,
		{},
		{},
		topology,
		regions,
		evidence,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, !hash_ok)
}

bridge_direction_test_span :: proc(
	t: ^testing.T,
) -> (slicing.Topology_Result, slicing.Region_Result) {
	layer_counts := []u32{2, 1}
	path_points := [][4]slicing.Snapped_Point{
		{{0, 0}, {200, 0}, {200, 1_000}, {0, 1_000}},
		{{800, 0}, {1_000, 0}, {1_000, 1_000}, {800, 1_000}},
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
	}
	topology := surface_rect_topology(layer_counts, path_points)
	regions, region_error := slicing.regions_build(topology)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	return topology, regions
}

bridge_direction_test_process :: proc() -> profiles.Resolved_Process_Profile {
	result := bridge_evidence_test_process(0, 1)
	result.source.bridge_angle_count = 2
	result.source.bridge_angles = {
		0,
		90_000,
		0,
		0,
		0,
		0,
		0,
		0,
	}
	result.source.nominal_line_width = contracts.Micrometres(100)
	return result
}
