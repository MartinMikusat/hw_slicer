package slicing

import "core:testing"

import contracts "../contracts"
import geometry "../geometry"

topology_test_schedule :: proc() -> (Fixed_Layer_Schedule, Schedule_Error) {
	return fixed_layer_schedule_build({
		minimum_z = 0,
		maximum_z = 1000,
		first_plane_z = 0,
		layer_step = 1000,
		max_layer_count = 1,
	})
}

@(test)
topology_reconstructs_a_canonical_closed_loop_test :: proc(t: ^testing.T) {
	raw := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 4, 0, 0}},
		segments = {
			layer_indices = []u32{0, 0, 0, 0},
			triangle_indices = []u32{0, 1, 2, 3},
			segment_ids = []contracts.Stable_ID{10, 11, 12, 13},
			triangle_ids = []contracts.Stable_ID{100, 101, 102, 103},
			edge_a = []Triangle_Edge{.AB, .AB, .AB, .AB},
			edge_b = []Triangle_Edge{.BC, .BC, .BC, .BC},
			x0 = []f64{1, 0, 0, 0},
			y0 = []f64{0, 0, 0, 1},
			x1 = []f64{1, 1, 0, 1},
			y1 = []f64{1, 0, 1, 1},
		},
	}
	snapped, snap_error := snapped_segments_build(raw)
	defer snapped_segments_destroy(&snapped)
	testing.expect_value(t, snap_error, Snapped_Segment_Error.None)
	schedule, schedule_error := topology_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	topology, error := topology_reconstruct(schedule, snapped)
	defer topology_result_destroy(&topology)
	testing.expect_value(t, error, Topology_Error.None)
	testing.expect_value(t, len(topology.vertices), 4)
	testing.expect_value(t, len(topology.paths), 1)
	testing.expect_value(t, topology.layers[0], Topology_Layer{0, 4, 0, 1})
	testing.expect_value(t, topology.paths[0].kind, Topology_Path_Kind.Loop)
	testing.expect_value(t, topology.paths[0].vertex_count, u32(4))
	testing.expect_value(t, topology.paths[0].segment_count, u32(4))
	testing.expect_value(t, topology.paths[0].signed_area_2, i128(-2_000_000))
	testing.expect_value(
		t,
		topology.paths[0].winding,
		geometry.Predicate_Sign.Negative,
	)
	expected_vertices := []u32{0, 1, 3, 2}
	for vertex_index, path_index in expected_vertices {
		testing.expect_value(
			t,
			topology.path_vertex_indices[path_index],
			vertex_index,
		)
	}
	testing.expect_value(t, topology.open_chain_count, u64(0))
	testing.expect_value(t, topology.non_manifold_vertex_count, u64(0))
	topology_hash, topology_hash_ok := topology_result_hash(
		{},
		len(snapped.segments.segment_ids),
		topology,
	)
	testing.expect(t, topology_hash_ok)
	expected_topology_hash := contracts.Content_Hash{
		0xae, 0xb1, 0xe9, 0x88, 0x71, 0x86, 0x0c, 0x5d,
		0xf3, 0x7f, 0x64, 0xe6, 0x7d, 0x36, 0x3f, 0x67,
		0x99, 0x78, 0xa4, 0x24, 0x9d, 0x10, 0x22, 0x40,
		0x6f, 0xd6, 0x0f, 0x42, 0xb0, 0xac, 0x7d, 0x9d,
	}
	testing.expect_value(t, topology_hash, expected_topology_hash)
}

