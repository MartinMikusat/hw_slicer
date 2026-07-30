package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

@(test)
gap_evidence_preserves_a_wall_below_the_minimum_as_unprinted_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters := gap_test_rectangle(
		t,
		1_000,
		100,
	)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	result, error := gap_evidence_build(
		topology,
		regions,
		perimeters,
		polygon.CLIPPER2_PROVIDER,
		gap_test_config(),
	)
	defer gap_evidence_result_destroy(&result)
	testing.expect_value(t, error, Gap_Evidence_Error.None)
	testing.expect_value(t, len(result.masks), 2)
	testing.expect_value(
		t,
		result.masks[0].kind,
		Gap_Evidence_Kind.Uncovered_Region,
	)
	testing.expect_value(
		t,
		result.masks[1].kind,
		Gap_Evidence_Kind.Unprinted_Remainder,
	)
	testing.expect_value(
		t,
		gap_test_mask_area_2(result, 0),
		i128(200_000),
	)
	testing.expect_value(
		t,
		gap_test_mask_area_2(result, 1),
		i128(200_000),
	)
}

@(test)
gap_evidence_extracts_shell_residual_and_minimum_center_domain_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters := gap_test_rectangle(
		t,
		1_000,
		500,
	)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	result, error := gap_evidence_build(
		topology,
		regions,
		perimeters,
		polygon.CLIPPER2_PROVIDER,
		gap_test_config(),
	)
	defer gap_evidence_result_destroy(&result)
	testing.expect_value(t, error, Gap_Evidence_Error.None)
	testing.expect_value(t, result.shell_half_width, contracts.Micrometres(100))
	testing.expect_value(
		t,
		result.minimum_center_radius,
		contracts.Micrometres(60),
	)
	testing.expect_value(
		t,
		result.maximum_one_radius,
		contracts.Micrometres(130),
	)
	shell_index, shell_ok := gap_test_find_mask(result, .Shell_Coverage)
	residual_index, residual_ok :=
		gap_test_find_mask(result, .Uncovered_Region)
	minimum_index, minimum_ok :=
		gap_test_find_mask(result, .Minimum_Line_Center_Domain)
	_, maximum_ok :=
		gap_test_find_mask(result, .Maximum_One_Line_Center_Domain)
	_, above_two_ok :=
		gap_test_find_mask(result, .Above_Two_Line_Core)
	testing.expect(t, shell_ok)
	testing.expect(t, residual_ok)
	testing.expect(t, !minimum_ok)
	testing.expect(t, !maximum_ok)
	testing.expect(t, !above_two_ok)
	testing.expect_value(
		t,
		gap_test_mask_area_2(result, shell_index),
		i128(880_000),
	)
	testing.expect_value(
		t,
		gap_test_mask_area_2(result, residual_index),
		i128(120_000),
	)
	_ = minimum_index
	region_hash, region_hash_ok := slicing.region_result_hash(
		{},
		topology,
		regions,
	)
	perimeter_hash, perimeter_hash_ok := perimeter_result_hash(
		region_hash,
		perimeters,
	)
	hash, hash_ok := gap_evidence_result_hash(
		region_hash,
		perimeter_hash,
		regions,
		perimeters,
		result,
	)
	testing.expect(t, region_hash_ok)
	testing.expect(t, perimeter_hash_ok)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0xa9, 0xc2, 0x90, 0x0d, 0xcc, 0x95, 0xc0, 0xf2,
		0xf2, 0x9e, 0x4c, 0xb5, 0xec, 0x3d, 0x75, 0x45,
		0x8e, 0x0c, 0x38, 0xfd, 0x73, 0x1f, 0xbc, 0xcb,
		0x3d, 0x81, 0x04, 0x97, 0xf6, 0xa5, 0x72, 0x73,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
