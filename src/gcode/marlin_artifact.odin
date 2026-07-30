package gcode

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

MARLIN_ARTIFACT_SCHEMA_VERSION :: u32(1)
MARLIN_ARTIFACT_HEADER_SIZE    :: u32(352)
MARLIN_ARTIFACT_COMMAND_SIZE   :: u32(48)
MARLIN_ARTIFACT_FORMAT         :: "hws-marlin-gcode-le"

MARLIN_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'G', 'C', 'O', 'D', '\n',
}

Marlin_Artifact_Limits :: struct {
	max_commands:    u64,
	max_gcode_bytes: u64,
	max_bytes:       u64,
}

DEFAULT_MARLIN_ARTIFACT_LIMITS :: Marlin_Artifact_Limits{
	max_commands = 100_000_000,
	max_gcode_bytes = 1024*1024*1024,
	max_bytes = 2*1024*1024*1024,
}

Marlin_Artifact :: struct {
	motion_hash:       contracts.Content_Hash,
	profile_revisions: contracts.Profile_Revisions,
	result_hash:       contracts.Content_Hash,
	result:            Marlin_Result,
}

Marlin_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

marlin_artifact_encode :: proc(
	motion_hash: contracts.Content_Hash,
	motion: features.Motion_Plan_Result,
	profile: profiles.Resolved_Profiles,
	result: Marlin_Result,
	limits := DEFAULT_MARLIN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Marlin_Artifact_Error) {
	result_hash, result_ok := marlin_result_hash(
		motion_hash,
		motion,
		profile,
		result,
		DEFAULT_MARLIN_LIMITS,
		allocator,
	)
	if !result_ok {return nil, .Invalid_Record}
	command_count := u64(len(result.commands))
	gcode_byte_count := u64(len(result.bytes))
	byte_count, size_ok :=
		marlin_artifact_byte_count(command_count, gcode_byte_count)
	counts_fit := marlin_artifact_counts_fit_limits(
		command_count,
		gcode_byte_count,
		byte_count,
		limits,
	)
	if !size_ok || !counts_fit ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}

	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in MARLIN_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	marlin_artifact_put_u32(bytes, 8, MARLIN_ARTIFACT_SCHEMA_VERSION)
	marlin_artifact_put_u32(bytes, 12, MARLIN_ARTIFACT_HEADER_SIZE)
	marlin_artifact_put_u32(bytes, 16, MARLIN_ARTIFACT_COMMAND_SIZE)
	marlin_artifact_put_u32(bytes, 20, result.schema_version)
	for byte, byte_index in motion_hash {
		bytes[32+byte_index] = byte
	}
	revisions := profiles.profile_revisions(profile)
	marlin_artifact_put_hash(bytes, 64, revisions.printer)
	marlin_artifact_put_hash(bytes, 96, revisions.material)
	marlin_artifact_put_hash(bytes, 128, revisions.process)
	marlin_artifact_put_hash(bytes, 160, revisions.dialect)
	marlin_artifact_put_hash(bytes, 192, result_hash)
	marlin_artifact_put_u64(bytes, 224, gcode_byte_count)
	marlin_artifact_put_u64(bytes, 232, command_count)
	marlin_artifact_put_u32(bytes, 240, result.layer_count)
	marlin_artifact_put_u64(
		bytes,
		248,
		result.motion_operation_count,
	)
	marlin_artifact_put_u128(bytes, 256, result.positive_filament_nm)
	marlin_artifact_put_u128(bytes, 272, result.negative_filament_nm)
	marlin_artifact_put_u64(bytes, 288, result.emitted_dwell_ms)
	marlin_artifact_put_u64(
		bytes,
		296,
		result.shutdown_retraction_nm,
	)
	marlin_artifact_put_i64(bytes, 304, i64(result.final_x))
	marlin_artifact_put_i64(bytes, 312, i64(result.final_y))
	marlin_artifact_put_i64(bytes, 320, i64(result.final_z))

	offset := int(MARLIN_ARTIFACT_HEADER_SIZE)
	for command in result.commands {
		marlin_artifact_put_u64(bytes, offset, u64(command.stable_id))
		marlin_artifact_put_u32(bytes, offset+8, command.command_index)
		bytes[offset+12] = u8(command.kind)
		marlin_artifact_put_u64(bytes, offset+16, command.byte_offset)
		marlin_artifact_put_u32(bytes, offset+24, command.byte_count)
		marlin_artifact_put_u32(bytes, offset+28, command.layer_index)
		marlin_artifact_put_u64(
			bytes,
			offset+32,
			u64(command.source_operation_id),
		)
		offset += int(MARLIN_ARTIFACT_COMMAND_SIZE)
	}
	copy(bytes[offset:], result.bytes)
	return bytes, .None
}

