package features

import "core:math"
import "core:mem"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

Bridge_Evidence_Kind :: enum u8 {
	Invalid,
	Eligible_Unsupported,
	Below_Minimum_Area,
}

Bridge_Evidence_Config :: struct {
	fill_rule:     polygon.Polygon_Fill_Rule,
	join_type:     polygon.Polygon_Join_Type,
	miter_limit:   f64,
	arc_tolerance: f64,
}

Bridge_Evidence_Limits :: struct {
	max_masks:  u64,
	max_paths:  u64,
	max_points: u64,
	polygon:    polygon.Polygon_Limits,
}

DEFAULT_BRIDGE_EVIDENCE_LIMITS :: Bridge_Evidence_Limits{
	max_masks = 200_000_000,
	max_paths = 400_000_000,
	max_points = 2_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Bridge_Evidence_Layer :: struct {
	mask_offset: u64,
	mask_count:  u32,
	path_offset: u64,
	path_count:  u32,
}

Bridge_Evidence_Mask :: struct {
	stable_id:     contracts.Stable_ID,
	region_id:     contracts.Stable_ID,
	region_index:  u32,
	layer_index:   u32,
	kind:          Bridge_Evidence_Kind,
	signed_area_2: i128,
	path_offset:   u64,
	path_count:    u32,
	point_offset:  u64,
	point_count:   u32,
}

Bridge_Evidence_Path :: struct {
	stable_id:       contracts.Stable_ID,
	mask_id:         contracts.Stable_ID,
	mask_path_index: u32,
	point_offset:    u64,
	point_count:     u32,
	signed_area_2:   i128,
	winding:         geometry.Predicate_Sign,
}

Bridge_Evidence_Result :: struct {
	config:                 Bridge_Evidence_Config,
	geometry_policy:        profiles.Bridge_Geometry_Policy,
	anchor_margin:          contracts.Micrometres,
	minimum_area:           profiles.Area_Square_Micrometres,
	layers:                 []Bridge_Evidence_Layer,
	masks:                  []Bridge_Evidence_Mask,
	paths:                  []Bridge_Evidence_Path,
	points:                 []polygon.Polygon_Point,
	eligible_mask_count:    u64,
	below_minimum_count:    u64,
}

Bridge_Evidence_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Mask_Limit,
	Path_Limit,
	Point_Limit,
	Provider,
	Allocation_Failed,
	Arithmetic,
}

