package features

import contracts "../contracts"
import geometry "../geometry"
import profiles "../profiles"

EXTRUSION_PI_SCALE :: u64(1_000_000_000)
EXTRUSION_PI_SCALED :: u64(3_141_592_654)

Extrusion_Cross_Section_Model :: enum u8 {
	Invalid,
	Rounded_Bead,
}

Extrusion_Layer :: struct {
	move_offset: u64,
	move_count:  u32,
}

Extrusion_Move :: struct {
	stable_id:                  contracts.Stable_ID,
	planned_move_id:            contracts.Stable_ID,
	planned_move_index:         u32,
	path_id:                    contracts.Stable_ID,
	layer_index:                u32,
	role:                       profiles.Printable_Role,
	flow_ratio:                 profiles.Ratio_Ppm,
	layer_height:               contracts.Micrometres,
	line_width_a:               contracts.Micrometres,
	line_width_b:               contracts.Micrometres,
	distance_squared_um_2:      u128,
	path_length_nm:             u64,
	length_error_squared_nm_2:  u128,
	cross_section_numerator:    u128,
	volume_numerator:           u128,
	volume_cubic_um:            u64,
	volume_error_numerator:     u128,
	incremental_filament_nm:    u64,
	remainder_numerator_after:  u128,
}

Extrusion_Result :: struct {
	policy:                       profiles.Extrusion_Accumulation_Policy,
	cross_section_model:          Extrusion_Cross_Section_Model,
	pi_scale:                     u64,
	pi_scaled:                    u64,
	filament_diameter:            contracts.Micrometres,
	length_quantum_nm:            u32,
	cross_section_denominator:    u64,
	volume_denominator:           u64,
	filament_length_denominator:  u128,
	quantized_length_denominator: u128,
	layers:                       []Extrusion_Layer,
	moves:                        []Extrusion_Move,
	total_volume_numerator:       u128,
	total_volume_cubic_um:        u64,
	total_volume_error_numerator: u128,
	total_filament_nm:            u128,
	final_remainder_numerator:    u128,
}

Extrusion_Limits :: struct {
	max_moves: u64,
}

DEFAULT_EXTRUSION_LIMITS :: Extrusion_Limits{
	max_moves = 4_000_000_000,
}

Extrusion_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Move_Limit,
	Allocation_Failed,
	Arithmetic,
}

