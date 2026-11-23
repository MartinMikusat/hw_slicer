package features

import "core:sync"
import "core:thread"

import contracts "../contracts"
import geometry "../geometry"
import gpu "../gpu"
import polygon "../polygon"
import profiles "../profiles"

Motion_Operation_Kind :: enum u8 {
	Invalid,
	Retract,
	Travel,
	Recover,
	Extrude,
	Dwell,
}

Motion_Layer :: struct {
	stable_id:            contracts.Stable_ID,
	layer_index:          u32,
	z:                    contracts.Micrometres,
	operation_offset:     u64,
	operation_count:      u32,
	speed_scale_ppm:      u32,
	base_duration_us:     u64,
	motion_duration_us:   u64,
	dwell_duration_us:    u64,
	planned_duration_us:  u64,
}

Motion_Arc_Kind :: enum u8 {
	None,
	CW,  // G2
	CCW, // G3
}

Motion_Operation :: struct {
	stable_id:             contracts.Stable_ID,
	source_move_id:        contracts.Stable_ID,
	source_move_index:     u32,
	path_id:               contracts.Stable_ID,
	layer_index:           u32,
	kind:                  Motion_Operation_Kind,
	arc:                   Motion_Arc_Kind,
	role:                  profiles.Printable_Role,
	point_a:               polygon.Polygon_Point,
	point_b:               polygon.Polygon_Point,
	arc_center:            polygon.Polygon_Point,
	z_hop_um:              contracts.Micrometres,
	z_offset_um:           contracts.Micrometres, // non-zero for scarf seams / spiral vase Z interpolation
	speed:                 profiles.Speed_Um_Per_Second,
	acceleration:          profiles.Acceleration_Um_Per_Second_Squared,
	fan_ratio:             profiles.Ratio_Ppm,
	filament_delta_nm:     i128,
	duration_us:           u64,
	crosses_exterior:      bool,
}

Motion_Plan_Options :: struct {
	wipe_distance_um:          contracts.Micrometres,
	overhang_slowdown_enabled: bool,
	overhang_speed_percent:    u32,
	use_gpu:                   bool,
	worker_threads:            int, // <= 1 = single-core; > 1 = multi-core CPU overhang detection
}

Motion_Plan_Result :: struct {
	layers:                    []Motion_Layer,
	operations:                []Motion_Operation,
	retraction_count:          u64,
	travel_count:              u64,
	extrusion_count:           u64,
	dwell_count:               u64,
	total_motion_duration_us:  u64,
	total_dwell_duration_us:   u64,
	total_planned_duration_us: u64,
}

Motion_Plan_Limits :: struct {
	max_operations: u64,
}

DEFAULT_MOTION_PLAN_LIMITS :: Motion_Plan_Limits{
	max_operations = 8_000_000_000,
}

Motion_Plan_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Invalid_Layer,
	Invalid_Model,
	Machine_Bounds,
	Extrusion_Mismatch,
	Operation_Limit,
	Allocation_Failed,
	Arithmetic,
}

Motion_Source_Move :: struct {
	length_nm:          u64,
	base_speed:         profiles.Speed_Um_Per_Second,
	acceleration:       profiles.Acceleration_Um_Per_Second_Squared,
	fan_ratio:          profiles.Ratio_Ppm,
	extrusion_index:    u32,
	is_extrusion:       bool,
	retract_before:     bool,
	crosses_exterior:   bool,
	has_wipe:           bool,
	wipe_point:         polygon.Polygon_Point,
	wipe_length_nm:     u64,
	travel_length_nm:   u64,
	z_hop_um:           contracts.Micrometres,
}

