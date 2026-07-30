package features

import "core:math"
import "core:mem"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

Support_Demand_Config :: struct {
	fill_rule:     polygon.Polygon_Fill_Rule,
	join_type:     polygon.Polygon_Join_Type,
	miter_limit:   f64,
	arc_tolerance: f64,
}

Support_Demand_Limits :: struct {
	max_masks:                  u64,
	max_paths:                  u64,
	max_points:                 u64,
	max_source_face_references: u64,
	polygon:                    polygon.Polygon_Limits,
}

DEFAULT_SUPPORT_DEMAND_LIMITS :: Support_Demand_Limits{
	max_masks = 100_000_000,
	max_paths = 200_000_000,
	max_points = 1_000_000_000,
	max_source_face_references = 1_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Support_Demand_Layer :: struct {
	mask_offset:             u64,
	mask_count:              u32,
	path_offset:             u64,
	path_count:              u32,
	source_reference_offset: u64,
	source_reference_count:  u32,
	allowed_lateral_margin:  contracts.Micrometres,
}

Support_Demand_Mask :: struct {
	stable_id:               contracts.Stable_ID,
	layer_id:                contracts.Stable_ID,
	layer_index:             u32,
	allowed_lateral_margin:  contracts.Micrometres,
	path_offset:             u64,
	path_count:              u32,
	point_offset:            u64,
	point_count:             u32,
	source_reference_offset: u64,
	source_reference_count:  u32,
}

Support_Demand_Path :: struct {
	stable_id:       contracts.Stable_ID,
	mask_id:         contracts.Stable_ID,
	mask_path_index: u32,
	point_offset:    u64,
	point_count:     u32,
	signed_area_2:   i128,
	winding:         geometry.Predicate_Sign,
}

Support_Demand_Result :: struct {
	config:                  Support_Demand_Config,
	policy:                  profiles.Support_Demand_Policy,
	overhang_angle:          profiles.Angle_Millidegrees,
	angle_direction_x:       i64,
	angle_direction_y:       i64,
	layers:                  []Support_Demand_Layer,
	masks:                   []Support_Demand_Mask,
	paths:                   []Support_Demand_Path,
	points:                  []polygon.Polygon_Point,
	source_face_references:  []u32,
}

Support_Demand_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Mask_Limit,
	Path_Limit,
	Point_Limit,
	Source_Reference_Limit,
	Provider,
	Allocation_Failed,
	Arithmetic,
}

