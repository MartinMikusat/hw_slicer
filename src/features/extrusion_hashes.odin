package features

import contracts "../contracts"
import profiles "../profiles"

SCHEMA_VERSION_EXTRUSION_HASH :: u32(1)

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

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/extrusion",
		SCHEMA_VERSION_EXTRUSION_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, path_plan_hash)
	contracts.canonical_hash_append_content_hash(
		&hash,
		layer_schedule_hash,
	)
	contracts.canonical_hash_append_content_hash(&hash, material_hash)
	contracts.canonical_hash_append_content_hash(&hash, process_hash)
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
