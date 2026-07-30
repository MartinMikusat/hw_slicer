package features

import "core:mem"
import "core:math"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

Gap_Evidence_Kind :: enum u8 {
	Invalid,
	Shell_Coverage,
	Uncovered_Region,
	Minimum_Line_Center_Domain,
	Maximum_One_Line_Center_Domain,
	Above_Two_Line_Core,
	Unprinted_Remainder,
}

Gap_Evidence_Config :: struct {
	fill_rule:          polygon.Polygon_Fill_Rule,
	minimum_line_width: contracts.Micrometres,
	maximum_line_width: contracts.Micrometres,
	join_type:          polygon.Polygon_Join_Type,
	miter_limit:        f64,
	arc_tolerance:      f64,
}

Gap_Evidence_Limits :: struct {
	max_masks:  u64,
	max_paths:  u64,
	max_points: u64,
	polygon:    polygon.Polygon_Limits,
}

DEFAULT_GAP_EVIDENCE_LIMITS :: Gap_Evidence_Limits{
	max_masks = 400_000_000,
	max_paths = 800_000_000,
	max_points = 4_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Gap_Evidence_Layer :: struct {
	mask_offset: u64,
	mask_count:  u32,
	path_offset: u64,
	path_count:  u32,
}

Gap_Evidence_Mask :: struct {
	stable_id:    contracts.Stable_ID,
	region_id:    contracts.Stable_ID,
	region_index: u32,
	layer_index:  u32,
	kind:         Gap_Evidence_Kind,
	path_offset:  u64,
	path_count:   u32,
	point_offset: u64,
	point_count:  u32,
}

Gap_Evidence_Path :: struct {
	stable_id:       contracts.Stable_ID,
	mask_id:         contracts.Stable_ID,
	mask_path_index: u32,
	point_offset:    u64,
	point_count:     u32,
	signed_area_2:   i128,
	winding:         geometry.Predicate_Sign,
}

Gap_Evidence_Result :: struct {
	config:                 Gap_Evidence_Config,
	shell_half_width:       contracts.Micrometres,
	minimum_center_radius:  contracts.Micrometres,
	maximum_one_radius:     contracts.Micrometres,
	maximum_two_radius:     contracts.Micrometres,
	layers:                 []Gap_Evidence_Layer,
	masks:                  []Gap_Evidence_Mask,
	paths:                  []Gap_Evidence_Path,
	points:                 []polygon.Polygon_Point,
}

Gap_Evidence_Error :: enum u8 {
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

gap_evidence_build :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	perimeters: Perimeter_Result,
	provider: polygon.Polygon_Provider,
	config: Gap_Evidence_Config,
	limits := DEFAULT_GAP_EVIDENCE_LIMITS,
	allocator := context.allocator,
) -> (Gap_Evidence_Result, Gap_Evidence_Error) {
	derived, config_ok := gap_evidence_derived_config(
		perimeters,
		config,
	)
	if !config_ok || provider.boolean == nil || provider.offset == nil {
		return {}, .Invalid_Config
	}
	if len(topology.layers) != len(regions.layers) ||
	   len(perimeters.layers) != len(regions.layers) {
		return {}, .Invalid_Input
	}
	region_hash, region_ok := slicing.region_result_hash(
		{},
		topology,
		regions,
	)
	if !region_ok {return {}, .Invalid_Input}
	_, perimeter_ok := perimeter_result_hash(region_hash, perimeters)
	if !perimeter_ok {return {}, .Invalid_Input}
	if len(regions.regions) > max(int)/6 {
		return {}, .Arithmetic
	}

	outputs := make(
		[]polygon.Polygon_Set,
		len(regions.regions)*6,
		allocator,
	)
	if len(regions.regions) > 0 && outputs == nil {
		return {}, .Allocation_Failed
	}
	defer {
		for &output in outputs {
			polygon.polygon_set_destroy(&output, allocator)
		}
		delete(outputs, allocator)
	}

	for region, region_index in regions.regions {
		region_input, input_error := perimeter_region_input(
			topology,
			regions,
			u32(region_index),
			allocator,
		)
		if input_error != .None {
			return {}, gap_evidence_perimeter_error(input_error)
		}
		coverage: polygon.Polygon_Set
		group_start := int(region_index)*int(perimeters.config.count)
		group_end := group_start+int(perimeters.config.count)
		for group_index in group_start..<group_end {
			group := perimeters.groups[group_index]
			if group.region_index != u32(region_index) ||
			   group.region_id != region.stable_id {
				polygon.polygon_set_destroy(&region_input, allocator)
				polygon.polygon_set_destroy(&coverage, allocator)
				return {}, .Invalid_Input
			}
			if group.path_count == 0 {continue}
			centerlines, centerline_error := gap_perimeter_group_input(
				perimeters,
				u32(group_index),
				allocator,
			)
			if centerline_error != .None {
				polygon.polygon_set_destroy(&region_input, allocator)
				polygon.polygon_set_destroy(&coverage, allocator)
				return {}, centerline_error
			}
			outer, outer_error := provider.offset(
				centerlines,
				derived.shell_half_width,
				config.join_type,
				config.miter_limit,
				config.arc_tolerance,
				limits.polygon,
				allocator,
			)
			inner, inner_error := provider.offset(
				centerlines,
				contracts.Micrometres(
					-i64(derived.shell_half_width),
				),
				config.join_type,
				config.miter_limit,
				config.arc_tolerance,
				limits.polygon,
				allocator,
			)
			polygon.polygon_set_destroy(&centerlines, allocator)
			if outer_error != .None || inner_error != .None {
				polygon.polygon_set_destroy(&outer, allocator)
				polygon.polygon_set_destroy(&inner, allocator)
				polygon.polygon_set_destroy(&region_input, allocator)
				polygon.polygon_set_destroy(&coverage, allocator)
				return {}, .Provider
			}
			band, band_error := provider.boolean(
				outer,
				inner,
				.Difference,
				config.fill_rule,
				limits.polygon,
				allocator,
			)
			polygon.polygon_set_destroy(&outer, allocator)
			polygon.polygon_set_destroy(&inner, allocator)
			if band_error != .None {
				polygon.polygon_set_destroy(&band, allocator)
				polygon.polygon_set_destroy(&region_input, allocator)
				polygon.polygon_set_destroy(&coverage, allocator)
				return {}, .Provider
			}
			clipped, clip_error := provider.boolean(
				band,
				region_input,
				.Intersection,
				config.fill_rule,
				limits.polygon,
				allocator,
			)
			polygon.polygon_set_destroy(&band, allocator)
			if clip_error != .None {
				polygon.polygon_set_destroy(&clipped, allocator)
				polygon.polygon_set_destroy(&region_input, allocator)
				polygon.polygon_set_destroy(&coverage, allocator)
				return {}, .Provider
			}
			accumulate_error := skin_polygon_accumulate(
				&coverage,
				&clipped,
				provider,
				config.fill_rule,
				limits.polygon,
				allocator,
			)
			if accumulate_error != .None {
				polygon.polygon_set_destroy(&region_input, allocator)
				polygon.polygon_set_destroy(&coverage, allocator)
				if accumulate_error == .Allocation_Failed {
					return {}, .Allocation_Failed
				}
				return {}, .Provider
			}
		}

		residual: polygon.Polygon_Set
		if len(coverage.paths) > 0 {
			residual_error: polygon.Polygon_Error
			residual, residual_error = provider.boolean(
				region_input,
				coverage,
				.Difference,
				config.fill_rule,
				limits.polygon,
				allocator,
			)
			if residual_error != .None {
				polygon.polygon_set_destroy(&region_input, allocator)
				polygon.polygon_set_destroy(&coverage, allocator)
				return {}, .Provider
			}
		} else {
			clone_ok: bool
			residual, clone_ok = skin_polygon_clone(
				region_input,
				allocator,
			)
			if !clone_ok {
				polygon.polygon_set_destroy(&region_input, allocator)
				return {}, .Allocation_Failed
			}
		}
		polygon.polygon_set_destroy(&region_input, allocator)

		minimum_centers, minimum_error := gap_evidence_inset(
			residual,
			derived.minimum_center_radius,
			provider,
			config,
			limits,
			allocator,
		)
		maximum_one_centers, maximum_one_error := gap_evidence_inset(
			residual,
			derived.maximum_one_radius,
			provider,
			config,
			limits,
			allocator,
		)
		above_two_core, maximum_two_error := gap_evidence_inset(
			residual,
			derived.maximum_two_radius,
			provider,
			config,
			limits,
			allocator,
		)
		if minimum_error != .None ||
		   maximum_one_error != .None ||
		   maximum_two_error != .None {
			polygon.polygon_set_destroy(&coverage, allocator)
			polygon.polygon_set_destroy(&residual, allocator)
			polygon.polygon_set_destroy(&minimum_centers, allocator)
			polygon.polygon_set_destroy(&maximum_one_centers, allocator)
			polygon.polygon_set_destroy(&above_two_core, allocator)
			return {}, .Provider
		}

		printable_opening: polygon.Polygon_Set
		if len(minimum_centers.paths) > 0 {
			expanded, expand_error := provider.offset(
				minimum_centers,
				derived.minimum_center_radius,
				config.join_type,
				config.miter_limit,
				config.arc_tolerance,
				limits.polygon,
				allocator,
			)
			if expand_error == .None {
				intersection_error: polygon.Polygon_Error
				printable_opening, intersection_error =
					provider.boolean(
						expanded,
						residual,
						.Intersection,
						config.fill_rule,
						limits.polygon,
						allocator,
					)
				if intersection_error != .None {
					expand_error = intersection_error
				}
			}
			polygon.polygon_set_destroy(&expanded, allocator)
			if expand_error != .None {
				polygon.polygon_set_destroy(&coverage, allocator)
				polygon.polygon_set_destroy(&residual, allocator)
				polygon.polygon_set_destroy(
					&minimum_centers,
					allocator,
				)
				polygon.polygon_set_destroy(
					&maximum_one_centers,
					allocator,
				)
				polygon.polygon_set_destroy(
					&above_two_core,
					allocator,
				)
				polygon.polygon_set_destroy(
					&printable_opening,
					allocator,
				)
				return {}, .Provider
			}
		}
		unprinted: polygon.Polygon_Set
		if len(printable_opening.paths) > 0 {
			unprinted_error: polygon.Polygon_Error
			unprinted, unprinted_error = provider.boolean(
				residual,
				printable_opening,
				.Difference,
				config.fill_rule,
				limits.polygon,
				allocator,
			)
			if unprinted_error != .None {
				polygon.polygon_set_destroy(&coverage, allocator)
				polygon.polygon_set_destroy(&residual, allocator)
				polygon.polygon_set_destroy(
					&minimum_centers,
					allocator,
				)
				polygon.polygon_set_destroy(
					&maximum_one_centers,
					allocator,
				)
				polygon.polygon_set_destroy(
					&above_two_core,
					allocator,
				)
				polygon.polygon_set_destroy(
					&printable_opening,
					allocator,
				)
				return {}, .Provider
			}
		} else {
			clone_ok: bool
			unprinted, clone_ok = skin_polygon_clone(residual, allocator)
			if !clone_ok {
				polygon.polygon_set_destroy(&coverage, allocator)
				polygon.polygon_set_destroy(&residual, allocator)
				polygon.polygon_set_destroy(
					&minimum_centers,
					allocator,
				)
				polygon.polygon_set_destroy(
					&maximum_one_centers,
					allocator,
				)
				polygon.polygon_set_destroy(
					&above_two_core,
					allocator,
				)
				return {}, .Allocation_Failed
			}
		}
		polygon.polygon_set_destroy(&printable_opening, allocator)

		output_offset := region_index*6
		outputs[output_offset] = coverage
		outputs[output_offset+1] = residual
		outputs[output_offset+2] = minimum_centers
		outputs[output_offset+3] = maximum_one_centers
		outputs[output_offset+4] = above_two_core
		outputs[output_offset+5] = unprinted
	}

	total_masks: u64
	total_paths: u64
	total_points: u64
	for output in outputs {
		if len(output.paths) == 0 {continue}
		total_masks += 1
		if total_masks > limits.max_masks {
			return {}, .Mask_Limit
		}
		if total_paths > limits.max_paths ||
		   u64(len(output.paths)) > limits.max_paths-total_paths {
			return {}, .Path_Limit
		}
		if total_points > limits.max_points ||
		   u64(len(output.points)) > limits.max_points-total_points {
			return {}, .Point_Limit
		}
		total_paths += u64(len(output.paths))
		total_points += u64(len(output.points))
	}
	if total_masks > u64(max(int)) ||
	   total_paths > u64(max(int)) ||
	   total_points > u64(max(int)) {
		return {}, .Arithmetic
	}

	result := Gap_Evidence_Result{
		config = config,
		shell_half_width = derived.shell_half_width,
		minimum_center_radius = derived.minimum_center_radius,
		maximum_one_radius = derived.maximum_one_radius,
		maximum_two_radius = derived.maximum_two_radius,
	}
	result.layers = make(
		[]Gap_Evidence_Layer,
		len(regions.layers),
		allocator,
	)
	result.masks = make(
		[]Gap_Evidence_Mask,
		int(total_masks),
		allocator,
	)
	result.paths = make(
		[]Gap_Evidence_Path,
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
		gap_evidence_result_destroy(&result, allocator)
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
			for kind_index in 0..<6 {
				output := outputs[region_index*6+kind_index]
				if len(output.paths) == 0 {continue}
				kind := Gap_Evidence_Kind(kind_index+1)
				ordinal, ordinal_ok := feature_gap_evidence_ordinal(
					kind,
				)
				if !ordinal_ok {
					gap_evidence_result_destroy(&result, allocator)
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
						gap_evidence_result_destroy(
							&result,
							allocator,
						)
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
					path_write += 1
					point_write += len(points)
				}
				result.masks[mask_write] = {
					stable_id = mask_id,
					region_id = region.stable_id,
					region_index = u32(region_index),
					layer_index = u32(layer_index),
					kind = kind,
					path_offset = u64(mask_path_start),
					path_count = u32(path_write-mask_path_start),
					point_offset = u64(mask_point_start),
					point_count = u32(point_write-mask_point_start),
				}
				mask_write += 1
			}
		}
		result.layers[layer_index] = {
			mask_offset = u64(layer_mask_start),
			mask_count = u32(mask_write-layer_mask_start),
			path_offset = u64(layer_path_start),
			path_count = u32(path_write-layer_path_start),
		}
	}
	if mask_write != len(result.masks) ||
	   path_write != len(result.paths) ||
	   point_write != len(result.points) {
		gap_evidence_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

Gap_Evidence_Derived_Config :: struct {
	shell_half_width:      contracts.Micrometres,
	minimum_center_radius: contracts.Micrometres,
	maximum_one_radius:    contracts.Micrometres,
	maximum_two_radius:    contracts.Micrometres,
}

gap_evidence_derived_config :: proc(
	perimeters: Perimeter_Result,
	config: Gap_Evidence_Config,
) -> (Gap_Evidence_Derived_Config, bool) {
	line_width := i64(perimeters.config.line_width)
	minimum := i64(config.minimum_line_width)
	maximum := i64(config.maximum_line_width)
	fill_valid := config.fill_rule == .Even_Odd ||
		config.fill_rule == .Non_Zero ||
		config.fill_rule == .Positive
	if !fill_valid || line_width <= 0 || line_width&1 != 0 ||
	   minimum <= 0 || maximum < minimum ||
	   !perimeter_join_type_valid(config.join_type) ||
	   math.is_nan(config.miter_limit) ||
	   math.is_inf(config.miter_limit) ||
	   math.is_nan(config.arc_tolerance) ||
	   math.is_inf(config.arc_tolerance) ||
	   config.miter_limit < 1 || config.arc_tolerance < 0 {
		return {}, false
	}
	minimum_radius := (minimum+1)/2
	maximum_one_radius := (maximum+1)/2
	if maximum > geometry.MAX_PLANAR_COORDINATE_UM ||
	   maximum_one_radius > geometry.MAX_PLANAR_COORDINATE_UM {
		return {}, false
	}
	return {
		shell_half_width =
			contracts.Micrometres(line_width/2),
		minimum_center_radius =
			contracts.Micrometres(minimum_radius),
		maximum_one_radius =
			contracts.Micrometres(maximum_one_radius),
		maximum_two_radius = config.maximum_line_width,
	}, true
}

gap_evidence_inset :: proc(
	input: polygon.Polygon_Set,
	radius: contracts.Micrometres,
	provider: polygon.Polygon_Provider,
	config: Gap_Evidence_Config,
	limits: Gap_Evidence_Limits,
	allocator: mem.Allocator,
) -> (polygon.Polygon_Set, polygon.Polygon_Error) {
	if len(input.paths) == 0 {return {}, .None}
	return provider.offset(
		input,
		contracts.Micrometres(-i64(radius)),
		config.join_type,
		config.miter_limit,
		config.arc_tolerance,
		limits.polygon,
		allocator,
	)
}

gap_perimeter_group_input :: proc(
	perimeters: Perimeter_Result,
	group_index: u32,
	allocator: mem.Allocator,
) -> (polygon.Polygon_Set, Gap_Evidence_Error) {
	if u64(group_index) >= u64(len(perimeters.groups)) {
		return {}, .Invalid_Input
	}
	group := perimeters.groups[group_index]
	if group.path_count == 0 {return {}, .None}
	if group.path_offset+u64(group.path_count) >
	   	u64(len(perimeters.paths)) {
		return {}, .Invalid_Input
	}
	path_start := int(group.path_offset)
	path_end := path_start+int(group.path_count)
	point_count: u64
	for path in perimeters.paths[path_start:path_end] {
		if point_count > u64(max(int)) ||
		   u64(path.point_count) > u64(max(int))-point_count {
			return {}, .Arithmetic
		}
		point_count += u64(path.point_count)
	}
	result: polygon.Polygon_Set
	result.paths = make(
		[]polygon.Polygon_Path,
		int(group.path_count),
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		int(point_count),
		allocator,
	)
	if result.paths == nil || result.points == nil {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	point_write := 0
	for path, local_path_index in perimeters.paths[path_start:path_end] {
		if path.region_index != group.region_index ||
		   path.perimeter_index != group.perimeter_index ||
		   path.group_path_index != u32(local_path_index) ||
		   path.point_offset+u64(path.point_count) >
		   	u64(len(perimeters.points)) {
			polygon.polygon_set_destroy(&result, allocator)
			return {}, .Invalid_Input
		}
		result.paths[local_path_index] = {
			offset = u64(point_write),
			count = u64(path.point_count),
		}
		source_start := int(path.point_offset)
		source_end := source_start+int(path.point_count)
		copy(
			result.points[
				point_write:point_write+int(path.point_count)
			],
			perimeters.points[source_start:source_end],
		)
		point_write += int(path.point_count)
	}
	if point_write != len(result.points) {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

gap_evidence_perimeter_error :: proc(
	error: Perimeter_Error,
) -> Gap_Evidence_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

gap_evidence_result_destroy :: proc(
	result: ^Gap_Evidence_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.masks, allocator)
	delete(result.paths, allocator)
	delete(result.points, allocator)
	result^ = {}
}