support_demand_build :: proc(
	schedule: slicing.Fixed_Layer_Schedule,
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	faces: Support_Face_Result,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	config: Support_Demand_Config,
	limits := DEFAULT_SUPPORT_DEMAND_LIMITS,
	allocator := context.allocator,
) -> (Support_Demand_Result, Support_Demand_Error) {
	direction_x, direction_y, direction_ok :=
		bridge_direction_vector(process.source.support_overhang_angle)
	if !support_demand_config_valid(config) ||
	   !profiles.process_support_targets_valid(process.source) ||
	   process.source.support_demand != .Mesh_And_Layer_Projection ||
	   !direction_ok || direction_x <= 0 || direction_y <= 0 ||
	   provider.boolean == nil || provider.offset == nil {
		return {}, .Invalid_Config
	}
	if len(schedule.layer_z) != len(schedule.layer_ids) ||
	   len(schedule.layer_z) != len(topology.layers) ||
	   len(schedule.layer_z) != len(regions.layers) ||
	   !support_face_result_basic_valid(faces, process) {
		return {}, .Invalid_Input
	}
	_, schedule_ok := slicing.fixed_layer_schedule_hash(schedule)
	_, regions_ok := slicing.region_result_hash({}, topology, regions)
	if !schedule_ok || !regions_ok {return {}, .Invalid_Input}
	for layer_index in 1..<len(schedule.layer_z) {
		if schedule.layer_z[layer_index] <=
		   schedule.layer_z[layer_index-1] {
			return {}, .Invalid_Input
		}
	}

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
	outputs := make(
		[]polygon.Polygon_Set,
		len(regions.layers),
		allocator,
	)
	output_sources := make(
		[][dynamic]u32,
		len(regions.layers),
		allocator,
	)
	allowed_margins := make(
		[]contracts.Micrometres,
		len(regions.layers),
		allocator,
	)
	if len(regions.regions) > 0 && region_inputs == nil ||
	   len(regions.layers) > 0 &&
	    (layer_inputs == nil || outputs == nil ||
	     output_sources == nil || allowed_margins == nil) {
		delete(region_inputs, allocator)
		delete(layer_inputs, allocator)
		delete(outputs, allocator)
		delete(output_sources, allocator)
		delete(allowed_margins, allocator)
		return {}, .Allocation_Failed
	}
	for &sources in output_sources {
		sources = make([dynamic]u32, allocator)
	}
	defer {
		for &input in region_inputs {
			polygon.polygon_set_destroy(&input, allocator)
		}
		for &input in layer_inputs {
			polygon.polygon_set_destroy(&input, allocator)
		}
		for &output in outputs {
			polygon.polygon_set_destroy(&output, allocator)
		}
		for &sources in output_sources {
			delete(sources)
		}
		delete(region_inputs, allocator)
		delete(layer_inputs, allocator)
		delete(outputs, allocator)
		delete(output_sources, allocator)
		delete(allowed_margins, allocator)
	}

	for _, region_index in regions.regions {
		input, input_error := perimeter_region_input(
			topology,
			regions,
			u32(region_index),
			allocator,
		)
		if input_error != .None {
			return {}, support_demand_perimeter_error(input_error)
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
		return {}, support_demand_bridge_error(layer_error)
	}

	total_masks: u64
	total_paths: u64
	total_points: u64
	total_source_references: u64
	for layer_index in 1..<len(layer_inputs) {
		margin, margin_ok := support_demand_allowed_margin(
			schedule.layer_z[layer_index]-
				schedule.layer_z[layer_index-1],
			direction_x,
			direction_y,
		)
		if !margin_ok {return {}, .Arithmetic}
		allowed_margins[layer_index] = margin
		expanded_below: polygon.Polygon_Set
		if len(layer_inputs[layer_index-1].paths) > 0 {
			if margin == 0 {
				cloned, clone_ok := skin_polygon_clone(
					layer_inputs[layer_index-1],
					allocator,
				)
				if !clone_ok {return {}, .Allocation_Failed}
				expanded_below = cloned
			} else {
				expand_error: polygon.Polygon_Error
				expanded_below, expand_error = provider.offset(
					layer_inputs[layer_index-1],
					margin,
					config.join_type,
					config.miter_limit,
					config.arc_tolerance,
					limits.polygon,
					allocator,
				)
				if expand_error != .None {
					polygon.polygon_set_destroy(
						&expanded_below,
						allocator,
					)
					return {}, .Provider
				}
			}
		}
		unsupported, unsupported_error := provider.boolean(
			layer_inputs[layer_index],
			expanded_below,
			.Difference,
			config.fill_rule,
			limits.polygon,
			allocator,
		)
		polygon.polygon_set_destroy(&expanded_below, allocator)
		if unsupported_error != .None {
			polygon.polygon_set_destroy(&unsupported, allocator)
			return {}, .Provider
		}
		if len(unsupported.paths) == 0 {
			polygon.polygon_set_destroy(&unsupported, allocator)
			continue
		}

		overhang_union: polygon.Polygon_Set
		candidate_faces := make([dynamic]u32, allocator)
		previous_z := schedule.layer_z[layer_index-1]
		current_z := schedule.layer_z[layer_index]
		for face, face_index in faces.faces {
			if face.kind != .Downward_Overhang ||
			   face.maximum_z <= previous_z ||
			   face.minimum_z > current_z {
				continue
			}
			projection, projection_error :=
				support_face_projection_input(
					faces,
					u32(face_index),
					allocator,
				)
			if projection_error != .None {
				delete(candidate_faces)
				polygon.polygon_set_destroy(&unsupported, allocator)
				polygon.polygon_set_destroy(&overhang_union, allocator)
				return {}, projection_error
			}
			accumulate_error := skin_polygon_accumulate(
				&overhang_union,
				&projection,
				provider,
				config.fill_rule,
				limits.polygon,
				allocator,
			)
			if accumulate_error != .None {
				delete(candidate_faces)
				polygon.polygon_set_destroy(&unsupported, allocator)
				polygon.polygon_set_destroy(&overhang_union, allocator)
				return {}, support_demand_skin_error(
					accumulate_error,
				)
			}
			append(&candidate_faces, u32(face_index))
		}
		if len(overhang_union.paths) == 0 {
			delete(candidate_faces)
			polygon.polygon_set_destroy(&unsupported, allocator)
			polygon.polygon_set_destroy(&overhang_union, allocator)
			continue
		}
		demand, demand_error := provider.boolean(
			unsupported,
			overhang_union,
			.Intersection,
			config.fill_rule,
			limits.polygon,
			allocator,
		)
		polygon.polygon_set_destroy(&unsupported, allocator)
		polygon.polygon_set_destroy(&overhang_union, allocator)
		if demand_error != .None {
			delete(candidate_faces)
			polygon.polygon_set_destroy(&demand, allocator)
			return {}, .Provider
		}
		if len(demand.paths) == 0 {
			delete(candidate_faces)
			polygon.polygon_set_destroy(&demand, allocator)
			continue
		}
		for face_index in candidate_faces {
			projection, projection_error :=
				support_face_projection_input(
					faces,
					face_index,
					allocator,
				)
			if projection_error != .None {
				delete(candidate_faces)
				polygon.polygon_set_destroy(&demand, allocator)
				return {}, projection_error
			}
			contribution, contribution_error := provider.boolean(
				demand,
				projection,
				.Intersection,
				config.fill_rule,
				limits.polygon,
				allocator,
			)
			polygon.polygon_set_destroy(&projection, allocator)
			if contribution_error != .None {
				delete(candidate_faces)
				polygon.polygon_set_destroy(&contribution, allocator)
				polygon.polygon_set_destroy(&demand, allocator)
				return {}, .Provider
			}
			contributes := len(contribution.paths) > 0
			polygon.polygon_set_destroy(&contribution, allocator)
			if contributes {
				append(&output_sources[layer_index], face_index)
			}
		}
		delete(candidate_faces)
		outputs[layer_index] = demand
		total_masks += 1
		if total_masks > limits.max_masks {return {}, .Mask_Limit}
		if total_paths > limits.max_paths ||
		   u64(len(demand.paths)) > limits.max_paths-total_paths {
			return {}, .Path_Limit
		}
		if total_points > limits.max_points ||
		   u64(len(demand.points)) > limits.max_points-total_points {
			return {}, .Point_Limit
		}
		if total_source_references >
		   limits.max_source_face_references ||
		   u64(len(output_sources[layer_index])) >
		    limits.max_source_face_references-
		    total_source_references {
			return {}, .Source_Reference_Limit
		}
		total_paths += u64(len(demand.paths))
		total_points += u64(len(demand.points))
		total_source_references +=
			u64(len(output_sources[layer_index]))
	}
	if total_masks > u64(max(int)) ||
	   total_paths > u64(max(int)) ||
	   total_points > u64(max(int)) ||
	   total_source_references > u64(max(int)) {
		return {}, .Arithmetic
	}

	result := Support_Demand_Result{
		config = config,
		policy = process.source.support_demand,
		overhang_angle = process.source.support_overhang_angle,
		angle_direction_x = direction_x,
		angle_direction_y = direction_y,
	}
	result.layers = make(
		[]Support_Demand_Layer,
		len(regions.layers),
		allocator,
	)
	result.masks = make(
		[]Support_Demand_Mask,
		int(total_masks),
		allocator,
	)
	result.paths = make(
		[]Support_Demand_Path,
		int(total_paths),
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		int(total_points),
		allocator,
	)
	result.source_face_references = make(
		[]u32,
		int(total_source_references),
		allocator,
	)
	if len(result.layers) > 0 && result.layers == nil ||
	   total_masks > 0 && result.masks == nil ||
	   total_paths > 0 && result.paths == nil ||
	   total_points > 0 && result.points == nil ||
	   total_source_references > 0 &&
	    result.source_face_references == nil {
		support_demand_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	mask_write := 0
	path_write := 0
	point_write := 0
	source_write := 0
	for output, layer_index in outputs {
		layer_mask_start := mask_write
		layer_path_start := path_write
		layer_source_start := source_write
		if len(output.paths) > 0 {
			layer_id := schedule.layer_ids[layer_index]
			mask_id := contracts.stable_id_child(
				layer_id,
				.Feature,
				feature_support_demand_ordinal(),
			)
			mask_path_start := path_write
			mask_point_start := point_write
			for source_path, local_path_index in output.paths {
				if source_path.count > u64(max(u32)) {
					support_demand_result_destroy(&result, allocator)
					return {}, .Arithmetic
				}
				start := int(source_path.offset)
				end := start+int(source_path.count)
				points := output.points[start:end]
				area_2 := polygon.polygon_path_area_2(points)
				winding := geometry.Predicate_Sign.Positive
				if area_2 < 0 {winding = .Negative}
				result.paths[path_write] = {
					stable_id = contracts.stable_id_child(
						mask_id,
						.Path,
						u64(local_path_index),
					),
					mask_id = mask_id,
					mask_path_index = u32(local_path_index),
					point_offset = u64(point_write),
					point_count = u32(source_path.count),
					signed_area_2 = area_2,
					winding = winding,
				}
				copy(
					result.points[
						point_write:point_write+len(points)
					],
					points,
				)
				point_write += len(points)
				path_write += 1
			}
			copy(
				result.source_face_references[
					source_write:
					source_write+len(output_sources[layer_index])
				],
				output_sources[layer_index][:],
			)
			source_write += len(output_sources[layer_index])
			mask_path_count := path_write-mask_path_start
			mask_point_count := point_write-mask_point_start
			if mask_path_count > int(max(u32)) ||
			   mask_point_count > int(max(u32)) ||
			   len(output_sources[layer_index]) > int(max(u32)) {
				support_demand_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			result.masks[mask_write] = {
				stable_id = mask_id,
				layer_id = layer_id,
				layer_index = u32(layer_index),
				allowed_lateral_margin = allowed_margins[layer_index],
				path_offset = u64(mask_path_start),
				path_count = u32(mask_path_count),
				point_offset = u64(mask_point_start),
				point_count = u32(mask_point_count),
				source_reference_offset = u64(layer_source_start),
				source_reference_count =
					u32(len(output_sources[layer_index])),
			}
			mask_write += 1
		}
		layer_mask_count := mask_write-layer_mask_start
		layer_path_count := path_write-layer_path_start
		layer_source_count := source_write-layer_source_start
		result.layers[layer_index] = {
			mask_offset = u64(layer_mask_start),
			mask_count = u32(layer_mask_count),
			path_offset = u64(layer_path_start),
			path_count = u32(layer_path_count),
			source_reference_offset = u64(layer_source_start),
			source_reference_count = u32(layer_source_count),
			allowed_lateral_margin = allowed_margins[layer_index],
		}
	}
	if mask_write != len(result.masks) ||
	   path_write != len(result.paths) ||
	   point_write != len(result.points) ||
	   source_write != len(result.source_face_references) {
		support_demand_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

support_demand_allowed_margin :: proc(
	layer_delta: contracts.Micrometres,
	direction_x, direction_y: i64,
) -> (contracts.Micrometres, bool) {
	if i64(layer_delta) <= 0 || direction_x <= 0 || direction_y <= 0 {
		return 0, false
	}
	numerator := i128(i64(layer_delta))*i128(direction_y)
	margin := numerator/i128(direction_x)
	if margin < 0 ||
	   margin > i128(geometry.MAX_PLANAR_COORDINATE_UM) {
		return 0, false
	}
	return contracts.Micrometres(margin), true
}

support_demand_mask_input :: proc(
	demand: Support_Demand_Result,
	mask_index: u32,
	allocator: mem.Allocator,
) -> (polygon.Polygon_Set, Support_Demand_Error) {
	if u64(mask_index) >= u64(len(demand.masks)) {
		return {}, .Invalid_Input
	}
	mask := demand.masks[mask_index]
	if mask.path_offset+u64(mask.path_count) >
		u64(len(demand.paths)) ||
	   mask.point_offset+u64(mask.point_count) >
		u64(len(demand.points)) {
		return {}, .Invalid_Input
	}
	result := polygon.Polygon_Set{
		paths = make(
			[]polygon.Polygon_Path,
			int(mask.path_count),
			allocator,
		),
		points = make(
			[]polygon.Polygon_Point,
			int(mask.point_count),
			allocator,
		),
	}
	if result.paths == nil || result.points == nil {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	point_write := 0
	path_start := int(mask.path_offset)
	path_end := path_start+int(mask.path_count)
	for path, local_path_index in demand.paths[path_start:path_end] {
		if path.mask_id != mask.stable_id ||
		   path.mask_path_index != u32(local_path_index) ||
		   path.point_offset+u64(path.point_count) >
			u64(len(demand.points)) {
			polygon.polygon_set_destroy(&result, allocator)
			return {}, .Invalid_Input
		}
		result.paths[local_path_index] = {
			offset = u64(point_write),
			count = u64(path.point_count),
		}
		start := int(path.point_offset)
		end := start+int(path.point_count)
		copy(
			result.points[
				point_write:point_write+int(path.point_count)
			],
			demand.points[start:end],
		)
		point_write += int(path.point_count)
	}
	if point_write != len(result.points) {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

support_face_result_basic_valid :: proc(
	faces: Support_Face_Result,
	process: profiles.Resolved_Process_Profile,
) -> bool {
	if faces.policy != process.source.support_demand ||
	   faces.overhang_angle != process.source.support_overhang_angle {
		return false
	}
	expected_point_offset: u64
	overhang_count: u64
	for face, face_index in faces.faces {
		if face.triangle_index != u32(face_index) ||
		   face.stable_id == contracts.INVALID_STABLE_ID ||
		   face.triangle_id != face.stable_id ||
		   face.kind == .Invalid {
			return false
		}
		if face.kind == .Downward_Overhang {
			if face.point_count != 3 ||
			   face.point_offset != expected_point_offset ||
			   face.point_offset+3 > u64(len(faces.points)) ||
			   face.projected_area_2 <= 0 {
				return false
			}
			expected_point_offset += 3
			overhang_count += 1
		} else if face.point_count != 0 ||
		          face.point_offset != 0 ||
		          face.projected_area_2 != 0 {
			return false
		}
	}
	return expected_point_offset == u64(len(faces.points)) &&
		overhang_count == faces.overhang_count
}

support_face_projection_input :: proc(
	faces: Support_Face_Result,
	face_index: u32,
	allocator: mem.Allocator,
) -> (polygon.Polygon_Set, Support_Demand_Error) {
	if u64(face_index) >= u64(len(faces.faces)) {
		return {}, .Invalid_Input
	}
	face := faces.faces[face_index]
	if face.kind != .Downward_Overhang ||
	   face.point_count != 3 ||
	   face.point_offset+3 > u64(len(faces.points)) {
		return {}, .Invalid_Input
	}
	result := polygon.Polygon_Set{
		paths = make([]polygon.Polygon_Path, 1, allocator),
		points = make([]polygon.Polygon_Point, 3, allocator),
	}
	if result.paths == nil || result.points == nil {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	result.paths[0] = {offset = 0, count = 3}
	start := int(face.point_offset)
	copy(result.points, faces.points[start:start+3])
	return result, .None
}

support_demand_config_valid :: proc(config: Support_Demand_Config) -> bool {
	fill_valid := config.fill_rule == .Even_Odd ||
		config.fill_rule == .Non_Zero ||
		config.fill_rule == .Positive
	return fill_valid &&
		perimeter_join_type_valid(config.join_type) &&
		!math.is_nan(config.miter_limit) &&
		!math.is_inf(config.miter_limit) &&
		!math.is_nan(config.arc_tolerance) &&
		!math.is_inf(config.arc_tolerance) &&
		config.miter_limit >= 1 &&
		config.arc_tolerance >= 0
}

support_demand_perimeter_error :: proc(
	error: Perimeter_Error,
) -> Support_Demand_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

support_demand_bridge_error :: proc(
	error: Bridge_Evidence_Error,
) -> Support_Demand_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

support_demand_skin_error :: proc(
	error: Skin_Error,
) -> Support_Demand_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Provider
}

support_demand_result_destroy :: proc(
	result: ^Support_Demand_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.masks, allocator)
	delete(result.paths, allocator)
	delete(result.points, allocator)
	delete(result.source_face_references, allocator)
	result^ = {}
}