@(test)
topology_reconstructs_open_chains_and_reports_branch_vertices_test :: proc(
	t: ^testing.T,
) {
	raw := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 3, 0, 0}},
		segments = {
			layer_indices = []u32{0, 0, 0},
			triangle_indices = []u32{0, 1, 2},
			segment_ids = []contracts.Stable_ID{10, 11, 12},
			triangle_ids = []contracts.Stable_ID{100, 101, 102},
			edge_a = []Triangle_Edge{.AB, .AB, .AB},
			edge_b = []Triangle_Edge{.BC, .BC, .BC},
			x0 = []f64{1, 1, 1},
			y0 = []f64{0, 0, 0},
			x1 = []f64{0, 2, 1},
			y1 = []f64{0, 0, 1},
		},
	}
	snapped, snap_error := snapped_segments_build(raw)
	defer snapped_segments_destroy(&snapped)
	testing.expect_value(t, snap_error, Snapped_Segment_Error.None)
	schedule, schedule_error := topology_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	topology, error := topology_reconstruct(schedule, snapped)
	defer topology_result_destroy(&topology)
	testing.expect_value(t, error, Topology_Error.None)
	testing.expect_value(t, len(topology.vertices), 4)
	testing.expect_value(t, len(topology.paths), 2)
	testing.expect_value(t, len(topology.path_segment_indices), 3)
	testing.expect_value(t, topology.open_chain_count, u64(2))
	testing.expect_value(t, topology.non_manifold_vertex_count, u64(1))
	for path in topology.paths {
		testing.expect_value(t, path.kind, Topology_Path_Kind.Open_Chain)
	}
}

@(test)
topology_enforces_vertex_and_path_limits_before_work_allocation_test :: proc(
	t: ^testing.T,
) {
	schedule, schedule_error := topology_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	segments := Snapped_Segment_Result{
		layers = []Snapped_Layer{{0, 1}},
		segments = {
			layer_indices = []u32{0},
			triangle_indices = []u32{0},
			segment_ids = []contracts.Stable_ID{10},
			triangle_ids = []contracts.Stable_ID{100},
			edge_a = []Triangle_Edge{.AB},
			edge_b = []Triangle_Edge{.BC},
			x0 = []contracts.Micrometres{0},
			y0 = []contracts.Micrometres{0},
			x1 = []contracts.Micrometres{1000},
			y1 = []contracts.Micrometres{0},
			x0_error_um = []f64{0},
			y0_error_um = []f64{0},
			x1_error_um = []f64{0},
			y1_error_um = []f64{0},
		},
	}
	_, vertex_error := topology_reconstruct(
		schedule,
		segments,
		{max_vertices = 1, max_paths = 1, max_path_entries = 2},
	)
	_, path_error := topology_reconstruct(
		schedule,
		segments,
		{max_vertices = 2, max_paths = 0, max_path_entries = 2},
	)
	testing.expect_value(t, vertex_error, Topology_Error.Vertex_Limit)
	testing.expect_value(t, path_error, Topology_Error.Path_Limit)
}

@(test)
topology_classifies_a_closed_collinear_walk_as_degenerate_test :: proc(
	t: ^testing.T,
) {
	schedule, schedule_error := topology_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	segments := Snapped_Segment_Result{
		layers = []Snapped_Layer{{0, 3}},
		segments = {
			layer_indices = []u32{0, 0, 0},
			triangle_indices = []u32{0, 1, 2},
			segment_ids = []contracts.Stable_ID{10, 11, 12},
			triangle_ids = []contracts.Stable_ID{100, 101, 102},
			edge_a = []Triangle_Edge{.AB, .AB, .AB},
			edge_b = []Triangle_Edge{.BC, .BC, .BC},
			x0 = []contracts.Micrometres{0, 1000, 0},
			y0 = []contracts.Micrometres{0, 0, 0},
			x1 = []contracts.Micrometres{1000, 2000, 2000},
			y1 = []contracts.Micrometres{0, 0, 0},
			x0_error_um = []f64{0, 0, 0},
			y0_error_um = []f64{0, 0, 0},
			x1_error_um = []f64{0, 0, 0},
			y1_error_um = []f64{0, 0, 0},
		},
	}
	topology, error := topology_reconstruct(schedule, segments)
	defer topology_result_destroy(&topology)
	testing.expect_value(t, error, Topology_Error.None)
	testing.expect_value(t, len(topology.paths), 1)
	testing.expect_value(
		t,
		topology.paths[0].kind,
		Topology_Path_Kind.Degenerate_Loop,
	)
	testing.expect_value(t, topology.paths[0].signed_area_2, i128(0))
	testing.expect_value(t, topology.degenerate_loop_count, u64(1))
	testing.expect_value(t, topology.open_chain_count, u64(0))
}
