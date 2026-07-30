package slicing

import "core:testing"

import contracts "../contracts"
import geometry "../geometry"

LAYER_SPAN_TEST_VERTEX_Z := [15]f64{
	0, 0.5, 1,
	0.4, 0.4, 0.4,
	0.801, 0.9, 0.999,
	0.3999996, 0.4, 0.4000004,
	0.2, 0.3, 0.4,
}
LAYER_SPAN_TEST_TRIANGLE_A := [5]u32{0, 3, 6, 9, 12}
LAYER_SPAN_TEST_TRIANGLE_B := [5]u32{1, 4, 7, 10, 13}
LAYER_SPAN_TEST_TRIANGLE_C := [5]u32{2, 5, 8, 11, 14}
LAYER_SPAN_TEST_TRIANGLE_IDS := [5]contracts.Stable_ID{10, 11, 12, 13, 14}

layer_span_test_mesh :: proc() -> geometry.Canonical_Mesh {
	return {
		vertex_z = LAYER_SPAN_TEST_VERTEX_Z[:],
		triangle_a = LAYER_SPAN_TEST_TRIANGLE_A[:],
		triangle_b = LAYER_SPAN_TEST_TRIANGLE_B[:],
		triangle_c = LAYER_SPAN_TEST_TRIANGLE_C[:],
		triangle_ids = LAYER_SPAN_TEST_TRIANGLE_IDS[:],
	}
}

@(test)
layer_span_index_applies_half_open_and_planar_candidate_rules_test :: proc(
	t: ^testing.T,
) {
	schedule, schedule_error := fixed_layer_schedule_build({
		minimum_z = 0,
		maximum_z = 1000,
		first_plane_z = 200,
		layer_step = 200,
		max_layer_count = 10,
	})
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	mesh := layer_span_test_mesh()
	index, error := layer_span_index_build(mesh, schedule)
	defer layer_span_index_destroy(&index)
	testing.expect_value(t, error, Layer_Span_Error.None)
	testing.expect_value(t, len(index.triangle_ranges), 5)
	testing.expect_value(
		t,
		index.triangle_ranges[0],
		Triangle_Layer_Range{0, 4, .Crossing_Candidates},
	)
	testing.expect_value(
		t,
		index.triangle_ranges[1],
		Triangle_Layer_Range{1, 1, .Quantized_Planar},
	)
	testing.expect_value(
		t,
		index.triangle_ranges[2],
		Triangle_Layer_Range{},
	)
	testing.expect_value(
		t,
		index.triangle_ranges[3],
		Triangle_Layer_Range{1, 1, .Quantized_Planar},
	)
	testing.expect_value(
		t,
		index.triangle_ranges[4],
		Triangle_Layer_Range{0, 1, .Crossing_Candidates},
	)
	testing.expect_value(t, index.layers[0], Layer_Descriptor{0, 2})
	testing.expect_value(t, index.layers[1], Layer_Descriptor{2, 3})
	testing.expect_value(t, index.layers[2], Layer_Descriptor{5, 1})
	testing.expect_value(t, index.layers[3], Layer_Descriptor{6, 1})
	expected_ids := []contracts.Stable_ID{10, 14, 10, 11, 13, 10, 10}
	expected_indices := []u32{0, 4, 0, 1, 3, 0, 0}
	testing.expect_value(t, len(index.triangle_ids), len(expected_ids))
	for triangle_id, pair_index in expected_ids {
		testing.expect_value(t, index.triangle_ids[pair_index], triangle_id)
		testing.expect_value(
			t,
			index.triangle_indices[pair_index],
			expected_indices[pair_index],
		)
	}
}

@(test)
layer_span_index_rejects_pair_limit_before_pair_allocation_test :: proc(
	t: ^testing.T,
) {
	schedule, schedule_error := fixed_layer_schedule_build({
		minimum_z = 0,
		maximum_z = 1000,
		first_plane_z = 200,
		layer_step = 200,
		max_layer_count = 10,
	})
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	mesh := layer_span_test_mesh()
	_, error := layer_span_index_build(mesh, schedule, {max_pairs = 6})
	testing.expect_value(t, error, Layer_Span_Error.Pair_Limit)
}
