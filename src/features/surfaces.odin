package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

Surface_Kind :: enum u8 {
	Invalid,
	Bottom_Exposed,
	Top_Exposed,
}

Surface_Config :: struct {
	fill_rule:       polygon.Polygon_Fill_Rule,
	topology_policy: Feature_Topology_Policy,
}

Surface_Limits :: struct {
	max_masks:  u64,
	max_paths:  u64,
	max_points: u64,
	polygon:    polygon.Polygon_Limits,
}

DEFAULT_SURFACE_LIMITS :: Surface_Limits{
	max_masks = 200_000_000,
	max_paths = 400_000_000,
	max_points = 2_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Surface_Layer :: struct {
	mask_offset: u64,
	mask_count:  u32,
	path_offset: u64,
	path_count:  u32,
}

Surface_Mask :: struct {
	stable_id:    contracts.Stable_ID,
	region_id:    contracts.Stable_ID,
	region_index: u32,
	layer_index:  u32,
	kind:         Surface_Kind,
	path_offset:  u64,
	path_count:   u32,
	point_offset: u64,
	point_count:  u32,
}

Surface_Path :: struct {
	stable_id:     contracts.Stable_ID,
	mask_id:       contracts.Stable_ID,
	mask_path_index: u32,
	point_offset:  u64,
	point_count:   u32,
	signed_area_2: i128,
	winding:       geometry.Predicate_Sign,
}

Surface_Result :: struct {
	config:            Surface_Config,
	layers:            []Surface_Layer,
	masks:             []Surface_Mask,
	paths:             []Surface_Path,
	points:            []polygon.Polygon_Point,
	bottom_mask_count: u64,
	top_mask_count:    u64,
}

Surface_Error :: enum u8 {
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

surfaces_classify :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	provider: polygon.Polygon_Provider,
	config: Surface_Config,
	limits := DEFAULT_SURFACE_LIMITS,
	allocator := context.allocator,
) -> (Surface_Result, Surface_Error) {
	if !surface_config_valid(config) || provider.boolean == nil {
		return {}, .Invalid_Config
	}
	if len(regions.layers) != len(topology.layers) {
		return {}, .Invalid_Input
	}
	_, regions_ok := slicing.region_result_hash(
		contracts.Content_Hash{},
		topology,
		regions,
	)
	if !regions_ok {return {}, .Invalid_Input}
	if config.topology_policy == .Strict_Printable &&
	   (topology.open_chain_count > 0 ||
	    topology.degenerate_loop_count > 0 ||
	    topology.non_manifold_vertex_count > 0) {
		return {}, .Invalid_Input
	}
	if u64(len(regions.layers)) > u64(max(u32)) ||
	   u64(len(regions.regions)) > u64(max(u32)) ||
	   len(regions.regions) > max(int)/2 {
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
	layer_path_counts := make([]u64, len(regions.layers), allocator)
	layer_point_counts := make([]u64, len(regions.layers), allocator)
	temporary_outputs := make(
		[]polygon.Polygon_Set,
		len(regions.regions)*2,
		allocator,
	)
	if len(regions.regions) > 0 &&
	   (region_inputs == nil || temporary_outputs == nil) ||
	   len(regions.layers) > 0 &&
	   (layer_inputs == nil || layer_path_counts == nil ||
	    layer_point_counts == nil) {
		delete(region_inputs, allocator)
		delete(layer_inputs, allocator)
		delete(layer_path_counts, allocator)
		delete(layer_point_counts, allocator)
		delete(temporary_outputs, allocator)
		return {}, .Allocation_Failed
	}
	defer {
		for &input in region_inputs {
			polygon.polygon_set_destroy(&input, allocator)
		}
		for &input in layer_inputs {
			polygon.polygon_set_destroy(&input, allocator)
		}
		for &output in temporary_outputs {
			polygon.polygon_set_destroy(&output, allocator)
		}
		delete(region_inputs, allocator)
		delete(layer_inputs, allocator)
		delete(layer_path_counts, allocator)
		delete(layer_point_counts, allocator)
		delete(temporary_outputs, allocator)
	}

	for region, region_index in regions.regions {
		input, input_error := perimeter_region_input(
			topology,
			regions,
			u32(region_index),
			allocator,
		)
		if input_error != .None {
			#partial switch input_error {
			case .Allocation_Failed:
				return {}, .Allocation_Failed
			case .Arithmetic:
				return {}, .Arithmetic
			}
			return {}, .Invalid_Input
		}
		region_inputs[region_index] = input
		if layer_path_counts[region.layer_index] >
		   max(u64)-u64(len(input.paths)) ||
		   layer_point_counts[region.layer_index] >
		   max(u64)-u64(len(input.points)) {
			return {}, .Arithmetic
		}
		layer_path_counts[region.layer_index] += u64(len(input.paths))
		layer_point_counts[region.layer_index] += u64(len(input.points))
	}
	for &input, layer_index in layer_inputs {
		path_count := layer_path_counts[layer_index]
		point_count := layer_point_counts[layer_index]
		if path_count > u64(max(int)) || point_count > u64(max(int)) {
			return {}, .Arithmetic
		}
		input.paths = make(
			[]polygon.Polygon_Path,
			int(path_count),
			allocator,
		)
		input.points = make(
			[]polygon.Polygon_Point,
			int(point_count),
			allocator,
		)
		if path_count > 0 && input.paths == nil ||
		   point_count > 0 && input.points == nil {
			return {}, .Allocation_Failed
		}
	}
	layer_path_writes := make([]int, len(regions.layers), allocator)
	layer_point_writes := make([]int, len(regions.layers), allocator)
	if len(regions.layers) > 0 &&
	   (layer_path_writes == nil || layer_point_writes == nil) {
		delete(layer_path_writes, allocator)
		delete(layer_point_writes, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(layer_path_writes, allocator)
	defer delete(layer_point_writes, allocator)
	for region, region_index in regions.regions {
		layer_index := int(region.layer_index)
		source := region_inputs[region_index]
		destination := &layer_inputs[layer_index]
		for path in source.paths {
			destination.paths[layer_path_writes[layer_index]] = {
				offset = u64(layer_point_writes[layer_index])+
					path.offset,
				count = path.count,
			}
			layer_path_writes[layer_index] += 1
		}
		copy(
			destination.points[
				layer_point_writes[layer_index]:
				layer_point_writes[layer_index]+len(source.points)
			],
			source.points,
		)
		layer_point_writes[layer_index] += len(source.points)
	}
	for layer_index in 0..<len(layer_inputs) {
		if layer_path_writes[layer_index] !=
		   	len(layer_inputs[layer_index].paths) ||
		   layer_point_writes[layer_index] !=
		   	len(layer_inputs[layer_index].points) {
			return {}, .Arithmetic
		}
	}

	total_masks: u64
	total_paths: u64
	total_points: u64
	for region, region_index in regions.regions {
		layer_index := int(region.layer_index)
		empty: polygon.Polygon_Set
		bottom_clip := empty
		if layer_index > 0 {
			bottom_clip = layer_inputs[layer_index-1]
		}
		top_clip := empty
		if layer_index+1 < len(layer_inputs) {
			top_clip = layer_inputs[layer_index+1]
		}
		bottom_index := region_index*2
		top_index := bottom_index+1
		bottom_matches := layer_index > 0 &&
			surface_region_matches_layer(
				region_inputs[region_index],
				regions.layers[layer_index-1],
				region_inputs,
			)
		if !bottom_matches {
			bottom_output, bottom_error := provider.boolean(
				region_inputs[region_index],
				bottom_clip,
				.Difference,
				config.fill_rule,
				limits.polygon,
				allocator,
			)
			temporary_outputs[bottom_index] = bottom_output
			if bottom_error != .None {return {}, .Provider}
		}
		top_matches := layer_index+1 < len(layer_inputs) &&
			surface_region_matches_layer(
				region_inputs[region_index],
				regions.layers[layer_index+1],
				region_inputs,
			)
		if !top_matches {
			top_output, top_error := provider.boolean(
				region_inputs[region_index],
				top_clip,
				.Difference,
				config.fill_rule,
				limits.polygon,
				allocator,
			)
			temporary_outputs[top_index] = top_output
			if top_error != .None {return {}, .Provider}
		}
		for output in temporary_outputs[bottom_index:top_index+1] {
			if len(output.paths) == 0 {continue}
			total_masks += 1
			if total_masks > limits.max_masks {
				return {}, .Mask_Limit
			}
			if total_paths > limits.max_paths ||
			   u64(len(output.paths)) >
			   	limits.max_paths-total_paths {
				return {}, .Path_Limit
			}
			if total_points > limits.max_points ||
			   u64(len(output.points)) >
			   	limits.max_points-total_points {
				return {}, .Point_Limit
			}
			total_paths += u64(len(output.paths))
			total_points += u64(len(output.points))
		}
	}
	if total_masks > u64(max(int)) ||
	   total_paths > u64(max(int)) ||
	   total_points > u64(max(int)) {
		return {}, .Arithmetic
	}

	result := Surface_Result{config = config}
	result.layers = make(
		[]Surface_Layer,
		len(regions.layers),
		allocator,
	)
	result.masks = make([]Surface_Mask, int(total_masks), allocator)
	result.paths = make([]Surface_Path, int(total_paths), allocator)
	result.points = make(
		[]polygon.Polygon_Point,
		int(total_points),
		allocator,
	)
	if len(result.layers) > 0 && result.layers == nil ||
	   total_masks > 0 && result.masks == nil ||
	   total_paths > 0 && result.paths == nil ||
	   total_points > 0 && result.points == nil {
		surface_result_destroy(&result, allocator)
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
			region := regions.regions[region_index]
			for kind_index in 0..<2 {
				output := temporary_outputs[region_index*2+kind_index]
				if len(output.paths) == 0 {continue}
				kind := Surface_Kind.Bottom_Exposed
				if kind_index == 1 {kind = .Top_Exposed}
				ordinal, ordinal_ok :=
					feature_surface_ordinal(kind)
				if !ordinal_ok {
					surface_result_destroy(&result, allocator)
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
						surface_result_destroy(&result, allocator)
						return {}, .Arithmetic
					}
					start := int(source_path.offset)
					end := start+int(source_path.count)
					points := output.points[start:end]
					area := polygon.polygon_path_area_2(points)
					winding := geometry.Predicate_Sign.Positive
					if area < 0 {winding = .Negative}
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
						signed_area_2 = area,
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
					surface_result_destroy(&result, allocator)
					return {}, .Arithmetic
				}
				result.masks[mask_write] = {
					stable_id = mask_id,
					region_id = region.stable_id,
					region_index = u32(region_index),
					layer_index = u32(layer_index),
					kind = kind,
					path_offset = u64(mask_path_start),
					path_count = u32(mask_path_count),
					point_offset = u64(mask_point_start),
					point_count = u32(mask_point_count),
				}
				if kind == .Bottom_Exposed {
					result.bottom_mask_count += 1
				} else {
					result.top_mask_count += 1
				}
				mask_write += 1
			}
		}
		layer_mask_count := mask_write-layer_mask_start
		layer_path_count := path_write-layer_path_start
		if layer_mask_count > int(max(u32)) ||
		   layer_path_count > int(max(u32)) {
			surface_result_destroy(&result, allocator)
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
		surface_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

surface_region_matches_layer :: proc(
	subject: polygon.Polygon_Set,
	layer: slicing.Region_Layer,
	region_inputs: []polygon.Polygon_Set,
) -> bool {
	start := int(layer.region_offset)
	end := start+int(layer.region_count)
	for candidate in region_inputs[start:end] {
		if len(subject.paths) != len(candidate.paths) ||
		   len(subject.points) != len(candidate.points) {
			continue
		}
		matches := true
		for path, path_index in subject.paths {
			if path != candidate.paths[path_index] {
				matches = false
				break
			}
		}
		if !matches {continue}
		for point, point_index in subject.points {
			if point != candidate.points[point_index] {
				matches = false
				break
			}
		}
		if matches {return true}
	}
	return false
}

surface_config_valid :: proc(config: Surface_Config) -> bool {
	fill_valid := config.fill_rule == .Even_Odd ||
		config.fill_rule == .Non_Zero ||
		config.fill_rule == .Positive
	policy_valid := config.topology_policy == .Strict_Printable ||
		config.topology_policy == .Diagnostic_Closed_Regions
	return fill_valid && policy_valid
}

surface_result_destroy :: proc(
	result: ^Surface_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.masks, allocator)
	delete(result.paths, allocator)
	delete(result.points, allocator)
	result^ = {}
}
