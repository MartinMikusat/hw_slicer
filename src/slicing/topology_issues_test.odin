package slicing

import "core:testing"

import contracts "../contracts"

@(test)
topology_issue_report_preserves_chain_and_branch_provenance_test :: proc(
	t: ^testing.T,
) {
	raw := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 3, 0, 0}},
		segments = {
			layer_indices = []u32{0, 0, 0},
			triangle_indices = []u32{20, 21, 22},
			segment_ids = []contracts.Stable_ID{10, 11, 12},
			triangle_ids = []contracts.Stable_ID{100, 101, 102},
			edge_a = []Triangle_Edge{.AB, .BC, .CA},
			edge_b = []Triangle_Edge{.BC, .CA, .AB},
			x0 = []f64{1, 1, 1},
			y0 = []f64{0, 0, 0},
			x1 = []f64{0, 2, 1},
			y1 = []f64{0, 0, 1},
		},
	}
	segments, snap_error := snapped_segments_build(raw)
	defer snapped_segments_destroy(&segments)
	testing.expect_value(t, snap_error, Snapped_Segment_Error.None)
	schedule, schedule_error := topology_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	topology, topology_error := topology_reconstruct(schedule, segments)
	defer topology_result_destroy(&topology)
	testing.expect_value(t, topology_error, Topology_Error.None)

	report, report_error := topology_issue_report_build(topology, segments)
	defer topology_issue_report_destroy(&report)
	testing.expect_value(t, report_error, Topology_Issue_Error.None)
	testing.expect_value(t, len(report.issues), 3)
	testing.expect_value(t, report.open_chain_count, u64(2))
	testing.expect_value(t, report.non_manifold_vertex_count, u64(1))
	testing.expect_value(t, len(report.segment_references), 6)
	testing.expect_value(
		t,
		report.issues[2].code,
		Topology_Issue_Code.Non_Manifold_Vertex,
	)
	testing.expect_value(t, report.issues[2].reference_count, u32(3))
	testing.expect_value(t, report.issues[2].point_a, Snapped_Point{1000, 0})
	for reference in report.segment_references[3:] {
		index := int(reference.segment_index)
		testing.expect_value(
			t,
			reference.segment_id,
			segments.segments.segment_ids[index],
		)
		testing.expect_value(
			t,
			reference.triangle_id,
			segments.segments.triangle_ids[index],
		)
	}
	hash, hash_ok := topology_issue_report_hash({}, report)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0x30, 0xee, 0xfe, 0xdf, 0x20, 0x66, 0x79, 0xd5,
		0xb0, 0xa8, 0x4e, 0x38, 0xaa, 0x41, 0xdf, 0x4f,
		0x17, 0xdb, 0x91, 0x32, 0x99, 0xf9, 0xb4, 0xb9,
		0x67, 0xd6, 0x83, 0x77, 0x5d, 0x46, 0x78, 0x5f,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
topology_issue_report_rejects_mismatched_counts_and_limits_test :: proc(
	t: ^testing.T,
) {
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
	schedule, schedule_error := topology_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	topology, topology_error := topology_reconstruct(schedule, segments)
	defer topology_result_destroy(&topology)
	testing.expect_value(t, topology_error, Topology_Error.None)

	_, limit_error := topology_issue_report_build(
		topology,
		segments,
		{max_issues = 0, max_segment_references = 1},
	)
	testing.expect_value(t, limit_error, Topology_Issue_Error.Issue_Limit)
	topology.open_chain_count = 0
	_, mismatch_error := topology_issue_report_build(topology, segments)
	testing.expect_value(
		t,
		mismatch_error,
		Topology_Issue_Error.Invalid_Input,
	)
}
