package gcode

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

KLIPPER_ARTIFACT_SCHEMA_VERSION :: u32(2)
KLIPPER_ARTIFACT_HEADER_SIZE    :: u32(352)
KLIPPER_ARTIFACT_COMMAND_SIZE   :: u32(48)
KLIPPER_ARTIFACT_FORMAT         :: "hws-klipper-gcode-le"

KLIPPER_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'G', 'C', 'O', 'D', '\n',
}

Klipper_Artifact_Limits :: struct {
	max_commands:    u64,
	max_gcode_bytes: u64,
	max_bytes:       u64,
}

DEFAULT_KLIPPER_ARTIFACT_LIMITS :: Klipper_Artifact_Limits{
	max_commands = 100_000_000,
	max_gcode_bytes = 1024*1024*1024,
	max_bytes = 2*1024*1024*1024,
}

Klipper_Artifact :: struct {
	motion_hash:       contracts.Content_Hash,
	profile_revisions: contracts.Profile_Revisions,
	result_hash:       contracts.Content_Hash,
	result:            Klipper_Result,
}

Klipper_Artifact_Summary :: struct {
	command_count:             u64,
	gcode_byte_count:          u64,
	byte_count:                u64,
	layer_count:               u32,
	motion_operation_count:    u64,
	emitted_dwell_ms:          u64,
}

Klipper_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

