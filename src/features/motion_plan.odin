package features

import "core:math"
import "core:mem"

import contracts "../contracts"
import geometry "../geometry"
import gpu "../gpu"
import polygon "../polygon"
import profiles "../profiles"
import workers "../workers"

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
	// Ordered by alignment (16 -> 8 -> 4 -> 1) to eliminate interior padding.
	filament_delta_nm:     i128,
	stable_id:             contracts.Stable_ID,
	source_move_id:        contracts.Stable_ID,
	path_id:               contracts.Stable_ID,
	point_a:               polygon.Polygon_Point,
	point_b:               polygon.Polygon_Point,
	arc_center:            polygon.Polygon_Point,
	z_hop_um:              contracts.Micrometres,
	z_offset_um:           contracts.Micrometres, // non-zero for scarf seams / spiral vase Z interpolation
	duration_us:           u64,
	source_move_index:     u32,
	layer_index:           u32,
	speed:                 profiles.Speed_Um_Per_Second,
	acceleration:          profiles.Acceleration_Um_Per_Second_Squared,
	fan_ratio:             profiles.Ratio_Ppm,
	kind:                  Motion_Operation_Kind,
	arc:                   Motion_Arc_Kind,
	role:                  profiles.Printable_Role,
	crosses_exterior:      bool,
}

