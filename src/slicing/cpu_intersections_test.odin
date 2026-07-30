package slicing

import "core:testing"

import contracts "../contracts"
import geometry "../geometry"

CPU_INTERSECTION_TEST_VERTEX_X := [12]f64{
	0, 2, 0,
	3, 5, 3,
	6, 8, 6,
	9, 11, 9,
}
CPU_INTERSECTION_TEST_VERTEX_Y := [12]f64{
	0, 0, 2,
	0, 0, 2,
	0, 0, 2,
	0, 0, 2,
}
CPU_INTERSECTION_TEST_VERTEX_Z := [12]f64{
	-1, 1, -1,
	0, 1, 1,
	0, 0, 1,
	0.0000004, -0.0000004, 0,
}
CPU_INTERSECTION_TEST_TRIANGLE_A := [4]u32{0, 3, 6, 9}
CPU_INTERSECTION_TEST_TRIANGLE_B := [4]u32{1, 4, 7, 10}
CPU_INTERSECTION_TEST_TRIANGLE_C := [4]u32{2, 5, 8, 11}
CPU_INTERSECTION_TEST_TRIANGLE_IDS := [4]contracts.Stable_ID{
	100,
	101,
	102,
	103,
}

cpu_intersection_test_mesh :: proc() -> geometry.Canonical_Mesh {
	return {
		coordinate_units = .Millimetres,
		vertex_x = CPU_INTERSECTION_TEST_VERTEX_X[:],
		vertex_y = CPU_INTERSECTION_TEST_VERTEX_Y[:],
		vertex_z = CPU_INTERSECTION_TEST_VERTEX_Z[:],
		triangle_a = CPU_INTERSECTION_TEST_TRIANGLE_A[:],
		triangle_b = CPU_INTERSECTION_TEST_TRIANGLE_B[:],
		triangle_c = CPU_INTERSECTION_TEST_TRIANGLE_C[:],
		triangle_ids = CPU_INTERSECTION_TEST_TRIANGLE_IDS[:],
	}
}

@(test)
cpu_intersections_compacts_segments_and_planar_candidates_test :: proc(
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
	mesh := cpu_intersection_test_mesh()
	index, span_error := layer_span_index_build(mesh, schedule)
	defer layer_span_index_destroy(&index)
	testing.expect_value(t, span_error, Layer_Span_Error.None)
	result, intersection_error := cpu_intersections_build(
		mesh,
		schedule,
		index,
	)
	defer cpu_intersections_destroy(&result)
	testing.expect_value(
		t,
		intersection_error,
		CPU_Intersection_Error.None,
	)
	testing.expect_value(t, len(result.layers), 2)
	testing.expect_value(
		t,
		result.layers[0],
		Intersection_Layer{0, 1, 0, 2},
	)
	testing.expect_value(
		t,
		result.layers[1],
		Intersection_Layer{1, 0, 2, 0},
	)
	testing.expect_value(t, len(result.segments.x0), 1)
	testing.expect_value(t, result.segments.triangle_indices[0], u32(0))
	testing.expect_value(t, result.segments.triangle_ids[0], contracts.Stable_ID(100))
	testing.expect_value(t, result.segments.x0[0], f64(1))
	testing.expect_value(t, result.segments.y0[0], f64(0))
	testing.expect_value(t, result.segments.x1[0], f64(1))
	testing.expect_value(t, result.segments.y1[0], f64(1))
	testing.expect_value(t, len(result.planar_candidates), 2)
	testing.expect_value(
		t,
		result.planar_candidates[0].kind,
		Planar_Candidate_Kind.Exact_Edge,
	)
	testing.expect_value(
		t,
		result.planar_candidates[1].kind,
		Planar_Candidate_Kind.Quantized_Face,
	)
	testing.expect_value(t, result.tangent_count, u64(1))
	testing.expect_value(t, result.degenerate_count, u64(0))
	testing.expect_value(t, result.exact_predicate_count, u64(3))
}

@(test)
cpu_intersections_enforces_output_limits_before_output_allocation_test :: proc(
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
	mesh := cpu_intersection_test_mesh()
	index, span_error := layer_span_index_build(mesh, schedule)
	defer layer_span_index_destroy(&index)
	testing.expect_value(t, span_error, Layer_Span_Error.None)
	_, segment_error := cpu_intersections_build(
		mesh,
		schedule,
		index,
		{max_segments = 0, max_planar_candidates = 10},
	)
	_, planar_error := cpu_intersections_build(
		mesh,
		schedule,
		index,
		{max_segments = 10, max_planar_candidates = 1},
	)
	testing.expect_value(
		t,
		segment_error,
		CPU_Intersection_Error.Segment_Limit,
	)
	testing.expect_value(
		t,
		planar_error,
		CPU_Intersection_Error.Planar_Limit,
	)
}
