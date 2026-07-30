package features

import "core:slice"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Role_Overlap_Source :: struct {
	stable_id:   contracts.Stable_ID,
	layer_id:    contracts.Stable_ID,
	layer_index: u32,
	role:        profiles.Printable_Role,
	geometry:    polygon.Polygon_Set,
}

Role_Overlap_Layer :: struct {
	mask_offset: u64,
	mask_count:  u32,
	path_offset: u64,
	path_count:  u32,
}

Role_Overlap_Mask :: struct {
	stable_id:        contracts.Stable_ID,
	source_id:        contracts.Stable_ID,
	source_index:     u32,
	layer_id:         contracts.Stable_ID,
	layer_index:      u32,
	role:             profiles.Printable_Role,
	priority:         u8,
	path_offset:      u64,
	path_count:       u32,
	point_offset:     u64,
	point_count:      u32,
	source_area_2:    i128,
	output_area_2:    i128,
	removed_area_2:   i128,
}

Role_Overlap_Path :: struct {
	stable_id:       contracts.Stable_ID,
	mask_id:         contracts.Stable_ID,
	mask_path_index: u32,
	point_offset:    u64,
	point_count:     u32,
	signed_area_2:   i128,
	winding:         geometry.Predicate_Sign,
}

Role_Overlap_Result :: struct {
	policy:                   profiles.Role_Overlap_Policy,
	fill_rule:                polygon.Polygon_Fill_Rule,
	layers:                   []Role_Overlap_Layer,
	masks:                    []Role_Overlap_Mask,
	paths:                    []Role_Overlap_Path,
	points:                   []polygon.Polygon_Point,
	fully_removed_mask_count: u64,
	source_area_2:            i128,
	output_area_2:            i128,
	removed_area_2:           i128,
}

Role_Overlap_Limits :: struct {
	max_masks:  u64,
	max_paths:  u64,
	max_points: u64,
	polygon:    polygon.Polygon_Limits,
}

DEFAULT_ROLE_OVERLAP_LIMITS :: Role_Overlap_Limits{
	max_masks = 400_000_000,
	max_paths = 800_000_000,
	max_points = 4_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Role_Overlap_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Same_Priority_Overlap,
	Mask_Limit,
	Path_Limit,
	Point_Limit,
	Provider,
	Allocation_Failed,
	Arithmetic,
}

Role_Overlap_Order :: struct {
	source_index: u32,
	layer_index:  u32,
	priority:     u8,
	stable_id:    contracts.Stable_ID,
}

