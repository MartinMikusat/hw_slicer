package slicing

import "core:math"
import "core:testing"

import geometry "../geometry"

@(test)
triangle_plane_intersection_emits_canonical_segment_test :: proc(
	t: ^testing.T,
) {
	result, error := triangle_plane_intersect(
		[3]f64{0, 2, 0},
		[3]f64{0, 0, 2},
		[3]f64{-1, 1, -1},
		0,
	)
	testing.expect_value(t, error, Triangle_Plane_Error.None)
	testing.expect_value(t, result.kind, Triangle_Plane_Kind.Segment)
	testing.expect_value(t, result.point_a, Raw_Point_2{1, 0})
	testing.expect_value(t, result.point_b, Raw_Point_2{1, 1})
	testing.expect_value(t, result.edge_a, Triangle_Edge.AB)
	testing.expect_value(t, result.edge_b, Triangle_Edge.BC)
}

@(test)
triangle_plane_intersection_applies_half_open_vertex_rule_test :: proc(
	t: ^testing.T,
) {
	crossing, crossing_error := triangle_plane_intersect(
		[3]f64{0, 2, 0},
		[3]f64{0, 0, 2},
		[3]f64{0, 1, -1},
		0,
	)
	tangent, tangent_error := triangle_plane_intersect(
		[3]f64{0, 2, 0},
		[3]f64{0, 0, 2},
		[3]f64{0, 1, 1},
		0,
	)
	testing.expect_value(t, crossing_error, Triangle_Plane_Error.None)
	testing.expect_value(t, tangent_error, Triangle_Plane_Error.None)
	testing.expect_value(t, crossing.kind, Triangle_Plane_Kind.Segment)
	testing.expect_value(t, crossing.point_a, Raw_Point_2{0, 0})
	testing.expect_value(t, crossing.point_b, Raw_Point_2{1, 1})
	testing.expect_value(t, tangent.kind, Triangle_Plane_Kind.Tangent_Vertex)
}

@(test)
triangle_plane_intersection_separates_coplanar_cases_test :: proc(
	t: ^testing.T,
) {
	edge, edge_error := triangle_plane_intersect(
		[3]f64{0, 2, 0},
		[3]f64{0, 0, 2},
		[3]f64{0, 0, 1},
		0,
	)
	face, face_error := triangle_plane_intersect(
		[3]f64{0, 2, 0},
		[3]f64{0, 0, 2},
		[3]f64{0, 0, 0},
		0,
	)
	testing.expect_value(t, edge_error, Triangle_Plane_Error.None)
	testing.expect_value(t, face_error, Triangle_Plane_Error.None)
	testing.expect_value(t, edge.kind, Triangle_Plane_Kind.Coplanar_Edge)
	testing.expect_value(t, edge.edge_a, Triangle_Edge.AB)
	testing.expect_value(t, face.kind, Triangle_Plane_Kind.Coplanar_Face)
}

@(test)
triangle_plane_intersection_reports_degenerate_projection_test :: proc(
	t: ^testing.T,
) {
	result, error := triangle_plane_intersect(
		[3]f64{1, 1, 1},
		[3]f64{1, 1, 1},
		[3]f64{-1, 1, -1},
		0,
	)
	testing.expect_value(t, error, Triangle_Plane_Error.None)
	testing.expect_value(
		t,
		result.kind,
		Triangle_Plane_Kind.Degenerate_Segment,
	)
}

@(test)
triangle_plane_intersection_records_exact_predicate_paths_test :: proc(
	t: ^testing.T,
) {
	result, error := triangle_plane_intersect(
		[3]f64{0, 2, 0},
		[3]f64{0, 0, 2},
		[3]f64{0.5, 1, 0},
		500,
	)
	testing.expect_value(t, error, Triangle_Plane_Error.None)
	testing.expect_value(t, result.exact_predicate_count, u8(1))
}

@(test)
triangle_plane_intersection_rejects_invalid_coordinates_test :: proc(
	t: ^testing.T,
) {
	_, error := triangle_plane_intersect(
		[3]f64{f64(geometry.MAX_PLANAR_COORDINATE_UM), 0, 0},
		[3]f64{0, 0, 0},
		[3]f64{-1, 1, -1},
		0,
	)
	testing.expect_value(t, error, Triangle_Plane_Error.Invalid_Coordinate)
}

@(test)
triangle_plane_intersection_is_invariant_under_vertex_permutations_test :: proc(
	t: ^testing.T,
) {
	source_x := [3]f64{0, 3, 1}
	source_y := [3]f64{0, 1, 4}
	source_z := [3]f64{-2, 2, -2}
	permutations := [6][3]int{
		{0, 1, 2},
		{0, 2, 1},
		{1, 0, 2},
		{1, 2, 0},
		{2, 0, 1},
		{2, 1, 0},
	}
	for permutation in permutations {
		x, y, z: [3]f64
		for source_index, output_index in permutation {
			x[output_index] = source_x[source_index]
			y[output_index] = source_y[source_index]
			z[output_index] = source_z[source_index]
		}
		result, error := triangle_plane_intersect(x, y, z, 0)
		testing.expect_value(t, error, Triangle_Plane_Error.None)
		testing.expect_value(t, result.kind, Triangle_Plane_Kind.Segment)
		testing.expect_value(t, result.point_a, Raw_Point_2{1.5, 0.5})
		testing.expect_value(t, result.point_b, Raw_Point_2{2, 2.5})
	}
}

@(test)
triangle_plane_intersection_handles_adjacent_f64_plane_values_test :: proc(
	t: ^testing.T,
) {
	center := f64(0.2)
	lower := math.nextafter_f64(center, math.inf_f64(-1))
	upper := math.nextafter_f64(center, math.inf_f64(1))
	result, error := triangle_plane_intersect(
		[3]f64{0, 2, 0},
		[3]f64{0, 0, 2},
		[3]f64{lower, upper, lower},
		200,
	)
	testing.expect_value(t, error, Triangle_Plane_Error.None)
	testing.expect_value(t, result.kind, Triangle_Plane_Kind.Segment)
	testing.expect_value(t, result.point_a, Raw_Point_2{1, 0})
	testing.expect_value(t, result.point_b, Raw_Point_2{1, 1})
	testing.expect_value(t, result.exact_predicate_count, u8(3))
}