extrusion_calculate :: proc(
	plan: Unified_Path_Plan_Result,
	layer_heights: []contracts.Micrometres,
	material: profiles.Material_Profile,
	process: profiles.Resolved_Process_Profile,
	limits := DEFAULT_EXTRUSION_LIMITS,
	allocator := context.allocator,
) -> (Extrusion_Result, Extrusion_Error) {
	if process.source.extrusion_accumulation !=
		.Volume_Then_Fixed_Point_Length ||
	   process.source.extrusion_length_quantum_nm == 0 ||
	   i64(material.filament_diameter) <= 0 {
		return {}, .Invalid_Config
	}
	if len(layer_heights) != len(plan.layers) ||
	   u64(len(plan.moves)) > u64(max(u32)) ||
	   !extrusion_plan_valid(plan) {
		return {}, .Invalid_Input
	}
	for height in layer_heights {
		if i64(height) <= 0 {return {}, .Invalid_Input}
	}
	extrude_move_count: u64
	for move in plan.moves {
		if move.kind == .Extrude {
			extrude_move_count += 1
		} else if move.kind != .Travel {
			return {}, .Invalid_Input
		}
	}
	if extrude_move_count != plan.extrude_move_count {
		return {}, .Invalid_Input
	}
	if extrude_move_count > limits.max_moves {
		return {}, .Move_Limit
	}
	if extrude_move_count > u64(max(int)) {
		return {}, .Arithmetic
	}
	cross_section_denominator :=
		u128(4)*u128(EXTRUSION_PI_SCALE)
	volume_denominator :=
		cross_section_denominator*u128(1_000)*u128(profiles.RATIO_SCALE)
	if cross_section_denominator > u128(max(u64)) ||
	   volume_denominator > u128(max(u64)) {
		return {}, .Arithmetic
	}
	filament_diameter := u128(i64(material.filament_diameter))
	filament_length_denominator, filament_ok :=
		extrusion_checked_multiply(
			u128(EXTRUSION_PI_SCALED),
			filament_diameter*filament_diameter,
		)
	if !filament_ok {
		return {}, .Arithmetic
	}
	filament_length_denominator, filament_ok =
		extrusion_checked_multiply(
			filament_length_denominator,
			u128(profiles.RATIO_SCALE),
		)
	if !filament_ok || filament_length_denominator == 0 {
		return {}, .Arithmetic
	}
	quantized_length_denominator, quantum_ok :=
		extrusion_checked_multiply(
			filament_length_denominator,
			u128(process.source.extrusion_length_quantum_nm),
		)
	if !quantum_ok {return {}, .Arithmetic}

	result := Extrusion_Result{
		policy = process.source.extrusion_accumulation,
		cross_section_model = .Rounded_Bead,
		pi_scale = EXTRUSION_PI_SCALE,
		pi_scaled = EXTRUSION_PI_SCALED,
		filament_diameter = material.filament_diameter,
		length_quantum_nm =
			process.source.extrusion_length_quantum_nm,
		cross_section_denominator =
			u64(cross_section_denominator),
		volume_denominator = u64(volume_denominator),
		filament_length_denominator =
			filament_length_denominator,
		quantized_length_denominator =
			quantized_length_denominator,
	}
	result.layers = make(
		[]Extrusion_Layer,
		len(plan.layers),
		allocator,
	)
	result.moves = make(
		[]Extrusion_Move,
		int(extrude_move_count),
		allocator,
	)
	if len(result.layers) > 0 && result.layers == nil ||
	   extrude_move_count > 0 && result.moves == nil {
		extrusion_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	move_write := 0
	remainder: u128
	for plan_layer, layer_index in plan.layers {
		layer_move_start := move_write
		move_start := int(plan_layer.move_offset)
		move_end := move_start+int(plan_layer.move_count)
		for planned_move_index in move_start..<move_end {
			move := plan.moves[planned_move_index]
			if move.kind == .Travel {continue}
			flow_ratio, flow_ok :=
				extrusion_role_flow_ratio(process, move.role)
			if !flow_ok {
				extrusion_result_destroy(&result, allocator)
				return {}, .Invalid_Config
			}
			height := layer_heights[layer_index]
			if i64(move.line_width_a) < i64(height) ||
			   i64(move.line_width_b) < i64(height) {
				extrusion_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			distance_squared := path_plan_distance_2(
				move.point_a,
				move.point_b,
			)
			scaled_distance, distance_ok :=
				extrusion_checked_multiply(
					distance_squared,
					1_000_000,
				)
			if !distance_ok {
				extrusion_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			path_length_nm, length_error, length_ok :=
				extrusion_integer_sqrt_round(scaled_distance)
			if !length_ok || path_length_nm == 0 {
				extrusion_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			cross_section_numerator, cross_section_ok :=
				extrusion_cross_section_numerator(
					height,
					move.line_width_a,
					move.line_width_b,
				)
			if !cross_section_ok {
				extrusion_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			volume_numerator, volume_ok :=
				extrusion_checked_multiply(
					cross_section_numerator,
					u128(path_length_nm),
				)
			if volume_ok {
				volume_numerator, volume_ok =
					extrusion_checked_multiply(
						volume_numerator,
						u128(u32(flow_ratio)),
					)
			}
			if !volume_ok {
				extrusion_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			volume_cubic_um, volume_error, volume_round_ok :=
				extrusion_round_ratio_u64(
					volume_numerator,
					volume_denominator,
				)
			if !volume_round_ok {
				extrusion_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			if remainder > max(u128)-volume_numerator {
				extrusion_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			accumulated := remainder+volume_numerator
			quantized_units :=
				accumulated/quantized_length_denominator
			if quantized_units >
			   u128(max(u64))/
				u128(result.length_quantum_nm) {
				extrusion_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			incremental_filament_nm :=
				quantized_units*u128(result.length_quantum_nm)
			remainder =
				accumulated%quantized_length_denominator
			if result.total_volume_numerator >
			   max(u128)-volume_numerator ||
			   result.total_filament_nm >
			   max(u128)-incremental_filament_nm {
				extrusion_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			result.total_volume_numerator += volume_numerator
			result.total_filament_nm +=
				incremental_filament_nm
			result.moves[move_write] = {
				stable_id = contracts.stable_id_child(
					move.stable_id,
					.Feature,
					0,
				),
				planned_move_id = move.stable_id,
				planned_move_index = u32(planned_move_index),
				path_id = move.path_id,
				layer_index = u32(layer_index),
				role = move.role,
				flow_ratio = flow_ratio,
				layer_height = height,
				line_width_a = move.line_width_a,
				line_width_b = move.line_width_b,
				distance_squared_um_2 = distance_squared,
				path_length_nm = path_length_nm,
				length_error_squared_nm_2 = length_error,
				cross_section_numerator =
					cross_section_numerator,
				volume_numerator = volume_numerator,
				volume_cubic_um = volume_cubic_um,
				volume_error_numerator = volume_error,
				incremental_filament_nm =
					u64(incremental_filament_nm),
				remainder_numerator_after = remainder,
			}
			move_write += 1
		}
		layer_move_count := move_write-layer_move_start
		if layer_move_count > int(max(u32)) {
			extrusion_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			move_offset = u64(layer_move_start),
			move_count = u32(layer_move_count),
		}
	}
	if move_write != len(result.moves) {
		extrusion_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	total_volume, total_volume_error, total_volume_ok :=
		extrusion_round_ratio_u64(
			result.total_volume_numerator,
			volume_denominator,
		)
	if !total_volume_ok {
		extrusion_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	result.total_volume_cubic_um = total_volume
	result.total_volume_error_numerator = total_volume_error
	result.final_remainder_numerator = remainder
	return result, .None
}

extrusion_cross_section_numerator :: proc(
	height, width_a, width_b: contracts.Micrometres,
) -> (u128, bool) {
	if i64(height) <= 0 ||
	   i64(width_a) < i64(height) ||
	   i64(width_b) < i64(height) {
		return 0, false
	}
	h := u128(i64(height))
	width_sum := u128(i64(width_a))+u128(i64(width_b))
	core_width_twice := width_sum-h*2
	core, core_ok := extrusion_checked_multiply(h*2, core_width_twice)
	if core_ok {
		core, core_ok = extrusion_checked_multiply(
			core,
			u128(EXTRUSION_PI_SCALE),
		)
	}
	caps, caps_ok := extrusion_checked_multiply(
		u128(EXTRUSION_PI_SCALED),
		h*h,
	)
	if !core_ok || !caps_ok || core > max(u128)-caps {
		return 0, false
	}
	return core+caps, true
}

extrusion_integer_sqrt_round :: proc(
	value: u128,
) -> (u64, u128, bool) {
	if value == 0 {return 0, 0, true}
	remainder := value
	root: u128
	bit := u128(1)<<126
	for bit > remainder {bit >>= 2}
	for bit != 0 {
		if remainder >= root+bit {
			remainder -= root+bit
			root = (root>>1)+bit
		} else {
			root >>= 1
		}
		bit >>= 2
	}
	if root > u128(max(u64)) {return 0, 0, false}
	floor := root
	floor_squared := floor*floor
	lower_error := value-floor_squared
	rounded := floor
	upper_delta := floor*2+1
	if lower_error*2 >= upper_delta {rounded += 1}
	if rounded > u128(max(u64)) {return 0, 0, false}
	rounded_squared := rounded*rounded
	error := value-rounded_squared
	if rounded_squared > value {error = rounded_squared-value}
	return u64(rounded), error, true
}

extrusion_round_ratio_u64 :: proc(
	numerator, denominator: u128,
) -> (u64, u128, bool) {
	if denominator == 0 ||
	   numerator > max(u128)-denominator/2 {
		return 0, 0, false
	}
	rounded := (numerator+denominator/2)/denominator
	if rounded > u128(max(u64)) {return 0, 0, false}
	product := rounded*denominator
	error := numerator-product
	if product > numerator {error = product-numerator}
	return u64(rounded), error, true
}

extrusion_checked_multiply :: proc(a, b: u128) -> (u128, bool) {
	if a != 0 && b > max(u128)/a {return 0, false}
	return a*b, true
}

extrusion_role_flow_ratio :: proc(
	process: profiles.Resolved_Process_Profile,
	role: profiles.Printable_Role,
) -> (profiles.Ratio_Ppm, bool) {
	target: profiles.Role_Target
	switch role {
	case .Perimeter:
		target = process.source.perimeter
	case .Bridge:
		target = process.source.bridge
	case .Gap, .Thin_Wall:
		target = process.source.gap
	case .Bottom_Skin, .Top_Skin, .Top_Bottom_Skin:
		target = process.source.skin
	case .Sparse_Infill:
		target = process.source.sparse_infill
	case .Support:
		target = process.source.support
	case .Support_Interface:
		target = process.source.support_interface
	case .Invalid:
		return 0, false
	}
	if u32(target.flow_ratio) == 0 ||
	   u32(target.flow_ratio) > profiles.RATIO_SCALE*2 {
		return 0, false
	}
	return target.flow_ratio, true
}

extrusion_plan_valid :: proc(plan: Unified_Path_Plan_Result) -> bool {
	expected_move_offset: u64
	extrude_count: u64
	travel_count: u64
	for layer, layer_index in plan.layers {
		if layer.move_offset != expected_move_offset ||
		   layer.move_offset+u64(layer.move_count) >
			u64(len(plan.moves)) {
			return false
		}
		move_start := int(layer.move_offset)
		move_end := move_start+int(layer.move_count)
		for move in plan.moves[move_start:move_end] {
			if move.stable_id == contracts.INVALID_STABLE_ID ||
			   move.path_id == contracts.INVALID_STABLE_ID ||
			   geometry.point_2_validate({
				move.point_a.x,
				move.point_a.y,
			   }) != .None ||
			   geometry.point_2_validate({
				move.point_b.x,
				move.point_b.y,
			   }) != .None ||
			   move.point_a == move.point_b {
				return false
			}
			if move.kind == .Travel {
				if move.role != .Invalid ||
				   move.source_edge_index != max(u32) ||
				   move.line_width_a != 0 ||
				   move.line_width_b != 0 {
					return false
				}
				travel_count += 1
			} else if move.kind == .Extrude {
				if move.role == .Invalid ||
				   i64(move.line_width_a) <= 0 ||
				   i64(move.line_width_b) <= 0 {
					return false
				}
				extrude_count += 1
			} else {
				return false
			}
		}
		expected_move_offset += u64(layer.move_count)
		_ = layer_index
	}
	return expected_move_offset == u64(len(plan.moves)) &&
		extrude_count == plan.extrude_move_count &&
		travel_count == plan.travel_move_count
}

extrusion_result_destroy :: proc(
	result: ^Extrusion_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.moves, allocator)
	result^ = {}
}