klipper_artifact_encode :: proc(
	motion_hash: contracts.Content_Hash,
	motion: features.Motion_Plan_Result,
	profile: profiles.Resolved_Profiles,
	result: Klipper_Result,
	limits := DEFAULT_KLIPPER_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Klipper_Artifact_Error) {
	result_hash, result_ok := klipper_result_hash(
		motion_hash,
		motion,
		profile,
		result,
		DEFAULT_KLIPPER_LIMITS,
		allocator,
	)
	if !result_ok {return nil, .Invalid_Record}
	command_count := u64(len(result.commands))
	gcode_byte_count := u64(len(result.bytes))
	byte_count, size_ok :=
		klipper_artifact_byte_count(command_count, gcode_byte_count)
	counts_fit := klipper_artifact_counts_fit_limits(
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
	for byte, byte_index in KLIPPER_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	klipper_artifact_put_u32(bytes, 8, KLIPPER_ARTIFACT_SCHEMA_VERSION)
	klipper_artifact_put_u32(bytes, 12, KLIPPER_ARTIFACT_HEADER_SIZE)
	klipper_artifact_put_u32(bytes, 16, KLIPPER_ARTIFACT_COMMAND_SIZE)
	klipper_artifact_put_u32(bytes, 20, result.schema_version)
	for byte, byte_index in motion_hash {
		bytes[32+byte_index] = byte
	}
	revisions := profiles.profile_revisions(profile)
	klipper_artifact_put_hash(bytes, 64, revisions.printer)
	klipper_artifact_put_hash(bytes, 96, revisions.material)
	klipper_artifact_put_hash(bytes, 128, revisions.process)
	klipper_artifact_put_hash(bytes, 160, revisions.dialect)
	klipper_artifact_put_hash(bytes, 192, result_hash)
	klipper_artifact_put_u64(bytes, 224, gcode_byte_count)
	klipper_artifact_put_u64(bytes, 232, command_count)
	klipper_artifact_put_u32(bytes, 240, result.layer_count)
	klipper_artifact_put_u64(
		bytes,
		248,
		result.motion_operation_count,
	)
	klipper_artifact_put_u128(bytes, 256, result.positive_filament_nm)
	klipper_artifact_put_u128(bytes, 272, result.negative_filament_nm)
	klipper_artifact_put_u64(bytes, 288, result.emitted_dwell_ms)
	// Bytes 296..<304 are reserved and zero.
	klipper_artifact_put_i64(bytes, 304, i64(result.final_x))
	klipper_artifact_put_i64(bytes, 312, i64(result.final_y))
	klipper_artifact_put_i64(bytes, 320, i64(result.final_z))

	offset := int(KLIPPER_ARTIFACT_HEADER_SIZE)
	for command in result.commands {
		klipper_artifact_put_u64(bytes, offset, u64(command.stable_id))
		klipper_artifact_put_u32(bytes, offset+8, command.command_index)
		bytes[offset+12] = u8(command.kind)
		klipper_artifact_put_u64(bytes, offset+16, command.byte_offset)
		klipper_artifact_put_u32(bytes, offset+24, command.byte_count)
		klipper_artifact_put_u32(bytes, offset+28, command.layer_index)
		klipper_artifact_put_u64(
			bytes,
			offset+32,
			u64(command.source_operation_id),
		)
		offset += int(KLIPPER_ARTIFACT_COMMAND_SIZE)
	}
	copy(bytes[offset:], result.bytes)
	return bytes, .None
}

klipper_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_KLIPPER_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Klipper_Artifact, Klipper_Artifact_Error) {
	summary, preflight_error := klipper_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	gcode_byte_count := summary.gcode_byte_count
	command_count := summary.command_count

	artifact: Klipper_Artifact
	klipper_artifact_get_hash(bytes, 32, &artifact.motion_hash)
	klipper_artifact_get_hash(
		bytes,
		64,
		&artifact.profile_revisions.printer,
	)
	klipper_artifact_get_hash(
		bytes,
		96,
		&artifact.profile_revisions.material,
	)
	klipper_artifact_get_hash(
		bytes,
		128,
		&artifact.profile_revisions.process,
	)
	klipper_artifact_get_hash(
		bytes,
		160,
		&artifact.profile_revisions.dialect,
	)
	klipper_artifact_get_hash(bytes, 192, &artifact.result_hash)
	artifact.result.schema_version =
		klipper_artifact_get_u32(bytes, 20)
	artifact.result.layer_count =
		klipper_artifact_get_u32(bytes, 240)
	artifact.result.motion_operation_count =
		klipper_artifact_get_u64(bytes, 248)
	artifact.result.positive_filament_nm =
		klipper_artifact_get_u128(bytes, 256)
	artifact.result.negative_filament_nm =
		klipper_artifact_get_u128(bytes, 272)
	artifact.result.emitted_dwell_ms =
		klipper_artifact_get_u64(bytes, 288)
	artifact.result.final_x =
		contracts.Micrometres(klipper_artifact_get_i64(bytes, 304))
	artifact.result.final_y =
		contracts.Micrometres(klipper_artifact_get_i64(bytes, 312))
	artifact.result.final_z =
		contracts.Micrometres(klipper_artifact_get_i64(bytes, 320))
	artifact.result.commands = make(
		[]Klipper_Command_Record,
		int(command_count),
		allocator,
	)
	artifact.result.bytes =
		make([]u8, int(gcode_byte_count), allocator)
	if command_count > 0 && artifact.result.commands == nil ||
	   gcode_byte_count > 0 && artifact.result.bytes == nil {
		klipper_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}

	offset := int(KLIPPER_ARTIFACT_HEADER_SIZE)
	for &command in artifact.result.commands {
		if !klipper_artifact_bytes_zero(bytes, offset+13, offset+16) ||
		   !klipper_artifact_bytes_zero(bytes, offset+40, offset+48) {
			klipper_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		command.stable_id = contracts.Stable_ID(
			klipper_artifact_get_u64(bytes, offset),
		)
		command.command_index =
			klipper_artifact_get_u32(bytes, offset+8)
		command.kind =
			transmute(Klipper_Command_Kind)bytes[offset+12]
		command.byte_offset =
			klipper_artifact_get_u64(bytes, offset+16)
		command.byte_count =
			klipper_artifact_get_u32(bytes, offset+24)
		command.layer_index =
			klipper_artifact_get_u32(bytes, offset+28)
		command.source_operation_id = contracts.Stable_ID(
			klipper_artifact_get_u64(bytes, offset+32),
		)
		offset += int(KLIPPER_ARTIFACT_COMMAND_SIZE)
	}
	copy(artifact.result.bytes, bytes[offset:])
	calculated_hash, result_ok := klipper_result_content_hash(
		artifact.motion_hash,
		artifact.profile_revisions,
		artifact.result,
	)
	if !result_ok {
		klipper_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		klipper_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

klipper_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_KLIPPER_ARTIFACT_LIMITS,
) -> (Klipper_Artifact_Summary, Klipper_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(KLIPPER_ARTIFACT_HEADER_SIZE) ||
	   !klipper_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if klipper_artifact_get_u32(bytes, 8) !=
	   KLIPPER_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	if klipper_artifact_get_u32(bytes, 12) != KLIPPER_ARTIFACT_HEADER_SIZE ||
	   klipper_artifact_get_u32(bytes, 16) != KLIPPER_ARTIFACT_COMMAND_SIZE ||
	   klipper_artifact_get_u32(bytes, 20) != KLIPPER_EMITTER_SCHEMA_VERSION ||
	   !klipper_artifact_bytes_zero(bytes, 24, 32) ||
	   !klipper_artifact_bytes_zero(bytes, 244, 248) ||
	   !klipper_artifact_bytes_zero(bytes, 296, 304) ||
	   !klipper_artifact_bytes_zero(bytes, 328, 352) {
		return {}, .Malformed
	}
	gcode_byte_count := klipper_artifact_get_u64(bytes, 224)
	command_count := klipper_artifact_get_u64(bytes, 232)
	byte_count, size_ok :=
		klipper_artifact_byte_count(command_count, gcode_byte_count)
	counts_fit := klipper_artifact_counts_fit_limits(
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
	return {
		command_count = command_count,
		gcode_byte_count = gcode_byte_count,
		byte_count = byte_count,
		layer_count = klipper_artifact_get_u32(bytes, 240),
		motion_operation_count = klipper_artifact_get_u64(bytes, 248),
		emitted_dwell_ms = klipper_artifact_get_u64(bytes, 288),
	}, .None
}

klipper_artifact_destroy :: proc(
	artifact: ^Klipper_Artifact,
	allocator := context.allocator,
) {
	klipper_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

klipper_artifact_byte_count :: proc(
	command_count, gcode_byte_count: u64,
) -> (u64, bool) {
	result := u64(KLIPPER_ARTIFACT_HEADER_SIZE)
	if command_count >
	   (max(u64)-result)/u64(KLIPPER_ARTIFACT_COMMAND_SIZE) {
		return 0, false
	}
	result += command_count*u64(KLIPPER_ARTIFACT_COMMAND_SIZE)
	if gcode_byte_count > max(u64)-result {return 0, false}
	return result+gcode_byte_count, true
}

klipper_artifact_counts_fit_limits :: proc(
	command_count, gcode_byte_count, byte_count: u64,
	limits: Klipper_Artifact_Limits,
) -> bool {
	return command_count <= limits.max_commands &&
		gcode_byte_count <= limits.max_gcode_bytes &&
		byte_count <= limits.max_bytes
}

klipper_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for byte, byte_index in KLIPPER_ARTIFACT_MAGIC {
		if bytes[byte_index] != byte {return false}
	}
	return true
}

klipper_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

klipper_artifact_put_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: contracts.Content_Hash,
) {
	for byte, byte_index in hash {
		bytes[offset+byte_index] = byte
	}
}

klipper_artifact_get_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: ^contracts.Content_Hash,
) {
	copy(hash[:], bytes[offset:offset+len(hash)])
}

klipper_artifact_put_u32 :: proc(bytes: []u8, offset: int, value: u32) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

klipper_artifact_put_u64 :: proc(bytes: []u8, offset: int, value: u64) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

klipper_artifact_put_u128 :: proc(
	bytes: []u8,
	offset: int,
	value: u128,
) {
	klipper_artifact_put_u64(bytes, offset, u64(value))
	klipper_artifact_put_u64(bytes, offset+8, u64(value>>64))
}

klipper_artifact_put_i64 :: proc(bytes: []u8, offset: int, value: i64) {
	klipper_artifact_put_u64(bytes, offset, transmute(u64)value)
}

klipper_artifact_get_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	result: u32
	for byte_index in 0..<4 {
		result |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return result
}

klipper_artifact_get_u64 :: proc(bytes: []u8, offset: int) -> u64 {
	result: u64
	for byte_index in 0..<8 {
		result |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return result
}

klipper_artifact_get_u128 :: proc(bytes: []u8, offset: int) -> u128 {
	return u128(klipper_artifact_get_u64(bytes, offset)) |
		u128(klipper_artifact_get_u64(bytes, offset+8))<<64
}

klipper_artifact_get_i64 :: proc(bytes: []u8, offset: int) -> i64 {
	return transmute(i64)klipper_artifact_get_u64(bytes, offset)
}
