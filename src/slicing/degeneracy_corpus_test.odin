package slicing

import "core:math"
import "core:testing"

import contracts "../contracts"
import geometry "../geometry"

@(test)
generated_triangle_plane_corpus_is_permutation_invariant_after_snapping_test :: proc(
	t: ^testing.T,
) {
	permutations := [6][3]int{
		{0, 1, 2},
		{0, 2, 1},
		{1, 0, 2},
		{1, 2, 0},
		{2, 0, 1},
		{2, 1, 0},
	}
	source_x := [3]f64{0, 2, 0}
	source_y := [3]f64{0, 0, 2}
	for case_index in 0..<257 {
		plane := contracts.Micrometres(-1_000_000+case_index*7_813)
		center := f64(i64(plane))/geometry.MICROMETRES_PER_MILLIMETRE
		lower := math.nextafter_f64(center, math.inf_f64(-1))
		upper := math.nextafter_f64(center, math.inf_f64(1))
		source_z := [3]f64{lower, upper, lower}
		for permutation in permutations {
			x, y, z: [3]f64
			for source_index, output_index in permutation {
				x[output_index] = source_x[source_index]
				y[output_index] = source_y[source_index]
				z[output_index] = source_z[source_index]
			}
			result, error := triangle_plane_intersect(x, y, z, plane)
			testing.expect_value(t, error, Triangle_Plane_Error.None)
			testing.expect_value(t, result.kind, Triangle_Plane_Kind.Segment)
			a_x, a_x_error := geometry.millimetres_to_micrometres(
				contracts.Millimetres(result.point_a.x),
			)
			a_y, a_y_error := geometry.millimetres_to_micrometres(
				contracts.Millimetres(result.point_a.y),
			)
			b_x, b_x_error := geometry.millimetres_to_micrometres(
				contracts.Millimetres(result.point_b.x),
			)
			b_y, b_y_error := geometry.millimetres_to_micrometres(
				contracts.Millimetres(result.point_b.y),
			)
			testing.expect_value(t, a_x_error, geometry.Numeric_Error.None)
			testing.expect_value(t, a_y_error, geometry.Numeric_Error.None)
			testing.expect_value(t, b_x_error, geometry.Numeric_Error.None)
			testing.expect_value(t, b_y_error, geometry.Numeric_Error.None)
			testing.expect_value(t, a_x, contracts.Micrometres(1000))
			testing.expect_value(t, a_y, contracts.Micrometres(0))
			testing.expect_value(t, b_x, contracts.Micrometres(1000))
			testing.expect_value(t, b_y, contracts.Micrometres(1000))
		}
	}
}

@(test)
generated_topology_corpus_is_invariant_to_order_and_direction_test :: proc(
	t: ^testing.T,
) {
	schedule, schedule_error := topology_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	logical_x0 := [4]f64{1, 0, 0, 1}
	logical_y0 := [4]f64{0, 0, 1, 1}
	logical_x1 := [4]f64{1, 1, 0, 0}
	logical_y1 := [4]f64{1, 0, 0, 1}
	expected_hash := contracts.Content_Hash{
		0xae, 0xb1, 0xe9, 0x88, 0x71, 0x86, 0x0c, 0x5d,
		0xf3, 0x7f, 0x64, 0xe6, 0x7d, 0x36, 0x3f, 0x67,
		0x99, 0x78, 0xa4, 0x24, 0x9d, 0x10, 0x22, 0x40,
		0x6f, 0xd6, 0x0f, 0x42, 0xb0, 0xac, 0x7d, 0x9d,
	}
	for a in 0..<4 {
		for b in 0..<4 {
			if b == a {continue}
			for c in 0..<4 {
				if c == a || c == b {continue}
				for d in 0..<4 {
					if d == a || d == b || d == c {continue}
					permutation := [4]int{a, b, c, d}
					for flip_mask in 0..<16 {
						layer_indices: [4]u32
						triangle_indices: [4]u32
						segment_ids: [4]contracts.Stable_ID
						triangle_ids: [4]contracts.Stable_ID
						edge_a: [4]Triangle_Edge
						edge_b: [4]Triangle_Edge
						x0, y0, x1, y1: [4]f64
						for logical_index, output_index in permutation {
							layer_indices[output_index] = 0
							triangle_indices[output_index] =
								u32(logical_index)
							segment_ids[output_index] =
								contracts.Stable_ID(10+logical_index)
							triangle_ids[output_index] =
								contracts.Stable_ID(100+logical_index)
							edge_a[output_index] = .AB
							edge_b[output_index] = .BC
							x0[output_index] = logical_x0[logical_index]
							y0[output_index] = logical_y0[logical_index]
							x1[output_index] = logical_x1[logical_index]
							y1[output_index] = logical_y1[logical_index]
							if u32(flip_mask)&(u32(1)<<u32(logical_index)) != 0 {
								x0[output_index], x1[output_index] =
									x1[output_index], x0[output_index]
								y0[output_index], y1[output_index] =
									y1[output_index], y0[output_index]
								edge_a[output_index], edge_b[output_index] =
									edge_b[output_index], edge_a[output_index]
							}
						}
						raw := CPU_Intersection_Result{
							layers = []Intersection_Layer{{0, 4, 0, 0}},
							segments = {
								layer_indices = layer_indices[:],
								triangle_indices = triangle_indices[:],
								segment_ids = segment_ids[:],
								triangle_ids = triangle_ids[:],
								edge_a = edge_a[:],
								edge_b = edge_b[:],
								x0 = x0[:],
								y0 = y0[:],
								x1 = x1[:],
								y1 = y1[:],
							},
						}
						snapped, snap_error := snapped_segments_build(raw)
						topology, topology_error :=
							topology_reconstruct(schedule, snapped)
						topology_hash, hash_ok := topology_result_hash(
							{},
							len(snapped.segments.segment_ids),
							topology,
						)
						testing.expect_value(
							t,
							snap_error,
							Snapped_Segment_Error.None,
						)
						testing.expect_value(
							t,
							topology_error,
							Topology_Error.None,
						)
						testing.expect(t, hash_ok)
						testing.expect_value(t, topology_hash, expected_hash)
						topology_result_destroy(&topology)
						snapped_segments_destroy(&snapped)
					}
				}
			}
		}
	}
}
