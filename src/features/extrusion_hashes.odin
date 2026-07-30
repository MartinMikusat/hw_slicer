package features

import contracts "../contracts"
import profiles "../profiles"

SCHEMA_VERSION_EXTRUSION_HASH :: u32(1)

Extrusion_Hash_Dependencies :: struct {
	path_plan_hash:      contracts.Content_Hash,
	layer_schedule_hash: contracts.Content_Hash,
	material_hash:       contracts.Content_Hash,
	process_hash:        contracts.Content_Hash,
}

extrusion_result_hash :: proc(
	path_plan_hash: contracts.Content_Hash,
	layer_schedule_hash: contracts.Content_Hash,
	material_hash: contracts.Content_Hash,
	process_hash: contracts.Content_Hash,
	plan: Unified_Path_Plan_Result,
	layer_heights: []contracts.Micrometres,
	material: profiles.Material_Profile,
	process: profiles.Resolved_Process_Profile,
	result: Extrusion_Result,
	limits := DEFAULT_EXTRUSION_LIMITS,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	expected, expected_error := extrusion_calculate(
		plan,
		layer_heights,
		material,
		process,
		limits,
		allocator,
	)
	if expected_error != .None {return {}, false}
	defer extrusion_result_destroy(&expected, allocator)
	if result.policy != expected.policy ||
	   result.cross_section_model != expected.cross_section_model ||
	   result.pi_scale != expected.pi_scale ||
	   result.pi_scaled != expected.pi_scaled ||
	   result.filament_diameter != expected.filament_diameter ||
	   result.length_quantum_nm != expected.length_quantum_nm ||
	   result.cross_section_denominator !=
		expected.cross_section_denominator ||
	   result.volume_denominator != expected.volume_denominator ||
	   result.filament_length_denominator !=
		expected.filament_length_denominator ||
	   result.quantized_length_denominator !=
		expected.quantized_length_denominator ||
	   result.total_volume_numerator !=
		expected.total_volume_numerator ||
	   result.total_volume_cubic_um != expected.total_volume_cubic_um ||
	   result.total_volume_error_numerator !=
		expected.total_volume_error_numerator ||
	   result.total_filament_nm != expected.total_filament_nm ||
	   result.final_remainder_numerator !=
		expected.final_remainder_numerator ||
	   len(result.layers) != len(expected.layers) ||
	   len(result.moves) != len(expected.moves) {
		return {}, false
	}
	for layer, layer_index in result.layers {
		if layer != expected.layers[layer_index] {
			return {}, false
		}
	}
	for move, move_index in result.moves {
		if move != expected.moves[move_index] {
			return {}, false
		}
	}
	return extrusion_result_content_hash(
		{
			path_plan_hash = path_plan_hash,
			layer_schedule_hash = layer_schedule_hash,
			material_hash = material_hash,
			process_hash = process_hash,
		},
		result,
	)
}