gap_evidence_marks_the_core_above_two_line_width_test :: proc(t: ^testing.T) {
	topology, regions, perimeters := gap_test_rectangle(
		t,
		2_000,
		2_000,
	)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	result, error := gap_evidence_build(
		topology,
		regions,
		perimeters,
		polygon.CLIPPER2_PROVIDER,
		gap_test_config(),
	)
	defer gap_evidence_result_destroy(&result)
	testing.expect_value(t, error, Gap_Evidence_Error.None)
	core_index, core_ok :=
		gap_test_find_mask(result, .Above_Two_Line_Core)
	testing.expect(t, core_ok)
	if core_ok {
		testing.expect_value(
			t,
			gap_test_mask_area_2(result, core_index),
			i128(2_332_800),
		)
	}
}

@(test)
gap_evidence_rejects_mismatched_widths_and_limits_test :: proc(t: ^testing.T) {
	topology, regions, perimeters := gap_test_rectangle(
		t,
		1_000,
		500,
	)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	config := gap_test_config()
	config.minimum_line_width = 0
	invalid_result, invalid_error := gap_evidence_build(
		topology,
		regions,
		perimeters,
		polygon.CLIPPER2_PROVIDER,
		config,
	)
	defer gap_evidence_result_destroy(&invalid_result)
	testing.expect_value(
		t,
		invalid_error,
		Gap_Evidence_Error.Invalid_Config,
	)

	config = gap_test_config()
	limited_result, limited_error := gap_evidence_build(
		topology,
		regions,
		perimeters,
		polygon.CLIPPER2_PROVIDER,
		config,
		{
			max_masks = 0,
			max_paths = 100,
			max_points = 1_000,
			polygon = polygon.DEFAULT_POLYGON_LIMITS,
		},
	)
	defer gap_evidence_result_destroy(&limited_result)
	testing.expect_value(
		t,
		limited_error,
		Gap_Evidence_Error.Mask_Limit,
	)
}

@(test)
gap_evidence_hash_rejects_mutated_mask_identity_test :: proc(t: ^testing.T) {
	topology, regions, perimeters := gap_test_rectangle(
		t,
		1_000,
		100,
	)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	result, error := gap_evidence_build(
		topology,
		regions,
		perimeters,
		polygon.CLIPPER2_PROVIDER,
		gap_test_config(),
	)
	defer gap_evidence_result_destroy(&result)
	testing.expect_value(t, error, Gap_Evidence_Error.None)
	if len(result.masks) == 0 {return}
	result.masks[0].stable_id = contracts.INVALID_STABLE_ID
	_, hash_ok := gap_evidence_result_hash(
		{},
		{},
		regions,
		perimeters,
		result,
	)
	testing.expect(t, !hash_ok)
}

gap_test_rectangle :: proc(
	t: ^testing.T,
	width, height: contracts.Micrometres,
) -> (
	slicing.Topology_Result,
	slicing.Region_Result,
	Perimeter_Result,
) {
	layer_counts := [?]u32{1}
	path_points := [?][4]slicing.Snapped_Point{{
		{0, 0},
		{width, 0},
		{width, height},
		{0, height},
	}}
	topology := surface_rect_topology(layer_counts[:], path_points[:])
	regions, region_error := slicing.regions_build(topology)
	perimeters, perimeter_error := perimeters_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			count = 1,
			line_width = 200,
			topology_policy = .Strict_Printable,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = 0,
		},
	)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, perimeter_error, Perimeter_Error.None)
	return topology, regions, perimeters
}

gap_test_config :: proc() -> Gap_Evidence_Config {
	return {
		fill_rule = .Even_Odd,
		minimum_line_width = 120,
		maximum_line_width = 260,
		join_type = .Miter,
		miter_limit = 2,
		arc_tolerance = 0,
	}
}

gap_test_find_mask :: proc(
	result: Gap_Evidence_Result,
	kind: Gap_Evidence_Kind,
) -> (int, bool) {
	for mask, mask_index in result.masks {
		if mask.kind == kind {return mask_index, true}
	}
	return 0, false
}

gap_test_mask_area_2 :: proc(
	result: Gap_Evidence_Result,
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
