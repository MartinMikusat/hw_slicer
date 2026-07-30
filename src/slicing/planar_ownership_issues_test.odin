package slicing

import "core:testing"

import contracts "../contracts"
import geometry "../geometry"

PLANAR_ISSUE_TEST_VERTEX_X := [9]f64{0, 1, 0, 0, 1, 0, 0, 1, 0}
PLANAR_ISSUE_TEST_VERTEX_Y := [9]f64{0, 0, 1, 0, 0, -1, 0, 0, 2}
PLANAR_ISSUE_TEST_VERTEX_Z := [9]f64{0, 0, 1, 0, 0, -1, 0, 0, 1}
PLANAR_ISSUE_TEST_TRIANGLE_A := [3]u32{0, 3, 6}
PLANAR_ISSUE_TEST_TRIANGLE_B := [3]u32{1, 4, 7}
PLANAR_ISSUE_TEST_TRIANGLE_C := [3]u32{2, 5, 8}
PLANAR_ISSUE_TEST_TRIANGLE_IDS :=
	[3]contracts.Stable_ID{100, 101, 102}
PLANAR_ISSUE_TEST_CANDIDATES := [3]Planar_Candidate{
	{0, 0, 100, .Exact_Edge, .AB},
	{0, 1, 101, .Exact_Edge, .AB},
	{0, 2, 102, .Exact_Edge, .AB},
}

planar_issue_test_mesh :: proc() -> geometry.Canonical_Mesh {
	return {
		coordinate_units = .Millimetres,
		vertex_x = PLANAR_ISSUE_TEST_VERTEX_X[:],
		vertex_y = PLANAR_ISSUE_TEST_VERTEX_Y[:],
		vertex_z = PLANAR_ISSUE_TEST_VERTEX_Z[:],
		triangle_a = PLANAR_ISSUE_TEST_TRIANGLE_A[:],
		triangle_b = PLANAR_ISSUE_TEST_TRIANGLE_B[:],
		triangle_c = PLANAR_ISSUE_TEST_TRIANGLE_C[:],
		triangle_ids = PLANAR_ISSUE_TEST_TRIANGLE_IDS[:],
	}
}

@(test)
planar_ownership_issue_report_preserves_unresolved_provenance_test :: proc(
	t: ^testing.T,
) {
	schedule, schedule_error := planar_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	mesh := planar_issue_test_mesh()
	intersections := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 0, 0, 3}},
		planar_candidates = PLANAR_ISSUE_TEST_CANDIDATES[:],
	}
	ownership, ownership_error := planar_ownership_resolve(
		mesh,
		schedule,
		intersections,
	)
	defer planar_ownership_destroy(&ownership)
	testing.expect_value(
		t,
		ownership_error,
		Planar_Ownership_Error.None,
	)
	report, report_error := planar_ownership_issue_report_build(
		mesh,
		schedule,
		intersections,
		ownership,
	)
	defer planar_ownership_issue_report_destroy(&report)
	testing.expect_value(
		t,
		report_error,
		Planar_Ownership_Issue_Error.None,
	)
	testing.expect_value(t, len(report.groups), 1)
	testing.expect_value(t, len(report.references), 3)
	testing.expect_value(t, report.groups[0].reference_count, u32(3))
	testing.expect_value(t, report.groups[0].third_above_count, u32(2))
	testing.expect_value(t, report.groups[0].third_below_count, u32(1))
	testing.expect_value(
		t,
		report.references[0].triangle_id,
		contracts.Stable_ID(100),
	)
	hash, hash_ok := planar_ownership_issue_report_hash({}, report)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0x24, 0x37, 0xce, 0x5a, 0xd2, 0x2b, 0x8c, 0x20,
		0xcc, 0x63, 0xb9, 0x47, 0xd7, 0x02, 0x18, 0xd0,
		0xfa, 0xc7, 0xf1, 0xb9, 0xf6, 0x81, 0xd3, 0x95,
		0x40, 0x89, 0xea, 0x2c, 0x91, 0x59, 0x3c, 0xad,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
planar_ownership_issue_report_enforces_limits_and_input_match_test :: proc(
	t: ^testing.T,
) {
	schedule, schedule_error := planar_test_schedule()
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, Schedule_Error.None)
	mesh := planar_issue_test_mesh()
	intersections := CPU_Intersection_Result{
		layers = []Intersection_Layer{{0, 0, 0, 3}},
		planar_candidates = PLANAR_ISSUE_TEST_CANDIDATES[:],
	}
	ownership, ownership_error := planar_ownership_resolve(
		mesh,
		schedule,
		intersections,
	)
	defer planar_ownership_destroy(&ownership)
	testing.expect_value(
		t,
		ownership_error,
		Planar_Ownership_Error.None,
	)
	_, limit_error := planar_ownership_issue_report_build(
		mesh,
		schedule,
		intersections,
		ownership,
		{max_groups = 0, max_references = 3},
	)
	testing.expect_value(
		t,
		limit_error,
		Planar_Ownership_Issue_Error.Group_Limit,
	)
	ownership.unresolved_group_count = 0
	_, mismatch_error := planar_ownership_issue_report_build(
		mesh,
		schedule,
		intersections,
		ownership,
	)
	testing.expect_value(
		t,
		mismatch_error,
		Planar_Ownership_Issue_Error.Invalid_Input,
	)
}
