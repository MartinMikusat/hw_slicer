package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

@(test)
bridge_paths_emit_selected_horizontal_span_test :: proc(t: ^testing.T) {
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
	directions, direction_error := bridge_directions_score(
		topology,
		regions,
		evidence,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer bridge_direction_result_destroy(&directions)
	testing.expect_value(
		t,
		direction_error,
		Bridge_Direction_Error.None,
	)
	result, error := bridge_paths_generate(
		evidence,
		directions,
		process,
	)
	defer bridge_path_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Path_Error.None)
	testing.expect_value(
		t,
		result.spacing,
		contracts.Micrometres(100),
	)
	testing.expect_value(t, result.scanline_count, u64(10))
	testing.expect_value(t, len(result.paths), 10)
	testing.expect_value(t, len(result.hits), 20)
	testing.expect_value(t, result.skipped_unanchored_count, u64(0))
	if len(result.paths) == 0 {return}
	for path, path_index in result.paths {
		testing.expect_value(t, path.role, profiles.Printable_Role.Bridge)
		testing.expect_value(t, path.angle, profiles.Angle_Millidegrees(0))
		testing.expect_value(t, path.direction_x, BRIDGE_DIRECTION_SCALE)
		testing.expect_value(t, path.direction_y, i64(0))
		testing.expect_value(t, path.mask_path_index, u64(path_index))
		testing.expect_value(t, path.scanline_index, u64(path_index))
		testing.expect_value(
			t,
			path.line_coordinate_scaled,
			i128(path_index)*100*i128(BRIDGE_DIRECTION_SCALE),
		)
		testing.expect_value(t, path.point_a.x, contracts.Micrometres(200))
		testing.expect_value(t, path.point_b.x, contracts.Micrometres(800))
		expected_y := contracts.Micrometres(path_index*100)
		testing.expect_value(t, path.point_a.y, expected_y)
		testing.expect_value(t, path.point_b.y, expected_y)
		testing.expect_value(t, path.hit_offset, u64(path_index*2))
	}
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
	direction_hash, direction_hash_ok := bridge_direction_result_hash(
		region_hash,
		evidence_hash,
		process_hash,
		topology,
		regions,
		evidence,
		process,
		polygon.CLIPPER2_PROVIDER,
		directions,
	)
	testing.expect(t, direction_hash_ok)
	hash, hash_ok := bridge_path_result_hash(
		evidence_hash,
		direction_hash,
		process_hash,
		evidence,
		directions,
		process,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0xbd, 0xb9, 0x16, 0x98, 0x7c, 0x36, 0x25, 0x62,
		0x25, 0xa3, 0x34, 0x44, 0x95, 0xe4, 0xec, 0xb4,
		0x2c, 0xba, 0x08, 0x59, 0x55, 0x66, 0xf3, 0x1b,
		0x78, 0xe8, 0x19, 0x84, 0x18, 0xb6, 0x5f, 0x62,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
bridge_paths_skip_one_sided_direction_results_test :: proc(t: ^testing.T) {
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
	directions, direction_error := bridge_directions_score(
		topology,
		regions,
		evidence,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer bridge_direction_result_destroy(&directions)
	testing.expect_value(
		t,
		direction_error,
		Bridge_Direction_Error.None,
	)
	result, error := bridge_paths_generate(
		evidence,
		directions,
		process,
	)
	defer bridge_path_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Path_Error.None)
	testing.expect_value(t, len(result.paths), 0)
	testing.expect_value(t, result.scanline_count, u64(0))
	testing.expect_value(t, result.skipped_unanchored_count, u64(1))
}

@(test)
bridge_paths_emit_diagonal_segments_with_exact_hits_test :: proc(
	t: ^testing.T,
) {
	topology, regions := bridge_direction_test_span(t)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	process := bridge_direction_test_process()
	process.source.bridge_angle_count = 1
	process.source.bridge_angles = {
		45_000,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
	}
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
	directions, direction_error := bridge_directions_score(
		topology,
		regions,
		evidence,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer bridge_direction_result_destroy(&directions)
	testing.expect_value(
		t,
		direction_error,
		Bridge_Direction_Error.None,
	)
	result, error := bridge_paths_generate(
		evidence,
		directions,
		process,
	)
	defer bridge_path_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Path_Error.None)
	testing.expect(t, len(result.paths) > 0)
	for path in result.paths {
		testing.expect_value(
			t,
			path.angle,
			profiles.Angle_Millidegrees(45_000),
		)
		testing.expect(t, path.point_a != path.point_b)
	}
	for hit in result.hits {
		testing.expect(t, hit.denominator > 0)
		x, error_x, x_ok :=
			infill_rational_round(hit.x_numerator, hit.denominator)
		y, error_y, y_ok :=
			infill_rational_round(hit.y_numerator, hit.denominator)
		testing.expect(t, x_ok && y_ok)
		testing.expect_value(t, hit.point, polygon.Polygon_Point{x, y})
		testing.expect_value(t, hit.error_x_numerator, error_x)
		testing.expect_value(t, hit.error_y_numerator, error_y)
	}
}

@(test)
bridge_path_rational_order_avoids_cross_product_overflow_test :: proc(
	t: ^testing.T,
) {
	scale := i128(1_000_000_000_000_000_000)
	a := i128(1_000_000_000_000)*scale
	b := a+scale
	testing.expect(
		t,
		bridge_path_rational_less(a, scale, b, scale),
	)
	testing.expect(
		t,
		bridge_path_rational_less(-b, scale, -a, scale),
	)
	testing.expect(
		t,
		!bridge_path_rational_less(a, scale, a, scale),
	)
}

@(test)
bridge_path_first_scanline_handles_negative_bounds_test :: proc(
	t: ^testing.T,
) {
	line, ok := bridge_path_first_scanline(-250, 0, 100)
	testing.expect(t, ok)
	testing.expect_value(t, line, i128(-200))
	line, ok = bridge_path_first_scanline(250, 0, 100)
	testing.expect(t, ok)
	testing.expect_value(t, line, i128(300))
}

@(test)
bridge_path_hash_rejects_mutated_exact_hits_test :: proc(t: ^testing.T) {
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
	directions, direction_error := bridge_directions_score(
		topology,
		regions,
		evidence,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer bridge_direction_result_destroy(&directions)
	testing.expect_value(
		t,
		direction_error,
		Bridge_Direction_Error.None,
	)
	result, error := bridge_paths_generate(
		evidence,
		directions,
		process,
	)
	defer bridge_path_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Path_Error.None)
	if len(result.hits) == 0 {return}
	result.hits[0].x_numerator += 1
	_, hash_ok := bridge_path_result_hash(
		{},
		{},
		{},
		evidence,
		directions,
		process,
		result,
	)
	testing.expect(t, !hash_ok)
}