extrusion_result_content_hash :: proc(
	dependencies: Extrusion_Hash_Dependencies,
	result: Extrusion_Result,
) -> (contracts.Content_Hash, bool) {
	if !extrusion_result_structurally_valid(result) {return {}, false}
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/extrusion",
		SCHEMA_VERSION_EXTRUSION_HASH,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.path_plan_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.layer_schedule_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.material_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.process_hash,
	)
	contracts.canonical_hash_append_u8(&hash, u8(result.policy))
	contracts.canonical_hash_append_u8(
		&hash,
		u8(result.cross_section_model),
	)
	contracts.canonical_hash_append_u64(&hash, result.pi_scale)
	contracts.canonical_hash_append_u64(&hash, result.pi_scaled)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.filament_diameter),
	)
	contracts.canonical_hash_append_u32(
		&hash,
		result.length_quantum_nm,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.cross_section_denominator,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.volume_denominator,
	)
	bridge_direction_hash_append_u128(
		&hash,
		result.filament_length_denominator,
	)
	bridge_direction_hash_append_u128(
		&hash,
		result.quantized_length_denominator,
	)
	bridge_direction_hash_append_u128(
		&hash,
		result.total_volume_numerator,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.total_volume_cubic_um,
	)
	bridge_direction_hash_append_u128(
		&hash,
		result.total_volume_error_numerator,
	)
	bridge_direction_hash_append_u128(
		&hash,
		result.total_filament_nm,
	)
	bridge_direction_hash_append_u128(
		&hash,
		result.final_remainder_numerator,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.move_offset)
		contracts.canonical_hash_append_u32(&hash, layer.move_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.moves)))
	for move in result.moves {
		contracts.canonical_hash_append_stable_id(&hash, move.stable_id)
		contracts.canonical_hash_append_stable_id(
			&hash,
			move.planned_move_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			move.planned_move_index,
		)
		contracts.canonical_hash_append_stable_id(&hash, move.path_id)
		contracts.canonical_hash_append_u32(&hash, move.layer_index)
		contracts.canonical_hash_append_u8(&hash, u8(move.role))
		contracts.canonical_hash_append_u32(
			&hash,
			u32(move.flow_ratio),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(move.layer_height),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(move.line_width_a),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(move.line_width_b),
		)
		bridge_direction_hash_append_u128(
			&hash,
			move.distance_squared_um_2,
		)
		contracts.canonical_hash_append_u64(
			&hash,
			move.path_length_nm,
		)
		bridge_direction_hash_append_u128(
			&hash,
			move.length_error_squared_nm_2,
		)
		bridge_direction_hash_append_u128(
			&hash,
			move.cross_section_numerator,
		)
		bridge_direction_hash_append_u128(
			&hash,
			move.volume_numerator,
		)
		contracts.canonical_hash_append_u64(
			&hash,
			move.volume_cubic_um,
		)
		bridge_direction_hash_append_u128(
			&hash,
			move.volume_error_numerator,
		)
		contracts.canonical_hash_append_u64(
			&hash,
			move.incremental_filament_nm,
		)
		bridge_direction_hash_append_u128(
			&hash,
			move.remainder_numerator_after,
		)
	}
	return contracts.canonical_hash_final(&hash), true
}