role_overlap_resolve :: proc(
	layer_ids: []contracts.Stable_ID,
	sources: []Role_Overlap_Source,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	fill_rule: polygon.Polygon_Fill_Rule,
	limits := DEFAULT_ROLE_OVERLAP_LIMITS,
	allocator := context.allocator,
) -> (Role_Overlap_Result, Role_Overlap_Error) {
	if process.source.role_overlap != .Subtract_Higher_Priority ||
	   provider.boolean == nil ||
	   !role_overlap_fill_rule_valid(fill_rule) {
		return {}, .Invalid_Config
	}
	if u64(len(layer_ids)) > u64(max(u32)) ||
	   u64(len(sources)) > u64(max(u32)) {
		return {}, .Arithmetic
	}
	if u64(len(sources)) > limits.max_masks {
		return {}, .Mask_Limit
	}
	orders := make([]Role_Overlap_Order, len(sources), allocator)
	outputs := make([]polygon.Polygon_Set, len(sources), allocator)
	source_areas := make([]i128, len(sources), allocator)
	output_areas := make([]i128, len(sources), allocator)
	if len(sources) > 0 &&
	   (orders == nil || outputs == nil ||
	    source_areas == nil || output_areas == nil) {
		delete(orders, allocator)
		delete(outputs, allocator)
		delete(source_areas, allocator)
		delete(output_areas, allocator)
		return {}, .Allocation_Failed
	}
	defer {
		for &output in outputs {
			polygon.polygon_set_destroy(&output, allocator)
		}
		delete(orders, allocator)
		delete(outputs, allocator)
		delete(source_areas, allocator)
		delete(output_areas, allocator)
	}
	for source, source_index in sources {
		priority, priority_ok :=
			profiles.printable_role_priority(source.role)
		ordinal, ordinal_ok :=
			feature_role_overlap_ordinal(source.role)
		_, geometry_ok := polygon.polygon_set_hash(source.geometry)
		source_area, area_ok := role_overlap_area_2(source.geometry)
		if !priority_ok || !ordinal_ok ||
		   source.stable_id == contracts.INVALID_STABLE_ID ||
		   source.layer_id == contracts.INVALID_STABLE_ID ||
		   u64(source.layer_index) >= u64(len(layer_ids)) ||
		   source.layer_id != layer_ids[source.layer_index] ||
		   !geometry_ok || !area_ok {
			return {}, .Invalid_Input
		}
		orders[source_index] = {
			source_index = u32(source_index),
			layer_index = source.layer_index,
			priority = priority,
			stable_id = source.stable_id,
		}
		source_areas[source_index] = source_area
	}
	slice.sort_by(orders, role_overlap_order_less)
	for order, order_index in orders {
		if order_index > 0 {
			previous := orders[order_index-1]
			if order.layer_index == previous.layer_index &&
			   order.stable_id == previous.stable_id {
				return {}, .Invalid_Input
			}
		}
	}

	order_cursor := 0
	for _, layer_index in layer_ids {
		occupied: polygon.Polygon_Set
		defer polygon.polygon_set_destroy(&occupied, allocator)
		for order_cursor < len(orders) &&
		    orders[order_cursor].layer_index == u32(layer_index) {
			priority := orders[order_cursor].priority
			priority_start := order_cursor
			for order_cursor < len(orders) &&
			    orders[order_cursor].layer_index ==
				u32(layer_index) &&
			    orders[order_cursor].priority == priority {
				order_cursor += 1
			}
			priority_coverage: polygon.Polygon_Set
			for order in orders[priority_start:order_cursor] {
				source := sources[order.source_index]
				output: polygon.Polygon_Set
				if len(occupied.paths) == 0 {
					clone_ok: bool
					output, clone_ok = skin_polygon_clone(
						source.geometry,
						allocator,
					)
					if !clone_ok {
						polygon.polygon_set_destroy(
							&priority_coverage,
							allocator,
						)
						return {}, .Allocation_Failed
					}
				} else {
					provider_error: polygon.Polygon_Error
					output, provider_error = provider.boolean(
						source.geometry,
						occupied,
						.Difference,
						fill_rule,
						limits.polygon,
						allocator,
					)
					if provider_error != .None {
						polygon.polygon_set_destroy(
							&priority_coverage,
							allocator,
						)
						return {}, .Provider
					}
				}
				output_area: i128
				if len(output.paths) > 0 {
					output_area_ok: bool
					output_area, output_area_ok =
						role_overlap_area_2(output)
					if !output_area_ok ||
					   output_area >
						source_areas[order.source_index] {
						polygon.polygon_set_destroy(
							&output,
							allocator,
						)
						polygon.polygon_set_destroy(
							&priority_coverage,
							allocator,
						)
						return {}, .Arithmetic
					}
				}
				if len(priority_coverage.paths) > 0 &&
				   len(output.paths) > 0 {
					overlap, overlap_error := provider.boolean(
						priority_coverage,
						output,
						.Intersection,
						fill_rule,
						limits.polygon,
						allocator,
					)
					if overlap_error != .None {
						polygon.polygon_set_destroy(
							&output,
							allocator,
						)
						polygon.polygon_set_destroy(
							&priority_coverage,
							allocator,
						)
						return {}, .Provider
					}
					has_overlap := len(overlap.paths) > 0
					polygon.polygon_set_destroy(
						&overlap,
						allocator,
					)
					if has_overlap {
						polygon.polygon_set_destroy(
							&output,
							allocator,
						)
						polygon.polygon_set_destroy(
							&priority_coverage,
							allocator,
						)
						return {}, .Same_Priority_Overlap
					}
				}
				outputs[order.source_index] = output
				output_areas[order.source_index] = output_area
				contribution, clone_ok := skin_polygon_clone(
					output,
					allocator,
				)
				if !clone_ok {
					polygon.polygon_set_destroy(
						&priority_coverage,
						allocator,
					)
					return {}, .Allocation_Failed
				}
				accumulate_error := skin_polygon_accumulate(
					&priority_coverage,
					&contribution,
					provider,
					fill_rule,
					limits.polygon,
					allocator,
				)
				if accumulate_error != .None {
					polygon.polygon_set_destroy(
						&priority_coverage,
						allocator,
					)
					return {}, role_overlap_skin_error(
						accumulate_error,
					)
				}
			}
			accumulate_error := skin_polygon_accumulate(
				&occupied,
				&priority_coverage,
				provider,
				fill_rule,
				limits.polygon,
				allocator,
			)
			if accumulate_error != .None {
				polygon.polygon_set_destroy(
					&priority_coverage,
					allocator,
				)
				return {}, role_overlap_skin_error(
					accumulate_error,
				)
			}
		}
		polygon.polygon_set_destroy(&occupied, allocator)
	}
	if order_cursor != len(orders) {
		return {}, .Invalid_Input
	}

	total_paths: u64
	total_points: u64
	for output in outputs {
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
	if total_paths > u64(max(int)) ||
	   total_points > u64(max(int)) {
		return {}, .Arithmetic
	}
	result := Role_Overlap_Result{
		policy = process.source.role_overlap,
		fill_rule = fill_rule,
	}
	result.layers = make(
		[]Role_Overlap_Layer,
		len(layer_ids),
		allocator,
	)
	result.masks = make(
		[]Role_Overlap_Mask,
		len(sources),
		allocator,
	)
	result.paths = make(
		[]Role_Overlap_Path,
		int(total_paths),
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		int(total_points),
		allocator,
	)
	if len(layer_ids) > 0 && result.layers == nil ||
	   len(sources) > 0 && result.masks == nil ||
	   total_paths > 0 && result.paths == nil ||
	   total_points > 0 && result.points == nil {
		role_overlap_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	mask_write := 0
	path_write := 0
	point_write := 0
	order_cursor = 0
	for _, layer_index in layer_ids {
		layer_mask_start := mask_write
		layer_path_start := path_write
		for order_cursor < len(orders) &&
		    orders[order_cursor].layer_index == u32(layer_index) {
			order := orders[order_cursor]
			source := sources[order.source_index]
			output := outputs[order.source_index]
			ordinal, ordinal_ok :=
				feature_role_overlap_ordinal(source.role)
			if !ordinal_ok {
				role_overlap_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			mask_id := contracts.stable_id_child(
				source.stable_id,
				.Feature,
				ordinal,
			)
			mask_path_start := path_write
			mask_point_start := point_write
			for output_path, local_path_index in output.paths {
				if output_path.count > u64(max(u32)) {
					role_overlap_result_destroy(&result, allocator)
					return {}, .Arithmetic
				}
				start := int(output_path.offset)
				end := start+int(output_path.count)
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
					point_count = u32(output_path.count),
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
			mask_path_count := path_write-mask_path_start
			mask_point_count := point_write-mask_point_start
			if mask_path_count > int(max(u32)) ||
			   mask_point_count > int(max(u32)) {
				role_overlap_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			source_area := source_areas[order.source_index]
			output_area := output_areas[order.source_index]
			removed_area := source_area-output_area
			result.masks[mask_write] = {
				stable_id = mask_id,
				source_id = source.stable_id,
				source_index = order.source_index,
				layer_id = source.layer_id,
				layer_index = source.layer_index,
				role = source.role,
				priority = order.priority,
				path_offset = u64(mask_path_start),
				path_count = u32(mask_path_count),
				point_offset = u64(mask_point_start),
				point_count = u32(mask_point_count),
				source_area_2 = source_area,
				output_area_2 = output_area,
				removed_area_2 = removed_area,
			}
			if output_area == 0 {
				result.fully_removed_mask_count += 1
			}
			result.source_area_2 += source_area
			result.output_area_2 += output_area
			result.removed_area_2 += removed_area
			mask_write += 1
			order_cursor += 1
		}
		layer_mask_count := mask_write-layer_mask_start
		layer_path_count := path_write-layer_path_start
		if layer_mask_count > int(max(u32)) ||
		   layer_path_count > int(max(u32)) {
			role_overlap_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			mask_offset = u64(layer_mask_start),
			mask_count = u32(layer_mask_count),
			path_offset = u64(layer_path_start),
			path_count = u32(layer_path_count),
		}
	}
	if order_cursor != len(orders) ||
	   mask_write != len(result.masks) ||
	   path_write != len(result.paths) ||
	   point_write != len(result.points) {
		role_overlap_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

role_overlap_order_less :: proc(
	a, b: Role_Overlap_Order,
) -> bool {
	if a.layer_index != b.layer_index {
		return a.layer_index < b.layer_index
	}
	if a.priority != b.priority {return a.priority < b.priority}
	if a.stable_id != b.stable_id {return a.stable_id < b.stable_id}
	return a.source_index < b.source_index
}

role_overlap_area_2 :: proc(
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
		area_2 +=
			polygon.polygon_path_area_2(set.points[start:end])
	}
	return area_2, area_2 > 0
}

role_overlap_fill_rule_valid :: proc(
	fill_rule: polygon.Polygon_Fill_Rule,
) -> bool {
	return fill_rule == .Even_Odd ||
		fill_rule == .Non_Zero ||
		fill_rule == .Positive
}

role_overlap_skin_error :: proc(
	error: Skin_Error,
) -> Role_Overlap_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Provider
}

role_overlap_result_destroy :: proc(
	result: ^Role_Overlap_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.masks, allocator)
	delete(result.paths, allocator)
	delete(result.points, allocator)
	result^ = {}
}
