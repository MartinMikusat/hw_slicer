package features

import "core:mem"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

Support_Geometry_Kind :: enum u8 {
	Invalid,
	Regular,
	Interface,
}

Support_Geometry_Layer :: struct {
	mask_offset:             u64,
	mask_count:              u32,
	path_offset:             u64,
	path_count:              u32,
	source_reference_offset: u64,
	source_reference_count:  u32,
}

Support_Geometry_Mask :: struct {
	stable_id:               contracts.Stable_ID,
	layer_id:                contracts.Stable_ID,
	layer_index:             u32,
	kind:                    Support_Geometry_Kind,
	role:                    profiles.Printable_Role,
	path_offset:             u64,
	path_count:              u32,
	point_offset:            u64,
	point_count:             u32,
	source_reference_offset: u64,
	source_reference_count:  u32,
}

Support_Geometry_Path :: struct {
	stable_id:       contracts.Stable_ID,
	mask_id:         contracts.Stable_ID,
	mask_path_index: u32,
	point_offset:    u64,
	point_count:     u32,
	signed_area_2:   i128,
	winding:         geometry.Predicate_Sign,
}

Support_Geometry_Result :: struct {
	config:                  Support_Demand_Config,
	mode:                    profiles.Support_Mode,
	clearance_xy:            contracts.Micrometres,
	clearance_z:             contracts.Micrometres,
	expansion:               contracts.Micrometres,
	interface_layers:        u32,
	layers:                  []Support_Geometry_Layer,
	masks:                   []Support_Geometry_Mask,
	paths:                   []Support_Geometry_Path,
	points:                  []polygon.Polygon_Point,
	source_demand_references: []u32,
	regular_mask_count:      u64,
	interface_mask_count:    u64,
	unresolved_demand_count: u64,
}

Support_Geometry_Limits :: struct {
	max_masks:              u64,
	max_paths:              u64,
	max_points:             u64,
	max_source_references:  u64,
	polygon:                polygon.Polygon_Limits,
}