extrusion_result_structurally_valid :: proc(
	result: Extrusion_Result,
) -> bool {
	if result.policy != .Volume_Then_Fixed_Point_Length ||
	   result.cross_section_model != .Rounded_Bead ||
	   result.pi_scale != EXTRUSION_PI_SCALE ||
	   result.pi_scaled != EXTRUSION_PI_SCALED ||
	   i64(result.filament_diameter) <= 0 ||
	   result.length_quantum_nm == 0 ||
	   u64(len(result.layers)) > u64(max(u32)) {
		return false
	}
	cross_section_denominator :=
		u128(4)*u128(EXTRUSION_PI_SCALE)
	volume_denominator, volume_denominator_ok :=
		extrusion_checked_multiply(
			cross_section_denominator,
			u128(1_000)*u128(profiles.RATIO_SCALE),
		)
	filament_diameter := u128(i64(result.filament_diameter))
	filament_length_denominator, filament_denominator_ok :=
		extrusion_checked_multiply(
			u128(EXTRUSION_PI_SCALED),
			filament_diameter*filament_diameter,
		)
	if filament_denominator_ok {
		filament_length_denominator, filament_denominator_ok =
			extrusion_checked_multiply(
				filament_length_denominator,
				u128(profiles.RATIO_SCALE),
			)
	}
	quantized_length_denominator, quantized_denominator_ok :=
		extrusion_checked_multiply(
			filament_length_denominator,
			u128(result.length_quantum_nm),
		)
	if !volume_denominator_ok ||
	   !filament_denominator_ok ||
	   !quantized_denominator_ok ||
	   cross_section_denominator > u128(max(u64)) ||
	   volume_denominator > u128(max(u64)) ||
	   result.cross_section_denominator !=
		u64(cross_section_denominator) ||
	   result.volume_denominator != u64(volume_denominator) ||
	   result.filament_length_denominator !=
		filament_length_denominator ||
	   result.quantized_length_denominator !=
		quantized_length_denominator {
		return false
	}

	expected_move_offset: u64
	for layer, layer_index in result.layers {
		if layer.move_offset != expected_move_offset ||
		   layer.move_offset >
			max(u64)-u64(layer.move_count) ||
		   layer.move_offset+u64(layer.move_count) >
			u64(len(result.moves)) {
			return false
		}
		move_start := int(layer.move_offset)
		move_end := move_start+int(layer.move_count)
		for move in result.moves[move_start:move_end] {
			if move.layer_index != u32(layer_index) {return false}
		}
		expected_move_offset += u64(layer.move_count)
	}
	if expected_move_offset != u64(len(result.moves)) {return false}

	total_volume_numerator: u128
	total_filament_nm: u128
	remainder: u128
	previous_planned_move_index: u32
	planned_move_index_set := false
	for move in result.moves {
		if move.stable_id == contracts.INVALID_STABLE_ID ||
		   move.planned_move_id == contracts.INVALID_STABLE_ID ||
		   move.path_id == contracts.INVALID_STABLE_ID ||
		   move.stable_id != contracts.stable_id_child(
			move.planned_move_id,
			.Feature,
			0,
		   ) ||
		   planned_move_index_set &&
			move.planned_move_index <= previous_planned_move_index ||
		   !extrusion_result_role_valid(move.role) ||
		   u32(move.flow_ratio) == 0 ||
		   u32(move.flow_ratio) > profiles.RATIO_SCALE*2 ||
		   i64(move.layer_height) <= 0 ||
		   i64(move.line_width_a) < i64(move.layer_height) ||
		   i64(move.line_width_b) < i64(move.layer_height) ||
		   move.distance_squared_um_2 == 0 ||
		   move.path_length_nm == 0 {
			return false
		}
		previous_planned_move_index = move.planned_move_index
		planned_move_index_set = true
		scaled_distance, scaled_distance_ok :=
			extrusion_checked_multiply(
				move.distance_squared_um_2,
				1_000_000,
			)
		path_length_squared :=
			u128(move.path_length_nm)*u128(move.path_length_nm)
		length_error :=
			path_length_squared-scaled_distance if
			path_length_squared > scaled_distance else
			scaled_distance-path_length_squared
		cross_section_numerator, cross_section_ok :=
			extrusion_cross_section_numerator(
				move.layer_height,
				move.line_width_a,
				move.line_width_b,
			)
		volume_numerator, volume_ok := extrusion_checked_multiply(
			cross_section_numerator,
			u128(move.path_length_nm),
		)
		if volume_ok {
			volume_numerator, volume_ok =
				extrusion_checked_multiply(
					volume_numerator,
					u128(u32(move.flow_ratio)),
				)
		}
		volume_cubic_um, volume_error, volume_round_ok :=
			extrusion_round_ratio_u64(
				volume_numerator,
				u128(result.volume_denominator),
			)
		if !scaled_distance_ok ||
		   !cross_section_ok ||
		   !volume_ok ||
		   !volume_round_ok ||
		   move.length_error_squared_nm_2 != length_error ||
		   move.cross_section_numerator != cross_section_numerator ||
		   move.volume_numerator != volume_numerator ||
		   move.volume_cubic_um != volume_cubic_um ||
		   move.volume_error_numerator != volume_error ||
		   remainder > max(u128)-volume_numerator {
			return false
		}
		accumulated := remainder+volume_numerator
		quantized_units :=
			accumulated/result.quantized_length_denominator
		if quantized_units >
		   u128(max(u64))/u128(result.length_quantum_nm) {
			return false
		}
		incremental_filament_nm :=
			quantized_units*u128(result.length_quantum_nm)
		remainder =
			accumulated%result.quantized_length_denominator
		if move.incremental_filament_nm !=
			u64(incremental_filament_nm) ||
		   move.remainder_numerator_after != remainder ||
		   total_volume_numerator > max(u128)-volume_numerator ||
		   total_filament_nm > max(u128)-incremental_filament_nm {
			return false
		}
		total_volume_numerator += volume_numerator
		total_filament_nm += incremental_filament_nm
	}
	total_volume_cubic_um, total_volume_error, total_round_ok :=
		extrusion_round_ratio_u64(
			total_volume_numerator,
			u128(result.volume_denominator),
		)
	return total_round_ok &&
		result.total_volume_numerator == total_volume_numerator &&
		result.total_volume_cubic_um == total_volume_cubic_um &&
		result.total_volume_error_numerator == total_volume_error &&
		result.total_filament_nm == total_filament_nm &&
		result.final_remainder_numerator == remainder &&
		remainder < result.quantized_length_denominator
}

extrusion_result_role_valid :: proc(role: profiles.Printable_Role) -> bool {
	switch role {
	case .Perimeter,
	     .Bridge,
	     .Gap,
	     .Thin_Wall,
	     .Bottom_Skin,
	     .Top_Skin,
	     .Top_Bottom_Skin,
	     .Sparse_Infill,
	     .Support,
	     .Support_Interface:
		return true
	case .Invalid:
		return false
	}
	return false
}
