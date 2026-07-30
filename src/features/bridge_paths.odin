package features

import "core:slice"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Bridge_Path_Layer :: struct {
	path_offset: u64,
	path_count:  u32,
	hit_offset:  u64,
	hit_count:   u32,
}

Bridge_Path :: struct {
	stable_id:               contracts.Stable_ID,
	path_set_id:             contracts.Stable_ID,
	evidence_mask_id:        contracts.Stable_ID,
	evidence_mask_index:     u32,
	region_id:               contracts.Stable_ID,
	region_index:            u32,
	layer_index:             u32,
	candidate_id:            contracts.Stable_ID,
	candidate_index:         u32,
	role:                    profiles.Printable_Role,
	angle:                   profiles.Angle_Millidegrees,
	direction_x:             i64,
	direction_y:             i64,
	mask_path_index:         u64,
	scanline_index:          u64,
	line_coordinate_scaled:  i128,
	line_width:              contracts.Micrometres,
	point_a:                 polygon.Polygon_Point,
	point_b:                 polygon.Polygon_Point,
	hit_offset:              u64,
}

Bridge_Path_Hit :: struct {
	boundary_path_index: u32,
	boundary_edge_index: u32,
	x_numerator:         i128,
	y_numerator:         i128,
	denominator:         i128,
	point:               polygon.Polygon_Point,
	error_x_numerator:   u128,
	error_y_numerator:   u128,
}

Bridge_Path_Result :: struct {
	spacing:                  contracts.Micrometres,
	phase:                    contracts.Micrometres,
	direction_scale:          i64,
	layers:                   []Bridge_Path_Layer,
	paths:                    []Bridge_Path,
	hits:                     []Bridge_Path_Hit,
	scanline_count:           u64,
	skipped_unanchored_count: u64,
}

Bridge_Path_Limits :: struct {
	max_scanlines: u64,
	max_paths:     u64,
}

DEFAULT_BRIDGE_PATH_LIMITS :: Bridge_Path_Limits{
	max_scanlines = 1_000_000_000,
	max_paths = 1_000_000_000,
}

Bridge_Path_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Scanline_Limit,
	Path_Limit,
	Odd_Intersection_Count,
	Allocation_Failed,
	Arithmetic,
}

Bridge_Path_Rational_Hit :: struct {
	boundary_path_index: u32,
	boundary_edge_index: u32,
	sort_numerator:      i128,
	x_numerator:         i128,
	y_numerator:         i128,
	denominator:         i128,
	point:               polygon.Polygon_Point,
	error_x_numerator:   u128,
	error_y_numerator:   u128,
}

