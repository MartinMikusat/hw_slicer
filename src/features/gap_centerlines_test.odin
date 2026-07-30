package features

import "core:testing"

import contracts "../contracts"
import profiles "../profiles"
import slicing "../slicing"

@(test)
gap_centerlines_connect_one_line_samples_test :: proc(t: ^testing.T) {
	topology, regions, perimeters, evidence :=
		gap_sample_test_rectangle(t, 1_000, 700)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer gap_evidence_result_destroy(&evidence)
	samples, sample_error := gap_samples_build(
		evidence,
		gap_sample_test_process(),
		{spacing = 100, phase = 0},
	)
	defer gap_sample_result_destroy(&samples)
	testing.expect_value(t, sample_error, Gap_Sample_Error.None)

	result, error := gap_centerlines_build(evidence, samples)
	defer gap_centerline_result_destroy(&result)
	testing.expect_value(t, error, Gap_Centerline_Error.None)
	testing.expect_value(t, len(result.paths), 1)
	testing.expect_value(t, len(result.vertices), 5)
	testing.expect_value(t, len(result.issues), 0)
	if len(result.paths) != 1 {return}
	path := result.paths[0]
	testing.expect_value(t, path.role, profiles.Printable_Role.Gap)
	testing.expect_value(t, path.line_index, u8(0))
	testing.expect_value(t, path.sample_count, u32(5))
	testing.expect_value(t, path.vertex_count, u32(5))
	for vertex, vertex_index in result.vertices {
		testing.expect_value(
			t,
			vertex.sample_index,
			u32(vertex_index),
		)
		testing.expect_value(t, vertex.point.y, contracts.Micrometres(350))
		testing.expect_value(t, vertex.exact_y_twice_um, i64(700))
		testing.expect_value(t, vertex.round_error_y_2x, u8(0))
		testing.expect_value(
			t,
			vertex.line_width,
			contracts.Micrometres(300),
		)
	}
	evidence_hash: contracts.Content_Hash
	evidence_hash[0] = 0x47
	sample_hash: contracts.Content_Hash
	sample_hash[0] = 0x53
	hash, hash_ok := gap_centerline_result_hash(
		evidence_hash,
		sample_hash,
		evidence,
		samples,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0x03, 0x23, 0x2f, 0x51, 0x8d, 0xb6, 0xd2, 0x1d,
		0x58, 0xfb, 0x8b, 0xb5, 0xc6, 0x23, 0x42, 0xef,
		0xf9, 0x9c, 0x92, 0x36, 0x10, 0x44, 0xe0, 0x09,
		0x89, 0xe8, 0xdc, 0xf0, 0x51, 0x0c, 0x4d, 0xa8,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
gap_centerlines_connect_two_line_samples_as_separate_paths_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters, evidence :=
		gap_sample_test_rectangle(t, 1_000, 1_000)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer gap_evidence_result_destroy(&evidence)
	samples, sample_error := gap_samples_build(
		evidence,
		gap_sample_test_process(),
		{spacing = 100, phase = 0},
	)
	defer gap_sample_result_destroy(&samples)
	testing.expect_value(t, sample_error, Gap_Sample_Error.None)

	result, error := gap_centerlines_build(evidence, samples)
	defer gap_centerline_result_destroy(&result)
	testing.expect_value(t, error, Gap_Centerline_Error.None)
	testing.expect_value(t, len(result.paths), 2)
	testing.expect_value(t, len(result.vertices), 10)
	testing.expect_value(t, len(result.issues), 0)
	if len(result.paths) != 2 {return}
	for path, line_index in result.paths {
		testing.expect_value(t, path.line_index, u8(line_index))
		testing.expect_value(t, path.sample_count, u32(5))
		testing.expect_value(t, path.vertex_count, u32(5))
		expected_y := contracts.Micrometres(350+line_index*300)
		vertex_start := int(path.vertex_offset)
		vertex_end := vertex_start+int(path.vertex_count)
		for vertex in result.vertices[vertex_start:vertex_end] {
			testing.expect_value(t, vertex.point.y, expected_y)
			testing.expect_value(
				t,
				vertex.line_width,
				contracts.Micrometres(300),
			)
		}
	}
}

@(test)
gap_centerlines_report_below_minimum_runs_test :: proc(t: ^testing.T) {
	topology, regions, perimeters, evidence :=
		gap_sample_test_rectangle(t, 1_000, 100)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer gap_evidence_result_destroy(&evidence)
	samples, sample_error := gap_samples_build(
		evidence,
		gap_sample_test_process(),
		{spacing = 100, phase = 0},
	)
	defer gap_sample_result_destroy(&samples)
	testing.expect_value(t, sample_error, Gap_Sample_Error.None)

	result, error := gap_centerlines_build(evidence, samples)
	defer gap_centerline_result_destroy(&result)
	testing.expect_value(t, error, Gap_Centerline_Error.None)
	testing.expect_value(t, len(result.paths), 0)
	testing.expect_value(t, len(result.vertices), 0)
	testing.expect_value(t, len(result.issues), 1)
	if len(result.issues) != 1 {return}
	testing.expect_value(
		t,
		result.issues[0].kind,
		Gap_Centerline_Issue_Kind.Unprinted_Below_Minimum,
	)
	testing.expect_value(t, result.issues[0].sample_count, u32(9))
}

@(test)
gap_centerlines_preserve_vertical_sample_orientation_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters, evidence :=
		gap_sample_test_rectangle(t, 700, 1_000)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer gap_evidence_result_destroy(&evidence)
	samples, sample_error := gap_samples_build(
		evidence,
		gap_sample_test_process(),
		{spacing = 100, phase = 0},
	)
	defer gap_sample_result_destroy(&samples)
	testing.expect_value(t, sample_error, Gap_Sample_Error.None)

	result, error := gap_centerlines_build(evidence, samples)
	defer gap_centerline_result_destroy(&result)
	testing.expect_value(t, error, Gap_Centerline_Error.None)
	testing.expect_value(t, len(result.paths), 1)
	for vertex in result.vertices {
		testing.expect_value(t, vertex.point.x, contracts.Micrometres(350))
		testing.expect_value(t, vertex.exact_x_twice_um, i64(700))
	}
}

