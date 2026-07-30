package slicing

import "core:testing"

import contracts "../contracts"
import geometry "../geometry"

PLANAR_TEST_VERTEX_X := [12]f64{
	0, 1, 0,
	0, 1, 0,
	1, 0, 1,
	0, 0, -1,
}
PLANAR_TEST_VERTEX_Y := [12]f64{
	0, 0, 1,
	0, 0, -1,
	0, 1, 1,
	1, 0, 0,
}
PLANAR_TEST_VERTEX_Z_ABOVE := [12]f64{
	0, 0, 0,
	0, 0, 1,
	0, 0, 1,
	0, 0, 1,
}
PLANAR_TEST_VERTEX_Z_BELOW := [12]f64{
	0, 0, 0,
	0, 0, -1,
	0, 0, -1,
	0, 0, -1,
}
PLANAR_TEST_TRIANGLE_A := [4]u32{0, 3, 6, 9}
PLANAR_TEST_TRIANGLE_B := [4]u32{1, 4, 7, 10}
PLANAR_TEST_TRIANGLE_C := [4]u32{2, 5, 8, 11}
PLANAR_TEST_TRIANGLE_IDS := [4]contracts.Stable_ID{100, 101, 102, 103}
PLANAR_TEST_CANDIDATES := [4]Planar_Candidate{
	{0, 0, 100, .Quantized_Face, .Invalid},
	{0, 1, 101, .Exact_Edge, .AB},
	{0, 2, 102, .Exact_Edge, .AB},
	{0, 3, 103, .Exact_Edge, .AB},
}

planar_test_mesh :: proc(vertex_z: []f64) -> geometry.Canonical_Mesh {
	return {
		coordinate_units = .Millimetres,
		vertex_x = PLANAR_TEST_VERTEX_X[:],
		vertex_y = PLANAR_TEST_VERTEX_Y[:],
		vertex_z = vertex_z,
		triangle_a = PLANAR_TEST_TRIANGLE_A[:],
		triangle_b = PLANAR_TEST_TRIANGLE_B[:],
		triangle_c = PLANAR_TEST_TRIANGLE_C[:],
		triangle_ids = PLANAR_TEST_TRIANGLE_IDS[:],
	}
}

planar_test_schedule :: proc() -> (Fixed_Layer_Schedule, Schedule_Error) {
	return fixed_layer_schedule_build({
		minimum_z = -1000,
		maximum_z = 1000,
		first_plane_z = 0,
		layer_step = 1000,
		max_layer_count = 1,
	})
}

@(test)
planar_ownership_emits_one_boundary_for_each_bottom_face_edge_test :: proc(
	t: ^testing.T,
) {
	schedule, schedule_error := planar_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	mesh := planar_test_mesh(PLANAR_TEST_VERTEX_Z_ABOVE[:])
	intersections := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 0, 0, 4}},
		planar_candidates = PLANAR_TEST_CANDIDATES[:],
	}
	owned, error := planar_ownership_resolve(
		mesh,
		schedule,
		intersections,
	)
	defer planar_ownership_destroy(&owned)
	testing.expect_value(t, error, Planar_Ownership_Error.None)
	testing.expect_value(t, owned.incidence_count, u64(6))
	testing.expect_value(t, owned.unresolved_group_count, u64(0))
	testing.expect_value(t, owned.suppressed_group_count, u64(0))
	testing.expect_value(t, len(owned.segments.segment_ids), 3)
	testing.expect_value(t, owned.layers[0], Snapped_Layer{0, 3})
	topology, topology_error := topology_reconstruct(
		schedule,
		{
			layers = owned.layers,
			segments = owned.segments,
		},
	)
	defer topology_result_destroy(&topology)
	testing.expect_value(t, topology_error, Topology_Error.None)
	testing.expect_value(t, len(topology.paths), 1)
	testing.expect_value(t, topology.paths[0].kind, Topology_Path_Kind.Loop)
	ownership_hash, ownership_hash_ok :=
		planar_ownership_result_hash({}, owned)
	testing.expect(t, ownership_hash_ok)
	expected_ownership_hash := contracts.Content_Hash{
		0x36, 0x35, 0x3c, 0x0b, 0x9d, 0xa5, 0x64, 0x6b,
		0x25, 0x98, 0xb4, 0xf5, 0x81, 0x44, 0xea, 0x21,
		0x28, 0xdd, 0x84, 0x49, 0x3e, 0x70, 0x27, 0x11,
		0x33, 0x27, 0x12, 0x3e, 0xf6, 0x71, 0xeb, 0xe6,
	}
	testing.expect_value(t, ownership_hash, expected_ownership_hash)
}

@(test)
planar_ownership_suppresses_the_excluded_top_face_boundary_test :: proc(
	t: ^testing.T,
) {
	schedule, schedule_error := planar_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	mesh := planar_test_mesh(PLANAR_TEST_VERTEX_Z_BELOW[:])
	intersections := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 0, 0, 4}},
		planar_candidates = PLANAR_TEST_CANDIDATES[:],
	}
	owned, error := planar_ownership_resolve(
		mesh,
		schedule,
		intersections,
	)
	defer planar_ownership_destroy(&owned)
	testing.expect_value(t, error, Planar_Ownership_Error.None)
	testing.expect_value(t, len(owned.segments.segment_ids), 0)
	testing.expect_value(t, owned.suppressed_group_count, u64(3))
}