bridge_evidence_build :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	config: Bridge_Evidence_Config,
	limits := DEFAULT_BRIDGE_EVIDENCE_LIMITS,
	allocator := context.allocator,
) -> (Bridge_Evidence_Result, Bridge_Evidence_Error) {
	if !bridge_evidence_config_valid(config) ||
	   !profiles.process_bridge_targets_valid(process.source) ||
	   provider.boolean == nil || provider.offset == nil {
		return {}, .Invalid_Config
	}
	if process.source.bridge_geometry != .Previous_Layer_Expanded_Support ||
	   len(topology.layers) != len(regions.layers) {
		return {}, .Invalid_Input
	}
	_, regions_ok := slicing.region_result_hash({}, topology, regions)
	if !regions_ok {return {}, .Invalid_Input}
	if u64(len(regions.regions)) > u64(max(u32)) {
		return {}, .Arithmetic
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
	expanded_supports := make(
		[]polygon.Polygon_Set,
		len(regions.layers),
		allocator,
	)
	outputs := make(
		[]polygon.Polygon_Set,
		len(regions.regions),
		allocator,
	)
	output_areas_2 := make([]i128, len(regions.regions), allocator)
	if len(regions.regions) > 0 &&
	   (region_inputs == nil || outputs == nil ||
	    output_areas_2 == nil) ||
	   len(regions.layers) > 0 &&
	   (layer_inputs == nil || expanded_supports == nil) {
		delete(region_inputs, allocator)
		delete(layer_inputs, allocator)
		delete(expanded_supports, allocator)
		delete(outputs, allocator)
		delete(output_areas_2, allocator)
		return {}, .Allocation_Failed
	}
	defer {
		for &input in region_inputs {
			polygon.polygon_set_destroy(&input, allocator)
		}
		for &input in layer_inputs {
			polygon.polygon_set_destroy(&input, allocator)
		}
		for &support in expanded_supports {
			polygon.polygon_set_destroy(&support, allocator)
		}
		for &output in outputs {
			polygon.polygon_set_destroy(&output, allocator)
		}
		delete(region_inputs, allocator)
		delete(layer_inputs, allocator)
		delete(expanded_supports, allocator)
		delete(outputs, allocator)
		delete(output_areas_2, allocator)
	}

	for region, region_index in regions.regions {
		input, input_error := perimeter_region_input(
			topology,
			regions,
			u32(region_index),
			allocator,
		)
		if input_error != .None {
			return {}, bridge_evidence_perimeter_error(input_error)
		}
		region_inputs[region_index] = input
	}
	layer_error := bridge_evidence_join_layers(
		regions,
		region_inputs,
		layer_inputs,
		allocator,
	)
	if layer_error != .None {return {}, layer_error}

	for layer_index in 1..<len(layer_inputs) {
		previous := layer_inputs[layer_index-1]
		if len(previous.paths) == 0 {continue}
		if process.source.bridge_anchor_margin == 0 {
			cloned, clone_ok := skin_polygon_clone(previous, allocator)
			if !clone_ok {return {}, .Allocation_Failed}
			expanded_supports[layer_index] = cloned
			continue
		}
		expanded, expand_error := provider.offset(
			previous,
			process.source.bridge_anchor_margin,
			config.join_type,
			config.miter_limit,
			config.arc_tolerance,
			limits.polygon,
			allocator,
		)
		expanded_supports[layer_index] = expanded
		if expand_error != .None {return {}, .Provider}
	}

	total_masks: u64
	total_paths: u64
	total_points: u64
	minimum_area_2 := i128(process.source.minimum_bridge_area)*2
	for region, region_index in regions.regions {
		if region.layer_index == 0 {continue}
		unsupported, unsupported_error := provider.boolean(
			region_inputs[region_index],
			expanded_supports[region.layer_index],
			.Difference,
			config.fill_rule,
			limits.polygon,
			allocator,
		)
		outputs[region_index] = unsupported
		if unsupported_error != .None {return {}, .Provider}
		if len(unsupported.paths) == 0 {continue}
		area_2, area_ok := bridge_evidence_area_2(unsupported)
		if !area_ok {return {}, .Provider}
		output_areas_2[region_index] = area_2
		total_masks += 1
		if total_masks > limits.max_masks {
			return {}, .Mask_Limit
		}
		if total_paths > limits.max_paths ||
		   u64(len(unsupported.paths)) >
		    limits.max_paths-total_paths {
			return {}, .Path_Limit
		}
		if total_points > limits.max_points ||
		   u64(len(unsupported.points)) >
		    limits.max_points-total_points {
			return {}, .Point_Limit
		}
		total_paths += u64(len(unsupported.paths))
		total_points += u64(len(unsupported.points))
	}
	if total_masks > u64(max(int)) ||
	   total_paths > u64(max(int)) ||
	   total_points > u64(max(int)) {
		return {}, .Arithmetic
	}

	result := Bridge_Evidence_Result{
		config = config,
		geometry_policy = process.source.bridge_geometry,
		anchor_margin = process.source.bridge_anchor_margin,
		minimum_area = process.source.minimum_bridge_area,
	}
	result.layers = make(
		[]Bridge_Evidence_Layer,
		len(regions.layers),
		allocator,
	)
	result.masks = make(
		[]Bridge_Evidence_Mask,
		int(total_masks),
		allocator,
	)
	result.paths = make(
		[]Bridge_Evidence_Path,
		int(total_paths),
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		int(total_points),
		allocator,
	)
	if len(result.layers) > 0 && result.layers == nil ||
	   total_masks > 0 && result.masks == nil ||
	   total_paths > 0 && result.paths == nil ||
	   total_points > 0 && result.points == nil {
		bridge_evidence_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	mask_write := 0
	path_write := 0
	point_write := 0
	for layer, layer_index in regions.layers {
		layer_mask_start := mask_write
		layer_path_start := path_write
		region_start := int(layer.region_offset)
		region_end := region_start+int(layer.region_count)
		for region_index in region_start..<region_end {
			output := outputs[region_index]
			if len(output.paths) == 0 {continue}
			region := regions.regions[region_index]
			area_2 := output_areas_2[region_index]
			kind := Bridge_Evidence_Kind.Eligible_Unsupported
			if area_2 < minimum_area_2 {
				kind = .Below_Minimum_Area
			}
			ordinal, ordinal_ok :=
				feature_bridge_evidence_ordinal(kind)
			if !ordinal_ok {
				bridge_evidence_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			mask_id := contracts.stable_id_child(
				region.stable_id,
				.Feature,
				ordinal,
			)
			mask_path_start := path_write
			mask_point_start := point_write
			for source_path, local_path_index in output.paths {
				if source_path.count > u64(max(u32)) {
					bridge_evidence_result_destroy(
						&result,
						allocator,
					)
					return {}, .Arithmetic
				}
				source_start := int(source_path.offset)
				source_end := source_start+int(source_path.count)
				points := output.points[source_start:source_end]
				path_area_2 := polygon.polygon_path_area_2(points)
				winding := geometry.Predicate_Sign.Positive
				if path_area_2 < 0 {winding = .Negative}
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
					signed_area_2 = path_area_2,
					winding = winding,
				}
				copy(
					result.points[
						point_write:
						point_write+len(points)
					],
					points,
				)
				point_write += len(points)
				path_write += 1
			}
			mask_path_count := path_write-mask_path_start
			mask_point_count := point_write-mask_point_start
			if mask_path_count > int(max(u32)) ||
			   mask_point_count > int(max(u32)) {
				bridge_evidence_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			result.masks[mask_write] = {
				stable_id = mask_id,
				region_id = region.stable_id,
				region_index = u32(region_index),
				layer_index = u32(layer_index),
				kind = kind,
				signed_area_2 = area_2,
				path_offset = u64(mask_path_start),
				path_count = u32(mask_path_count),
				point_offset = u64(mask_point_start),
				point_count = u32(mask_point_count),
			}
			if kind == .Eligible_Unsupported {
				result.eligible_mask_count += 1
			} else {
				result.below_minimum_count += 1
			}
			mask_write += 1
		}
		layer_mask_count := mask_write-layer_mask_start
		layer_path_count := path_write-layer_path_start
		if layer_mask_count > int(max(u32)) ||
		   layer_path_count > int(max(u32)) {
			bridge_evidence_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			mask_offset = u64(layer_mask_start),
			mask_count = u32(layer_mask_count),
			path_offset = u64(layer_path_start),
			path_count = u32(layer_path_count),
		}
	}
	if mask_write != len(result.masks) ||
	   path_write != len(result.paths) ||
	   point_write != len(result.points) {
		bridge_evidence_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

bridge_evidence_join_layers :: proc(
	regions: slicing.Region_Result,
	region_inputs: []polygon.Polygon_Set,
	layer_inputs: []polygon.Polygon_Set,
	allocator: mem.Allocator,
) -> Bridge_Evidence_Error {
	for layer, layer_index in regions.layers {
		region_start := int(layer.region_offset)
		region_end := region_start+int(layer.region_count)
		path_count: u64
		point_count: u64
		for input in region_inputs[region_start:region_end] {
			path_count += u64(len(input.paths))
			point_count += u64(len(input.points))
		}
		if path_count > u64(max(int)) ||
		   point_count > u64(max(int)) {
			return .Arithmetic
		}
		destination := &layer_inputs[layer_index]
		destination.paths = make(
			[]polygon.Polygon_Path,
			int(path_count),
			allocator,
		)
		destination.points = make(
			[]polygon.Polygon_Point,
			int(point_count),
			allocator,
		)
		if path_count > 0 && destination.paths == nil ||
		   point_count > 0 && destination.points == nil {
			return .Allocation_Failed
		}
		path_write := 0
		point_write := 0
		for input in region_inputs[region_start:region_end] {
			for path in input.paths {
				destination.paths[path_write] = {
					offset = u64(point_write)+path.offset,
					count = path.count,
				}
				path_write += 1
			}
			copy(
				destination.points[
					point_write:point_write+len(input.points)
				],
				input.points,
			)
			point_write += len(input.points)
		}
		if path_write != len(destination.paths) ||
		   point_write != len(destination.points) {
			return .Arithmetic
		}
	}
	return .None
}

bridge_evidence_area_2 :: proc(
	set: polygon.Polygon_Set,
) -> (i128, bool) {
	area_2: i128
	for path in set.paths {
		if path.count < 3 ||
		   path.offset+path.count > u64(len(set.points)) {
			return 0, false
		}
		start := int(path.offset)
		end := start+int(path.count)
		area_2 += polygon.polygon_path_area_2(set.points[start:end])
	}
	return area_2, area_2 > 0
}

bridge_evidence_config_valid :: proc(
	config: Bridge_Evidence_Config,
) -> bool {
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

bridge_evidence_perimeter_error :: proc(
	error: Perimeter_Error,
) -> Bridge_Evidence_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

bridge_evidence_result_destroy :: proc(
	result: ^Bridge_Evidence_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.masks, allocator)
	delete(result.paths, allocator)
	delete(result.points, allocator)
	result^ = {}
}
