package gcode

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

MARLIN_RESULT_HASH_SCHEMA_VERSION :: u32(1)

marlin_result_hash :: proc(
	motion_hash: contracts.Content_Hash,
	motion: features.Motion_Plan_Result,
	profile: profiles.Resolved_Profiles,
	result: Marlin_Result,
	limits := DEFAULT_MARLIN_LIMITS,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	expected, expected_error :=
		marlin_emit(motion, profile, limits, allocator)
	if expected_error != .None {return {}, false}
	defer marlin_result_destroy(&expected, allocator)
	if result.schema_version != expected.schema_version ||
	   result.layer_count != expected.layer_count ||
	   result.motion_operation_count != expected.motion_operation_count ||
	   result.positive_filament_nm != expected.positive_filament_nm ||
	   result.negative_filament_nm != expected.negative_filament_nm ||
	   result.emitted_dwell_ms != expected.emitted_dwell_ms ||
	   result.shutdown_retraction_nm != expected.shutdown_retraction_nm ||
	   result.final_x != expected.final_x ||
	   result.final_y != expected.final_y ||
	   result.final_z != expected.final_z ||
	   len(result.bytes) != len(expected.bytes) ||
	   len(result.commands) != len(expected.commands) {
		return {}, false
	}
	for value, byte_index in result.bytes {
		if value != expected.bytes[byte_index] {return {}, false}
	}
	for command, command_index in result.commands {
		if command != expected.commands[command_index] {
			return {}, false
		}
	}
	report, validation_error :=
		marlin_validate(result.bytes, profile, motion)
	if validation_error != .None ||
	   report.command_count != u64(len(result.commands)) ||
	   report.layer_count != result.layer_count ||
	   report.motion_operation_count != result.motion_operation_count ||
	   report.positive_filament_nm != result.positive_filament_nm ||
	   report.negative_filament_nm != result.negative_filament_nm ||
	   report.dwell_ms != result.emitted_dwell_ms ||
	   report.final_x != result.final_x ||
	   report.final_y != result.final_y ||
	   report.final_z != result.final_z {
		return {}, false
	}

	revisions := profiles.profile_revisions(profile)
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/marlin-gcode",
		MARLIN_RESULT_HASH_SCHEMA_VERSION,
	)
	contracts.canonical_hash_append_content_hash(&hash, motion_hash)
	contracts.canonical_hash_append_content_hash(&hash, revisions.printer)
	contracts.canonical_hash_append_content_hash(&hash, revisions.material)
	contracts.canonical_hash_append_content_hash(&hash, revisions.process)
	contracts.canonical_hash_append_content_hash(&hash, revisions.dialect)
	contracts.canonical_hash_append_u32(&hash, result.schema_version)
	contracts.canonical_hash_append_u32(&hash, result.layer_count)
	contracts.canonical_hash_append_u64(
		&hash,
		result.motion_operation_count,
	)
	marlin_hash_append_u128(
		&hash,
		result.positive_filament_nm,
	)
	marlin_hash_append_u128(
		&hash,
		result.negative_filament_nm,
	)
	contracts.canonical_hash_append_u64(&hash, result.emitted_dwell_ms)
	contracts.canonical_hash_append_u64(
		&hash,
		result.shutdown_retraction_nm,
	)
	contracts.canonical_hash_append_i64(&hash, i64(result.final_x))
	contracts.canonical_hash_append_i64(&hash, i64(result.final_y))
	contracts.canonical_hash_append_i64(&hash, i64(result.final_z))
	contracts.canonical_hash_append_bytes(&hash, result.bytes)
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.commands)),
	)
	for command in result.commands {
		contracts.canonical_hash_append_stable_id(
			&hash,
			command.stable_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			command.command_index,
		)
		contracts.canonical_hash_append_u8(&hash, u8(command.kind))
		contracts.canonical_hash_append_u64(&hash, command.byte_offset)
		contracts.canonical_hash_append_u32(&hash, command.byte_count)
		contracts.canonical_hash_append_stable_id(
			&hash,
			command.source_operation_id,
		)
		contracts.canonical_hash_append_u32(&hash, command.layer_index)
	}
	return contracts.canonical_hash_final(&hash), true
}

marlin_hash_append_u128 :: proc(
	hash: ^contracts.Canonical_Hash,
	value: u128,
) {
	contracts.canonical_hash_append_u64(hash, u64(value))
	contracts.canonical_hash_append_u64(hash, u64(value>>64))
}
