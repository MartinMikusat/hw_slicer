package features

import "core:mem"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"
import workers "../workers"

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
	record_sources := true,
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
	   !support_geometry_demand_valid(schedule, demand) ||
	   !slicing.fixed_layer_schedule_valid(schedule) ||
	   !slicing.region_result_valid(topology, regions) {
		return {}, .Invalid_Input
	}

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
	mask_targets := make([]int, len(demand.masks), allocator)
	defer delete(mask_targets, allocator)
	unresolved_demand_count: u64
	max_target_layer := -1
	for mask, mask_index in demand.masks {
		target_layer, target_ok := support_geometry_top_target(
			schedule,
			mask.layer_index,
			process.source.support_clearance_z,
		)
		if !target_ok {
			mask_targets[mask_index] = -1
			unresolved_demand_count += 1
			continue
		}
		mask_targets[mask_index] = int(target_layer)
		if int(target_layer) > max_target_layer {
			max_target_layer = int(target_layer)
		}
	}

	if max_target_layer >= 0 {
		active_layers := max_target_layer + 1

		canon_layer := make([]int, active_layers, allocator)
		unique_layers := make([dynamic]int, 0, active_layers, allocator)
		defer delete(canon_layer, allocator)
		defer delete(unique_layers)
		{
			cap_pow2 := 16
			for cap_pow2 < active_layers * 2 {cap_pow2 <<= 1}
			ht_mask := u64(cap_pow2 - 1)
			ht := make([]int, cap_pow2, allocator)
			defer delete(ht, allocator)
			for li in 0..<active_layers {
				ml := model_layers[li]
				if len(ml.paths) == 0 {
					canon_layer[li] = li
					continue
				}
				h := features_polygon_set_hash64(ml)
				slot := h & ht_mask
				found := -1
				for {
					entry := ht[slot]
					if entry == 0 {break}
					cand := entry - 1
					if features_polygon_sets_equal(model_layers[cand], ml) {
						found = cand
						break
					}
					slot = (slot + 1) & ht_mask
				}
				if found >= 0 {
					canon_layer[li] = found
				} else {
					ht[slot] = li + 1
					canon_layer[li] = li
					append(&unique_layers, li)
				}
			}
		}

		Clear_Par_Ctx :: struct {
			model_layers:     []polygon.Polygon_Set,
			unique_layers:    []int,
			model_clearances: []polygon.Polygon_Set,
			clearance_xy:     contracts.Micrometres,
			config:           Support_Demand_Config,
			provider:         polygon.Polygon_Provider,
			limits:           Support_Geometry_Limits,
			errors:           []Support_Geometry_Error,
			allocator:        mem.Allocator,
		}
		clear_errors := make([]Support_Geometry_Error, active_layers, allocator)
		defer delete(clear_errors, allocator)
		cctx := Clear_Par_Ctx{
			model_layers     = model_layers,
			unique_layers    = unique_layers[:],
			model_clearances = model_clearances,
			clearance_xy     = process.source.support_clearance_xy,
			config           = demand.config,
			provider         = provider,
			limits           = limits,
			errors           = clear_errors,
			allocator        = allocator,
		}
		parallel_for(len(unique_layers), &cctx, proc(c: ^Clear_Par_Ctx, ui: int) {
			li := c.unique_layers[ui]
			ml := c.model_layers[li]
			if len(ml.paths) == 0 {return}
			if c.clearance_xy == 0 {
				cloned, clone_ok := skin_polygon_clone(ml, c.allocator)
				if !clone_ok {c.errors[li] = .Allocation_Failed; return}
				c.model_clearances[li] = cloned
			} else {
				clearance, cerr := c.provider.offset(
					ml,
					c.clearance_xy,
					c.config.join_type,
					c.config.miter_limit,
					c.config.arc_tolerance,
					c.limits.polygon,
					c.allocator,
				)
				c.model_clearances[li] = clearance
				if cerr != .None {c.errors[li] = .Provider}
			}
		})
		for ui in unique_layers {
			if clear_errors[ui] != .None {return {}, clear_errors[ui]}
		}
		for li in 0..<active_layers {
			if canon_layer[li] != li && len(model_clearances[canon_layer[li]].paths) > 0 {
				cloned, ok := skin_polygon_clone(model_clearances[canon_layer[li]], allocator)
				if !ok {return {}, .Allocation_Failed}
				model_clearances[li] = cloned
			}
		}

		expanded_masks := make([]polygon.Polygon_Set, len(demand.masks), allocator)
		expand_errors := make([]Support_Geometry_Error, len(demand.masks), allocator)
		defer {
			for &em in expanded_masks {polygon.polygon_set_destroy(&em, allocator)}
			delete(expanded_masks, allocator)
			delete(expand_errors, allocator)
		}
		Expand_Par_Ctx :: struct {
			demand:         Support_Demand_Result,
			mask_targets:   []int,
			expansion:      contracts.Micrometres,
			provider:       polygon.Polygon_Provider,
			limits:         Support_Geometry_Limits,
			expanded_masks: []polygon.Polygon_Set,
			errors:         []Support_Geometry_Error,
			allocator:      mem.Allocator,
		}
		ectx := Expand_Par_Ctx{
			demand         = demand,
			mask_targets   = mask_targets,
			expansion      = process.source.support_expansion,
			provider       = provider,
			limits         = limits,
			expanded_masks = expanded_masks,
			errors         = expand_errors,
			allocator      = allocator,
		}
		parallel_for(len(demand.masks), &ectx, proc(c: ^Expand_Par_Ctx, mi: int) {
			if c.mask_targets[mi] < 0 {return}
			source, source_error := support_demand_mask_input(c.demand, u32(mi), workers.scratch_allocator())
			if source_error != .None {
				c.errors[mi] = support_geometry_demand_error(source_error)
				return
			}
			if c.expansion == 0 {
				cloned, ok := skin_polygon_clone(source, c.allocator)
				if !ok {c.errors[mi] = .Allocation_Failed; return}
				c.expanded_masks[mi] = cloned
			} else {
				exp, eerr := c.provider.offset(
					source,
					c.expansion,
					c.demand.config.join_type,
					c.demand.config.miter_limit,
					c.demand.config.arc_tolerance,
					c.limits.polygon,
					c.allocator,
				)
				if eerr != .None {
					polygon.polygon_set_destroy(&exp, c.allocator)
					c.errors[mi] = .Provider
					return
				}
				c.expanded_masks[mi] = exp
			}
		})
		for err in expand_errors {
			if err != .None {return {}, err}
		}

		masks_at_target := make([][dynamic]u32, active_layers, allocator)
		defer {
			for &m in masks_at_target {delete(m)}
			delete(masks_at_target, allocator)
		}
		for mi in 0..<len(demand.masks) {
			tl := mask_targets[mi]
			if tl >= 0 && len(expanded_masks[mi].paths) > 0 {
				append(&masks_at_target[tl], u32(mi))
				if record_sources {
					for target := tl; target >= 0; target -= 1 {
						append(&source_candidates[target], u32(mi))
					}
				}
			}
		}

		cum_demand := make([]polygon.Polygon_Set, active_layers, allocator)
		cum_owned := make([]bool, active_layers, allocator)
		defer {
			for &cd, ci in cum_demand {
				if cum_owned[ci] {polygon.polygon_set_destroy(&cd, allocator)}
			}
			delete(cum_demand, allocator)
			delete(cum_owned, allocator)
		}
		for li := max_target_layer; li >= 0; li -= 1 {
			above := cum_demand[li + 1] if li + 1 < active_layers else polygon.Polygon_Set{}
			if len(masks_at_target[li]) == 0 {
				cum_demand[li] = above
				continue
			}
			total_pts := len(above.points)
			total_p := len(above.paths)
			for mi in masks_at_target[li] {
				total_pts += len(expanded_masks[mi].points)
				total_p += len(expanded_masks[mi].paths)
			}
			batch_pts := make([]polygon.Polygon_Point, total_pts, context.temp_allocator)
			batch_paths := make([]polygon.Polygon_Path, total_p, context.temp_allocator)
			pw, path_w := 0, 0
			if len(above.paths) > 0 {
				copy(batch_pts[pw:pw+len(above.points)], above.points)
				for p in above.paths {
					batch_paths[path_w] = {offset = u64(pw) + p.offset, count = p.count}
					path_w += 1
				}
				pw += len(above.points)
			}
			for mi in masks_at_target[li] {
				em := expanded_masks[mi]
				copy(batch_pts[pw:pw+len(em.points)], em.points)
				for p in em.paths {
					batch_paths[path_w] = {offset = u64(pw) + p.offset, count = p.count}
					path_w += 1
				}
				pw += len(em.points)
			}
			unioned, uerr := provider.boolean(
				polygon.Polygon_Set{points = batch_pts, paths = batch_paths},
				{},
				.Union,
				.Non_Zero,
				limits.polygon,
				allocator,
			)
			if uerr != .None {
				polygon.polygon_set_destroy(&unioned, allocator)
				return {}, .Provider
			}
			cum_demand[li] = unioned
			cum_owned[li] = true
		}

		Sub_Par_Ctx :: struct {
			cum_demand:             []polygon.Polygon_Set,
			model_clearances:       []polygon.Polygon_Set,
			masks_at_target:        [][dynamic]u32,
			expanded_masks:         []polygon.Polygon_Set,
			interface_layers:       int,
			fill_rule:              polygon.Polygon_Fill_Rule,
			provider:               polygon.Polygon_Provider,
			limits:                 Support_Geometry_Limits,
			support_accumulators:   []polygon.Polygon_Set,
			interface_accumulators: []polygon.Polygon_Set,
			errors:                 []Support_Geometry_Error,
			allocator:              mem.Allocator,
		}
		sub_errors := make([]Support_Geometry_Error, active_layers, allocator)
		defer delete(sub_errors, allocator)
		sctx := Sub_Par_Ctx{
			cum_demand             = cum_demand,
			model_clearances       = model_clearances,
			masks_at_target        = masks_at_target,
			expanded_masks         = expanded_masks,
			interface_layers       = int(process.source.support_interface_layers),
			fill_rule              = demand.config.fill_rule,
			provider               = provider,
			limits                 = limits,
			support_accumulators   = support_accumulators,
			interface_accumulators = interface_accumulators,
			errors                 = sub_errors,
			allocator              = allocator,
		}
		parallel_for(active_layers, &sctx, proc(c: ^Sub_Par_Ctx, li: int) {
			cd := c.cum_demand[li]
			if len(cd.paths) == 0 {return}
			mc := c.model_clearances[li]
			if len(mc.paths) == 0 {
				cloned, ok := skin_polygon_clone(cd, c.allocator)
				if !ok {c.errors[li] = .Allocation_Failed; return}
				c.support_accumulators[li] = cloned
			} else {
				diff, derr := c.provider.boolean(cd, mc, .Difference, c.fill_rule, c.limits.polygon, c.allocator)
				if derr != .None {
					polygon.polygon_set_destroy(&diff, c.allocator)
					c.errors[li] = .Provider
					return
				}
				c.support_accumulators[li] = diff
			}
			if c.interface_layers > 0 && len(c.support_accumulators[li].paths) > 0 {
				hi_t := min(len(c.masks_at_target) - 1, li + c.interface_layers - 1)
				total_pts, total_p := 0, 0
				for tl in li..=hi_t {
					for mi in c.masks_at_target[tl] {
						total_pts += len(c.expanded_masks[mi].points)
						total_p += len(c.expanded_masks[mi].paths)
					}
				}
				if total_p > 0 {
					scratch := workers.scratch_allocator()
					bpts := make([]polygon.Polygon_Point, total_pts, scratch)
					bpaths := make([]polygon.Polygon_Path, total_p, scratch)
					pw, path_w := 0, 0
					for tl in li..=hi_t {
						for mi in c.masks_at_target[tl] {
							em := c.expanded_masks[mi]
							copy(bpts[pw:pw+len(em.points)], em.points)
							for p in em.paths {
								bpaths[path_w] = {offset = u64(pw) + p.offset, count = p.count}
								path_w += 1
							}
							pw += len(em.points)
						}
					}
					raw_if, uerr := c.provider.boolean(
						polygon.Polygon_Set{points = bpts, paths = bpaths},
						{},
						.Union,
						.Non_Zero,
						c.limits.polygon,
						scratch,
					)
					if uerr != .None {
						c.errors[li] = .Provider
						return
					}
					if len(raw_if.paths) > 0 {
						if len(mc.paths) == 0 {
							cloned, ok := skin_polygon_clone(raw_if, c.allocator)
							if !ok {c.errors[li] = .Allocation_Failed; return}
							c.interface_accumulators[li] = cloned
						} else {
							idiff, ierr := c.provider.boolean(raw_if, mc, .Difference, c.fill_rule, c.limits.polygon, c.allocator)
							if ierr != .None {
								polygon.polygon_set_destroy(&idiff, c.allocator)
								c.errors[li] = .Provider
								return
							}
							c.interface_accumulators[li] = idiff
						}
					}
				}
			}
		})
		for err in sub_errors {
			if err != .None {return {}, err}
		}
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

	Split_Par_Ctx :: struct {
		final_supports:         []polygon.Polygon_Set,
		interface_accumulators: []polygon.Polygon_Set,
		outputs:                []polygon.Polygon_Set,
		fill_rule:              polygon.Polygon_Fill_Rule,
		provider:               polygon.Polygon_Provider,
		limits:                 Support_Geometry_Limits,
		errors:                 []Support_Geometry_Error,
		allocator:              mem.Allocator,
	}
	split_errors := make([]Support_Geometry_Error, layer_count, allocator)
	defer delete(split_errors, allocator)
	spctx := Split_Par_Ctx{
		final_supports         = final_supports,
		interface_accumulators = interface_accumulators,
		outputs                = outputs,
		fill_rule              = demand.config.fill_rule,
		provider               = provider,
		limits                 = limits,
		errors                 = split_errors,
		allocator              = allocator,
	}
	parallel_for(layer_count, &spctx, proc(c: ^Split_Par_Ctx, layer_index: int) {
		support := c.final_supports[layer_index]
		if len(support.paths) == 0 {return}
		iface_acc := c.interface_accumulators[layer_index]
		if len(iface_acc.paths) == 0 {
			c.outputs[layer_index*2] = support
			c.final_supports[layer_index] = {}
			return
		}
		interface_output, interface_error := c.provider.boolean(
			support,
			iface_acc,
			.Intersection,
			c.fill_rule,
			c.limits.polygon,
			c.allocator,
		)
		if interface_error != .None {
			polygon.polygon_set_destroy(&interface_output, c.allocator)
			c.errors[layer_index] = .Provider
			return
		}
		if len(interface_output.paths) == 0 {
			polygon.polygon_set_destroy(&interface_output, c.allocator)
			c.outputs[layer_index*2] = support
			c.final_supports[layer_index] = {}
			return
		}
		regular_output, regular_error := c.provider.boolean(
			support,
			interface_output,
			.Difference,
			c.fill_rule,
			c.limits.polygon,
			c.allocator,
		)
		if regular_error != .None {
			polygon.polygon_set_destroy(&interface_output, c.allocator)
			polygon.polygon_set_destroy(&regular_output, c.allocator)
			c.errors[layer_index] = .Provider
			return
		}
		c.outputs[layer_index*2] = regular_output
		c.outputs[layer_index*2+1] = interface_output
	})
	for err in split_errors {
		if err != .None {return {}, err}
	}

	if record_sources {
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
					polygon.polygon_set_destroy(&contribution, allocator)
					return {}, contribution_error
				}
				if !contributes {
					polygon.polygon_set_destroy(&contribution, allocator)
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


support_geometry_mask_input :: proc(
	geometry: Support_Geometry_Result,
	mask_index: u32,
	allocator: mem.Allocator,
) -> (polygon.Polygon_Set, Support_Geometry_Error) {
	if u64(mask_index) >= u64(len(geometry.masks)) {
		return {}, .Invalid_Input
	}
	mask := geometry.masks[mask_index]
	if mask.path_offset+u64(mask.path_count) >
		u64(len(geometry.paths)) ||
	   mask.point_offset+u64(mask.point_count) >
		u64(len(geometry.points)) {
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
	for path, local_path_index in geometry.paths[path_start:path_end] {
		if path.mask_id != mask.stable_id ||
		   path.mask_path_index != u32(local_path_index) ||
		   path.point_offset+u64(path.point_count) >
			u64(len(geometry.points)) {
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
			geometry.points[start:end],
		)
		point_write += int(path.point_count)
	}
	if point_write != len(result.points) {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
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