marlin_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_MARLIN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Marlin_Artifact, Marlin_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(MARLIN_ARTIFACT_HEADER_SIZE) ||
	   !marlin_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if marlin_artifact_get_u32(bytes, 8) !=
	   MARLIN_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	if marlin_artifact_get_u32(bytes, 12) != MARLIN_ARTIFACT_HEADER_SIZE ||
	   marlin_artifact_get_u32(bytes, 16) != MARLIN_ARTIFACT_COMMAND_SIZE ||
	   marlin_artifact_get_u32(bytes, 20) != MARLIN_EMITTER_SCHEMA_VERSION ||
	   !marlin_artifact_bytes_zero(bytes, 24, 32) ||
	   !marlin_artifact_bytes_zero(bytes, 244, 248) ||
	   !marlin_artifact_bytes_zero(bytes, 328, 352) {
		return {}, .Malformed
	}
	gcode_byte_count := marlin_artifact_get_u64(bytes, 224)
	command_count := marlin_artifact_get_u64(bytes, 232)
	byte_count, size_ok :=
		marlin_artifact_byte_count(command_count, gcode_byte_count)
	counts_fit := marlin_artifact_counts_fit_limits(
		command_count,
		gcode_byte_count,
		byte_count,
		limits,
	)
	if !size_ok || !counts_fit ||
	   command_count > u64(max(int)) ||
	   gcode_byte_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}

	artifact: Marlin_Artifact
	marlin_artifact_get_hash(bytes, 32, &artifact.motion_hash)
	marlin_artifact_get_hash(
		bytes,
		64,
		&artifact.profile_revisions.printer,
	)
	marlin_artifact_get_hash(
		bytes,
		96,
		&artifact.profile_revisions.material,
	)
	marlin_artifact_get_hash(
		bytes,
		128,
		&artifact.profile_revisions.process,
	)
	marlin_artifact_get_hash(
		bytes,
		160,
		&artifact.profile_revisions.dialect,
	)
	marlin_artifact_get_hash(bytes, 192, &artifact.result_hash)
	artifact.result.schema_version =
		marlin_artifact_get_u32(bytes, 20)
	artifact.result.layer_count =
		marlin_artifact_get_u32(bytes, 240)
	artifact.result.motion_operation_count =
		marlin_artifact_get_u64(bytes, 248)
	artifact.result.positive_filament_nm =
		marlin_artifact_get_u128(bytes, 256)
	artifact.result.negative_filament_nm =
		marlin_artifact_get_u128(bytes, 272)
	artifact.result.emitted_dwell_ms =
		marlin_artifact_get_u64(bytes, 288)
	artifact.result.shutdown_retraction_nm =
		marlin_artifact_get_u64(bytes, 296)
	artifact.result.final_x =
		contracts.Micrometres(marlin_artifact_get_i64(bytes, 304))
	artifact.result.final_y =
		contracts.Micrometres(marlin_artifact_get_i64(bytes, 312))
	artifact.result.final_z =
		contracts.Micrometres(marlin_artifact_get_i64(bytes, 320))
	artifact.result.commands = make(
		[]Marlin_Command_Record,
		int(command_count),
		allocator,
	)
	artifact.result.bytes =
		make([]u8, int(gcode_byte_count), allocator)
	if command_count > 0 && artifact.result.commands == nil ||
	   gcode_byte_count > 0 && artifact.result.bytes == nil {
		marlin_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}

	offset := int(MARLIN_ARTIFACT_HEADER_SIZE)
	for &command in artifact.result.commands {
		if !marlin_artifact_bytes_zero(bytes, offset+13, offset+16) ||
		   !marlin_artifact_bytes_zero(bytes, offset+40, offset+48) {
			marlin_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		command.stable_id = contracts.Stable_ID(
			marlin_artifact_get_u64(bytes, offset),
		)
		command.command_index =
			marlin_artifact_get_u32(bytes, offset+8)
		command.kind =
			transmute(Marlin_Command_Kind)bytes[offset+12]
		command.byte_offset =
			marlin_artifact_get_u64(bytes, offset+16)
		command.byte_count =
			marlin_artifact_get_u32(bytes, offset+24)
		command.layer_index =
			marlin_artifact_get_u32(bytes, offset+28)
		command.source_operation_id = contracts.Stable_ID(
			marlin_artifact_get_u64(bytes, offset+32),
		)
		offset += int(MARLIN_ARTIFACT_COMMAND_SIZE)
	}
	copy(artifact.result.bytes, bytes[offset:])
	calculated_hash, result_ok := marlin_result_content_hash(
		artifact.motion_hash,
		artifact.profile_revisions,
		artifact.result,
	)
	if !result_ok {
		marlin_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		marlin_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

marlin_artifact_destroy :: proc(
	artifact: ^Marlin_Artifact,
	allocator := context.allocator,
) {
	marlin_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

marlin_artifact_byte_count :: proc(
	command_count, gcode_byte_count: u64,
) -> (u64, bool) {
	result := u64(MARLIN_ARTIFACT_HEADER_SIZE)
	if command_count >
	   (max(u64)-result)/u64(MARLIN_ARTIFACT_COMMAND_SIZE) {
		return 0, false
	}
	result += command_count*u64(MARLIN_ARTIFACT_COMMAND_SIZE)
	if gcode_byte_count > max(u64)-result {return 0, false}
	return result+gcode_byte_count, true
}

marlin_artifact_counts_fit_limits :: proc(
	command_count, gcode_byte_count, byte_count: u64,
	limits: Marlin_Artifact_Limits,
) -> bool {
	return command_count <= limits.max_commands &&
		gcode_byte_count <= limits.max_gcode_bytes &&
		byte_count <= limits.max_bytes
}

marlin_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for byte, byte_index in MARLIN_ARTIFACT_MAGIC {
		if bytes[byte_index] != byte {return false}
	}
	return true
}

marlin_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

marlin_artifact_put_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: contracts.Content_Hash,
) {
	for byte, byte_index in hash {
		bytes[offset+byte_index] = byte
	}
}

marlin_artifact_get_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: ^contracts.Content_Hash,
) {
	copy(hash[:], bytes[offset:offset+len(hash)])
}

