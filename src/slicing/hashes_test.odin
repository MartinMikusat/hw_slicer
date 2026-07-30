package slicing

import "core:testing"

import contracts "../contracts"

@(test)
slicing_stage_hashes_are_stable_test :: proc(t: ^testing.T) {
	request_hash: contracts.Content_Hash
	request_hash[0] = 0x48
	schedule, schedule_error := fixed_layer_schedule_build({
		request_hash = request_hash,
		minimum_z = 0,
		maximum_z = 1000,
		first_plane_z = 200,
		layer_step = 200,
		max_layer_count = 10,
	})
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	schedule_hash, schedule_hash_ok := fixed_layer_schedule_hash(schedule)
	testing.expect(t, schedule_hash_ok)
	expected_schedule_hash := contracts.Content_Hash{
		0x2c, 0x3f, 0xc7, 0xfd, 0x4d, 0x04, 0x72, 0xab,
		0x5e, 0xf5, 0x2b, 0x06, 0x4b, 0xce, 0xf7, 0xe2,
		0x3d, 0xb6, 0xa0, 0x07, 0x4b, 0xec, 0x1a, 0x71,
		0x57, 0x10, 0xad, 0xef, 0x09, 0x0a, 0x37, 0xdb,
	}
	testing.expect_value(t, schedule_hash, expected_schedule_hash)

	mesh := layer_span_test_mesh()
	index, span_error := layer_span_index_build(mesh, schedule)
	defer layer_span_index_destroy(&index)
	testing.expect_value(t, span_error, Layer_Span_Error.None)
	span_hash, span_hash_ok := layer_span_index_hash(schedule_hash, index)
	testing.expect(t, span_hash_ok)
	expected_span_hash := contracts.Content_Hash{
		0x56, 0xb0, 0x38, 0xc3, 0xb9, 0x1b, 0x3a, 0xba,
		0x4e, 0xdc, 0x8a, 0xec, 0x23, 0x9d, 0xb5, 0x38,
		0x31, 0xc2, 0xcd, 0x5a, 0xda, 0x25, 0xa5, 0x0e,
		0x5a, 0xd6, 0xfd, 0x3d, 0x52, 0xa7, 0xa2, 0xcf,
	}
	testing.expect_value(t, span_hash, expected_span_hash)
}

@(test)
slicing_stage_hashes_reject_inconsistent_arrays_test :: proc(t: ^testing.T) {
	_, schedule_ok := fixed_layer_schedule_hash({
		layer_z = []contracts.Micrometres{200},
	})
	testing.expect(t, !schedule_ok)
	schedule, schedule_error := fixed_layer_schedule_build({
		minimum_z = 0,
		maximum_z = 1000,
		first_plane_z = 200,
		layer_step = 200,
		max_layer_count = 10,
	})
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	schedule.layer_z[0] += 1
	_, schedule_ok = fixed_layer_schedule_hash(schedule)
	testing.expect(t, !schedule_ok)
	schedule.layer_z[0] -= 1
	schedule.layer_ids[0] = contracts.INVALID_STABLE_ID
	_, schedule_ok = fixed_layer_schedule_hash(schedule)
	testing.expect(t, !schedule_ok)
	schedule.layer_ids[0] = contracts.stable_id_child(
		contracts.stable_id_root(schedule.request_hash, .Layer),
		.Layer,
		0,
	)
	schedule.maximum_z += 1
	_, schedule_ok = fixed_layer_schedule_hash(schedule)
	testing.expect(t, !schedule_ok)
	_, span_ok := layer_span_index_hash({}, {
		triangle_ranges = []Triangle_Layer_Range{{}},
		layers = []Layer_Descriptor{{}},
		triangle_ids = []contracts.Stable_ID{1},
	})
	testing.expect(t, !span_ok)
}

@(test)
layer_span_hash_rejects_semantic_mutations_test :: proc(t: ^testing.T) {
	schedule, schedule_error := fixed_layer_schedule_build({
		minimum_z = 0,
		maximum_z = 1000,
		first_plane_z = 200,
		layer_step = 200,
		max_layer_count = 10,
	})
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	schedule_hash, schedule_hash_ok := fixed_layer_schedule_hash(schedule)
	testing.expect(t, schedule_hash_ok)
	index, span_error :=
		layer_span_index_build(layer_span_test_mesh(), schedule)
	defer layer_span_index_destroy(&index)
	testing.expect_value(t, span_error, Layer_Span_Error.None)

	index.triangle_ranges[0].kind = Triangle_Span_Kind(255)
	_, span_ok := layer_span_index_hash(schedule_hash, index)
	testing.expect(t, !span_ok)
	index.triangle_ranges[0].kind = .Crossing_Candidates

	index.triangle_ranges[0].layer_count -= 1
	_, span_ok = layer_span_index_hash(schedule_hash, index)
	testing.expect(t, !span_ok)
	index.triangle_ranges[0].layer_count += 1

	index.triangle_indices[1] = index.triangle_indices[0]
	_, span_ok = layer_span_index_hash(schedule_hash, index)
	testing.expect(t, !span_ok)
	index.triangle_indices[1] = 4

	index.triangle_ids[0] = contracts.INVALID_STABLE_ID
	_, span_ok = layer_span_index_hash(schedule_hash, index)
	testing.expect(t, !span_ok)
}

