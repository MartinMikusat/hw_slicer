package slicing

import "core:math"
import "core:testing"

import contracts "../contracts"

@(test)
snapped_segments_quantize_compact_and_preserve_provenance_test :: proc(
	t: ^testing.T,
) {
	raw := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 2, 0, 0}},
		segments = {
			layer_indices = []u32{0, 0},
			triangle_indices = []u32{4, 5},
			segment_ids = []contracts.Stable_ID{40, 50},
			triangle_ids = []contracts.Stable_ID{400, 500},
			edge_a = []Triangle_Edge{.AB, .BC},
			edge_b = []Triangle_Edge{.CA, .CA},
			x0 = []f64{0.00049, 1.0001},
			y0 = []f64{0.00049, 1.0001},
			x1 = []f64{0.00151, 1.0004},
			y1 = []f64{0.00249, 1.0004},
		},
	}
	result, error := snapped_segments_build(raw)
	defer snapped_segments_destroy(&result)
	testing.expect_value(t, error, Snapped_Segment_Error.None)
	testing.expect_value(t, result.layers[0], Snapped_Layer{0, 1})
	testing.expect_value(t, result.collapsed_count, u64(1))
	testing.expect_value(t, len(result.segments.segment_ids), 1)
	testing.expect_value(t, result.segments.segment_ids[0], contracts.Stable_ID(40))
	testing.expect_value(t, result.segments.x0[0], contracts.Micrometres(0))
	testing.expect_value(t, result.segments.y0[0], contracts.Micrometres(0))
	testing.expect_value(t, result.segments.x1[0], contracts.Micrometres(2))
	testing.expect_value(t, result.segments.y1[0], contracts.Micrometres(2))
	testing.expect(
		t,
		math.abs(result.maximum_snap_error_um-0.49) < 0.000000000001,
	)
}

@(test)
snapped_segments_reorders_endpoints_after_quantization_test :: proc(
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
			x0 = []f64{0.002},
			y0 = []f64{0.001},
			x1 = []f64{0.001},
			y1 = []f64{0.002},
		},
	}
	result, error := snapped_segments_build(raw)
	defer snapped_segments_destroy(&result)
	testing.expect_value(t, error, Snapped_Segment_Error.None)
	testing.expect_value(t, result.segments.x0[0], contracts.Micrometres(1))
	testing.expect_value(t, result.segments.edge_a[0], Triangle_Edge.CA)
	testing.expect_value(t, result.segments.edge_b[0], Triangle_Edge.AB)
}

@(test)
snapped_segments_sort_each_layer_into_canonical_order_test :: proc(
	t: ^testing.T,
) {
	raw := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 2, 0, 0}},
		segments = {
			layer_indices = []u32{0, 0},
			triangle_indices = []u32{5, 4},
			segment_ids = []contracts.Stable_ID{50, 40},
			triangle_ids = []contracts.Stable_ID{500, 400},
			edge_a = []Triangle_Edge{.AB, .AB},
			edge_b = []Triangle_Edge{.CA, .CA},
			x0 = []f64{2, 0},
			y0 = []f64{2, 0},
			x1 = []f64{3, 1},
			y1 = []f64{3, 1},
		},
	}
	result, error := snapped_segments_build(raw)
	defer snapped_segments_destroy(&result)
	testing.expect_value(t, error, Snapped_Segment_Error.None)
	testing.expect_value(t, result.segments.segment_ids[0], contracts.Stable_ID(40))
	testing.expect_value(t, result.segments.segment_ids[1], contracts.Stable_ID(50))
}

@(test)
snapped_segment_merge_restores_canonical_layer_order_test :: proc(
	t: ^testing.T,
) {
	left_raw := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 1, 0, 0}},
		segments = {
			layer_indices = []u32{0},
			triangle_indices = []u32{5},
			segment_ids = []contracts.Stable_ID{50},
			triangle_ids = []contracts.Stable_ID{500},
			edge_a = []Triangle_Edge{.AB},
			edge_b = []Triangle_Edge{.CA},
			x0 = []f64{2},
			y0 = []f64{2},
			x1 = []f64{3},
			y1 = []f64{3},
		},
	}
	right_raw := CPU_Intersection_Result{
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
	left, left_error := snapped_segments_build(left_raw)
	defer snapped_segments_destroy(&left)
	right, right_error := snapped_segments_build(right_raw)
	defer snapped_segments_destroy(&right)
	testing.expect_value(t, left_error, Snapped_Segment_Error.None)
	testing.expect_value(t, right_error, Snapped_Segment_Error.None)
	merged, merge_error := snapped_segments_merge(left, right)
	defer snapped_segments_destroy(&merged)
	testing.expect_value(t, merge_error, Snapped_Segment_Error.None)
	testing.expect_value(t, merged.layers[0], Snapped_Layer{0, 2})
	testing.expect_value(t, merged.segments.segment_ids[0], contracts.Stable_ID(40))
	testing.expect_value(t, merged.segments.segment_ids[1], contracts.Stable_ID(50))
}

@(test)
snapped_segments_rejects_inconsistent_raw_arrays_test :: proc(t: ^testing.T) {
	_, error := snapped_segments_build({
		layers = []Intersection_Layer{{}},
		segments = {segment_ids = []contracts.Stable_ID{1}},
	})
	testing.expect_value(t, error, Snapped_Segment_Error.Invalid_Input)
}