DEFAULT_SUPPORT_GEOMETRY_LIMITS :: Support_Geometry_Limits{
	max_masks = 200_000_000,
	max_paths = 400_000_000,
	max_points = 2_000_000_000,
	max_source_references = 2_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Support_Geometry_Error :: enum u8 {
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

support_geometry_build :: proc(
	schedule: slicing.Fixed_Layer_Schedule,
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	demand: Support_Demand_Result,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	limits := DEFAULT_SUPPORT_GEOMETRY_LIMITS,
	allocator := context.allocator,
) -> (Support_Geometry_Result, Support_Geometry_Error) {
	if !profiles.process_support_targets_valid(process.source) ||
	   process.source.support_mode == .Invalid ||
	   demand.policy != process.source.support_demand ||
	   demand.overhang_angle != process.source.support_overhang_angle ||
	   provider.boolean == nil || provider.offset == nil {
		return {}, .Invalid_Config
	}
	if len(schedule.layer_z) != len(schedule.layer_ids) ||
	   len(schedule.layer_z) != len(topology.layers) ||
	   len(schedule.layer_z) != len(regions.layers) ||
	   len(schedule.layer_z) != len(demand.layers) ||
	   !support_geometry_demand_valid(schedule, demand) {
		return {}, .Invalid_Input
	}
	_, schedule_ok := slicing.fixed_layer_schedule_hash(schedule)
	_, regions_ok := slicing.region_result_hash({}, topology, regions)
	if !schedule_ok || !regions_ok {return {}, .Invalid_Input}

	layer_count := len(schedule.layer_z)
	region_inputs := make(
		[]polygon.Polygon_Set,
		len(regions.regions),
		allocator,
	)
	model_layers := make(
		[]polygon.Polygon_Set,
		layer_count,
		allocator,
	)
	model_clearances := make(
		[]polygon.Polygon_Set,
		layer_count,
		allocator,
	)
	support_accumulators := make(
		[]polygon.Polygon_Set,
		layer_count,
		allocator,
	)
	interface_accumulators := make(
		[]polygon.Polygon_Set,
		layer_count,
		allocator,
	)
	final_supports := make(
		[]polygon.Polygon_Set,
		layer_count,
		allocator,
	)
	outputs := make(
		[]polygon.Polygon_Set,
		layer_count*2,
		allocator,
	)
	source_candidates := make(
		[][dynamic]u32,
		layer_count,
		allocator,
	)
	output_sources := make(
		[][dynamic]u32,
		layer_count*2,
		allocator,
	)
	if len(regions.regions) > 0 && region_inputs == nil ||
	   layer_count > 0 &&
		(model_layers == nil || model_clearances == nil ||
		 support_accumulators == nil ||
		 interface_accumulators == nil ||
		 final_supports == nil || outputs == nil ||
		 source_candidates == nil || output_sources == nil) {
		delete(region_inputs, allocator)
		delete(model_layers, allocator)
		delete(model_clearances, allocator)
		delete(support_accumulators, allocator)
		delete(interface_accumulators, allocator)
		delete(final_supports, allocator)
		delete(outputs, allocator)
		delete(source_candidates, allocator)
		delete(output_sources, allocator)
		return {}, .Allocation_Failed
	}
	for &sources in source_candidates {
		sources = make([dynamic]u32, allocator)
	}
	for &sources in output_sources {
		sources = make([dynamic]u32, allocator)
	}
	defer {
		for &input in region_inputs {
			polygon.polygon_set_destroy(&input, allocator)
		}
		for &set in model_layers {
			polygon.polygon_set_destroy(&set, allocator)
		}
		for &set in model_clearances {
			polygon.polygon_set_destroy(&set, allocator)
		}
		for &set in support_accumulators {
			polygon.polygon_set_destroy(&set, allocator)
		}
		for &set in interface_accumulators {
			polygon.polygon_set_destroy(&set, allocator)
		}
		for &set in final_supports {
			polygon.polygon_set_destroy(&set, allocator)
		}
		for &set in outputs {
			polygon.polygon_set_destroy(&set, allocator)
		}
		for &sources in source_candidates {
			delete(sources)
		}
		for &sources in output_sources {
			delete(sources)
		}
		delete(region_inputs, allocator)
		delete(model_layers, allocator)
		delete(model_clearances, allocator)
		delete(support_accumulators, allocator)
		delete(interface_accumulators, allocator)
		delete(final_supports, allocator)
		delete(outputs, allocator)
		delete(source_candidates, allocator)
		delete(output_sources, allocator)
	}

	for _, region_index in regions.regions {
		input, input_error := perimeter_region_input(
			topology,
			regions,
			u32(region_index),
			allocator,
		)
		if input_error != .None {
			return {}, support_geometry_perimeter_error(input_error)
		}
		region_inputs[region_index] = input
	}
	layer_error := bridge_evidence_join_layers(
		regions,
		region_inputs,
		model_layers,
		allocator,
	)
	if layer_error != .None {
		return {}, support_geometry_bridge_error(layer_error)
	}
	for layer_input, layer_index in model_layers {
		if len(layer_input.paths) == 0 {continue}
		if process.source.support_clearance_xy == 0 {
			cloned, clone_ok := skin_polygon_clone(layer_input, allocator)
			if !clone_ok {return {}, .Allocation_Failed}
			model_clearances[layer_index] = cloned
		} else {
			clearance, clearance_error := provider.offset(
				layer_input,
				process.source.support_clearance_xy,
				demand.config.join_type,
				demand.config.miter_limit,
				demand.config.arc_tolerance,
				limits.polygon,
				allocator,
			)
			model_clearances[layer_index] = clearance
			if clearance_error != .None {return {}, .Provider}
		}
	}

	unresolved_demand_count: u64
	for mask, mask_index in demand.masks {
		target_layer, target_ok := support_geometry_top_target(
			schedule,
			mask.layer_index,
			process.source.support_clearance_z,
		)
		if !target_ok {
			unresolved_demand_count += 1
			continue
		}
		source, source_error := support_demand_mask_input(
			demand,
			u32(mask_index),
			allocator,
		)
		if source_error != .None {
			return {}, support_geometry_demand_error(source_error)
		}
		expanded: polygon.Polygon_Set
		if process.source.support_expansion == 0 {
			cloned, clone_ok := skin_polygon_clone(source, allocator)
			polygon.polygon_set_destroy(&source, allocator)
			if !clone_ok {return {}, .Allocation_Failed}
			expanded = cloned
		} else {
			expansion_error: polygon.Polygon_Error
			expanded, expansion_error = provider.offset(
				source,
				process.source.support_expansion,
				demand.config.join_type,
				demand.config.miter_limit,
				demand.config.arc_tolerance,
				limits.polygon,
				allocator,
			)
			polygon.polygon_set_destroy(&source, allocator)
			if expansion_error != .None {
				polygon.polygon_set_destroy(&expanded, allocator)
				return {}, .Provider
			}
		}
		for target := int(target_layer); target >= 0; target -= 1 {
			contribution, contribution_error := provider.boolean(
				expanded,
				model_clearances[target],
				.Difference,
				demand.config.fill_rule,
				limits.polygon,
				allocator,
			)
			if contribution_error != .None {
				polygon.polygon_set_destroy(&contribution, allocator)
				polygon.polygon_set_destroy(&expanded, allocator)
				return {}, .Provider
			}
			if len(contribution.paths) == 0 {
				polygon.polygon_set_destroy(&contribution, allocator)
				continue
			}
			interface_copy: polygon.Polygon_Set
			interface_rank := int(target_layer)-target
			if interface_rank <
			   int(process.source.support_interface_layers) {
				cloned, clone_ok := skin_polygon_clone(
					contribution,
					allocator,
				)
				if !clone_ok {
					polygon.polygon_set_destroy(
						&contribution,
						allocator,
					)
					polygon.polygon_set_destroy(
						&expanded,
						allocator,
					)
					return {}, .Allocation_Failed
				}
				interface_copy = cloned
			}
			accumulate_error := skin_polygon_accumulate(
				&support_accumulators[target],
				&contribution,
				provider,
				demand.config.fill_rule,
				limits.polygon,
				allocator,
			)
			if accumulate_error != .None {
				polygon.polygon_set_destroy(&interface_copy, allocator)
				polygon.polygon_set_destroy(&expanded, allocator)
				return {}, support_geometry_skin_error(
					accumulate_error,
				)
			}
			if len(interface_copy.paths) > 0 {
				interface_error := skin_polygon_accumulate(
					&interface_accumulators[target],
					&interface_copy,
					provider,
					demand.config.fill_rule,
					limits.polygon,
					allocator,
				)
				if interface_error != .None {
					polygon.polygon_set_destroy(
						&expanded,
						allocator,
					)
					return {}, support_geometry_skin_error(
						interface_error,
					)
				}
			}
			support_geometry_append_unique(
				&source_candidates[target],
				u32(mask_index),
			)
		}
		polygon.polygon_set_destroy(&expanded, allocator)
	}

	if process.source.support_mode == .Everywhere {
		for &support, layer_index in final_supports {
			support = support_accumulators[layer_index]
			support_accumulators[layer_index] = {}
		}
	} else {
		if layer_count > 0 {
			final_supports[0] = support_accumulators[0]
			support_accumulators[0] = {}
		}
		for layer_index in 1..<layer_count {
			if len(final_supports[layer_index-1].paths) == 0 ||
			   len(support_accumulators[layer_index].paths) == 0 {
				continue
			}
			reachable: polygon.Polygon_Set
			if process.source.support_expansion == 0 {
				cloned, clone_ok := skin_polygon_clone(
					final_supports[layer_index-1],
					allocator,
				)
				if !clone_ok {return {}, .Allocation_Failed}
				reachable = cloned
			} else {
				reachable_error: polygon.Polygon_Error
				reachable, reachable_error = provider.offset(
					final_supports[layer_index-1],
					process.source.support_expansion,
					demand.config.join_type,
					demand.config.miter_limit,
					demand.config.arc_tolerance,
					limits.polygon,
					allocator,
				)
				if reachable_error != .None {
					polygon.polygon_set_destroy(
						&reachable,
						allocator,
					)
					return {}, .Provider
				}
			}
			filtered, filter_error := provider.boolean(
				support_accumulators[layer_index],
				reachable,
				.Intersection,
				demand.config.fill_rule,
				limits.polygon,
				allocator,
			)
			polygon.polygon_set_destroy(&reachable, allocator)
			if filter_error != .None {
				polygon.polygon_set_destroy(&filtered, allocator)
				return {}, .Provider
			}
			final_supports[layer_index] = filtered
		}
	}

	for support, layer_index in final_supports {
		if len(support.paths) == 0 {continue}
		interface_output, interface_error := provider.boolean(
			support,
			interface_accumulators[layer_index],
			.Intersection,
			demand.config.fill_rule,
			limits.polygon,
			allocator,
		)
		if interface_error != .None {
			polygon.polygon_set_destroy(&interface_output, allocator)
			return {}, .Provider
		}
		regular_output, regular_error := provider.boolean(
			support,
			interface_output,
			.Difference,
			demand.config.fill_rule,
			limits.polygon,
			allocator,
		)
		if regular_error != .None {
			polygon.polygon_set_destroy(&interface_output, allocator)
			polygon.polygon_set_destroy(&regular_output, allocator)
			return {}, .Provider
		}
		outputs[layer_index*2] = regular_output
		outputs[layer_index*2+1] = interface_output
	}

	for output, output_index in outputs {
		if len(output.paths) == 0 {continue}
		layer_index := output_index/2
		kind := Support_Geometry_Kind.Regular
		if output_index&1 != 0 {kind = .Interface}
		for mask_index in source_candidates[layer_index] {
			contribution, contributes, contribution_error :=
				support_geometry_source_contribution(
					schedule,
					demand,
					model_clearances,
					process,
					provider,
					limits,
					mask_index,
					u32(layer_index),
					kind,
					allocator,
				)
			if contribution_error != .None {
				polygon.polygon_set_destroy(
					&contribution,
					allocator,
				)
				return {}, contribution_error
			}
			if !contributes {
				polygon.polygon_set_destroy(
					&contribution,
					allocator,
				)
				continue
			}
			overlap, overlap_error := provider.boolean(
				output,
				contribution,
				.Intersection,
				demand.config.fill_rule,
				limits.polygon,
				allocator,
			)
			polygon.polygon_set_destroy(&contribution, allocator)
			if overlap_error != .None {
				polygon.polygon_set_destroy(&overlap, allocator)
				return {}, .Provider
			}
			if len(overlap.paths) > 0 {
				append(&output_sources[output_index], mask_index)
			}
			polygon.polygon_set_destroy(&overlap, allocator)
		}
	}

	total_masks: u64
	total_paths: u64
	total_points: u64
	total_source_references: u64
	for output, output_index in outputs {
		if len(output.paths) == 0 {continue}
		total_masks += 1
		if total_masks > limits.max_masks {return {}, .Mask_Limit}
		if total_paths > limits.max_paths ||
		   u64(len(output.paths)) > limits.max_paths-total_paths {
			return {}, .Path_Limit
		}
		if total_points > limits.max_points ||
		   u64(len(output.points)) > limits.max_points-total_points {
			return {}, .Point_Limit
		}
		if total_source_references > limits.max_source_references ||
		   u64(len(output_sources[output_index])) >
			limits.max_source_references-total_source_references {
			return {}, .Source_Reference_Limit
		}
		total_paths += u64(len(output.paths))
		total_points += u64(len(output.points))
		total_source_references +=
			u64(len(output_sources[output_index]))
	}
	if total_masks > u64(max(int)) ||
	   total_paths > u64(max(int)) ||
	   total_points > u64(max(int)) ||
	   total_source_references > u64(max(int)) {
		return {}, .Arithmetic
	}

	result := Support_Geometry_Result{
		config = demand.config,
		mode = process.source.support_mode,
		clearance_xy = process.source.support_clearance_xy,
		clearance_z = process.source.support_clearance_z,
		expansion = process.source.support_expansion,
		interface_layers = process.source.support_interface_layers,
		unresolved_demand_count = unresolved_demand_count,
	}
	result.layers = make(
		[]Support_Geometry_Layer,
		layer_count,
		allocator,
	)
	result.masks = make(
		[]Support_Geometry_Mask,
		int(total_masks),
		allocator,
	)
	result.paths = make(
		[]Support_Geometry_Path,
		int(total_paths),
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		int(total_points),
		allocator,
	)
	result.source_demand_references = make(
		[]u32,
		int(total_source_references),
		allocator,
	)
	if layer_count > 0 && result.layers == nil ||
	   total_masks > 0 && result.masks == nil ||
	   total_paths > 0 && result.paths == nil ||
	   total_points > 0 && result.points == nil ||
	   total_source_references > 0 &&
		result.source_demand_references == nil {
		support_geometry_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	mask_write := 0
	path_write := 0
	point_write := 0
	source_write := 0
	for layer_index in 0..<layer_count {
		layer_mask_start := mask_write
		layer_path_start := path_write
		layer_source_start := source_write
		for kind_index in 0..<2 {
			output := outputs[layer_index*2+kind_index]
			if len(output.paths) == 0 {continue}
			kind := Support_Geometry_Kind.Regular
			role := profiles.Printable_Role.Support
			if kind_index == 1 {
				kind = .Interface
				role = .Support_Interface
			}
			ordinal, ordinal_ok :=
				feature_support_geometry_ordinal(kind)
			if !ordinal_ok {
				support_geometry_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			layer_id := schedule.layer_ids[layer_index]
			mask_id := contracts.stable_id_child(
				layer_id,
				.Feature,
				ordinal,
			)
			mask_path_start := path_write
			mask_point_start := point_write
			mask_source_start := source_write
			for source_path, local_path_index in output.paths {
				if source_path.count > u64(max(u32)) {
					support_geometry_result_destroy(&result, allocator)
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
				result.source_demand_references[
					source_write:
					source_write+
						len(output_sources[layer_index*2+kind_index])
				],
				output_sources[layer_index*2+kind_index][:],
			)
			source_write +=
				len(output_sources[layer_index*2+kind_index])
			mask_path_count := path_write-mask_path_start
			mask_point_count := point_write-mask_point_start
			mask_source_count := source_write-mask_source_start
			result.masks[mask_write] = {
				stable_id = mask_id,
				layer_id = layer_id,
				layer_index = u32(layer_index),
				kind = kind,
				role = role,
				path_offset = u64(mask_path_start),
				path_count = u32(mask_path_count),
				point_offset = u64(mask_point_start),
				point_count = u32(mask_point_count),
				source_reference_offset = u64(mask_source_start),
				source_reference_count = u32(mask_source_count),
			}
			if kind == .Regular {
				result.regular_mask_count += 1
			} else {
				result.interface_mask_count += 1
			}
			mask_write += 1
		}
		result.layers[layer_index] = {
			mask_offset = u64(layer_mask_start),
			mask_count = u32(mask_write-layer_mask_start),
			path_offset = u64(layer_path_start),
			path_count = u32(path_write-layer_path_start),
			source_reference_offset = u64(layer_source_start),
			source_reference_count =
				u32(source_write-layer_source_start),
		}
	}
	if mask_write != len(result.masks) ||
	   path_write != len(result.paths) ||
	   point_write != len(result.points) ||
	   source_write != len(result.source_demand_references) {
		support_geometry_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

support_geometry_source_contribution :: proc(
	schedule: slicing.Fixed_Layer_Schedule,
	demand: Support_Demand_Result,
	model_clearances: []polygon.Polygon_Set,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	limits: Support_Geometry_Limits,
	mask_index, target_layer: u32,
	kind: Support_Geometry_Kind,
	allocator: mem.Allocator,
) -> (
	polygon.Polygon_Set,
	bool,
	Support_Geometry_Error,
) {
	if u64(mask_index) >= u64(len(demand.masks)) ||
	   u64(target_layer) >= u64(len(model_clearances)) {
		return {}, false, .Invalid_Input
	}
	mask := demand.masks[mask_index]
	top_target, target_ok := support_geometry_top_target(
		schedule,
		mask.layer_index,
		process.source.support_clearance_z,
	)
	if !target_ok || target_layer > top_target {
		return {}, false, .None
	}
	interface_rank := top_target-target_layer
	if kind == .Interface &&
	   interface_rank >= process.source.support_interface_layers {
		return {}, false, .None
	}
	source, source_error := support_demand_mask_input(
		demand,
		mask_index,
		allocator,
	)
	if source_error != .None {
		return {}, false, support_geometry_demand_error(source_error)
	}
	expanded: polygon.Polygon_Set
	if process.source.support_expansion == 0 {
		cloned, clone_ok := skin_polygon_clone(source, allocator)
		polygon.polygon_set_destroy(&source, allocator)
		if !clone_ok {return {}, false, .Allocation_Failed}
		expanded = cloned
	} else {
		expansion_error: polygon.Polygon_Error
		expanded, expansion_error = provider.offset(
			source,
			process.source.support_expansion,
			demand.config.join_type,
			demand.config.miter_limit,
			demand.config.arc_tolerance,
			limits.polygon,
			allocator,
		)
		polygon.polygon_set_destroy(&source, allocator)
		if expansion_error != .None {
			polygon.polygon_set_destroy(&expanded, allocator)
			return {}, false, .Provider
		}
	}
	contribution, contribution_error := provider.boolean(
		expanded,
		model_clearances[target_layer],
		.Difference,
		demand.config.fill_rule,
		limits.polygon,
		allocator,
	)
	polygon.polygon_set_destroy(&expanded, allocator)
	if contribution_error != .None {
		polygon.polygon_set_destroy(&contribution, allocator)
		return {}, false, .Provider
	}
	return contribution, len(contribution.paths) > 0, .None
}

support_geometry_top_target :: proc(
	schedule: slicing.Fixed_Layer_Schedule,
	source_layer: u32,
	clearance_z: contracts.Micrometres,
) -> (u32, bool) {
	if source_layer == 0 ||
	   u64(source_layer) >= u64(len(schedule.layer_z)) ||
	   i64(clearance_z) < 0 {
		return 0, false
	}
	source_z := schedule.layer_z[source_layer]
	for target := int(source_layer)-1; target >= 0; target -= 1 {
		delta := i128(i64(source_z))-
			i128(i64(schedule.layer_z[target]))
		if delta >= i128(i64(clearance_z)) {
			return u32(target), true
		}
	}
	return 0, false
}

support_geometry_append_unique :: proc(
	values: ^[dynamic]u32,
	value: u32,
) {
	for existing in values^ {
		if existing == value {return}
	}
	append(values, value)
}

support_geometry_demand_valid :: proc(
	schedule: slicing.Fixed_Layer_Schedule,
	demand: Support_Demand_Result,
) -> bool {
	expected_mask_offset: u64
	expected_path_offset: u64
	expected_source_offset: u64
	for layer, layer_index in demand.layers {
		if layer.mask_offset != expected_mask_offset ||
		   layer.path_offset != expected_path_offset ||
		   layer.source_reference_offset != expected_source_offset ||
		   layer.mask_offset+u64(layer.mask_count) >
			u64(len(demand.masks)) ||
		   layer.path_offset+u64(layer.path_count) >
			u64(len(demand.paths)) ||
		   layer.source_reference_offset+
			u64(layer.source_reference_count) >
			u64(len(demand.source_face_references)) {
			return false
		}
		if layer.mask_count > 1 {return false}
		if layer.mask_count == 1 {
			mask := demand.masks[layer.mask_offset]
			if mask.layer_index != u32(layer_index) ||
			   mask.layer_id != schedule.layer_ids[layer_index] ||
			   mask.path_offset != layer.path_offset ||
			   mask.path_count != layer.path_count ||
			   mask.source_reference_offset !=
				layer.source_reference_offset ||
			   mask.source_reference_count !=
				layer.source_reference_count {
				return false
			}
		}
		expected_mask_offset += u64(layer.mask_count)
		expected_path_offset += u64(layer.path_count)
		expected_source_offset += u64(layer.source_reference_count)
	}
	return expected_mask_offset == u64(len(demand.masks)) &&
		expected_path_offset == u64(len(demand.paths)) &&
		expected_source_offset ==
			u64(len(demand.source_face_references))
}

support_geometry_perimeter_error :: proc(
	error: Perimeter_Error,
) -> Support_Geometry_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

support_geometry_bridge_error :: proc(
	error: Bridge_Evidence_Error,
) -> Support_Geometry_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

support_geometry_demand_error :: proc(
	error: Support_Demand_Error,
) -> Support_Geometry_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

support_geometry_skin_error :: proc(
	error: Skin_Error,
) -> Support_Geometry_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Provider
}

support_geometry_result_destroy :: proc(
	result: ^Support_Geometry_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.masks, allocator)
	delete(result.paths, allocator)
	delete(result.points, allocator)
	delete(result.source_demand_references, allocator)
	result^ = {}
}
