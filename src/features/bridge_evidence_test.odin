package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

@(test)
bridge_evidence_subtracts_expanded_previous_layer_support_test :: proc(
	t: ^testing.T,
) {
	topology, regions := bridge_evidence_test_cantilever(t)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	process := bridge_evidence_test_process(100, 100_000)
	result, error := bridge_evidence_build(
		topology,
		regions,
		process,
		polygon.CLIPPER2_PROVIDER,
		bridge_evidence_test_config(),
	)
	defer bridge_evidence_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Evidence_Error.None)
	testing.expect_value(t, len(result.layers), 2)
	testing.expect_value(t, len(result.masks), 1)
	testing.expect_value(t, result.eligible_mask_count, u64(1))
	testing.expect_value(t, result.below_minimum_count, u64(0))
	if len(result.masks) != 1 {return}
	mask := result.masks[0]
	testing.expect_value(
		t,
		mask.kind,
		Bridge_Evidence_Kind.Eligible_Unsupported,
	)
	testing.expect_value(t, mask.layer_index, u32(1))
	testing.expect_value(t, mask.signed_area_2, i128(800_000))
	testing.expect_value(t, mask.path_count, u32(1))
	testing.expect_value(t, mask.point_count, u32(4))
	minimum_x := contracts.Micrometres(max(i64))
	maximum_x := contracts.Micrometres(min(i64))
	point_start := int(mask.point_offset)
	point_end := point_start+int(mask.point_count)
	for point in result.points[point_start:point_end] {
		minimum_x = min(minimum_x, point.x)
		maximum_x = max(maximum_x, point.x)
	}
	testing.expect_value(t, minimum_x, contracts.Micrometres(1_100))
	testing.expect_value(t, maximum_x, contracts.Micrometres(1_500))
	region_hash, region_hash_ok :=
		slicing.region_result_hash({}, topology, regions)
	testing.expect(t, region_hash_ok)
	process_hash: contracts.Content_Hash
	process_hash[0] = 0x50
	hash, hash_ok := bridge_evidence_result_hash(
		region_hash,
		process_hash,
		topology,
		regions,
		process,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0xef, 0x0a, 0x58, 0x4f, 0xba, 0x07, 0xe1, 0xfe,
		0x5a, 0xcd, 0xee, 0x7c, 0x24, 0x04, 0xf8, 0x7a,
		0x4c, 0x29, 0x4f, 0xd6, 0x53, 0x45, 0x84, 0xc2,
		0xfa, 0xe1, 0x78, 0x41, 0xfd, 0x7e, 0x8a, 0xe6,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
bridge_evidence_preserves_below_minimum_unsupported_area_test :: proc(
	t: ^testing.T,
) {
	topology, regions := bridge_evidence_test_cantilever(t)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	result, error := bridge_evidence_build(
		topology,
		regions,
		bridge_evidence_test_process(100, 400_001),
		polygon.CLIPPER2_PROVIDER,
		bridge_evidence_test_config(),
	)
	defer bridge_evidence_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Evidence_Error.None)
	testing.expect_value(t, len(result.masks), 1)
	testing.expect_value(t, result.eligible_mask_count, u64(0))
	testing.expect_value(t, result.below_minimum_count, u64(1))
	if len(result.masks) != 1 {return}
	testing.expect_value(
		t,
		result.masks[0].kind,
		Bridge_Evidence_Kind.Below_Minimum_Area,
	)
	testing.expect_value(
		t,
		result.masks[0].signed_area_2,
		i128(800_000),
	)
}

@(test)
bridge_evidence_omits_fully_supported_regions_test :: proc(t: ^testing.T) {
	layer_counts := []u32{1, 1}
	path_points := [][4]slicing.Snapped_Point{
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
	}
	topology := surface_rect_topology(layer_counts, path_points)
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	result, error := bridge_evidence_build(
		topology,
		regions,
		bridge_evidence_test_process(100, 1),
		polygon.CLIPPER2_PROVIDER,
		bridge_evidence_test_config(),
	)
	defer bridge_evidence_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Evidence_Error.None)
	testing.expect_value(t, len(result.masks), 0)
	testing.expect_value(t, len(result.paths), 0)
	testing.expect_value(t, len(result.points), 0)
}

@(test)
bridge_evidence_does_not_classify_the_first_layer_as_a_bridge_test :: proc(
	t: ^testing.T,
) {
	layer_counts := []u32{1}
	path_points := [][4]slicing.Snapped_Point{
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
	}
	topology := surface_rect_topology(layer_counts, path_points)
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	result, error := bridge_evidence_build(
		topology,
		regions,
		bridge_evidence_test_process(100, 1),
		polygon.CLIPPER2_PROVIDER,
		bridge_evidence_test_config(),
	)
	defer bridge_evidence_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Evidence_Error.None)
	testing.expect_value(t, len(result.masks), 0)
}

@(test)
bridge_evidence_hash_rejects_mutated_mask_area_test :: proc(t: ^testing.T) {
	topology, regions := bridge_evidence_test_cantilever(t)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	process := bridge_evidence_test_process(100, 100_000)
	result, error := bridge_evidence_build(
		topology,
		regions,
		process,
		polygon.CLIPPER2_PROVIDER,
		bridge_evidence_test_config(),
	)
	defer bridge_evidence_result_destroy(&result)
	testing.expect_value(t, error, Bridge_Evidence_Error.None)
	if len(result.masks) == 0 {return}
	result.masks[0].signed_area_2 += 2
	region_hash, region_hash_ok :=
		slicing.region_result_hash({}, topology, regions)
	testing.expect(t, region_hash_ok)
	_, hash_ok := bridge_evidence_result_hash(
		region_hash,
		{},
		topology,
		regions,
		process,
		result,
	)
	testing.expect(t, !hash_ok)
}

bridge_evidence_test_cantilever :: proc(
	t: ^testing.T,
) -> (slicing.Topology_Result, slicing.Region_Result) {
	layer_counts := []u32{1, 1}
	path_points := [][4]slicing.Snapped_Point{
		{{0, 0}, {1_000, 0}, {1_000, 1_000}, {0, 1_000}},
		{{0, 0}, {1_500, 0}, {1_500, 1_000}, {0, 1_000}},
	}
	topology := surface_rect_topology(layer_counts, path_points)
	regions, region_error := slicing.regions_build(topology)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	return topology, regions
}

bridge_evidence_test_process :: proc(
	anchor_margin: contracts.Micrometres,
	minimum_area: i64,
) -> profiles.Resolved_Process_Profile {
	return {
		source = {
			bridge_geometry = .Previous_Layer_Expanded_Support,
			bridge_anchor_margin = anchor_margin,
			bridge_direction = .Bounded_Candidate_Score,
			bridge_angle_count = 1,
			bridge_angles = {0, 0, 0, 0, 0, 0, 0, 0},
			minimum_bridge_area =
				profiles.Area_Square_Micrometres(minimum_area),
		},
	}
}

bridge_evidence_test_config :: proc() -> Bridge_Evidence_Config {
	return {
		fill_rule = .Even_Odd,
		join_type = .Miter,
		miter_limit = 2,
		arc_tolerance = 0,
	}
}