Motion_Plan_Options :: struct {
	wipe_distance_um:               contracts.Micrometres,
	overhang_slowdown_enabled:      bool,
	overhang_speed_percent:         u32,
	overhang_tier_speeds_um_s:      [4]profiles.Speed_Um_Per_Second, // 0 = use overhang_speed_percent
	ironing_speed_um_s:             profiles.Speed_Um_Per_Second,    // 0 = inherit skin speed
	initial_layer_speed_um_s:       profiles.Speed_Um_Per_Second,    // 0 = inherit role speed
	initial_layer_infill_speed_um_s: profiles.Speed_Um_Per_Second,   // 0 = inherit role speed
	outer_wall_speed_um_s:          profiles.Speed_Um_Per_Second,    // 0 = inherit perimeter speed
	inner_wall_speed_um_s:          profiles.Speed_Um_Per_Second,    // 0 = inherit perimeter speed
	top_surface_speed_um_s:         profiles.Speed_Um_Per_Second,    // 0 = inherit skin speed
	internal_solid_speed_um_s:      profiles.Speed_Um_Per_Second,    // 0 = inherit skin speed
	small_perimeter_speed_um_s:     profiles.Speed_Um_Per_Second,    // 0 = disabled
	initial_layer_accel_um_s2:      profiles.Acceleration_Um_Per_Second_Squared,
	initial_layer_travel_accel_um_s2: profiles.Acceleration_Um_Per_Second_Squared,
	outer_wall_accel_um_s2:         profiles.Acceleration_Um_Per_Second_Squared,
	inner_wall_accel_um_s2:         profiles.Acceleration_Um_Per_Second_Squared,
	top_surface_accel_um_s2:        profiles.Acceleration_Um_Per_Second_Squared,
	internal_solid_accel_um_s2:     profiles.Acceleration_Um_Per_Second_Squared,
	bridge_accel_um_s2:             profiles.Acceleration_Um_Per_Second_Squared,
	reduce_infill_retraction:       bool,
	use_gpu:                        bool,
	worker_threads:                 int, // <= 1 = single-core; > 1 = multi-core CPU overhang detection
	skip_stable_ids:                bool, // true when evidence is disabled; skips per-operation FNV-1a ID derivation
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

// Hot per-move motion source (32 B, 2 per cache line; down from 72 B). Cold travel-only wipe/z-hop
// fields live in sparse per-layer `Motion_Travel_Extra` slices indexed by `extrusion_index` on travels.
Motion_Source_Move :: struct {
	length_nm:        u64,
	base_speed:       profiles.Speed_Um_Per_Second,
	acceleration:     profiles.Acceleration_Um_Per_Second_Squared,
	fan_ratio:        profiles.Ratio_Ppm,
	extrusion_index:  u32, // for Travel: index into layer's travel_extras, or max(u32) if none
	is_extrusion:     bool,
	retract_before:   bool,
	crosses_exterior: bool,
	has_wipe:         bool,
}

Motion_Travel_Extra :: struct {
	wipe_point:       polygon.Polygon_Point,
	wipe_length_nm:   u64,
	travel_length_nm: u64,
	z_hop_um:         contracts.Micrometres,
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
	   !extrusion_plan_valid(plan, !options.skip_stable_ids) {
		return {}, .Invalid_Input
	}
	if u64(len(plan.moves)) > u64(max(u32)) {
		return {}, .Arithmetic
	}
	expected_ext: u64
	for ext_layer in extrusion.layers {
		if ext_layer.move_offset != expected_ext ||
		   ext_layer.move_offset+u64(ext_layer.move_count) > u64(len(extrusion.moves)) {
			return {}, .Extrusion_Mismatch
		}
		expected_ext += u64(ext_layer.move_count)
	}
	if expected_ext != u64(len(extrusion.moves)) ||
	   expected_ext != plan.extrude_move_count {
		return {}, .Extrusion_Mismatch
	}

	sources := features_make_non_zeroed([]Motion_Source_Move, len(plan.moves), allocator)
	layer_states := make([]Motion_Layer_Build_State, len(plan.layers), allocator)
	if len(plan.moves) > 0 && sources == nil ||
	   len(plan.layers) > 0 && layer_states == nil {
		delete(sources, allocator)
		delete(layer_states, allocator)
		return {}, .Allocation_Failed
	}
	defer {
		for &st in layer_states {delete(st.travel_extras)}
		delete(sources, allocator)
		delete(layer_states, allocator)
	}

	worker_limit := options.worker_threads
	if worker_limit <= 0 {
		worker_limit = get_worker_threads()
	}

	GPU_QUERY_MIN_MOVES :: 300_000
	precomputed_overhangs: []bool
	precomputed_overhangs_ready := false
	precomputed_travels: []bool
	precomputed_travels_ready := false
	use_gpu_queries := options.use_gpu && (worker_limit <= 1 || len(plan.moves) >= GPU_QUERY_MIN_MOVES)
	if len(plan.moves) > 0 && len(model_layers) > 0 && use_gpu_queries {
		precomputed_overhangs, precomputed_overhangs_ready, precomputed_travels, precomputed_travels_ready =
			motion_gpu_compute_queries(
				model_layers,
				plan,
				options.overhang_slowdown_enabled,
				allocator,
			)
	}
	defer delete(precomputed_overhangs, allocator)
	defer delete(precomputed_travels, allocator)

	build_ctx := Motion_Build_Context{
		layer_ids                   = layer_ids,
		layer_z                     = layer_z,
		model_layers                = model_layers,
		plan                        = plan,
		extrusion                   = extrusion,
		profile                     = profile,
		options                     = options,
		sources                     = sources,
		layer_states                = layer_states,
		precomputed_overhangs       = precomputed_overhangs,
		precomputed_overhangs_ready = precomputed_overhangs_ready,
		precomputed_travels         = precomputed_travels,
		precomputed_travels_ready   = precomputed_travels_ready,
	}
	workers.parallel_for(len(plan.layers), &build_ctx, motion_build_layer_sources, worker_limit)

	retraction_count: u64
	wipe_count: u64
	for st in layer_states {
		if st.source_error != .None {
			return {}, st.source_error
		}
		retraction_count += st.retraction_count
		wipe_count += st.wipe_count
	}

	base_operation_count := u64(len(plan.moves))+retraction_count*2+wipe_count
	if base_operation_count < u64(len(plan.moves)) ||
	   base_operation_count > limits.max_operations {
		return {}, .Operation_Limit
	}
	operation_count: u64
	for &st, layer_index in layer_states {
		if st.timing_error != .None {
			return {}, st.timing_error
		}
		layer_ops := u64(plan.layers[layer_index].move_count)+st.retraction_count*2+st.wipe_count
		if st.dwell > 0 {
			if layer_ops == max(u64) {
				return {}, .Arithmetic
			}
			layer_ops += 1
		}
		if layer_ops > u64(max(u32)) {
			return {}, .Arithmetic
		}
		if operation_count > limits.max_operations ||
		   layer_ops > limits.max_operations-operation_count {
			return {}, .Operation_Limit
		}
		st.op_offset = operation_count
		st.op_count = u32(layer_ops)
		operation_count += layer_ops
	}
	if operation_count > limits.max_operations ||
	   operation_count > u64(max(int)) {
		return {}, .Operation_Limit
	}

	result := Motion_Plan_Result{}
	result.layers = make([]Motion_Layer, len(plan.layers), allocator)
	result.operations =
		features_make_non_zeroed([]Motion_Operation, int(operation_count), allocator)
	if len(plan.layers) > 0 && result.layers == nil ||
	   operation_count > 0 && result.operations == nil {
		motion_plan_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	build_ctx.result_layers = result.layers
	build_ctx.result_operations = result.operations
	workers.parallel_for(len(plan.layers), &build_ctx, motion_emit_layer_operations, worker_limit)

	for st, layer_index in layer_states {
		if st.emit_error != .None {
			motion_plan_result_destroy(&result, allocator)
			return {}, st.emit_error
		}
		result.retraction_count += st.retraction_count
		result.travel_count += st.travel_count
		result.extrusion_count += st.extrusion_count
		result.dwell_count += st.dwell_count
		total_ok: bool
		result.total_motion_duration_us, total_ok = motion_checked_add_u64(
			result.total_motion_duration_us,
			st.motion_duration,
		)
		if total_ok {
			result.total_dwell_duration_us, total_ok = motion_checked_add_u64(
				result.total_dwell_duration_us,
				st.dwell,
			)
		}
		if total_ok {
			result.total_planned_duration_us, total_ok = motion_checked_add_u64(
				result.total_planned_duration_us,
				result.layers[layer_index].planned_duration_us,
			)
		}
		if !total_ok {
			motion_plan_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
	}
	if result.retraction_count != retraction_count ||
	   result.travel_count != plan.travel_move_count+wipe_count ||
	   result.extrusion_count != plan.extrude_move_count {
		motion_plan_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

@(private = "file")
Motion_Layer_Build_State :: struct {
	scale:            u32,
	base_duration:    u64,
	motion_duration:  u64,
	dwell:            u64,
	retraction_count: u64,
	wipe_count:       u64,
	travel_count:     u64,
	extrusion_count:  u64,
	dwell_count:      u64,
	op_offset:        u64,
	op_count:         u32,
	source_error:     Motion_Plan_Error,
	timing_error:     Motion_Plan_Error,
	emit_error:       Motion_Plan_Error,
	travel_extras:    [dynamic]Motion_Travel_Extra,
}

@(private = "file")
Motion_Build_Context :: struct {
	layer_ids:                   []contracts.Stable_ID,
	layer_z:                     []contracts.Micrometres,
	model_layers:                []polygon.Polygon_Set,
	plan:                        Unified_Path_Plan_Result,
	extrusion:                   Extrusion_Result,
	profile:                     profiles.Resolved_Profiles,
	options:                     Motion_Plan_Options,
	sources:                     []Motion_Source_Move,
	layer_states:                []Motion_Layer_Build_State,
	precomputed_overhangs:       []bool,
	precomputed_overhangs_ready: bool,
	precomputed_travels:         []bool,
	precomputed_travels_ready:   bool,
	result_layers:               []Motion_Layer,
	result_operations:           []Motion_Operation,
}

@(private = "file")
motion_build_layer_sources :: proc(ctx: ^Motion_Build_Context, layer_index: int) {
	st := &ctx.layer_states[layer_index]
	process := ctx.profile.process.source
	layer := ctx.plan.layers[layer_index]
	z := i64(ctx.layer_z[layer_index])
	if ctx.layer_ids[layer_index] == contracts.INVALID_STABLE_ID ||
	   z < i64(ctx.profile.printer.axis_minimum_z) ||
	   z > i64(ctx.profile.printer.axis_maximum_z) {
		st.source_error = .Invalid_Layer
		return
	}
	if polygon.polygon_set_validate(ctx.model_layers[layer_index], polygon.DEFAULT_POLYGON_LIMITS) != .None {
		st.source_error = .Invalid_Model
		return
	}
	move_start := int(layer.move_offset)
	move_end := move_start+int(layer.move_count)
	if move_start < 0 || move_end < move_start ||
	   move_end > len(ctx.plan.moves) {
		st.source_error = .Invalid_Input
		return
	}

	ext_layer := ctx.extrusion.layers[layer_index]
	extrusion_cursor := int(ext_layer.move_offset)
	ext_end := extrusion_cursor+int(ext_layer.move_count)
	has_extruded := ext_layer.move_offset > 0

	for move_index in move_start..<move_end {
		move := ctx.plan.moves[move_index]
		if !motion_point_in_machine(move.point_a, ctx.profile.printer) ||
		   !motion_point_in_machine(move.point_b, ctx.profile.printer) {
			st.source_error = .Machine_Bounds
			return
		}
		source: Motion_Source_Move
		length_nm: u64
		switch move.kind {
		case .Travel:
			length_ok: bool
			length_nm, length_ok = motion_move_length_nm(move.point_a, move.point_b)
			if !length_ok || length_nm == 0 {
				st.source_error = .Arithmetic
				return
			}
			source.length_nm = length_nm
			source.extrusion_index = max(u32)
			source.base_speed = process.travel.speed
			source.acceleration = process.travel.acceleration
			if layer_index == 0 && i64(ctx.options.initial_layer_travel_accel_um_s2) > 0 {
				source.acceleration = min(ctx.options.initial_layer_travel_accel_um_s2, ctx.profile.printer.maximum_acceleration)
			}
			if ctx.precomputed_travels_ready {
				source.crosses_exterior = ctx.precomputed_travels[move_index]
			} else {
				source.crosses_exterior = motion_travel_crosses_exterior(
					move.point_a,
					move.point_b,
					ctx.model_layers[layer_index],
				)
			}
			retraction_threshold_nm := u128(i64(process.minimum_retraction_travel))*1_000
			skip_infill_retract := false
			if ctx.options.reduce_infill_retraction && move_index > move_start && move_index + 1 < move_end {
				prev_m := ctx.plan.moves[move_index - 1]
				next_m := ctx.plan.moves[move_index + 1]
				if prev_m.kind == .Extrude && prev_m.role == .Sparse_Infill &&
				   next_m.kind == .Extrude && next_m.role == .Sparse_Infill {
					skip_infill_retract = true
				}
			}
			source.retract_before =
				has_extruded &&
				!skip_infill_retract &&
				i64(process.retraction_distance) > 0 &&
				u128(length_nm) >= retraction_threshold_nm &&
				source.crosses_exterior
			if source.retract_before {
				st.retraction_count += 1
				extra := Motion_Travel_Extra{travel_length_nm = length_nm}
				need_extra := false
				if process.z_hop_enabled && i64(process.z_hop_height) > 0 {
					max_hop := i64(ctx.profile.printer.axis_maximum_z)-z
					if max_hop > 0 {
						extra.z_hop_um = contracts.Micrometres(min(i64(process.z_hop_height), max_hop))
						need_extra = true
					}
				}
				if i64(ctx.options.wipe_distance_um) > 0 && move_index > move_start {
					prev_move := ctx.plan.moves[move_index-1]
					if prev_move.kind == .Extrude && prev_move.point_b == move.point_a {
						if wp, w_len, t_len, w_ok := motion_compute_wipe(
							prev_move.point_a,
							move.point_a,
							move.point_b,
							ctx.options.wipe_distance_um,
							ctx.profile.printer,
						); w_ok {
							source.has_wipe = true
							extra.wipe_point = wp
							extra.wipe_length_nm = w_len
							extra.travel_length_nm = t_len
							need_extra = true
							st.wipe_count += 1
						}
					}
				}
				if need_extra {
					source.extrusion_index = u32(len(st.travel_extras))
					append(&st.travel_extras, extra)
				}
			}
		case .Extrude:
			if extrusion_cursor >= ext_end {
				st.source_error = .Extrusion_Mismatch
				return
			}
			extrusion_move := ctx.extrusion.moves[extrusion_cursor]
			length_nm = extrusion_move.path_length_nm
			if length_nm == 0 {
				st.source_error = .Arithmetic
				return
			}
			source.length_nm = length_nm
			if extrusion_move.planned_move_id != move.stable_id ||
			   extrusion_move.planned_move_index != u32(move_index) ||
			   extrusion_move.path_id != move.path_id ||
			   extrusion_move.layer_index != u32(layer_index) ||
			   extrusion_move.role != move.role {
				st.source_error = .Extrusion_Mismatch
				return
			}
			target, target_ok := motion_role_target(ctx.profile.process, move.role)
			if !target_ok {
				st.source_error = .Invalid_Config
				return
			}
			source.base_speed = target.speed
			source.acceleration = target.acceleration
			source.fan_ratio = target.fan_ratio
			max_spd := ctx.profile.printer.maximum_speed
			max_acc := ctx.profile.printer.maximum_acceleration
			if .Ironing in move.flags && i64(ctx.options.ironing_speed_um_s) > 0 {
				source.base_speed = clamp(ctx.options.ironing_speed_um_s, process.minimum_print_speed, max_spd)
			} else {
				if .Outer_Perimeter in move.flags {
					if i64(ctx.options.outer_wall_speed_um_s) > 0 {
						source.base_speed = clamp(ctx.options.outer_wall_speed_um_s, process.minimum_print_speed, max_spd)
					}
					if i64(ctx.options.outer_wall_accel_um_s2) > 0 {
						source.acceleration = min(ctx.options.outer_wall_accel_um_s2, max_acc)
					}
				} else if .Inner_Perimeter in move.flags {
					if i64(ctx.options.inner_wall_speed_um_s) > 0 {
						source.base_speed = clamp(ctx.options.inner_wall_speed_um_s, process.minimum_print_speed, max_spd)
					}
					if i64(ctx.options.inner_wall_accel_um_s2) > 0 {
						source.acceleration = min(ctx.options.inner_wall_accel_um_s2, max_acc)
					}
				} else if move.role == .Top_Skin || move.role == .Top_Bottom_Skin {
					if i64(ctx.options.top_surface_speed_um_s) > 0 {
						source.base_speed = clamp(ctx.options.top_surface_speed_um_s, process.minimum_print_speed, max_spd)
					}
					if i64(ctx.options.top_surface_accel_um_s2) > 0 {
						source.acceleration = min(ctx.options.top_surface_accel_um_s2, max_acc)
					}
				} else if move.role == .Bottom_Skin {
					if i64(ctx.options.internal_solid_speed_um_s) > 0 {
						source.base_speed = clamp(ctx.options.internal_solid_speed_um_s, process.minimum_print_speed, max_spd)
					}
					if i64(ctx.options.internal_solid_accel_um_s2) > 0 {
						source.acceleration = min(ctx.options.internal_solid_accel_um_s2, max_acc)
					}
				} else if move.role == .Bridge {
					if i64(ctx.options.bridge_accel_um_s2) > 0 {
						source.acceleration = min(ctx.options.bridge_accel_um_s2, max_acc)
					}
				}
				if .Small_Perimeter in move.flags && i64(ctx.options.small_perimeter_speed_um_s) > 0 {
					source.base_speed = min(source.base_speed, clamp(ctx.options.small_perimeter_speed_um_s, process.minimum_print_speed, max_spd))
				}
				if layer_index == 0 {
					is_infill_or_skin := move.role == .Sparse_Infill || move.role == .Top_Skin || move.role == .Bottom_Skin || move.role == .Top_Bottom_Skin
					if is_infill_or_skin && i64(ctx.options.initial_layer_infill_speed_um_s) > 0 {
						source.base_speed = min(source.base_speed, clamp(ctx.options.initial_layer_infill_speed_um_s, process.minimum_print_speed, max_spd))
					} else if i64(ctx.options.initial_layer_speed_um_s) > 0 {
						source.base_speed = min(source.base_speed, clamp(ctx.options.initial_layer_speed_um_s, process.minimum_print_speed, max_spd))
					}
					if i64(ctx.options.initial_layer_accel_um_s2) > 0 {
						source.acceleration = min(ctx.options.initial_layer_accel_um_s2, max_acc)
					}
				}
			}
			has_tiered_ov := i64(ctx.options.overhang_tier_speeds_um_s[0]) > 0 ||
				i64(ctx.options.overhang_tier_speeds_um_s[1]) > 0 ||
				i64(ctx.options.overhang_tier_speeds_um_s[2]) > 0 ||
				i64(ctx.options.overhang_tier_speeds_um_s[3]) > 0
			is_ov := false
			ov_tier := 0
			if ctx.options.overhang_slowdown_enabled &&
			   layer_index > 0 &&
			   (move.role == .Perimeter || move.role == .Thin_Wall) {
				if has_tiered_ov {
					ov_tier = motion_segment_overhang_tier(
						move.point_a,
						move.point_b,
						ctx.model_layers[layer_index-1],
					)
					is_ov = ov_tier > 0
				} else if ctx.precomputed_overhangs_ready {
					is_ov = ctx.precomputed_overhangs[move_index]
				} else {
					is_ov = motion_segment_is_overhang(
						move.point_a,
						move.point_b,
						ctx.model_layers[layer_index-1],
					)
				}
			}
			if is_ov {
				tier_spd := ctx.options.overhang_tier_speeds_um_s[ov_tier-1] if (has_tiered_ov && ov_tier >= 1 && ov_tier <= 4) else 0
				if i64(tier_spd) > 0 {
					source.base_speed = min(source.base_speed, clamp(tier_spd, process.minimum_print_speed, max_spd))
				} else {
					pct := ctx.options.overhang_speed_percent
					if pct == 0 || pct > 100 {pct = 50}
					ov_scale := u32((u64(pct)*u64(profiles.RATIO_SCALE))/100)
					source.base_speed = motion_scaled_speed(
						source.base_speed,
						process.minimum_print_speed,
						ov_scale,
					)
				}
				boost_fan := max(source.fan_ratio, process.bridge.fan_ratio)
				source.fan_ratio = clamp(
					boost_fan,
					ctx.profile.material.minimum_fan_ratio,
					ctx.profile.material.maximum_fan_ratio,
				)
			}
			source.extrusion_index = u32(extrusion_cursor)
			source.is_extrusion = true
			extrusion_cursor += 1
			has_extruded = true
		case .Invalid:
			st.source_error = .Invalid_Input
			return
		}
		ctx.sources[move_index] = source
	}
	if extrusion_cursor != ext_end {
		st.source_error = .Extrusion_Mismatch
		return
	}

	scale, base_duration, motion_duration, dwell, timing_ok := motion_layer_timing(
		layer,
		ctx.sources,
		st.travel_extras[:],
		process,
	)
	if !timing_ok {
		st.timing_error = .Arithmetic
		return
	}
	st.scale = scale
	st.base_duration = base_duration
	st.motion_duration = motion_duration
	st.dwell = dwell
}

@(private = "file")
motion_emit_layer_operations :: proc(ctx: ^Motion_Build_Context, layer_index: int) {
	st := &ctx.layer_states[layer_index]
	process := ctx.profile.process.source
	layer := ctx.plan.layers[layer_index]
	operation_start := int(st.op_offset)
	operation_write := operation_start
	move_start := int(layer.move_offset)
	move_end := move_start+int(layer.move_count)
	scale := st.scale
	current_point: polygon.Polygon_Point
	travel_count: u64
	extrusion_count: u64
	dwell_count: u64

	skip_ids := ctx.options.skip_stable_ids
	travel_extras := st.travel_extras[:]
	for move_index in move_start..<move_end {
		move := ctx.plan.moves[move_index]
		source := ctx.sources[move_index]
		current_point = move.point_b
		has_extra := !source.is_extrusion && source.extrusion_index != max(u32)
		extra: Motion_Travel_Extra
		if has_extra {extra = travel_extras[source.extrusion_index]}
		if source.retract_before {
			duration, duration_ok := motion_duration_for_distance_um(
				process.retraction_distance,
				process.retraction_speed,
			)
			if !duration_ok {
				st.emit_error = .Arithmetic
				return
			}
			ctx.result_operations[operation_write] = {
				stable_id         = contracts.INVALID_STABLE_ID if skip_ids else contracts.stable_id_child(move.stable_id, .Motion, 0),
				source_move_id    = move.stable_id,
				source_move_index = u32(move_index),
				path_id           = move.path_id,
				layer_index       = u32(layer_index),
				kind              = .Retract,
				point_a           = move.point_a,
				point_b           = move.point_a,
				speed             = process.retraction_speed,
				acceleration      = process.retraction_acceleration,
				filament_delta_nm = -i128(i64(process.retraction_distance))*1_000,
				duration_us       = duration,
				crosses_exterior  = true,
			}
			operation_write += 1
		}

		if source.has_wipe {
			wipe_dur, wipe_dur_ok := motion_duration_for_length(extra.wipe_length_nm, source.base_speed)
			if !wipe_dur_ok {
				st.emit_error = .Arithmetic
				return
			}
			ctx.result_operations[operation_write] = {
				stable_id         = contracts.INVALID_STABLE_ID if skip_ids else contracts.stable_id_child(move.stable_id, .Motion, 4),
				source_move_id    = move.stable_id,
				source_move_index = u32(move_index),
				path_id           = move.path_id,
				layer_index       = u32(layer_index),
				kind              = .Travel,
				point_a           = move.point_a,
				point_b           = extra.wipe_point,
				speed             = source.base_speed,
				acceleration      = source.acceleration,
				duration_us       = wipe_dur,
				crosses_exterior  = false,
			}
			operation_write += 1
			travel_count += 1
		}

		operation_kind := Motion_Operation_Kind.Travel
		speed := source.base_speed
		filament_delta_nm: i128
		move_point_a := move.point_a
		move_len_nm := source.length_nm
		if move.kind == .Extrude {
			operation_kind = .Extrude
			speed = motion_scaled_speed(source.base_speed, process.minimum_print_speed, scale)
			filament_delta_nm = i128(ctx.extrusion.moves[source.extrusion_index].incremental_filament_nm)
			if filament_delta_nm <= 0 {
				filament_delta_nm = i128(max(u32(10), process.extrusion_length_quantum_nm))
			}
		} else if source.has_wipe {
			move_point_a = extra.wipe_point
			move_len_nm = extra.travel_length_nm
		}
		duration, duration_ok := motion_duration_for_length(move_len_nm, speed)
		if !duration_ok {
			st.emit_error = .Arithmetic
			return
		}
		if move.kind == .Travel && i64(extra.z_hop_um) > 0 {
			hop_dur, hop_ok := motion_duration_for_distance_um(extra.z_hop_um, speed)
			if !hop_ok {
				st.emit_error = .Arithmetic
				return
			}
			duration, duration_ok = motion_checked_add_u64(duration, hop_dur)
			if duration_ok {
				duration, duration_ok = motion_checked_add_u64(duration, hop_dur)
			}
			if !duration_ok {
				st.emit_error = .Arithmetic
				return
			}
		}
		ctx.result_operations[operation_write] = {
			stable_id         = contracts.INVALID_STABLE_ID if skip_ids else contracts.stable_id_child(move.stable_id, .Motion, 1),
			source_move_id    = move.stable_id,
			source_move_index = u32(move_index),
			path_id           = move.path_id,
			layer_index       = u32(layer_index),
			kind              = operation_kind,
			role              = move.role,
			point_a           = move_point_a,
			point_b           = move.point_b,
			z_hop_um          = extra.z_hop_um if move.kind == .Travel else 0,
			speed             = speed,
			acceleration      = source.acceleration,
			fan_ratio         = source.fan_ratio,
			filament_delta_nm = filament_delta_nm,
			duration_us       = duration,
			crosses_exterior  = source.crosses_exterior,
		}
		operation_write += 1
		if move.kind == .Travel {
			travel_count += 1
		} else {
			extrusion_count += 1
		}

		if source.retract_before {
			duration, duration_ok = motion_duration_for_distance_um(
				process.retraction_distance,
				process.recovery_speed,
			)
			if !duration_ok {
				st.emit_error = .Arithmetic
				return
			}
			ctx.result_operations[operation_write] = {
				stable_id         = contracts.INVALID_STABLE_ID if skip_ids else contracts.stable_id_child(move.stable_id, .Motion, 2),
				source_move_id    = move.stable_id,
				source_move_index = u32(move_index),
				path_id           = move.path_id,
				layer_index       = u32(layer_index),
				kind              = .Recover,
				point_a           = move.point_b,
				point_b           = move.point_b,
				speed             = process.recovery_speed,
				acceleration      = process.retraction_acceleration,
				filament_delta_nm = i128(i64(process.retraction_distance))*1_000,
				duration_us       = duration,
				crosses_exterior  = true,
			}
			operation_write += 1
		}
	}

	dwell := st.dwell
	if dwell > 0 {
		ctx.result_operations[operation_write] = {
			stable_id   = contracts.INVALID_STABLE_ID if skip_ids else contracts.stable_id_child(ctx.layer_ids[layer_index], .Motion, 3),
			layer_index = u32(layer_index),
			kind        = .Dwell,
			point_a     = current_point,
			point_b     = current_point,
			duration_us = dwell,
		}
		operation_write += 1
		dwell_count = 1
	}

	layer_operation_count := operation_write-operation_start
	if layer_operation_count != int(st.op_count) {
		st.emit_error = .Arithmetic
		return
	}
	planned_duration, planned_ok := motion_checked_add_u64(st.motion_duration, dwell)
	if !planned_ok {
		st.emit_error = .Arithmetic
		return
	}
	ctx.result_layers[layer_index] = {
		stable_id           = ctx.layer_ids[layer_index],
		layer_index         = u32(layer_index),
		z                   = ctx.layer_z[layer_index],
		operation_offset    = u64(operation_start),
		operation_count     = u32(layer_operation_count),
		speed_scale_ppm     = scale,
		base_duration_us    = st.base_duration,
		motion_duration_us  = st.motion_duration,
		dwell_duration_us   = dwell,
		planned_duration_us = planned_duration,
	}
	st.travel_count = travel_count
	st.extrusion_count = extrusion_count
	st.dwell_count = dwell_count
}

motion_layer_timing :: proc(
	layer: Unified_Planned_Layer,
	sources: []Motion_Source_Move,
	travel_extras: []Motion_Travel_Extra,
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
		motion_layer_duration(layer, sources, travel_extras, process, profiles.RATIO_SCALE)
	if !base_ok {return 0, 0, 0, 0, false}
	if extrusion_count == 0 {
		return profiles.RATIO_SCALE, base_duration, base_duration, 0, true
	}
	target_us := u64(process.minimum_layer_time)*1_000
	if base_duration >= target_us {
		return profiles.RATIO_SCALE, base_duration, base_duration, 0, true
	}
	minimum_duration, minimum_ok :=
		motion_layer_duration(layer, sources, travel_extras, process, 0)
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
			motion_layer_duration(layer, sources, travel_extras, process, middle)
		if !duration_ok {return 0, 0, 0, 0, false}
		if duration >= target_us {
			low = middle
		} else {
			high = middle
		}
	}
	duration_ok: bool
	motion_duration, duration_ok =
		motion_layer_duration(layer, sources, travel_extras, process, low)
	if !duration_ok {return 0, 0, 0, 0, false}
	return low, base_duration, motion_duration, 0, true
}

motion_layer_duration :: proc(
	layer: Unified_Planned_Layer,
	sources: []Motion_Source_Move,
	travel_extras: []Motion_Travel_Extra,
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
		has_extra := !source.is_extrusion && source.extrusion_index != max(u32)
		extra: Motion_Travel_Extra
		if has_extra {extra = travel_extras[source.extrusion_index]}
		if source.is_extrusion {
			speed = motion_scaled_speed(
				source.base_speed,
				process.minimum_print_speed,
				scale,
			)
		} else if source.has_wipe {
			move_len_nm = extra.travel_length_nm
		}
		duration, duration_ok :=
			motion_duration_for_length(move_len_nm, speed)
		if !duration_ok {return 0, false}
		total, duration_ok = motion_checked_add_u64(total, duration)
		if !duration_ok {return 0, false}
		if source.has_wipe {
			wipe_dur, wipe_ok := motion_duration_for_length(extra.wipe_length_nm, source.base_speed)
			if !wipe_ok {return 0, false}
			total, duration_ok = motion_checked_add_u64(total, wipe_dur)
			if !duration_ok {return 0, false}
		}
		if !source.is_extrusion && i64(extra.z_hop_um) > 0 {
			hop_dur, hop_ok := motion_duration_for_distance_um(extra.z_hop_um, speed)
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

	// Collect overhang and travel-crossing queries in a single pass over moves, then dispatch both
	// in one Metal command buffer sharing the uploaded edges and layer ranges.
	want_ov := compute_overhangs && len(model_layers) > 1
	pip_queries := make([dynamic]gpu.Point_Query, 0, len(plan.moves)/2 if want_ov else 0, context.temp_allocator)
	pip_indices := make([dynamic]int, 0, len(plan.moves)/4 if want_ov else 0, context.temp_allocator)
	t_queries := make([dynamic]gpu.Travel_Query, 0, int(plan.travel_move_count), context.temp_allocator)
	t_indices := make([dynamic]int, 0, int(plan.travel_move_count), context.temp_allocator)

	for layer, li in plan.layers {
		ms := int(layer.move_offset)
		me := ms + int(layer.move_count)
		check_ov := want_ov && li > 0 && len(model_layers[li - 1].paths) > 0
		prev_li := u32(li - 1) if li > 0 else 0
		for mi in ms..<me {
			m := plan.moves[mi]
			if m.kind == .Travel {
				append(&t_indices, mi)
				append(&t_queries, gpu.Travel_Query{
					ax        = i64(m.point_a.x),
					ay        = i64(m.point_a.y),
					bx        = i64(m.point_b.x),
					by        = i64(m.point_b.y),
					layer_idx = u32(li),
				})
			} else if check_ov && m.kind == .Extrude && (m.role == .Perimeter || m.role == .Thin_Wall) {
				ax, ay := i64(m.point_a.x), i64(m.point_a.y)
				bx, by := i64(m.point_b.x), i64(m.point_b.y)
				append(&pip_indices, mi)
				append(&pip_queries, gpu.Point_Query{x2 = ax + bx, y2 = ay + by, layer_idx = prev_li})
				append(&pip_queries, gpu.Point_Query{x2 = (3*ax + bx)/2, y2 = (3*ay + by)/2, layer_idx = prev_li})
				append(&pip_queries, gpu.Point_Query{x2 = (ax + 3*bx)/2, y2 = (ay + 3*by)/2, layer_idx = prev_li})
			}
		}
	}

	pip_out := make([]u8, len(pip_queries), context.temp_allocator)
	t_out := make([]u8, len(t_queries), context.temp_allocator)
	if !gpu.metal_batch_motion_queries(edges, ranges, pip_queries[:], pip_out, t_queries[:], t_out) {
		return
	}

	if want_ov {
		ov_flags = make([]bool, len(plan.moves), allocator)
		if ov_flags != nil {
			for mi, idx in pip_indices {
				base := idx * 3
				unsupported := 0
				if pip_out[base + 0] == 0 {unsupported += 1}
				if pip_out[base + 1] == 0 {unsupported += 1}
				if pip_out[base + 2] == 0 {unsupported += 1}
				ov_flags[mi] = unsupported >= 2
			}
			ov_ok = true
		}
	}

	trv_flags = make([]bool, len(plan.moves), allocator)
	if trv_flags != nil {
		for mi, idx in t_indices {
			trv_flags[mi] = t_out[idx] != 0
		}
		trv_ok = true
	}
	return
}

// Returns 0..4 unsupported sample count across 4 interior points (20%, 40%, 60%, 80%).
motion_segment_overhang_tier :: proc(
	a, b: polygon.Polygon_Point,
	prev_layer: polygon.Polygon_Set,
) -> int {
	if len(prev_layer.paths) == 0 {return 0}
	ax, ay := i64(a.x), i64(a.y)
	bx, by := i64(b.x), i64(b.y)
	unsupported := 0
	// Exact doubled coordinates for t = 1/5, 2/5, 3/5, 4/5: 2*(a + t*(b-a)) = (2*(5-k)*a + 2*k*b)/5
	for k in i64(1)..=i64(4) {
		x2 := (2*(5-k)*ax + 2*k*bx) / 5
		y2 := (2*(5-k)*ay + 2*k*by) / 5
		if !bridge_polygon_contains_twice(prev_layer, x2, y2) {
			unsupported += 1
		}
	}
	return unsupported
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

// Detours exterior-crossing travel moves along the enclosing layer contour when both endpoints
// belong to the same island and the detour stays within `max_detour_um` (0 = 3x direct distance).
motion_plan_apply_combing :: proc(
	motion: ^Motion_Plan_Result,
	model_layers: []polygon.Polygon_Set,
	max_detour_um: contracts.Micrometres,
	allocator := context.allocator,
) -> u64 {
	if motion == nil || len(motion.layers) == 0 || len(motion.operations) == 0 {return 0}
	layer_count := len(motion.layers)

	Layer_Comb_Result :: struct {
		ops:           []Motion_Operation,
		owned:         bool,
		detoured:      u64,
		added_travels: u64,
		dur_delta:     i64,
	}
	results := make([]Layer_Comb_Result, layer_count, allocator)
	defer {
		for r in results {
			if r.owned {delete(r.ops, allocator)}
		}
		delete(results, allocator)
	}

	Comb_Par_Ctx :: struct {
		motion:        ^Motion_Plan_Result,
		model_layers:  []polygon.Polygon_Set,
		max_detour_um: contracts.Micrometres,
		results:       []Layer_Comb_Result,
		allocator:     mem.Allocator,
	}
	cctx := Comb_Par_Ctx{
		motion        = motion,
		model_layers  = model_layers,
		max_detour_um = max_detour_um,
		results       = results,
		allocator     = allocator,
	}

	parallel_for(layer_count, &cctx, proc(c: ^Comb_Par_Ctx, li: int) {
		layer := c.motion.layers[li]
		op_start := int(layer.operation_offset)
		op_end := op_start + int(layer.operation_count)
		orig := c.motion.operations[op_start:op_end]
		ml := c.model_layers[li] if li < len(c.model_layers) else polygon.Polygon_Set{}
		if len(ml.paths) == 0 || len(orig) == 0 {
			c.results[li] = {ops = orig}
			return
		}
		has_cand := false
		for op in orig {
			if op.kind == .Travel && op.crosses_exterior {
				has_cand = true
				break
			}
		}
		if !has_cand {
			c.results[li] = {ops = orig}
			return
		}

		Outer_Ring :: struct {
			ring:      []polygon.Polygon_Point,
			cum:       []f64, // len == len(ring), cum[0] = 0
			total_len: f64,
		}
		outer_rings := make([dynamic]Outer_Ring, 0, len(ml.paths), context.temp_allocator)
		for mp in ml.paths {
			if mp.count < 3 {continue}
			ring := ml.points[mp.offset:mp.offset+mp.count]
			if polygon.polygon_path_area_2(ring) <= 0 {continue}
			n := len(ring)
			cum := make([]f64, n, context.temp_allocator)
			total := 0.0
			for k in 0..<n {
				cum[k] = total
				a := ring[k]
				b := ring[(k + 1) % n]
				edx := f64(i64(b.x) - i64(a.x))
				edy := f64(i64(b.y) - i64(a.y))
				total += math.sqrt(edx*edx + edy*edy)
			}
			append(&outer_rings, Outer_Ring{ring = ring, cum = cum, total_len = total})
		}
		if len(outer_rings) == 0 {
			c.results[li] = {ops = orig}
			return
		}

		out_ops := make([dynamic]Motion_Operation, 0, len(orig) + 32, c.allocator)
		detoured: u64
		added_travels: u64
		dur_delta: i64

		MAX_NEAR_SQ :: 5_000.0 * 5_000.0
		for op in orig {
			if op.kind != .Travel || !op.crosses_exterior {
				append(&out_ops, op)
				continue
			}
			a, b := op.point_a, op.point_b
			adx := f64(i64(b.x) - i64(a.x))
			ady := f64(i64(b.y) - i64(a.y))
			direct_sq := adx*adx + ady*ady
			if direct_sq < 500.0 * 500.0 {
				append(&out_ops, op)
				continue
			}
			direct_len := math.sqrt(direct_sq)
			best_ring_idx := -1
			best_va, best_vb := 0, 0
			best_detour := f64(c.max_detour_um) if i64(c.max_detour_um) > 0 else direct_len * 3.0
			best_forward := true
			ax_f, ay_f := f64(i64(a.x)), f64(i64(a.y))
			bx_f, by_f := f64(i64(b.x)), f64(i64(b.y))

			for oring, ridx in outer_rings {
				ring := oring.ring
				va, vb := 0, 0
				dx0a := f64(i64(ring[0].x)) - ax_f
				dy0a := f64(i64(ring[0].y)) - ay_f
				da_sq := dx0a*dx0a + dy0a*dy0a
				dx0b := f64(i64(ring[0].x)) - bx_f
				dy0b := f64(i64(ring[0].y)) - by_f
				db_sq := dx0b*dx0b + dy0b*dy0b
				for vi in 1..<len(ring) {
					rx := f64(i64(ring[vi].x))
					ry := f64(i64(ring[vi].y))
					dxa, dya := rx - ax_f, ry - ay_f
					dsqa := dxa*dxa + dya*dya
					if dsqa < da_sq {da_sq = dsqa; va = vi}
					dxb, dyb := rx - bx_f, ry - by_f
					dsqb := dxb*dxb + dyb*dyb
					if dsqb < db_sq {db_sq = dsqb; vb = vi}
				}
				if da_sq > MAX_NEAR_SQ || db_sq > MAX_NEAR_SQ || va == vb {continue}
				ends_len := math.sqrt(da_sq) + math.sqrt(db_sq)
				arc_fwd := (oring.cum[vb] - oring.cum[va]) if vb >= va else (oring.total_len - (oring.cum[va] - oring.cum[vb]))
				arc_bwd := oring.total_len - arc_fwd
				fwd_len := ends_len + arc_fwd
				bwd_len := ends_len + arc_bwd
				if fwd_len <= bwd_len && fwd_len < best_detour {
					best_detour = fwd_len
					best_ring_idx = ridx
					best_va = va
					best_vb = vb
					best_forward = true
				} else if bwd_len < fwd_len && bwd_len < best_detour {
					best_detour = bwd_len
					best_ring_idx = ridx
					best_va = va
					best_vb = vb
					best_forward = false
				}
			}
			if best_ring_idx < 0 {
				append(&out_ops, op)
				continue
			}
			ring := outer_rings[best_ring_idx].ring
			n := len(ring)
			step_count := (best_vb - best_va + n) % n if best_forward else (best_va - best_vb + n) % n
			stride := max(1, (step_count + 31) / 32)
			cur := a
			emitted_here: u64 = 0
			for s := 0; s <= step_count; s += stride {
				idx := (best_va + s) % n if best_forward else (best_va + n - (s % n)) % n
				nxt := ring[idx]
				if nxt == cur {continue}
				seg_op := op
				seg_op.point_a = cur
				seg_op.point_b = nxt
				seg_op.crosses_exterior = false
				seg_op.z_hop_um = 0
				append(&out_ops, seg_op)
				cur = nxt
				emitted_here += 1
			}
			if cur != b {
				seg_op := op
				seg_op.point_a = cur
				seg_op.point_b = b
				seg_op.crosses_exterior = false
				seg_op.z_hop_um = 0
				append(&out_ops, seg_op)
				emitted_here += 1
			}
			if emitted_here == 0 {
				append(&out_ops, op)
			} else {
				old_dur := op.duration_us
				new_dur: u64 = 0
				sub_start := len(out_ops) - int(emitted_here)
				spd := max(f64(1.0), f64(i64(op.speed)))
				for si in sub_start..<len(out_ops) {
					sub := &out_ops[si]
					sdx := f64(i64(sub.point_b.x) - i64(sub.point_a.x))
					sdy := f64(i64(sub.point_b.y) - i64(sub.point_a.y))
					seg_um := math.sqrt(sdx*sdx + sdy*sdy)
					d_us := max(u64(1), u64(math.round(seg_um * 1_000_000.0 / spd)))
					sub.duration_us = d_us
					new_dur += d_us
				}
				dur_delta += i64(new_dur) - i64(old_dur)
				detoured += 1
				added_travels += emitted_here - 1
			}
		}
		if detoured > 0 {
			c.results[li] = {
				ops           = out_ops[:],
				owned         = true,
				detoured      = detoured,
				added_travels = added_travels,
				dur_delta     = dur_delta,
			}
		} else {
			delete(out_ops)
			c.results[li] = {ops = orig}
		}
	})

	total_detoured: u64
	total_added: u64
	total_ops := 0
	for r in results {
		total_detoured += r.detoured
		total_added += r.added_travels
		total_ops += len(r.ops)
	}
	if total_detoured == 0 {return 0}

	new_ops := features_make_non_zeroed([]Motion_Operation, total_ops, allocator)
	if new_ops == nil {return 0}
	write := 0
	for r, li in results {
		layer := &motion.layers[li]
		layer.operation_offset = u64(write)
		layer.operation_count = u32(len(r.ops))
		if len(r.ops) > 0 {
			copy(new_ops[write:write+len(r.ops)], r.ops)
			write += len(r.ops)
		}
		if r.dur_delta >= 0 {
			d := u64(r.dur_delta)
			layer.motion_duration_us += d
			layer.planned_duration_us += d
			motion.total_motion_duration_us += d
			motion.total_planned_duration_us += d
		} else {
			d := u64(-r.dur_delta)
			layer.motion_duration_us -= d
			layer.planned_duration_us -= d
			motion.total_motion_duration_us -= d
			motion.total_planned_duration_us -= d
		}
	}
	delete(motion.operations, allocator)
	motion.operations = new_ops
	motion.travel_count += total_added
	return total_detoured
}

motion_plan_result_destroy :: proc(
	result: ^Motion_Plan_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.operations, allocator)
	result^ = {}
}
