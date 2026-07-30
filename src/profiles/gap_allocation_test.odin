package profiles

import "core:testing"

import contracts "../contracts"

@(test)
gap_width_allocation_covers_each_selected_policy_interval_test :: proc(
	t: ^testing.T,
) {
	process := gap_test_resolved_process(t)
	cases := [?]struct {
		width:        contracts.Micrometres,
		kind:         Gap_Width_Kind,
		line_count:   u8,
		first_width:  contracts.Micrometres,
		second_width: contracts.Micrometres,
		unprinted:    contracts.Micrometres,
	}{
		{269, .Unprinted_Below_Minimum, 0, 0, 0, 269},
		{270, .One_Line, 1, 270, 0, 0},
		{585, .One_Line, 1, 585, 0, 0},
		{586, .Two_Lines, 2, 293, 293, 0},
		{587, .Two_Lines, 2, 293, 294, 0},
		{1_170, .Two_Lines, 2, 585, 585, 0},
		{1_171, .Above_Two_Line_Maximum, 0, 0, 0, 0},
	}
	for test_case in cases {
		allocation, ok := gap_width_allocate(process, test_case.width)
		testing.expect(t, ok)
		testing.expect_value(t, allocation.kind, test_case.kind)
		testing.expect_value(
			t,
			allocation.line_count,
			test_case.line_count,
		)
		testing.expect_value(
			t,
			allocation.lines[0].width,
			test_case.first_width,
		)
		testing.expect_value(
			t,
			allocation.lines[1].width,
			test_case.second_width,
		)
		testing.expect_value(
			t,
			allocation.unprinted_width,
			test_case.unprinted,
		)
		testing.expect(
			t,
			gap_width_allocation_valid(allocation, process),
		)
	}
}

@(test)
gap_width_allocation_preserves_exact_half_micrometre_centers_test :: proc(
	t: ^testing.T,
) {
	process := gap_test_resolved_process(t)
	one, one_ok := gap_width_allocate(process, 271)
	two, two_ok := gap_width_allocate(process, 587)
	testing.expect(t, one_ok)
	testing.expect(t, two_ok)
	testing.expect_value(t, one.lines[0].center_twice_um, i64(271))
	testing.expect_value(t, two.lines[0].center_twice_um, i64(293))
	testing.expect_value(t, two.lines[1].center_twice_um, i64(880))
	testing.expect_value(
		t,
		two.lines[0].width+two.lines[1].width,
		two.measured_width,
	)
}

@(test)
gap_width_allocation_records_a_nonprintable_transition_interval_test :: proc(
	t: ^testing.T,
) {
	process := gap_test_resolved_process(t)
	process.thin_wall_minimum_width = 400
	process.thin_wall_maximum_width = 500
	allocation, ok := gap_width_allocate(process, 600)
	testing.expect(t, ok)
	testing.expect_value(
		t,
		allocation.kind,
		Gap_Width_Kind.Unprinted_Transition,
	)
	testing.expect_value(
		t,
		allocation.unprinted_width,
		contracts.Micrometres(600),
	)
	testing.expect_value(t, allocation.line_count, u8(0))
}

@(test)
gap_width_allocation_rejects_invalid_measurements_and_policies_test :: proc(
	t: ^testing.T,
) {
	process := gap_test_resolved_process(t)
	_, zero_ok := gap_width_allocate(process, 0)
	testing.expect(t, !zero_ok)

	process.source.gap_allocation = .Invalid
	_, policy_ok := gap_width_allocate(process, 450)
	testing.expect(t, !policy_ok)
}

gap_test_resolved_process :: proc(t: ^testing.T) -> Resolved_Process_Profile {
	printer, material, process, dialect := profile_test_documents()
	resolved, error := profiles_resolve(
		printer,
		material,
		process,
		dialect,
	)
	testing.expect_value(t, error, Profile_Resolve_Error.None)
	return resolved.process
}