bridge_paths_generate :: proc(
	evidence: Bridge_Evidence_Result,
	directions: Bridge_Direction_Result,
	process: profiles.Resolved_Process_Profile,
	limits := DEFAULT_BRIDGE_PATH_LIMITS,
	allocator := context.allocator,
) -> (Bridge_Path_Result, Bridge_Path_Error) {
	spacing := process.source.nominal_line_width
	phase := contracts.Micrometres(0)
	if !profiles.process_bridge_targets_valid(process.source) ||
	   i64(spacing) <= 0 ||
	   directions.policy != process.source.bridge_direction ||
	   directions.scale != BRIDGE_DIRECTION_SCALE {
		return {}, .Invalid_Config
	}
	if !bridge_path_inputs_valid(evidence, directions, process) {
		return {}, .Invalid_Input
	}

	boundaries := make(
		[]polygon.Polygon_Set,
		len(directions.selections),
		allocator,
	)
	if len(directions.selections) > 0 && boundaries == nil {
		return {}, .Allocation_Failed
	}
	defer {
		for &boundary in boundaries {
			polygon.polygon_set_destroy(&boundary, allocator)
		}
		delete(boundaries, allocator)
	}
	maximum_boundary_points := 0
	for selection, selection_index in directions.selections {
		if selection.status != .Selected {continue}
		boundary, boundary_error := bridge_evidence_mask_input(
			evidence,
			selection.evidence_mask_index,
			allocator,
		)
		if boundary_error != .None {
			return {}, bridge_path_evidence_error(boundary_error)
		}
		boundaries[selection_index] = boundary
		maximum_boundary_points = max(
			maximum_boundary_points,
			len(boundary.points),
		)
	}
	scratch_hits := make(
		[]Bridge_Path_Rational_Hit,
		maximum_boundary_points,
		allocator,
	)
	if maximum_boundary_points > 0 && scratch_hits == nil {
		return {}, .Allocation_Failed
	}
	defer delete(scratch_hits, allocator)

	path_count: u64
	scanline_count: u64
	skipped_unanchored_count: u64
	for selection, selection_index in directions.selections {
		if selection.status == .No_Bidirectional_Anchor {
			skipped_unanchored_count += 1
			continue
		}
		candidate :=
			directions.candidates[selection.selected_candidate_index]
		written_paths, written_scanlines, scan_error :=
			bridge_path_scan_boundary(
				boundaries[selection_index],
				candidate,
				spacing,
				phase,
				scratch_hits,
				nil,
				nil,
				selection,
				0,
				limits,
			)
		if scan_error != .None {return {}, scan_error}
		if path_count > limits.max_paths ||
		   written_paths > limits.max_paths-path_count {
			return {}, .Path_Limit
		}
		if scanline_count > limits.max_scanlines ||
		   written_scanlines > limits.max_scanlines-scanline_count {
			return {}, .Scanline_Limit
		}
		path_count += written_paths
		scanline_count += written_scanlines
	}
	if path_count > u64(max(int)) ||
	   path_count > u64(max(int))/2 {
		return {}, .Arithmetic
	}

	result := Bridge_Path_Result{
		spacing = spacing,
		phase = phase,
		direction_scale = BRIDGE_DIRECTION_SCALE,
		scanline_count = scanline_count,
		skipped_unanchored_count = skipped_unanchored_count,
	}
	result.layers = make(
		[]Bridge_Path_Layer,
		len(directions.layers),
		allocator,
	)
	result.paths = make([]Bridge_Path, int(path_count), allocator)
	result.hits = make([]Bridge_Path_Hit, int(path_count*2), allocator)
	if len(result.layers) > 0 && result.layers == nil ||
	   path_count > 0 && (result.paths == nil || result.hits == nil) {
		bridge_path_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	path_write: u64
	selection_cursor := 0
	for direction_layer, layer_index in directions.layers {
		layer_path_start := path_write
		selection_end :=
			int(direction_layer.selection_offset)+
			int(direction_layer.selection_count)
		for selection_cursor < selection_end {
			selection := directions.selections[selection_cursor]
			if selection.status == .Selected {
				candidate := directions.candidates[
					selection.selected_candidate_index
				]
				written_paths, _, scan_error :=
					bridge_path_scan_boundary(
						boundaries[selection_cursor],
						candidate,
						spacing,
						phase,
						scratch_hits,
						result.paths,
						result.hits,
						selection,
						path_write,
						limits,
					)
				if scan_error != .None {
					bridge_path_result_destroy(&result, allocator)
					return {}, scan_error
				}
				path_write += written_paths
			}
			selection_cursor += 1
		}
		layer_path_count := path_write-layer_path_start
		if layer_path_count > u64(max(u32)) ||
		   layer_path_count > u64(max(u32))/2 {
			bridge_path_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			path_offset = layer_path_start,
			path_count = u32(layer_path_count),
			hit_offset = layer_path_start*2,
			hit_count = u32(layer_path_count*2),
		}
	}
	if path_write != path_count ||
	   selection_cursor != len(directions.selections) {
		bridge_path_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

bridge_path_scan_boundary :: proc(
	boundary: polygon.Polygon_Set,
	candidate: Bridge_Direction_Candidate,
	spacing, phase: contracts.Micrometres,
	scratch_hits: []Bridge_Path_Rational_Hit,
	paths: []Bridge_Path,
	output_hits: []Bridge_Path_Hit,
	selection: Bridge_Direction_Selection,
	path_offset: u64,
	limits: Bridge_Path_Limits,
) -> (
	path_count: u64,
	scanline_count: u64,
	error: Bridge_Path_Error,
) {
	if len(boundary.points) == 0 {return}
	normal_x := -candidate.direction_y
	normal_y := candidate.direction_x
	minimum, maximum := bridge_path_projection_bounds(
		boundary,
		normal_x,
		normal_y,
	)
	step := i128(i64(spacing))*i128(BRIDGE_DIRECTION_SCALE)
	phase_scaled := i128(i64(phase))*i128(BRIDGE_DIRECTION_SCALE)
	if step <= 0 {error = .Invalid_Config; return}
	line, line_ok := bridge_path_first_scanline(
		minimum,
		phase_scaled,
		step,
	)
	if !line_ok {error = .Arithmetic; return}
	mask_path_index: u64
	for line < maximum {
		if scanline_count >= limits.max_scanlines {
			error = .Scanline_Limit
			return
		}
		scanline_index := scanline_count
		scanline_count += 1
		hit_count, hit_error := bridge_path_collect_hits(
			boundary,
			candidate.direction_x,
			candidate.direction_y,
			normal_x,
			normal_y,
			line,
			scratch_hits,
		)
		if hit_error != .None {error = hit_error; return}
		if hit_count&1 != 0 {
			error = .Odd_Intersection_Count
			return
		}
		for hit_index := 0; hit_index < hit_count; hit_index += 2 {
			first := scratch_hits[hit_index]
			second := scratch_hits[hit_index+1]
			if first.point == second.point {continue}
			if path_count >= limits.max_paths {
				error = .Path_Limit
				return
			}
			if paths != nil {
				write_index := path_offset+path_count
				if write_index >= u64(len(paths)) ||
				   write_index*2+1 >= u64(len(output_hits)) {
					error = .Arithmetic
					return
				}
				path_set_id := contracts.stable_id_child(
					selection.evidence_mask_id,
					.Feature,
					0,
				)
				paths[write_index] = {
					stable_id = contracts.stable_id_child(
						path_set_id,
						.Path,
						mask_path_index,
					),
					path_set_id = path_set_id,
					evidence_mask_id =
						selection.evidence_mask_id,
					evidence_mask_index =
						selection.evidence_mask_index,
					region_id = selection.region_id,
					region_index = selection.region_index,
					layer_index = selection.layer_index,
					candidate_id = candidate.stable_id,
					candidate_index =
						selection.selected_candidate_index,
					role = .Bridge,
					angle = candidate.angle,
					direction_x = candidate.direction_x,
					direction_y = candidate.direction_y,
					mask_path_index = mask_path_index,
					scanline_index = scanline_index,
					line_coordinate_scaled = line,
					line_width = spacing,
					point_a = first.point,
					point_b = second.point,
					hit_offset = write_index*2,
				}
				output_hits[write_index*2] =
					bridge_path_output_hit(first)
				output_hits[write_index*2+1] =
					bridge_path_output_hit(second)
			}
			path_count += 1
			mask_path_index += 1
		}
		if line > max(i128)-step {break}
		line += step
	}
	return
}

bridge_path_collect_hits :: proc(
	boundary: polygon.Polygon_Set,
	direction_x, direction_y, normal_x, normal_y: i64,
	line: i128,
	hits: []Bridge_Path_Rational_Hit,
) -> (int, Bridge_Path_Error) {
	hit_count := 0
	for path, path_index in boundary.paths {
		if path.count < 3 ||
		   path.offset+path.count > u64(len(boundary.points)) {
			return 0, .Invalid_Input
		}
		start := int(path.offset)
		for edge_index in 0..<int(path.count) {
			a := boundary.points[start+edge_index]
			b := boundary.points[
				start+(edge_index+1)%int(path.count)
			]
			fixed_a := bridge_path_dot(a, normal_x, normal_y)
			fixed_b := bridge_path_dot(b, normal_x, normal_y)
			if !((fixed_a <= line && line < fixed_b) ||
			     (fixed_b <= line && line < fixed_a)) {
				continue
			}
			if hit_count >= len(hits) {return 0, .Arithmetic}
			denominator := fixed_b-fixed_a
			delta := line-fixed_a
			x_numerator :=
				i128(i64(a.x))*denominator+
				delta*(i128(i64(b.x))-i128(i64(a.x)))
			y_numerator :=
				i128(i64(a.y))*denominator+
				delta*(i128(i64(b.y))-i128(i64(a.y)))
			if denominator < 0 {
				denominator = -denominator
				x_numerator = -x_numerator
				y_numerator = -y_numerator
			}
			x, error_x, x_ok :=
				infill_rational_round(x_numerator, denominator)
			y, error_y, y_ok :=
				infill_rational_round(y_numerator, denominator)
			if !x_ok || !y_ok {return 0, .Arithmetic}
			sort_numerator :=
				i128(direction_x)*x_numerator+
				i128(direction_y)*y_numerator
			hits[hit_count] = {
				boundary_path_index = u32(path_index),
				boundary_edge_index = u32(edge_index),
				sort_numerator = sort_numerator,
				x_numerator = x_numerator,
				y_numerator = y_numerator,
				denominator = denominator,
				point = {x, y},
				error_x_numerator = error_x,
				error_y_numerator = error_y,
			}
			hit_count += 1
		}
	}
	slice.sort_by(hits[:hit_count], bridge_path_hit_less)
	return hit_count, .None
}

bridge_path_hit_less :: proc(
	a, b: Bridge_Path_Rational_Hit,
) -> bool {
	if a.sort_numerator != b.sort_numerator ||
	   a.denominator != b.denominator {
		if bridge_path_rational_less(
			a.sort_numerator,
			a.denominator,
			b.sort_numerator,
			b.denominator,
		) {
			return true
		}
		if bridge_path_rational_less(
			b.sort_numerator,
			b.denominator,
			a.sort_numerator,
			a.denominator,
		) {
			return false
		}
	}
	if a.boundary_path_index != b.boundary_path_index {
		return a.boundary_path_index < b.boundary_path_index
	}
	return a.boundary_edge_index < b.boundary_edge_index
}

bridge_path_rational_less :: proc(
	a_numerator, a_denominator, b_numerator, b_denominator: i128,
) -> bool {
	if a_denominator <= 0 || b_denominator <= 0 {
		return false
	}
	a_negative := a_numerator < 0
	b_negative := b_numerator < 0
	if a_negative != b_negative {return a_negative}
	if a_numerator == b_numerator &&
	   a_denominator == b_denominator {
		return false
	}
	if a_numerator == min(i128) ||
	   b_numerator == min(i128) {
		return a_numerator < b_numerator
	}
	a_magnitude := a_numerator
	b_magnitude := b_numerator
	if a_negative {
		a_magnitude = -a_magnitude
		b_magnitude = -b_magnitude
	}
	magnitude_less := bridge_path_positive_rational_less(
		u128(a_magnitude),
		u128(a_denominator),
		u128(b_magnitude),
		u128(b_denominator),
	)
	if !a_negative {return magnitude_less}
	magnitude_greater := bridge_path_positive_rational_less(
		u128(b_magnitude),
		u128(b_denominator),
		u128(a_magnitude),
		u128(a_denominator),
	)
	return magnitude_greater
}

bridge_path_positive_rational_less :: proc(
	a_numerator, a_denominator, b_numerator, b_denominator: u128,
) -> bool {
	a_num, a_den := a_numerator, a_denominator
	b_num, b_den := b_numerator, b_denominator
	reverse := false
	for {
		a_quotient := a_num/a_den
		b_quotient := b_num/b_den
		if a_quotient != b_quotient {
			if reverse {return a_quotient > b_quotient}
			return a_quotient < b_quotient
		}
		a_remainder := a_num%a_den
		b_remainder := b_num%b_den
		if a_remainder == 0 || b_remainder == 0 {
			if a_remainder == 0 && b_remainder == 0 {
				return false
			}
			if reverse {return b_remainder == 0}
			return a_remainder == 0
		}
		a_num, a_den = a_den, a_remainder
		b_num, b_den = b_den, b_remainder
		reverse = !reverse
	}
}

bridge_path_projection_bounds :: proc(
	boundary: polygon.Polygon_Set,
	normal_x, normal_y: i64,
) -> (i128, i128) {
	first := bridge_path_dot(boundary.points[0], normal_x, normal_y)
	minimum, maximum := first, first
	for point in boundary.points[1:] {
		value := bridge_path_dot(point, normal_x, normal_y)
		minimum = min(minimum, value)
		maximum = max(maximum, value)
	}
	return minimum, maximum
}

bridge_path_dot :: proc(
	point: polygon.Polygon_Point,
	x, y: i64,
) -> i128 {
	return i128(i64(point.x))*i128(x)+
		i128(i64(point.y))*i128(y)
}

bridge_path_first_scanline :: proc(
	minimum, phase, step: i128,
) -> (i128, bool) {
	if step <= 0 {return 0, false}
	delta := minimum-phase
	quotient := delta/step
	remainder := delta%step
	if remainder > 0 {
		if quotient == max(i128) {return 0, false}
		quotient += 1
	}
	if quotient > 0 && quotient > (max(i128)-phase)/step ||
	   quotient < 0 && quotient < (min(i128)-phase)/step {
		return 0, false
	}
	return phase+quotient*step, true
}

bridge_path_output_hit :: proc(
	hit: Bridge_Path_Rational_Hit,
) -> Bridge_Path_Hit {
	return {
		boundary_path_index = hit.boundary_path_index,
		boundary_edge_index = hit.boundary_edge_index,
		x_numerator = hit.x_numerator,
		y_numerator = hit.y_numerator,
		denominator = hit.denominator,
		point = hit.point,
		error_x_numerator = hit.error_x_numerator,
		error_y_numerator = hit.error_y_numerator,
	}
}

bridge_path_inputs_valid :: proc(
	evidence: Bridge_Evidence_Result,
	directions: Bridge_Direction_Result,
	process: profiles.Resolved_Process_Profile,
) -> bool {
	if len(directions.layers) != len(evidence.layers) {
		return false
	}
	expected_selection_offset: u64
	expected_candidate_offset: u64
	for layer, layer_index in directions.layers {
		if layer.selection_offset != expected_selection_offset ||
		   layer.candidate_offset != expected_candidate_offset ||
		   layer.selection_offset+u64(layer.selection_count) >
		    u64(len(directions.selections)) ||
		   layer.candidate_offset+u64(layer.candidate_count) >
		    u64(len(directions.candidates)) {
			return false
		}
		selection_start := int(layer.selection_offset)
		selection_end := selection_start+int(layer.selection_count)
		for selection in
		    directions.selections[selection_start:selection_end] {
			if selection.layer_index != u32(layer_index) {
				return false
			}
		}
		expected_selection_offset += u64(layer.selection_count)
		expected_candidate_offset += u64(layer.candidate_count)
	}
	if expected_selection_offset != u64(len(directions.selections)) ||
	   expected_candidate_offset != u64(len(directions.candidates)) {
		return false
	}
	previous_mask_index: u32
	for selection, selection_index in directions.selections {
		if u64(selection.evidence_mask_index) >=
		    u64(len(evidence.masks)) ||
		   u64(selection.selected_candidate_index) >=
		    u64(len(directions.candidates)) ||
		   selection.candidate_count !=
		    process.source.bridge_angle_count ||
		   selection.candidate_offset+
		    u64(selection.candidate_count) >
		    u64(len(directions.candidates)) ||
		   u64(selection.selected_candidate_index) <
		    selection.candidate_offset ||
		   u64(selection.selected_candidate_index) >=
		    selection.candidate_offset+
		    u64(selection.candidate_count) ||
		   selection.status != .Selected &&
		    selection.status != .No_Bidirectional_Anchor {
			return false
		}
		mask := evidence.masks[selection.evidence_mask_index]
		candidate :=
			directions.candidates[selection.selected_candidate_index]
		expected_direction_x, expected_direction_y, direction_ok :=
			bridge_direction_vector(candidate.angle)
		if mask.kind != .Eligible_Unsupported ||
		   selection.evidence_mask_id != mask.stable_id ||
		   selection.region_id != mask.region_id ||
		   selection.region_index != mask.region_index ||
		   selection.layer_index != mask.layer_index ||
		   candidate.evidence_mask_id != mask.stable_id ||
		   candidate.evidence_mask_index !=
		    selection.evidence_mask_index ||
		   !direction_ok ||
		   candidate.direction_x != expected_direction_x ||
		   candidate.direction_y != expected_direction_y ||
		   selection.status == .Selected &&
		    candidate.bidirectional_anchor_capacity == 0 ||
		   selection.status == .No_Bidirectional_Anchor &&
		    candidate.bidirectional_anchor_capacity != 0 ||
		   selection_index > 0 &&
		    selection.evidence_mask_index <= previous_mask_index {
			return false
		}
		previous_mask_index = selection.evidence_mask_index
	}
	return true
}

bridge_path_evidence_error :: proc(
	error: Bridge_Evidence_Error,
) -> Bridge_Path_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

bridge_path_result_destroy :: proc(
	result: ^Bridge_Path_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.paths, allocator)
	delete(result.hits, allocator)
	result^ = {}
}