@(test)
gap_centerlines_report_ambiguous_scanline_branches_test :: proc(
	t: ^testing.T,
) {
	topology, regions, perimeters, evidence :=
		gap_sample_test_rectangle(t, 1_000, 700)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer gap_evidence_result_destroy(&evidence)
	samples, sample_error := gap_samples_build(
		evidence,
		gap_sample_test_process(),
		{spacing = 100, phase = 0},
	)
	defer gap_sample_result_destroy(&samples)
	testing.expect_value(t, sample_error, Gap_Sample_Error.None)
	if len(samples.samples) < 2 {return}
	samples.samples[1].scan_coordinate =
		samples.samples[0].scan_coordinate

	result, error := gap_centerlines_build(evidence, samples)
	defer gap_centerline_result_destroy(&result)
	testing.expect_value(t, error, Gap_Centerline_Error.None)
	testing.expect_value(t, len(result.paths), 0)
	testing.expect_value(t, len(result.vertices), 0)
	testing.expect_value(t, len(result.issues), 1)
	if len(result.issues) != 1 {return}
	testing.expect_value(
		t,
		result.issues[0].kind,
		Gap_Centerline_Issue_Kind.Ambiguous_Branch,
	)
	testing.expect_value(t, result.issues[0].sample_count, u32(5))
}

@(test)
gap_centerline_hash_rejects_mutated_vertices_test :: proc(t: ^testing.T) {
	topology, regions, perimeters, evidence :=
		gap_sample_test_rectangle(t, 1_000, 700)
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer perimeter_result_destroy(&perimeters)
	defer gap_evidence_result_destroy(&evidence)
	samples, sample_error := gap_samples_build(
		evidence,
		gap_sample_test_process(),
		{spacing = 100, phase = 0},
	)
	defer gap_sample_result_destroy(&samples)
	testing.expect_value(t, sample_error, Gap_Sample_Error.None)
	result, error := gap_centerlines_build(evidence, samples)
	defer gap_centerline_result_destroy(&result)
	testing.expect_value(t, error, Gap_Centerline_Error.None)
	if len(result.vertices) == 0 {return}
	result.vertices[0].point.y += 1
	_, hash_ok := gap_centerline_result_hash(
		{},
		{},
		evidence,
		samples,
		result,
	)
	testing.expect(t, !hash_ok)
}