@(test)
planar_ownership_emits_a_half_open_edge_with_the_third_vertex_above_test :: proc(
	t: ^testing.T,
) {
	schedule, schedule_error := planar_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	mesh := planar_test_mesh(PLANAR_TEST_VERTEX_Z_ABOVE[:])
	intersections := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 0, 0, 1}},
		planar_candidates = PLANAR_TEST_CANDIDATES[1:2],
	}
	owned, error := planar_ownership_resolve(
		mesh,
		schedule,
		intersections,
	)
	defer planar_ownership_destroy(&owned)
	testing.expect_value(t, error, Planar_Ownership_Error.None)
	testing.expect_value(t, len(owned.segments.segment_ids), 1)
	testing.expect_value(t, owned.unresolved_group_count, u64(0))
	testing.expect_value(t, owned.suppressed_group_count, u64(0))
}

@(test)
planar_ownership_reports_three_incident_faces_as_nonmanifold_test :: proc(
	t: ^testing.T,
) {
	vertex_x := [9]f64{0, 1, 0, 0, 1, 0, 0, 1, 0}
	vertex_y := [9]f64{0, 0, 1, 0, 0, -1, 0, 0, 2}
	vertex_z := [9]f64{0, 0, 1, 0, 0, -1, 0, 0, 1}
	triangle_a := [3]u32{0, 3, 6}
	triangle_b := [3]u32{1, 4, 7}
	triangle_c := [3]u32{2, 5, 8}
	triangle_ids := [3]contracts.Stable_ID{100, 101, 102}
	mesh := geometry.Canonical_Mesh{
		coordinate_units = .Millimetres,
		vertex_x = vertex_x[:],
		vertex_y = vertex_y[:],
		vertex_z = vertex_z[:],
		triangle_a = triangle_a[:],
		triangle_b = triangle_b[:],
		triangle_c = triangle_c[:],
		triangle_ids = triangle_ids[:],
	}
	candidates := [3]Planar_Candidate{
		{0, 0, 100, .Exact_Edge, .AB},
		{0, 1, 101, .Exact_Edge, .AB},
		{0, 2, 102, .Exact_Edge, .AB},
	}
	schedule, schedule_error := planar_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	owned, error := planar_ownership_resolve(
		mesh,
		schedule,
		{
			layers = []Intersection_Layer{{0, 0, 0, 3}},
			planar_candidates = candidates[:],
		},
	)
	defer planar_ownership_destroy(&owned)
	testing.expect_value(t, error, Planar_Ownership_Error.None)
	testing.expect_value(t, owned.incidence_count, u64(3))
	testing.expect_value(t, owned.unresolved_group_count, u64(1))
	testing.expect_value(t, len(owned.segments.segment_ids), 0)
}

@(test)
planar_ownership_closes_a_manifold_bipyramid_midplane_test :: proc(
	t: ^testing.T,
) {
	vertex_x := [6]f64{-1, 1, 1, -1, 0, 0}
	vertex_y := [6]f64{-1, -1, 1, 1, 0, 0}
	vertex_z := [6]f64{0, 0, 0, 0, 1, -1}
	triangle_a := [8]u32{0, 1, 2, 3, 1, 2, 3, 0}
	triangle_b := [8]u32{1, 2, 3, 0, 0, 1, 2, 3}
	triangle_c := [8]u32{4, 4, 4, 4, 5, 5, 5, 5}
	triangle_ids := [8]contracts.Stable_ID{
		100, 101, 102, 103, 104, 105, 106, 107,
	}
	mesh := geometry.Canonical_Mesh{
		coordinate_units = .Millimetres,
		vertex_x = vertex_x[:],
		vertex_y = vertex_y[:],
		vertex_z = vertex_z[:],
		triangle_a = triangle_a[:],
		triangle_b = triangle_b[:],
		triangle_c = triangle_c[:],
		triangle_ids = triangle_ids[:],
	}
	schedule, schedule_error := fixed_layer_schedule_build({
		minimum_z = -1000,
		maximum_z = 1000,
		first_plane_z = 0,
		layer_step = 1000,
		max_layer_count = 1,
	})
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	spans, span_error := layer_span_index_build(mesh, schedule)
	defer layer_span_index_destroy(&spans)
	testing.expect_value(t, span_error, Layer_Span_Error.None)
	intersections, intersection_error := cpu_intersections_build(
		mesh,
		schedule,
		spans,
	)
	defer cpu_intersections_destroy(&intersections)
	testing.expect_value(
		t,
		intersection_error,
		CPU_Intersection_Error.None,
	)
	testing.expect_value(t, len(intersections.planar_candidates), 4)
	primary, snap_error := snapped_segments_build(intersections)
	defer snapped_segments_destroy(&primary)
	testing.expect_value(t, snap_error, Snapped_Segment_Error.None)
	owned, ownership_error := planar_ownership_resolve(
		mesh,
		schedule,
		intersections,
	)
	defer planar_ownership_destroy(&owned)
	testing.expect_value(
		t,
		ownership_error,
		Planar_Ownership_Error.None,
	)
	testing.expect_value(t, owned.unresolved_group_count, u64(0))
	testing.expect_value(t, owned.suppressed_group_count, u64(0))
	testing.expect_value(t, len(owned.segments.segment_ids), 4)
	merged, merge_error := snapped_segments_merge(
		primary,
		{
			layers = owned.layers,
			segments = owned.segments,
		},
	)
	defer snapped_segments_destroy(&merged)
	testing.expect_value(t, merge_error, Snapped_Segment_Error.None)
	topology, topology_error := topology_reconstruct(schedule, merged)
	defer topology_result_destroy(&topology)
	testing.expect_value(t, topology_error, Topology_Error.None)
	testing.expect_value(t, len(topology.paths), 1)
	testing.expect_value(t, topology.paths[0].kind, Topology_Path_Kind.Loop)
	testing.expect_value(t, topology.open_chain_count, u64(0))
	testing.expect_value(t, topology.non_manifold_vertex_count, u64(0))
}
