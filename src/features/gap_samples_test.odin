package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

@(test)
gap_samples_apply_one_line_allocations_across_an_uncovered_channel_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters, evidence :=
		gap_sample_test_rectangle(t, 1_000, 700)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer gap_evidence_result_destroy(&evidence)
	result, error := gap_samples_build(
		evidence,
		gap_sample_test_process(),
		{spacing = 100, phase = 0},
	)
	defer gap_sample_result_destroy(&result)
	testing.expect_value(t, error, Gap_Sample_Error.None)
	testing.expect_value(t, len(result.samples), 5)
	testing.expect_value(t, len(result.centers), 5)
	testing.expect_value(t, len(result.boundary_hits), 10)
	for sample, sample_index in result.samples {
		testing.expect_value(t, sample.path_axis, Gap_Path_Axis.Horizontal)
		testing.expect_value(
			t,
			sample.allocation.kind,
			profiles.Gap_Width_Kind.One_Line,
		)
		testing.expect_value(
			t,
			sample.allocation.measured_width,
			contracts.Micrometres(300),
		)
		testing.expect_value(t, sample.center_count, u8(1))
		center := result.centers[sample.center_offset]
		testing.expect_value(t, center.y_twice_um, i64(700))
		testing.expect_value(
			t,
			center.line_width,
			contracts.Micrometres(300),
		)
		if sample_index > 0 {
			testing.expect(
				t,
				sample.scan_coordinate >
					result.samples[sample_index-1].scan_coordinate,
			)
		}
	}
	gap_hash: contracts.Content_Hash
	gap_hash[0] = 0x47
	process_hash: contracts.Content_Hash
	process_hash[0] = 0x50
	hash, hash_ok := gap_sample_result_hash(
		gap_hash,
		process_hash,
		evidence,
		gap_sample_test_process(),
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0xfe, 0x7e, 0xc6, 0xb7, 0x60, 0x00, 0x06, 0x8d,
		0x52, 0xc3, 0xb0, 0xdf, 0x51, 0x2c, 0x13, 0xee,
		0x2e, 0x2c, 0x14, 0x6f, 0x0d, 0xfe, 0xd8, 0x37,
		0xd3, 0x0f, 0x6e, 0xa5, 0x40, 0x63, 0xb2, 0x9a,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
gap_samples_partition_two_lines_without_losing_width_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters, evidence :=
		gap_sample_test_rectangle(t, 1_000, 1_000)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer gap_evidence_result_destroy(&evidence)
	result, error := gap_samples_build(
		evidence,
		gap_sample_test_process(),
		{spacing = 100, phase = 0},
	)
	defer gap_sample_result_destroy(&result)
	testing.expect_value(t, error, Gap_Sample_Error.None)
	testing.expect_value(t, len(result.samples), 5)
	testing.expect_value(t, len(result.centers), 10)
	for sample in result.samples {
		testing.expect_value(
			t,
			sample.allocation.kind,
			profiles.Gap_Width_Kind.Two_Lines,
		)
		testing.expect_value(t, sample.center_count, u8(2))
		first := result.centers[sample.center_offset]
		second := result.centers[sample.center_offset+1]
		testing.expect_value(t, first.y_twice_um, i64(700))
		testing.expect_value(t, second.y_twice_um, i64(1_300))
		testing.expect_value(
			t,
			first.line_width+second.line_width,
			sample.allocation.measured_width,
		)
	}
}

@(test)
gap_samples_retain_below_minimum_cross_sections_without_centers_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters, evidence :=
		gap_sample_test_rectangle(t, 1_000, 100)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer gap_evidence_result_destroy(&evidence)
	result, error := gap_samples_build(
		evidence,
		gap_sample_test_process(),
		{spacing = 100, phase = 0},
	)
	defer gap_sample_result_destroy(&result)
	testing.expect_value(t, error, Gap_Sample_Error.None)
	testing.expect_value(t, len(result.samples), 9)
	testing.expect_value(t, len(result.centers), 0)
	for sample in result.samples {
		testing.expect_value(
			t,
			sample.allocation.kind,
			profiles.Gap_Width_Kind.Unprinted_Below_Minimum,
		)
		testing.expect_value(t, sample.center_count, u8(0))
	}
}

@(test)
gap_samples_select_the_vertical_path_axis_for_a_tall_channel_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters, evidence :=
		gap_sample_test_rectangle(t, 700, 1_000)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer gap_evidence_result_destroy(&evidence)
	result, error := gap_samples_build(
		evidence,
		gap_sample_test_process(),
		{spacing = 100, phase = 0},
	)
	defer gap_sample_result_destroy(&result)
	testing.expect_value(t, error, Gap_Sample_Error.None)
	testing.expect_value(t, len(result.samples), 5)
	for sample in result.samples {
		testing.expect_value(t, sample.path_axis, Gap_Path_Axis.Vertical)
		center := result.centers[sample.center_offset]
		testing.expect_value(t, center.x_twice_um, i64(700))
	}
}

@(test)
gap_sample_hash_rejects_mutated_center_coordinates_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters, evidence :=
		gap_sample_test_rectangle(t, 1_000, 700)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer gap_evidence_result_destroy(&evidence)
	process := gap_sample_test_process()
	result, error := gap_samples_build(
		evidence,
		process,
		{spacing = 100, phase = 0},
	)
	defer gap_sample_result_destroy(&result)
	testing.expect_value(t, error, Gap_Sample_Error.None)
	if len(result.centers) == 0 {return}
	result.centers[0].y_twice_um += 1
	_, hash_ok := gap_sample_result_hash(
		{},
		{},
		evidence,
		process,
		result,
	)
	testing.expect(t, !hash_ok)
}

gap_sample_test_rectangle :: proc(
	t: ^testing.T,
	width, height: contracts.Micrometres,
) -> (
	slicing.Topology_Result,
	slicing.Region_Result,
	Perimeter_Result,
	Gap_Evidence_Result,
) {
	topology, regions, perimeters :=
		gap_test_rectangle(t, width, height)
	evidence, error := gap_evidence_build(
		topology,
		regions,
		perimeters,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			minimum_line_width = 270,
			maximum_line_width = 585,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = 0,
		},
	)
	testing.expect_value(t, error, Gap_Evidence_Error.None)
	return topology, regions, perimeters, evidence
}

gap_sample_test_process :: proc() -> profiles.Resolved_Process_Profile {
	return {
		source = {
			thin_wall_remainder = .Preserve_Unprinted,
			gap_allocation = .One_Then_Two_Lines,
		},
		thin_wall_minimum_width = 270,
		thin_wall_maximum_width = 585,
	}
}