marlin_artifact_put_u32 :: proc(bytes: []u8, offset: int, value: u32) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

marlin_artifact_put_u64 :: proc(bytes: []u8, offset: int, value: u64) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

marlin_artifact_put_u128 :: proc(
	bytes: []u8,
	offset: int,
	value: u128,
) {
	marlin_artifact_put_u64(bytes, offset, u64(value))
	marlin_artifact_put_u64(bytes, offset+8, u64(value>>64))
}

marlin_artifact_put_i64 :: proc(bytes: []u8, offset: int, value: i64) {
	marlin_artifact_put_u64(bytes, offset, transmute(u64)value)
}

marlin_artifact_get_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	result: u32
	for byte_index in 0..<4 {
		result |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return result
}

marlin_artifact_get_u64 :: proc(bytes: []u8, offset: int) -> u64 {
	result: u64
	for byte_index in 0..<8 {
		result |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return result
}

marlin_artifact_get_u128 :: proc(bytes: []u8, offset: int) -> u128 {
	return u128(marlin_artifact_get_u64(bytes, offset)) |
		u128(marlin_artifact_get_u64(bytes, offset+8))<<64
}

marlin_artifact_get_i64 :: proc(bytes: []u8, offset: int) -> i64 {
	return transmute(i64)marlin_artifact_get_u64(bytes, offset)
}
