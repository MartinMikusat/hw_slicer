package features

import "core:math"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

BRIDGE_DIRECTION_SCALE :: i64(1_000_000_000)

Bridge_Direction_Status :: enum u8 {
	Invalid,
	Selected,
	No_Bidirectional_Anchor,
}

Bridge_Direction_Layer :: struct {
	selection_offset: u64,
	selection_count:  u32,
	candidate_offset: u64,
	candidate_count:  u32,
}

Bridge_Direction_Selection :: struct {
	evidence_mask_id:         contracts.Stable_ID,
	evidence_mask_index:      u32,
	region_id:                contracts.Stable_ID,
	region_index:             u32,
	layer_index:              u32,
	status:                   Bridge_Direction_Status,
	selected_candidate_index: u32,
	candidate_offset:         u64,
	candidate_count:          u8,
}

Bridge_Direction_Candidate :: struct {
	stable_id:                    contracts.Stable_ID,
	evidence_mask_id:             contracts.Stable_ID,
	evidence_mask_index:          u32,
	angle_index:                  u8,
	angle:                        profiles.Angle_Millidegrees,
	direction_x:                  i64,
	direction_y:                  i64,
	span_projection:              i128,
	positive_anchor_capacity:     u128,
	negative_anchor_capacity:     u128,
	bidirectional_anchor_capacity: u128,
	total_anchor_capacity:        u128,
}

Bridge_Direction_Result :: struct {
	policy:     profiles.Bridge_Direction_Policy,
	scale:      i64,
	layers:     []Bridge_Direction_Layer,
	selections: []Bridge_Direction_Selection,
	candidates: []Bridge_Direction_Candidate,
}

Bridge_Direction_Limits :: struct {
	max_selections: u64,
	max_candidates: u64,
	polygon:        polygon.Polygon_Limits,
}

DEFAULT_BRIDGE_DIRECTION_LIMITS :: Bridge_Direction_Limits{
	max_selections = 200_000_000,
	max_candidates = 1_600_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Bridge_Direction_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Selection_Limit,
	Candidate_Limit,
	Provider,
	Allocation_Failed,
	Arithmetic,
}