motion_plan_build :: proc(
	layer_ids: []contracts.Stable_ID,
	layer_z: []contracts.Micrometres,
	model_layers: []polygon.Polygon_Set,
	plan: Unified_Path_Plan_Result,
	extrusion: Extrusion_Result,
	profile: profiles.Resolved_Profiles,
	limits := DEFAULT_MOTION_PLAN_LIMITS,
	allocator := context.allocator,
	options := Motion_Plan_Options{},
) -> (Motion_Plan_Result, Motion_Plan_Error) {
	process := profile.process.source
	selected_policies :=
		process.minimum_layer_time_policy == .Slowdown_Then_Dwell &&
		process.retraction == .Distance_And_Exterior_Crossing &&
		process.travel_policy == .Direct
	if !selected_policies {
		return {}, .Invalid_Config
	}
	if len(layer_ids) != len(plan.layers) ||
	   len(layer_z) != len(plan.layers) ||
	   len(model_layers) != len(plan.layers) ||
	   len(extrusion.layers) != len(plan.layers) ||
	   !extrusion_plan_valid(plan) {
		return {}, .Invalid_Input
	}
	if u64(len(plan.moves)) > u64(max(u32)) {
		return {}, .Arithmetic
	}
	sources := make([]Motion_Source_Move, len(plan.moves), allocator)
	layer_scales := make([]u32, len(plan.layers), allocator)
	layer_base_durations := make([]u64, len(plan.layers), allocator)
	layer_motion_durations := make([]u64, len(plan.layers), allocator)
	layer_dwells := make([]u64, len(plan.layers), allocator)
	layer_allocation_ok :=
		len(plan.layers) == 0 ||
		layer_scales != nil &&
		layer_base_durations != nil &&
		layer_motion_durations != nil &&
		layer_dwells != nil
	if len(plan.moves) > 0 && sources == nil || !layer_allocation_ok {
		delete(sources, allocator)
		delete(layer_scales, allocator)
		delete(layer_base_durations, allocator)
		delete(layer_motion_durations, allocator)
		delete(layer_dwells, allocator)
		return {}, .Allocation_Failed
	}
	defer {
		delete(sources, allocator)
		delete(layer_scales, allocator)
		delete(layer_base_durations, allocator)
		delete(layer_motion_durations, allocator)
		delete(layer_dwells, allocator)
	}

	// Precompute per-move overhang and travel-exterior-crossing flags via Metal GPU or multi-core CPU.
	precomputed_overhangs: []bool
	precomputed_overhangs_ready := false
	precomputed_travels: []bool
	precomputed_travels_ready := false
	if len(plan.moves) > 0 && len(model_layers) > 0 {
		if options.use_gpu {
			precomputed_overhangs, precomputed_overhangs_ready, precomputed_travels, precomputed_travels_ready =
				motion_gpu_compute_queries(
					model_layers,
					plan,
					options.overhang_slowdown_enabled,
					allocator,
				)
		} else if options.worker_threads > 1 && options.overhang_slowdown_enabled && len(model_layers) > 1 {
			precomputed_overhangs, precomputed_overhangs_ready = motion_cpu_mt_compute_overhangs(
				model_layers,
				plan,
				options.worker_threads,
				allocator,
			)
		}
	}
	defer delete(precomputed_overhangs, allocator)
	defer delete(precomputed_travels, allocator)

	extrusion_cursor := 0
	has_extruded := false
	retraction_count: u64
	wipe_count: u64
	for layer, layer_index in plan.layers {
		z := i64(layer_z[layer_index])
		if layer_ids[layer_index] == contracts.INVALID_STABLE_ID ||
		   z < i64(profile.printer.axis_minimum_z) ||
		   z > i64(profile.printer.axis_maximum_z) {
			return {}, .Invalid_Layer
		}
		if _, geometry_ok := polygon.polygon_set_hash(
			model_layers[layer_index],
		); !geometry_ok {
			return {}, .Invalid_Model
		}
		move_start := int(layer.move_offset)
		move_end := move_start+int(layer.move_count)
		if move_start < 0 || move_end < move_start ||
		   move_end > len(plan.moves) {
			return {}, .Invalid_Input
		}
		for move_index in move_start..<move_end {
			move := plan.moves[move_index]
			if !motion_point_in_machine(move.point_a, profile.printer) ||
			   !motion_point_in_machine(move.point_b, profile.printer) {
				return {}, .Machine_Bounds
			}
			length_nm, length_ok :=
				motion_move_length_nm(move.point_a, move.point_b)
			if !length_ok || length_nm == 0 {
				return {}, .Arithmetic
			}
			source := Motion_Source_Move{
				length_nm        = length_nm,
				travel_length_nm = length_nm,
			}
			switch move.kind {
			case .Travel:
				source.base_speed = profile.process.source.travel.speed
				source.acceleration =
					profile.process.source.travel.acceleration
				if precomputed_travels_ready {
					source.crosses_exterior = precomputed_travels[move_index]
				} else {
					source.crosses_exterior =
						motion_travel_crosses_exterior(
							move.point_a,
							move.point_b,
							model_layers[layer_index],
						)
				}
				retraction_threshold_nm :=
					u128(i64(profile.process.source.minimum_retraction_travel))*1_000
				source.retract_before =
					has_extruded &&
					i64(profile.process.source.retraction_distance) > 0 &&
					u128(length_nm) >= retraction_threshold_nm &&
					source.crosses_exterior
				if source.retract_before {
					retraction_count += 1
					if process.z_hop_enabled && i64(process.z_hop_height) > 0 {
						max_hop := i64(profile.printer.axis_maximum_z) - z
						if max_hop > 0 {
							source.z_hop_um = contracts.Micrometres(min(i64(process.z_hop_height), max_hop))
						}
					}
					if i64(options.wipe_distance_um) > 0 && move_index > move_start {
						prev_move := plan.moves[move_index - 1]
						if prev_move.kind == .Extrude && prev_move.point_b == move.point_a {
							if wp, w_len, t_len, w_ok := motion_compute_wipe(
								prev_move.point_a,
								move.point_a,
								move.point_b,
								options.wipe_distance_um,
								profile.printer,
							); w_ok {
								source.has_wipe = true
								source.wipe_point = wp
								source.wipe_length_nm = w_len
								source.travel_length_nm = t_len
								wipe_count += 1
							}
						}
					}
				}
			case .Extrude:
				if extrusion_cursor >= len(extrusion.moves) {
					return {}, .Extrusion_Mismatch
				}
				extrusion_move := extrusion.moves[extrusion_cursor]
				if extrusion_move.planned_move_id != move.stable_id ||
				   extrusion_move.planned_move_index != u32(move_index) ||
				   extrusion_move.path_id != move.path_id ||
				   extrusion_move.layer_index != u32(layer_index) ||
				   extrusion_move.role != move.role ||
				   extrusion_move.path_length_nm != length_nm {
					return {}, .Extrusion_Mismatch
				}
				target, target_ok :=
					motion_role_target(profile.process, move.role)
				if !target_ok {
					return {}, .Invalid_Config
				}
				source.base_speed = target.speed
				source.acceleration = target.acceleration
				source.fan_ratio = target.fan_ratio
				is_ov := false
				if options.overhang_slowdown_enabled &&
				   layer_index > 0 &&
				   (move.role == .Perimeter || move.role == .Thin_Wall) {
					if precomputed_overhangs_ready {
						is_ov = precomputed_overhangs[move_index]
					} else {
						is_ov = motion_segment_is_overhang(move.point_a, move.point_b, model_layers[layer_index - 1])
					}
				}
				if is_ov {
					pct := options.overhang_speed_percent
					if pct == 0 || pct > 100 {pct = 50}
					ov_scale := u32((u64(pct) * u64(profiles.RATIO_SCALE)) / 100)
					source.base_speed = motion_scaled_speed(
						source.base_speed,
						process.minimum_print_speed,
						ov_scale,
					)
					boost_fan := max(source.fan_ratio, process.bridge.fan_ratio)
					source.fan_ratio = clamp(
						boost_fan,
						profile.material.minimum_fan_ratio,
						profile.material.maximum_fan_ratio,
					)
				}
				source.extrusion_index = u32(extrusion_cursor)
				source.is_extrusion = true
				extrusion_cursor += 1
				has_extruded = true
			case .Invalid:
				return {}, .Invalid_Input
			}
			sources[move_index] = source
		}
	}
	if extrusion_cursor != len(extrusion.moves) ||
	   u64(extrusion_cursor) != plan.extrude_move_count {
		return {}, .Extrusion_Mismatch
	}

	operation_count :=
		u64(len(plan.moves))+retraction_count*2+wipe_count
	if operation_count < u64(len(plan.moves)) ||
	   operation_count > limits.max_operations {
		return {}, .Operation_Limit
	}
	for layer, layer_index in plan.layers {
		scale, base_duration, motion_duration, dwell, timing_ok :=
			motion_layer_timing(
				layer,
				sources,
				profile.process.source,
			)
		if !timing_ok {
			return {}, .Arithmetic
		}
		layer_scales[layer_index] = scale
		layer_base_durations[layer_index] = base_duration
		layer_motion_durations[layer_index] = motion_duration
		layer_dwells[layer_index] = dwell
		if dwell > 0 {
			if operation_count == max(u64) {
				return {}, .Arithmetic
			}
			operation_count += 1
		}
	}
	if operation_count > limits.max_operations ||
	   operation_count > u64(max(int)) {
		return {}, .Operation_Limit
	}

	result := Motion_Plan_Result{}
	result.layers = make([]Motion_Layer, len(plan.layers), allocator)
	result.operations =
		make([]Motion_Operation, int(operation_count), allocator)
	if len(plan.layers) > 0 && result.layers == nil ||
	   operation_count > 0 && result.operations == nil {
		motion_plan_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	operation_write := 0
	for layer, layer_index in plan.layers {
		operation_start := operation_write
		move_start := int(layer.move_offset)
		move_end := move_start+int(layer.move_count)
		scale := layer_scales[layer_index]
		current_point: polygon.Polygon_Point
		for move_index in move_start..<move_end {
			move := plan.moves[move_index]
			source := sources[move_index]
			current_point = move.point_b
			if source.retract_before {
				duration, duration_ok := motion_duration_for_distance_um(
					profile.process.source.retraction_distance,
					profile.process.source.retraction_speed,
				)
				if !duration_ok {
					motion_plan_result_destroy(&result, allocator)
					return {}, .Arithmetic
				}
				result.operations[operation_write] = {
					stable_id = contracts.stable_id_child(
						move.stable_id,
						.Motion,
						0,
					),
					source_move_id = move.stable_id,
					source_move_index = u32(move_index),
					path_id = move.path_id,
					layer_index = u32(layer_index),
					kind = .Retract,
					point_a = move.point_a,
					point_b = move.point_a,
					speed = profile.process.source.retraction_speed,
					acceleration =
						profile.process.source.retraction_acceleration,
					filament_delta_nm =
						-i128(i64(profile.process.source.retraction_distance))*1_000,
					duration_us = duration,
					crosses_exterior = true,
				}
				operation_write += 1
				result.retraction_count += 1
			}

			if source.has_wipe {
				wipe_dur, wipe_dur_ok := motion_duration_for_length(source.wipe_length_nm, source.base_speed)
				if !wipe_dur_ok {
					motion_plan_result_destroy(&result, allocator)
					return {}, .Arithmetic
				}
				result.operations[operation_write] = {
					stable_id         = contracts.stable_id_child(move.stable_id, .Motion, 4),
					source_move_id    = move.stable_id,
					source_move_index = u32(move_index),
					path_id           = move.path_id,
					layer_index       = u32(layer_index),
					kind              = .Travel,
					point_a           = move.point_a,
					point_b           = source.wipe_point,
					speed             = source.base_speed,
					acceleration      = source.acceleration,
					duration_us       = wipe_dur,
					crosses_exterior  = false,
				}
				operation_write += 1
				result.travel_count += 1
			}

			operation_kind := Motion_Operation_Kind.Travel
			speed := source.base_speed
			filament_delta_nm: i128
			move_point_a := move.point_a
			move_len_nm := source.length_nm
			if move.kind == .Extrude {
				operation_kind = .Extrude
				speed = motion_scaled_speed(
					source.base_speed,
					profile.process.source.minimum_print_speed,
					scale,
				)
				filament_delta_nm =
					i128(extrusion.moves[source.extrusion_index].incremental_filament_nm)
				if filament_delta_nm <= 0 {
					filament_delta_nm = i128(max(u32(10), profile.process.source.extrusion_length_quantum_nm))
				}
			} else if source.has_wipe {
				move_point_a = source.wipe_point
				move_len_nm = source.travel_length_nm
			}
			duration, duration_ok :=
				motion_duration_for_length(move_len_nm, speed)
			if !duration_ok {
				motion_plan_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			if move.kind == .Travel && i64(source.z_hop_um) > 0 {
				hop_dur, hop_ok := motion_duration_for_distance_um(source.z_hop_um, speed)
				if !hop_ok {
					motion_plan_result_destroy(&result, allocator)
					return {}, .Arithmetic
				}
				duration, duration_ok = motion_checked_add_u64(duration, hop_dur)
				if duration_ok {
					duration, duration_ok = motion_checked_add_u64(duration, hop_dur)
				}
				if !duration_ok {
					motion_plan_result_destroy(&result, allocator)
					return {}, .Arithmetic
				}
			}
			result.operations[operation_write] = {
				stable_id = contracts.stable_id_child(
					move.stable_id,
					.Motion,
					1,
				),
				source_move_id = move.stable_id,
				source_move_index = u32(move_index),
				path_id = move.path_id,
				layer_index = u32(layer_index),
				kind = operation_kind,
				role = move.role,
				point_a = move_point_a,
				point_b = move.point_b,
				z_hop_um = source.z_hop_um if move.kind == .Travel else 0,
				speed = speed,
				acceleration = source.acceleration,
				fan_ratio = source.fan_ratio,
				filament_delta_nm = filament_delta_nm,
				duration_us = duration,
				crosses_exterior = source.crosses_exterior,
			}
			operation_write += 1
			if move.kind == .Travel {
				result.travel_count += 1
			} else {
				result.extrusion_count += 1
			}

			if source.retract_before {
				duration, duration_ok = motion_duration_for_distance_um(
					profile.process.source.retraction_distance,
					profile.process.source.recovery_speed,
				)
				if !duration_ok {
					motion_plan_result_destroy(&result, allocator)
					return {}, .Arithmetic
				}
				result.operations[operation_write] = {
					stable_id = contracts.stable_id_child(
						move.stable_id,
						.Motion,
						2,
					),
					source_move_id = move.stable_id,
					source_move_index = u32(move_index),
					path_id = move.path_id,
					layer_index = u32(layer_index),
					kind = .Recover,
					point_a = move.point_b,
					point_b = move.point_b,
					speed = profile.process.source.recovery_speed,
					acceleration =
						profile.process.source.retraction_acceleration,
					filament_delta_nm =
						i128(i64(profile.process.source.retraction_distance))*1_000,
					duration_us = duration,
					crosses_exterior = true,
				}
				operation_write += 1
			}
		}
		dwell := layer_dwells[layer_index]
		if dwell > 0 {
			result.operations[operation_write] = {
				stable_id = contracts.stable_id_child(
					layer_ids[layer_index],
					.Motion,
					3,
				),
				layer_index = u32(layer_index),
				kind = .Dwell,
				point_a = current_point,
				point_b = current_point,
				duration_us = dwell,
			}
			operation_write += 1
			result.dwell_count += 1
		}
		layer_operation_count := operation_write-operation_start
		if layer_operation_count > int(max(u32)) {
			motion_plan_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		planned_duration, planned_ok := motion_checked_add_u64(
			layer_motion_durations[layer_index],
			dwell,
		)
		if !planned_ok {
			motion_plan_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			stable_id = layer_ids[layer_index],
			layer_index = u32(layer_index),
			z = layer_z[layer_index],
			operation_offset = u64(operation_start),
			operation_count = u32(layer_operation_count),
			speed_scale_ppm = layer_scales[layer_index],
			base_duration_us = layer_base_durations[layer_index],
			motion_duration_us = layer_motion_durations[layer_index],
			dwell_duration_us = dwell,
			planned_duration_us = planned_duration,
		}
		total_ok: bool
		result.total_motion_duration_us, total_ok =
			motion_checked_add_u64(
				result.total_motion_duration_us,
				layer_motion_durations[layer_index],
			)
		if total_ok {
			result.total_dwell_duration_us, total_ok =
				motion_checked_add_u64(
					result.total_dwell_duration_us,
					dwell,
				)
		}
		if total_ok {
			result.total_planned_duration_us, total_ok =
				motion_checked_add_u64(
					result.total_planned_duration_us,
					planned_duration,
				)
		}
		if !total_ok {
			motion_plan_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
	}
	if operation_write != len(result.operations) ||
	   result.retraction_count != retraction_count ||
	   result.travel_count != plan.travel_move_count + wipe_count ||
	   result.extrusion_count != plan.extrude_move_count {
		motion_plan_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

motion_layer_timing :: proc(
	layer: Unified_Planned_Layer,
	sources: []Motion_Source_Move,
	process: profiles.Process_Profile,
) -> (
	scale: u32,
	base_duration, motion_duration, dwell: u64,
	ok: bool,
) {
	extrusion_count := 0
	move_start := int(layer.move_offset)
	move_end := move_start+int(layer.move_count)
	if move_start < 0 || move_end < move_start ||
	   move_end > len(sources) {
		return 0, 0, 0, 0, false
	}
	for source in sources[move_start:move_end] {
		if source.is_extrusion {extrusion_count += 1}
	}
	base_ok: bool
	base_duration, base_ok =
		motion_layer_duration(layer, sources, process, profiles.RATIO_SCALE)
	if !base_ok {return 0, 0, 0, 0, false}
	if extrusion_count == 0 {
		return profiles.RATIO_SCALE, base_duration, base_duration, 0, true
	}
	target_us := u64(process.minimum_layer_time)*1_000
	if base_duration >= target_us {
		return profiles.RATIO_SCALE, base_duration, base_duration, 0, true
	}
	minimum_duration, minimum_ok :=
		motion_layer_duration(layer, sources, process, 0)
	if !minimum_ok {return 0, 0, 0, 0, false}
	if minimum_duration < target_us {
		return 0, base_duration, minimum_duration,
			target_us-minimum_duration, true
	}
	low := u32(0)
	high := profiles.RATIO_SCALE
	for low+1 < high {
		middle := low+(high-low)/2
		duration, duration_ok :=
			motion_layer_duration(layer, sources, process, middle)
		if !duration_ok {return 0, 0, 0, 0, false}
		if duration >= target_us {
			low = middle
		} else {
			high = middle
		}
	}
	duration_ok: bool
	motion_duration, duration_ok =
		motion_layer_duration(layer, sources, process, low)
	if !duration_ok {return 0, 0, 0, 0, false}
	return low, base_duration, motion_duration, 0, true
}

motion_layer_duration :: proc(
	layer: Unified_Planned_Layer,
	sources: []Motion_Source_Move,
	process: profiles.Process_Profile,
	scale: u32,
) -> (u64, bool) {
	if scale > profiles.RATIO_SCALE {return 0, false}
	move_start := int(layer.move_offset)
	move_end := move_start+int(layer.move_count)
	if move_start < 0 || move_end < move_start || move_end > len(sources) {
		return 0, false
	}
	total: u64
	for source in sources[move_start:move_end] {
		speed := source.base_speed
		move_len_nm := source.length_nm
		if source.is_extrusion {
			speed = motion_scaled_speed(
				source.base_speed,
				process.minimum_print_speed,
				scale,
			)
		} else if source.has_wipe {
			move_len_nm = source.travel_length_nm
		}
		duration, duration_ok :=
			motion_duration_for_length(move_len_nm, speed)
		if !duration_ok {return 0, false}
		total, duration_ok = motion_checked_add_u64(total, duration)
		if !duration_ok {return 0, false}
		if source.has_wipe {
			wipe_dur, wipe_ok := motion_duration_for_length(source.wipe_length_nm, source.base_speed)
			if !wipe_ok {return 0, false}
			total, duration_ok = motion_checked_add_u64(total, wipe_dur)
			if !duration_ok {return 0, false}
		}
		if !source.is_extrusion && i64(source.z_hop_um) > 0 {
			hop_dur, hop_ok := motion_duration_for_distance_um(source.z_hop_um, speed)
			if !hop_ok {return 0, false}
			total, duration_ok = motion_checked_add_u64(total, hop_dur)
			if duration_ok {
				total, duration_ok = motion_checked_add_u64(total, hop_dur)
			}
			if !duration_ok {return 0, false}
		}
		if source.retract_before {
			retract_duration, retract_ok :=
				motion_duration_for_distance_um(
					process.retraction_distance,
					process.retraction_speed,
				)
			recover_duration, recover_ok :=
				motion_duration_for_distance_um(
					process.retraction_distance,
					process.recovery_speed,
				)
			if !retract_ok || !recover_ok {
				return 0, false
			}
			total, duration_ok =
				motion_checked_add_u64(total, retract_duration)
			if duration_ok {
				total, duration_ok =
					motion_checked_add_u64(total, recover_duration)
			}
			if !duration_ok {return 0, false}
		}
	}
	return total, true
}

motion_scaled_speed :: proc(
	base, minimum: profiles.Speed_Um_Per_Second,
	scale: u32,
) -> profiles.Speed_Um_Per_Second {
	scaled :=
		(i128(base)*i128(scale))/i128(profiles.RATIO_SCALE)
	if scaled < i128(minimum) {return minimum}
	scaled -= scaled%50
	if scaled < i128(minimum) {return minimum}
	return profiles.Speed_Um_Per_Second(scaled)
}

motion_duration_for_length :: proc(
	length_nm: u64,
	speed: profiles.Speed_Um_Per_Second,
) -> (u64, bool) {
	if length_nm == 0 || i64(speed) <= 0 {return 0, false}
	numerator := u128(length_nm)*1_000
	value :=
		(numerator+u128(i64(speed))-1)/u128(i64(speed))
	if value == 0 || value > u128(max(u64)) {return 0, false}
	return u64(value), true
}

motion_duration_for_distance_um :: proc(
	distance: contracts.Micrometres,
	speed: profiles.Speed_Um_Per_Second,
) -> (u64, bool) {
	if i64(distance) <= 0 || i64(speed) <= 0 {return 0, false}
	numerator := u128(i64(distance))*1_000_000
	value :=
		(numerator+u128(i64(speed))-1)/u128(i64(speed))
	if value == 0 || value > u128(max(u64)) {return 0, false}
	return u64(value), true
}

motion_move_length_nm :: proc(
	a, b: polygon.Polygon_Point,
) -> (u64, bool) {
	distance_squared := path_plan_distance_2(a, b)
	scaled, scaled_ok :=
		extrusion_checked_multiply(distance_squared, 1_000_000)
	if !scaled_ok {return 0, false}
	length, _, length_ok := extrusion_integer_sqrt_round(scaled)
	return length, length_ok
}

motion_point_in_machine :: proc(
	point: polygon.Polygon_Point,
	printer: profiles.Printer_Profile,
) -> bool {
	return i64(point.x) >= i64(printer.axis_minimum_x) &&
	       i64(point.x) <= i64(printer.axis_maximum_x) &&
	       i64(point.y) >= i64(printer.axis_minimum_y) &&
	       i64(point.y) <= i64(printer.axis_maximum_y)
}

motion_travel_crosses_exterior :: proc(
	a, b: polygon.Polygon_Point,
	model: polygon.Polygon_Set,
) -> bool {
	if a == b {return false}
	if !bridge_polygon_contains_twice(
		model,
		i64(a.x)*2,
		i64(a.y)*2,
	) ||
	   !bridge_polygon_contains_twice(
		model,
		i64(b.x)*2,
		i64(b.y)*2,
	) ||
	   !bridge_polygon_contains_twice(
		model,
		i64(a.x)+i64(b.x),
		i64(a.y)+i64(b.y),
	) {
		return true
	}
	for path in model.paths {
		start := int(path.offset)
		for edge_index in 0..<int(path.count) {
			edge_a := model.points[start+edge_index]
			edge_b :=
				model.points[start+(edge_index+1)%int(path.count)]
			if motion_segment_touches_boundary_inside(
				a,
				b,
				edge_a,
				edge_b,
			) {
				return true
			}
		}
	}
	return false
}

motion_segment_touches_boundary_inside :: proc(
	a, b, edge_a, edge_b: polygon.Polygon_Point,
) -> bool {
	_, edge_a_sign, edge_a_error := geometry.orient_2d_checked(
		{x = a.x, y = a.y},
		{x = b.x, y = b.y},
		{x = edge_a.x, y = edge_a.y},
	)
	_, edge_b_sign, edge_b_error := geometry.orient_2d_checked(
		{x = a.x, y = a.y},
		{x = b.x, y = b.y},
		{x = edge_b.x, y = edge_b.y},
	)
	_, a_sign, a_error := geometry.orient_2d_checked(
		{x = edge_a.x, y = edge_a.y},
		{x = edge_b.x, y = edge_b.y},
		{x = a.x, y = a.y},
	)
	_, b_sign, b_error := geometry.orient_2d_checked(
		{x = edge_a.x, y = edge_a.y},
		{x = edge_b.x, y = edge_b.y},
		{x = b.x, y = b.y},
	)
	if edge_a_error != .None || edge_b_error != .None ||
	   a_error != .None || b_error != .None {
		return true
	}
	if edge_a_sign == .Zero && edge_b_sign == .Zero {
		return false
	}
	if motion_opposite_signs(edge_a_sign, edge_b_sign) &&
	   motion_opposite_signs(a_sign, b_sign) {
		return true
	}
	if edge_a_sign == .Zero &&
	   edge_a != a && edge_a != b &&
	   motion_point_on_segment(edge_a, a, b) {
		return true
	}
	if edge_b_sign == .Zero &&
	   edge_b != a && edge_b != b &&
	   motion_point_on_segment(edge_b, a, b) {
		return true
	}
	return false
}

motion_opposite_signs :: proc(
	a, b: geometry.Predicate_Sign,
) -> bool {
	return a == .Negative && b == .Positive ||
		a == .Positive && b == .Negative
}

motion_point_on_segment :: proc(
	point, a, b: polygon.Polygon_Point,
) -> bool {
	return point.x >= min(a.x, b.x) && point.x <= max(a.x, b.x) &&
		point.y >= min(a.y, b.y) && point.y <= max(a.y, b.y)
}

motion_role_target :: proc(
	process: profiles.Resolved_Process_Profile,
	role: profiles.Printable_Role,
) -> (profiles.Role_Target, bool) {
	switch role {
	case .Perimeter:
		return process.source.perimeter, true
	case .Bridge:
		return process.source.bridge, true
	case .Gap, .Thin_Wall:
		return process.source.gap, true
	case .Bottom_Skin, .Top_Skin, .Top_Bottom_Skin:
		return process.source.skin, true
	case .Sparse_Infill:
		return process.source.sparse_infill, true
	case .Support:
		return process.source.support, true
	case .Support_Interface:
		return process.source.support_interface, true
	case .Invalid:
		return {}, false
	}
	return {}, false
}

motion_checked_add_u64 :: proc(a, b: u64) -> (u64, bool) {
	if b > max(u64)-a {return 0, false}
	return a+b, true
}

motion_compute_wipe :: proc(
	prev_a, cur_a, target_b: polygon.Polygon_Point,
	wipe_dist_um: contracts.Micrometres,
	printer: profiles.Printer_Profile,
) -> (wipe_pt: polygon.Polygon_Point, wipe_len_nm, travel_len_nm: u64, ok: bool) {
	dx := i64(prev_a.x) - i64(cur_a.x)
	dy := i64(prev_a.y) - i64(cur_a.y)
	prev_len_nm, prev_ok := motion_move_length_nm(cur_a, prev_a)
	if !prev_ok || prev_len_nm == 0 {return {}, 0, 0, false}
	prev_len_um := i64(prev_len_nm / 1_000)
	if prev_len_um <= 0 {return {}, 0, 0, false}
	d := min(i64(wipe_dist_um), prev_len_um)
	wx := i64(cur_a.x) + (dx * d) / prev_len_um
	wy := i64(cur_a.y) + (dy * d) / prev_len_um
	wipe_pt = {x = contracts.Micrometres(wx), y = contracts.Micrometres(wy)}
	if wipe_pt == cur_a || wipe_pt == target_b || !motion_point_in_machine(wipe_pt, printer) {
		return {}, 0, 0, false
	}
	w_len, w_ok := motion_move_length_nm(cur_a, wipe_pt)
	t_len, t_ok := motion_move_length_nm(wipe_pt, target_b)
	if !w_ok || !t_ok || w_len == 0 || t_len == 0 {
		return {}, 0, 0, false
	}
	return wipe_pt, w_len, t_len, true
}

@(private = "file")
motion_cpu_mt_compute_overhangs :: proc(
	model_layers: []polygon.Polygon_Set,
	plan: Unified_Path_Plan_Result,
	worker_threads: int,
	allocator := context.allocator,
) -> (flags: []bool, ok: bool) {
	flags = make([]bool, len(plan.moves), allocator)
	if flags == nil {return nil, false}

	Ov_Worker_Ctx :: struct {
		model_layers: []polygon.Polygon_Set,
		plan:         Unified_Path_Plan_Result,
		flags:        []bool,
		next_layer:   int,
		layer_count:  int,
	}
	wctx := Ov_Worker_Ctx{
		model_layers = model_layers,
		plan         = plan,
		flags        = flags,
		next_layer   = 1,
		layer_count  = len(plan.layers),
	}
	worker_proc :: proc(c: ^Ov_Worker_Ctx) {
		for {
			li := sync.atomic_add(&c.next_layer, 1)
			if li >= c.layer_count {break}
			prev := c.model_layers[li - 1]
			if len(prev.paths) == 0 {continue}
			layer := c.plan.layers[li]
			ms := int(layer.move_offset)
			me := ms + int(layer.move_count)
			for mi in ms..<me {
				m := c.plan.moves[mi]
				if m.kind != .Extrude || (m.role != .Perimeter && m.role != .Thin_Wall) {continue}
				c.flags[mi] = motion_segment_is_overhang(m.point_a, m.point_b, prev)
			}
		}
	}

	num_workers := clamp(worker_threads, 1, 16)
	if len(plan.layers) < 8 || num_workers <= 1 {
		worker_proc(&wctx)
	} else {
		threads: [15]^thread.Thread
		spawn_count := num_workers - 1
		for wi in 0..<spawn_count {
			threads[wi] = thread.create_and_start_with_poly_data(&wctx, worker_proc)
		}
		worker_proc(&wctx)
		for wi in 0..<spawn_count {
			if threads[wi] != nil {
				thread.join(threads[wi])
				thread.destroy(threads[wi])
			}
		}
	}
	return flags, true
}

@(private = "file")
motion_gpu_compute_queries :: proc(
	model_layers: []polygon.Polygon_Set,
	plan: Unified_Path_Plan_Result,
	compute_overhangs: bool,
	allocator := context.allocator,
) -> (ov_flags: []bool, ov_ok: bool, trv_flags: []bool, trv_ok: bool) {
	// Flatten all model layer polygon edges once for shared-memory Metal upload.
	total_edges := 0
	for ml in model_layers {
		for p in ml.paths {total_edges += int(p.count)}
	}
	edges := make([]gpu.Poly_Edge, total_edges, context.temp_allocator)
	ranges := make([]gpu.Layer_Edge_Range, len(model_layers), context.temp_allocator)
	ew := 0
	for ml, li in model_layers {
		start := ew
		for p in ml.paths {
			ps := int(p.offset)
			cnt := int(p.count)
			for ei in 0..<cnt {
				pa := ml.points[ps + ei]
				pb := ml.points[ps + (ei + 1) % cnt]
				edges[ew] = {ax = i64(pa.x), ay = i64(pa.y), bx = i64(pb.x), by = i64(pb.y)}
				ew += 1
			}
		}
		ranges[li] = {offset = u32(start), count = u32(ew - start)}
	}

	// 1. Overhang point-in-polygon batch.
	if compute_overhangs && len(model_layers) > 1 {
		queries := make([dynamic]gpu.Point_Query, 0, len(plan.moves) / 2, context.temp_allocator)
		move_indices := make([dynamic]int, 0, len(plan.moves) / 4, context.temp_allocator)
		for layer, li in plan.layers {
			if li == 0 || len(model_layers[li - 1].paths) == 0 {continue}
			ms := int(layer.move_offset)
			me := ms + int(layer.move_count)
			prev_li := u32(li - 1)
			for mi in ms..<me {
				m := plan.moves[mi]
				if m.kind != .Extrude || (m.role != .Perimeter && m.role != .Thin_Wall) {continue}
				ax, ay := i64(m.point_a.x), i64(m.point_a.y)
				bx, by := i64(m.point_b.x), i64(m.point_b.y)
				append(&move_indices, mi)
				append(&queries, gpu.Point_Query{x2 = ax + bx, y2 = ay + by, layer_idx = prev_li})
				append(&queries, gpu.Point_Query{x2 = (3*ax + bx)/2, y2 = (3*ay + by)/2, layer_idx = prev_li})
				append(&queries, gpu.Point_Query{x2 = (ax + 3*bx)/2, y2 = (ay + 3*by)/2, layer_idx = prev_li})
			}
		}
		ov_flags = make([]bool, len(plan.moves), allocator)
		if len(queries) == 0 {
			ov_ok = true
		} else {
			out_res := make([]u8, len(queries), context.temp_allocator)
			if gpu.metal_batch_point_in_polygon(edges, ranges, queries[:], out_res) {
				for mi, idx in move_indices {
					base := idx * 3
					unsupported := 0
					if out_res[base + 0] == 0 {unsupported += 1}
					if out_res[base + 1] == 0 {unsupported += 1}
					if out_res[base + 2] == 0 {unsupported += 1}
					ov_flags[mi] = unsupported >= 2
				}
				ov_ok = true
			} else {
				delete(ov_flags, allocator)
				ov_flags = nil
			}
		}
	}

	// 2. Travel exterior-crossing batch.
	t_queries := make([dynamic]gpu.Travel_Query, 0, int(plan.travel_move_count), context.temp_allocator)
	t_indices := make([dynamic]int, 0, int(plan.travel_move_count), context.temp_allocator)
	for layer, li in plan.layers {
		ms := int(layer.move_offset)
		me := ms + int(layer.move_count)
		for mi in ms..<me {
			m := plan.moves[mi]
			if m.kind != .Travel {continue}
			append(&t_indices, mi)
			append(&t_queries, gpu.Travel_Query{
				ax        = i64(m.point_a.x),
				ay        = i64(m.point_a.y),
				bx        = i64(m.point_b.x),
				by        = i64(m.point_b.y),
				layer_idx = u32(li),
			})
		}
	}
	trv_flags = make([]bool, len(plan.moves), allocator)
	if len(t_queries) == 0 {
		trv_ok = true
	} else {
		t_out := make([]u8, len(t_queries), context.temp_allocator)
		if gpu.metal_batch_travel_crosses_exterior(edges, ranges, t_queries[:], t_out) {
			for mi, idx in t_indices {
				trv_flags[mi] = t_out[idx] != 0
			}
			trv_ok = true
		} else {
			delete(trv_flags, allocator)
			trv_flags = nil
		}
	}
	return
}

motion_segment_is_overhang :: proc(
	a, b: polygon.Polygon_Point,
	prev_layer: polygon.Polygon_Set,
) -> bool {
	if len(prev_layer.paths) == 0 {return false}
	// Sample 3 interior points (25%, 50%, 75%) using exact doubled integer coordinates.
	ax := i64(a.x)
	ay := i64(a.y)
	bx := i64(b.x)
	by := i64(b.y)
	unsupported := 0
	if !bridge_polygon_contains_twice(prev_layer, ax + bx, ay + by) {
		unsupported += 1
	}
	if !bridge_polygon_contains_twice(prev_layer, (3*ax + bx)/2, (3*ay + by)/2) {
		unsupported += 1
	}
	if !bridge_polygon_contains_twice(prev_layer, (ax + 3*bx)/2, (ay + 3*by)/2) {
		unsupported += 1
	}
	return unsupported >= 2
}

motion_plan_result_destroy :: proc(
	result: ^Motion_Plan_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.operations, allocator)
	result^ = {}
}