@(test)
intersection_and_snapped_segment_hashes_are_stable_test :: proc(
	t: ^testing.T,
) {
	schedule, schedule_error := fixed_layer_schedule_build({
		minimum_z = -1000,
		maximum_z = 1500,
		first_plane_z = 0,
		layer_step = 1000,
		max_layer_count = 3,
	})
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	schedule_hash, schedule_hash_ok := fixed_layer_schedule_hash(schedule)
	testing.expect(t, schedule_hash_ok)
	mesh := cpu_intersection_test_mesh()
	index, span_error := layer_span_index_build(mesh, schedule)
	defer layer_span_index_destroy(&index)
	testing.expect_value(t, span_error, Layer_Span_Error.None)
	span_hash, span_hash_ok := layer_span_index_hash(schedule_hash, index)
	testing.expect(t, span_hash_ok)
	intersections, intersection_error := cpu_intersections_build(
		mesh,
		schedule,
		index,
	)
	defer cpu_intersections_destroy(&intersections)
	testing.expect_value(
		t,
		intersection_error,
		CPU_Intersection_Error.None,
	)
	intersection_hash, intersection_hash_ok :=
		cpu_intersection_result_hash(span_hash, intersections)
	testing.expect(t, intersection_hash_ok)
	expected_intersection_hash := contracts.Content_Hash{
		0x3b, 0xcf, 0xda, 0x3f, 0xc6, 0x7e, 0x2b, 0xbe,
		0x84, 0xc4, 0x84, 0x21, 0x86, 0x68, 0x29, 0x91,
		0xc3, 0xae, 0x05, 0x22, 0x1d, 0x54, 0xe9, 0x7c,
		0xc6, 0xa9, 0xd3, 0x21, 0xdb, 0x0e, 0x5a, 0x90,
	}
	testing.expect_value(
		t,
		intersection_hash,
		expected_intersection_hash,
	)

	snapped, snap_error := snapped_segments_build(intersections)
	defer snapped_segments_destroy(&snapped)
	testing.expect_value(t, snap_error, Snapped_Segment_Error.None)
	snapped_hash, snapped_hash_ok := snapped_segment_result_hash(
		intersection_hash,
		snapped,
	)
	testing.expect(t, snapped_hash_ok)
	expected_snapped_hash := contracts.Content_Hash{
		0x23, 0x8e, 0x80, 0x55, 0xf3, 0x90, 0xff, 0xae,
		0xb6, 0x65, 0x6c, 0x1a, 0x7c, 0x7e, 0xa8, 0xc2,
		0xef, 0xaa, 0x1f, 0x0f, 0x13, 0x19, 0x2f, 0x0b,
		0x57, 0xd2, 0x4f, 0x11, 0x22, 0x4f, 0xfb, 0xd1,
	}
	testing.expect_value(t, snapped_hash, expected_snapped_hash)
}

@(test)
snapped_segment_hash_excludes_diagnostic_error_measurements_test :: proc(
	t: ^testing.T,
) {
	raw := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 1, 0, 0}},
		segments = {
			layer_indices = []u32{0},
			triangle_indices = []u32{4},
			segment_ids = []contracts.Stable_ID{40},
			triangle_ids = []contracts.Stable_ID{400},
			edge_a = []Triangle_Edge{.AB},
			edge_b = []Triangle_Edge{.CA},
			x0 = []f64{0},
			y0 = []f64{0},
			x1 = []f64{1},
			y1 = []f64{1},
		},
	}
	snapped, error := snapped_segments_build(raw)
	defer snapped_segments_destroy(&snapped)
	testing.expect_value(t, error, Snapped_Segment_Error.None)
	before, before_ok := snapped_segment_result_hash({}, snapped)
	testing.expect(t, before_ok)
	snapped.segments.x0_error_um[0] = 0.4
	snapped.maximum_snap_error_um = 0.4
	after, after_ok := snapped_segment_result_hash({}, snapped)
	testing.expect(t, after_ok)
	testing.expect_value(t, after, before)
}
