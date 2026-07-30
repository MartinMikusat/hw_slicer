package profiles

import contracts "../contracts"

Gap_Width_Kind :: enum u8 {
	Invalid,
	Unprinted_Below_Minimum,
	One_Line,
	Two_Lines,
	Unprinted_Transition,
	Above_Two_Line_Maximum,
}

Gap_Line_Allocation :: struct {
	width:           contracts.Micrometres,
	center_twice_um: i64,
}

Gap_Width_Allocation :: struct {
	kind:            Gap_Width_Kind,
	measured_width:  contracts.Micrometres,
	line_count:      u8,
	lines:           [2]Gap_Line_Allocation,
	unprinted_width: contracts.Micrometres,
}

gap_width_allocate :: proc(
	process: Resolved_Process_Profile,
	measured_width: contracts.Micrometres,
) -> (Gap_Width_Allocation, bool) {
	width := i64(measured_width)
	minimum := i64(process.thin_wall_minimum_width)
	maximum := i64(process.thin_wall_maximum_width)
	if width <= 0 || minimum <= 0 || maximum < minimum ||
	   process.source.thin_wall_remainder != .Preserve_Unprinted ||
	   process.source.gap_allocation != .One_Then_Two_Lines {
		return {}, false
	}
	result := Gap_Width_Allocation{measured_width = measured_width}
	if width < minimum {
		result.kind = .Unprinted_Below_Minimum
		result.unprinted_width = measured_width
		return result, true
	}
	if width <= maximum {
		result.kind = .One_Line
		result.line_count = 1
		result.lines[0] = {
			width = measured_width,
			center_twice_um = width,
		}
		return result, true
	}
	maximum_two := i128(maximum)*2
	if i128(width) > maximum_two {
		result.kind = .Above_Two_Line_Maximum
		return result, true
	}
	first_width := width/2
	second_width := width-first_width
	if first_width < minimum || second_width < minimum ||
	   first_width > maximum || second_width > maximum {
		result.kind = .Unprinted_Transition
		result.unprinted_width = measured_width
		return result, true
	}
	result.kind = .Two_Lines
	result.line_count = 2
	result.lines[0] = {
		width = contracts.Micrometres(first_width),
		center_twice_um = first_width,
	}
	result.lines[1] = {
		width = contracts.Micrometres(second_width),
		center_twice_um = first_width*2+second_width,
	}
	return result, true
}

gap_width_allocation_valid :: proc(
	allocation: Gap_Width_Allocation,
	process: Resolved_Process_Profile,
) -> bool {
	expected, ok := gap_width_allocate(
		process,
		allocation.measured_width,
	)
	return ok && allocation == expected
}