bridge_directions_score :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	evidence: Bridge_Evidence_Result,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	limits := DEFAULT_BRIDGE_DIRECTION_LIMITS,
	allocator := context.allocator,
) -> (Bridge_Direction_Result, Bridge_Direction_Error) {
	if !profiles.process_bridge_targets_valid(process.source) ||
	   process.source.bridge_direction != .Bounded_Candidate_Score ||
	   provider.offset == nil {
		return {}, .Invalid_Config
	}
	if len(topology.layers) != len(regions.layers) ||
	   len(evidence.layers) != len(regions.layers) ||
	   evidence.geometry_policy != process.source.bridge_geometry ||
	   evidence.anchor_margin != process.source.bridge_anchor_margin ||
	   evidence.minimum_area != process.source.minimum_bridge_area ||
	   evidence.eligible_mask_count > u64(len(evidence.masks)) {
		return {}, .Invalid_Input
	}
	_, regions_ok := slicing.region_result_hash({}, topology, regions)
	if !regions_ok ||
	   !bridge_direction_evidence_valid(regions, evidence) {
		return {}, .Invalid_Input
	}
	if evidence.eligible_mask_count > limits.max_selections {
		return {}, .Selection_Limit
	}
	candidate_count :=
		evidence.eligible_mask_count*
		u64(process.source.bridge_angle_count)
	if candidate_count > limits.max_candidates {
		return {}, .Candidate_Limit
	}
	if evidence.eligible_mask_count > u64(max(int)) ||
	   candidate_count > u64(max(int)) ||
	   candidate_count > u64(max(u32)) {
		return {}, .Arithmetic
	}

	supports, support_error := bridge_direction_supports_build(
		topology,
		regions,
		process.source.bridge_anchor_margin,
		provider,
		evidence.config,
		limits.polygon,
		allocator,
	)
	if support_error != .None {return {}, support_error}
	defer {
		for &support in supports {
			polygon.polygon_set_destroy(&support, allocator)
		}
		delete(supports, allocator)
	}

	result := Bridge_Direction_Result{
		policy = process.source.bridge_direction,
		scale = BRIDGE_DIRECTION_SCALE,
	}
	result.layers = make(
		[]Bridge_Direction_Layer,
		len(evidence.layers),
		allocator,
	)
	result.selections = make(
		[]Bridge_Direction_Selection,
		int(evidence.eligible_mask_count),
		allocator,
	)
	result.candidates = make(
		[]Bridge_Direction_Candidate,
		int(candidate_count),
		allocator,
	)
	if len(result.layers) > 0 && result.layers == nil ||
	   evidence.eligible_mask_count > 0 &&
	    result.selections == nil ||
	   candidate_count > 0 && result.candidates == nil {
		bridge_direction_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	selection_write := 0
	candidate_write := 0
	for layer, layer_index in evidence.layers {
		layer_selection_start := selection_write
		layer_candidate_start := candidate_write
		mask_start := int(layer.mask_offset)
		mask_end := mask_start+int(layer.mask_count)
		for mask_index in mask_start..<mask_end {
			mask := evidence.masks[mask_index]
			if mask.kind != .Eligible_Unsupported {continue}
			if mask.layer_index != u32(layer_index) ||
			   mask.layer_index == 0 ||
			   u64(mask.region_index) >=
			    u64(len(regions.regions)) {
				bridge_direction_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			boundary, boundary_error :=
				bridge_evidence_mask_input(
					evidence,
					u32(mask_index),
					allocator,
				)
			if boundary_error != .None {
				bridge_direction_result_destroy(&result, allocator)
				return {}, bridge_direction_evidence_error(
					boundary_error,
				)
			}
			candidate_start := candidate_write
			best_index := candidate_write
			for angle_index in
			    0..<int(process.source.bridge_angle_count) {
				angle := process.source.bridge_angles[angle_index]
				direction_x, direction_y, direction_ok :=
					bridge_direction_vector(angle)
				if !direction_ok {
					polygon.polygon_set_destroy(
						&boundary,
						allocator,
					)
					bridge_direction_result_destroy(
						&result,
						allocator,
					)
					return {}, .Arithmetic
				}
				score, score_ok := bridge_direction_score_candidate(
					boundary,
					supports[layer_index],
					direction_x,
					direction_y,
				)
				if !score_ok {
					polygon.polygon_set_destroy(
						&boundary,
						allocator,
					)
					bridge_direction_result_destroy(
						&result,
						allocator,
					)
					return {}, .Arithmetic
				}
				candidate_id := contracts.stable_id_child(
					mask.stable_id,
					.Property,
					u64(angle_index),
				)
				result.candidates[candidate_write] = {
					stable_id = candidate_id,
					evidence_mask_id = mask.stable_id,
					evidence_mask_index = u32(mask_index),
					angle_index = u8(angle_index),
					angle = angle,
					direction_x = direction_x,
					direction_y = direction_y,
					span_projection = score.span_projection,
					positive_anchor_capacity =
						score.positive_anchor_capacity,
					negative_anchor_capacity =
						score.negative_anchor_capacity,
					bidirectional_anchor_capacity =
						score.bidirectional_anchor_capacity,
					total_anchor_capacity =
						score.total_anchor_capacity,
				}
				if candidate_write > candidate_start &&
				   bridge_direction_candidate_better(
						result.candidates[candidate_write],
						result.candidates[best_index],
				   ) {
					best_index = candidate_write
				}
				candidate_write += 1
			}
			polygon.polygon_set_destroy(&boundary, allocator)
			status := Bridge_Direction_Status.Selected
			if result.candidates[best_index].
			   bidirectional_anchor_capacity == 0 {
				status = .No_Bidirectional_Anchor
			}
			region := regions.regions[mask.region_index]
			result.selections[selection_write] = {
				evidence_mask_id = mask.stable_id,
				evidence_mask_index = u32(mask_index),
				region_id = region.stable_id,
				region_index = mask.region_index,
				layer_index = mask.layer_index,
				status = status,
				selected_candidate_index = u32(best_index),
				candidate_offset = u64(candidate_start),
				candidate_count =
					process.source.bridge_angle_count,
			}
			selection_write += 1
		}
		layer_selection_count := selection_write-layer_selection_start
		layer_candidate_count := candidate_write-layer_candidate_start
		if layer_selection_count > int(max(u32)) ||
		   layer_candidate_count > int(max(u32)) {
			bridge_direction_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			selection_offset = u64(layer_selection_start),
			selection_count = u32(layer_selection_count),
			candidate_offset = u64(layer_candidate_start),
			candidate_count = u32(layer_candidate_count),
		}
	}
	if selection_write != len(result.selections) ||
	   candidate_write != len(result.candidates) {
		bridge_direction_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

bridge_direction_evidence_valid :: proc(
	regions: slicing.Region_Result,
	evidence: Bridge_Evidence_Result,
) -> bool {
	expected_mask_offset: u64
	expected_path_offset: u64
	eligible_count: u64
	previous_region_index: u32
	for layer, layer_index in evidence.layers {
		if layer.mask_offset != expected_mask_offset ||
		   layer.path_offset != expected_path_offset ||
		   layer.mask_offset+u64(layer.mask_count) >
		    u64(len(evidence.masks)) ||
		   layer.path_offset+u64(layer.path_count) >
		    u64(len(evidence.paths)) {
			return false
		}
		mask_start := int(layer.mask_offset)
		mask_end := mask_start+int(layer.mask_count)
		layer_path_count: u64
		for mask, local_mask_index in
		    evidence.masks[mask_start:mask_end] {
			if u64(mask.region_index) >=
			    u64(len(regions.regions)) {
				return false
			}
			region := regions.regions[mask.region_index]
			if mask.layer_index != u32(layer_index) ||
			   mask.layer_index != region.layer_index ||
			   mask.region_id != region.stable_id ||
			   mask.kind != .Eligible_Unsupported &&
			    mask.kind != .Below_Minimum_Area ||
			   mask.path_count == 0 ||
			   mask.point_count == 0 ||
			   mask.path_offset !=
			    expected_path_offset+layer_path_count ||
			   mask.path_offset+u64(mask.path_count) >
			    u64(len(evidence.paths)) ||
			   mask.point_offset+u64(mask.point_count) >
			    u64(len(evidence.points)) ||
			   (expected_mask_offset > 0 ||
			    local_mask_index > 0) &&
			    mask.region_index <= previous_region_index {
				return false
			}
			if mask.kind == .Eligible_Unsupported {
				eligible_count += 1
			}
			layer_path_count += u64(mask.path_count)
			previous_region_index = mask.region_index
		}
		if layer_path_count != u64(layer.path_count) {
			return false
		}
		expected_mask_offset += u64(layer.mask_count)
		expected_path_offset += u64(layer.path_count)
	}
	return expected_mask_offset == u64(len(evidence.masks)) &&
		expected_path_offset == u64(len(evidence.paths)) &&
		eligible_count == evidence.eligible_mask_count
}

Bridge_Direction_Score :: struct {
	span_projection:               i128,
	positive_anchor_capacity:      u128,
	negative_anchor_capacity:      u128,
	bidirectional_anchor_capacity: u128,
	total_anchor_capacity:         u128,
}

bridge_direction_score_candidate :: proc(
	boundary, support: polygon.Polygon_Set,
	direction_x, direction_y: i64,
) -> (Bridge_Direction_Score, bool) {
	if len(boundary.points) == 0 {return {}, false}
	first_projection :=
		i128(i64(boundary.points[0].x))*i128(direction_x)+
		i128(i64(boundary.points[0].y))*i128(direction_y)
	minimum_projection := first_projection
	maximum_projection := first_projection
	for point in boundary.points[1:] {
		projection :=
			i128(i64(point.x))*i128(direction_x)+
			i128(i64(point.y))*i128(direction_y)
		minimum_projection = min(minimum_projection, projection)
		maximum_projection = max(maximum_projection, projection)
	}
	result := Bridge_Direction_Score{
		span_projection = maximum_projection-minimum_projection,
	}
	for path in boundary.paths {
		if path.count < 3 ||
		   path.offset+path.count > u64(len(boundary.points)) {
			return {}, false
		}
		start := int(path.offset)
		for edge_index in 0..<int(path.count) {
			a := boundary.points[start+edge_index]
			b := boundary.points[
				start+(edge_index+1)%int(path.count)
			]
			midpoint_x_twice := i64(a.x)+i64(b.x)
			midpoint_y_twice := i64(a.y)+i64(b.y)
			if !bridge_polygon_contains_twice(
				support,
				midpoint_x_twice,
				midpoint_y_twice,
			) {
				continue
			}
			edge_x := i128(i64(b.x))-i128(i64(a.x))
			edge_y := i128(i64(b.y))-i128(i64(a.y))
			crossing :=
				i128(direction_x)*edge_y-
				i128(direction_y)*edge_x
			if crossing > 0 {
				added := u128(crossing)
				if result.positive_anchor_capacity >
				   max(u128)-added {
					return {}, false
				}
				result.positive_anchor_capacity += added
			} else if crossing < 0 {
				if crossing == min(i128) {return {}, false}
				added := u128(-crossing)
				if result.negative_anchor_capacity >
				   max(u128)-added {
					return {}, false
				}
				result.negative_anchor_capacity += added
			}
		}
	}
	result.bidirectional_anchor_capacity = min(
		result.positive_anchor_capacity,
		result.negative_anchor_capacity,
	)
	if result.positive_anchor_capacity >
	   max(u128)-result.negative_anchor_capacity {
		return {}, false
	}
	result.total_anchor_capacity =
		result.positive_anchor_capacity+
		result.negative_anchor_capacity
	return result, true
}

bridge_direction_candidate_better :: proc(
	candidate, current: Bridge_Direction_Candidate,
) -> bool {
	if candidate.bidirectional_anchor_capacity !=
	   current.bidirectional_anchor_capacity {
		return candidate.bidirectional_anchor_capacity >
			current.bidirectional_anchor_capacity
	}
	if candidate.total_anchor_capacity != current.total_anchor_capacity {
		return candidate.total_anchor_capacity >
			current.total_anchor_capacity
	}
	if candidate.span_projection != current.span_projection {
		return candidate.span_projection < current.span_projection
	}
	return candidate.angle < current.angle
}

bridge_direction_vector :: proc(
	angle: profiles.Angle_Millidegrees,
) -> (i64, i64, bool) {
	value := i32(angle)
	if value < 0 || value >= 180_000 {return 0, 0, false}
	switch value {
	case 0:
		return BRIDGE_DIRECTION_SCALE, 0, true
	case 90_000:
		return 0, BRIDGE_DIRECTION_SCALE, true
	}
	radians := f64(value)*math.PI/(180.0*1_000.0)
	x := i64(math.round(math.cos(radians)*f64(BRIDGE_DIRECTION_SCALE)))
	y := i64(math.round(math.sin(radians)*f64(BRIDGE_DIRECTION_SCALE)))
	if x == 0 && y == 0 {return 0, 0, false}
	return x, y, true
}

bridge_polygon_contains_twice :: proc(
	set: polygon.Polygon_Set,
	x_twice, y_twice: i64,
) -> bool {
	inside := false
	for path in set.paths {
		if path.count < 3 ||
		   path.offset+path.count > u64(len(set.points)) {
			return false
		}
		start := int(path.offset)
		for edge_index in 0..<int(path.count) {
			a := set.points[start+edge_index]
			b := set.points[start+(edge_index+1)%int(path.count)]
			ax_twice := i128(i64(a.x))*2
			ay_twice := i128(i64(a.y))*2
			bx_twice := i128(i64(b.x))*2
			by_twice := i128(i64(b.y))*2
			qx := i128(x_twice)
			qy := i128(y_twice)
			cross :=
				(bx_twice-ax_twice)*(qy-ay_twice)-
				(by_twice-ay_twice)*(qx-ax_twice)
			if cross == 0 &&
			   qx >= min(ax_twice, bx_twice) &&
			   qx <= max(ax_twice, bx_twice) &&
			   qy >= min(ay_twice, by_twice) &&
			   qy <= max(ay_twice, by_twice) {
				return true
			}
			crosses := ay_twice <= qy && qy < by_twice ||
				by_twice <= qy && qy < ay_twice
			if !crosses {continue}
			delta_y := i128(i64(b.y))-i128(i64(a.y))
			numerator :=
				i128(i64(a.x))*2*delta_y+
				(qy-ay_twice)*
				(i128(i64(b.x))-i128(i64(a.x)))
			right := qx*delta_y
			if delta_y > 0 && numerator > right ||
			   delta_y < 0 && numerator < right {
				inside = !inside
			}
		}
	}
	return inside
}

bridge_direction_supports_build :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	anchor_margin: contracts.Micrometres,
	provider: polygon.Polygon_Provider,
	config: Bridge_Evidence_Config,
	polygon_limits: polygon.Polygon_Limits,
	allocator := context.allocator,
) -> ([]polygon.Polygon_Set, Bridge_Direction_Error) {
	region_inputs := make(
		[]polygon.Polygon_Set,
		len(regions.regions),
		allocator,
	)
	layer_inputs := make(
		[]polygon.Polygon_Set,
		len(regions.layers),
		allocator,
	)
	supports := make(
		[]polygon.Polygon_Set,
		len(regions.layers),
		allocator,
	)
	if len(regions.regions) > 0 && region_inputs == nil ||
	   len(regions.layers) > 0 &&
	    (layer_inputs == nil || supports == nil) {
		delete(region_inputs, allocator)
		delete(layer_inputs, allocator)
		delete(supports, allocator)
		return nil, .Allocation_Failed
	}
	defer {
		for &input in region_inputs {
			polygon.polygon_set_destroy(&input, allocator)
		}
		for &input in layer_inputs {
			polygon.polygon_set_destroy(&input, allocator)
		}
		delete(region_inputs, allocator)
		delete(layer_inputs, allocator)
	}
	for _, region_index in regions.regions {
		input, input_error := perimeter_region_input(
			topology,
			regions,
			u32(region_index),
			allocator,
		)
		if input_error != .None {
			for &support in supports {
				polygon.polygon_set_destroy(&support, allocator)
			}
			delete(supports, allocator)
			return nil, bridge_direction_perimeter_error(input_error)
		}
		region_inputs[region_index] = input
	}
	layer_error := bridge_evidence_join_layers(
		regions,
		region_inputs,
		layer_inputs,
		allocator,
	)
	if layer_error != .None {
		delete(supports, allocator)
		return nil, bridge_direction_evidence_error(layer_error)
	}
	for layer_index in 1..<len(layer_inputs) {
		previous := layer_inputs[layer_index-1]
		if len(previous.paths) == 0 {continue}
		if anchor_margin == 0 {
			cloned, clone_ok := skin_polygon_clone(previous, allocator)
			if !clone_ok {
				for &support in supports {
					polygon.polygon_set_destroy(&support, allocator)
				}
				delete(supports, allocator)
				return nil, .Allocation_Failed
			}
			supports[layer_index] = cloned
			continue
		}
		support, support_error := provider.offset(
			previous,
			anchor_margin,
			config.join_type,
			config.miter_limit,
			config.arc_tolerance,
			polygon_limits,
			allocator,
		)
		supports[layer_index] = support
		if support_error != .None {
			for &item in supports {
				polygon.polygon_set_destroy(&item, allocator)
			}
			delete(supports, allocator)
			return nil, .Provider
		}
	}
	return supports, .None
}

bridge_direction_perimeter_error :: proc(
	error: Perimeter_Error,
) -> Bridge_Direction_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

bridge_direction_evidence_error :: proc(
	error: Bridge_Evidence_Error,
) -> Bridge_Direction_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

bridge_direction_result_destroy :: proc(
	result: ^Bridge_Direction_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.selections, allocator)
	delete(result.candidates, allocator)
	result^ = {}
}
