package evidence

import contracts "../contracts"
import slicing "../slicing"

LAYER_SCHEDULE_ARTIFACT_SCHEMA_VERSION :: u32(1)
LAYER_SCHEDULE_ARTIFACT_HEADER_SIZE    :: u32(160)
LAYER_SCHEDULE_ARTIFACT_LAYER_SIZE     :: u32(16)
LAYER_SCHEDULE_ARTIFACT_FORMAT         :: "hws-layer-schedule-le"

LAYER_SCHEDULE_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'S', 'C', 'H', 'D', '\n',
}

Layer_Schedule_Artifact_Limits :: struct {
	max_layers: u64,
	max_bytes:  u64,
}

DEFAULT_LAYER_SCHEDULE_ARTIFACT_LIMITS :: Layer_Schedule_Artifact_Limits{
	max_layers = 100_000_000,
	max_bytes = 2*1024*1024*1024,
}

Layer_Schedule_Artifact :: struct {
	result_hash: contracts.Content_Hash,
	result:      slicing.Fixed_Layer_Schedule,
}

Layer_Schedule_Artifact_Summary :: struct {
	layer_count: u64,
	byte_count:  u64,
}

Layer_Schedule_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

layer_schedule_artifact_encode :: proc(
	result: slicing.Fixed_Layer_Schedule,
	limits := DEFAULT_LAYER_SCHEDULE_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Layer_Schedule_Artifact_Error) {
	result_hash, result_ok := slicing.fixed_layer_schedule_hash(result)
	if !result_ok {return nil, .Invalid_Record}
	layer_count := u64(len(result.layer_z))
	byte_count, size_ok := layer_schedule_artifact_byte_count(layer_count)
	if !size_ok ||
	   layer_count > limits.max_layers ||
	   byte_count > limits.max_bytes ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in LAYER_SCHEDULE_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	layer_schedule_artifact_put_u32(
		bytes,
		8,
		LAYER_SCHEDULE_ARTIFACT_SCHEMA_VERSION,
	)
	layer_schedule_artifact_put_u32(
		bytes,
		12,
		LAYER_SCHEDULE_ARTIFACT_HEADER_SIZE,
	)
	layer_schedule_artifact_put_u32(
		bytes,
		16,
		LAYER_SCHEDULE_ARTIFACT_LAYER_SIZE,
	)
	layer_schedule_artifact_put_u32(
		bytes,
		20,
		slicing.SCHEMA_VERSION_FIXED_LAYER_SCHEDULE_HASH,
	)
	layer_schedule_artifact_put_hash(bytes, 24, result.request_hash)
	layer_schedule_artifact_put_hash(bytes, 56, result_hash)
	layer_schedule_artifact_put_i64(
		bytes,
		88,
		i64(result.minimum_z),
	)
	layer_schedule_artifact_put_i64(
		bytes,
		96,
		i64(result.maximum_z),
	)
	layer_schedule_artifact_put_i64(
		bytes,
		104,
		i64(result.first_plane_z),
	)
	layer_schedule_artifact_put_i64(
		bytes,
		112,
		i64(result.layer_step),
	)
	layer_schedule_artifact_put_u64(bytes, 120, layer_count)
	offset := int(LAYER_SCHEDULE_ARTIFACT_HEADER_SIZE)
	for layer_z, layer_index in result.layer_z {
		layer_schedule_artifact_put_i64(bytes, offset, i64(layer_z))
		layer_schedule_artifact_put_u64(
			bytes,
			offset+8,
			u64(result.layer_ids[layer_index]),
		)
		offset += int(LAYER_SCHEDULE_ARTIFACT_LAYER_SIZE)
	}
	return bytes, .None
}

layer_schedule_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_LAYER_SCHEDULE_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Layer_Schedule_Artifact, Layer_Schedule_Artifact_Error) {
	summary, preflight_error :=
		layer_schedule_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Layer_Schedule_Artifact
	result := &artifact.result
	layer_schedule_artifact_get_hash(bytes, 24, &result.request_hash)
	layer_schedule_artifact_get_hash(bytes, 56, &artifact.result_hash)
	result.minimum_z = contracts.Micrometres(
		layer_schedule_artifact_get_i64(bytes, 88),
	)
	result.maximum_z = contracts.Micrometres(
		layer_schedule_artifact_get_i64(bytes, 96),
	)
	result.first_plane_z = contracts.Micrometres(
		layer_schedule_artifact_get_i64(bytes, 104),
	)
	result.layer_step = contracts.Micrometres(
		layer_schedule_artifact_get_i64(bytes, 112),
	)
	result.layer_z = make(
		[]contracts.Micrometres,
		int(summary.layer_count),
		allocator,
	)
	result.layer_ids = make(
		[]contracts.Stable_ID,
		int(summary.layer_count),
		allocator,
	)
	if summary.layer_count > 0 &&
	   (result.layer_z == nil || result.layer_ids == nil) {
		layer_schedule_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	offset := int(LAYER_SCHEDULE_ARTIFACT_HEADER_SIZE)
	for &layer_z, layer_index in result.layer_z {
		layer_z = contracts.Micrometres(
			layer_schedule_artifact_get_i64(bytes, offset),
		)
		result.layer_ids[layer_index] = contracts.Stable_ID(
			layer_schedule_artifact_get_u64(bytes, offset+8),
		)
		offset += int(LAYER_SCHEDULE_ARTIFACT_LAYER_SIZE)
	}
	calculated_hash, result_ok :=
		slicing.fixed_layer_schedule_hash(artifact.result)
	if !result_ok {
		layer_schedule_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		layer_schedule_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

layer_schedule_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_LAYER_SCHEDULE_ARTIFACT_LIMITS,
) -> (Layer_Schedule_Artifact_Summary, Layer_Schedule_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(LAYER_SCHEDULE_ARTIFACT_HEADER_SIZE) ||
	   !layer_schedule_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if layer_schedule_artifact_get_u32(bytes, 8) !=
	   LAYER_SCHEDULE_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	if layer_schedule_artifact_get_u32(bytes, 12) !=
	   LAYER_SCHEDULE_ARTIFACT_HEADER_SIZE ||
	   layer_schedule_artifact_get_u32(bytes, 16) !=
	   LAYER_SCHEDULE_ARTIFACT_LAYER_SIZE ||
	   layer_schedule_artifact_get_u32(bytes, 20) !=
	   slicing.SCHEMA_VERSION_FIXED_LAYER_SCHEDULE_HASH ||
	   !layer_schedule_artifact_bytes_zero(bytes, 128, 160) {
		return {}, .Malformed
	}
	layer_count := layer_schedule_artifact_get_u64(bytes, 120)
	byte_count, size_ok := layer_schedule_artifact_byte_count(layer_count)
	if !size_ok ||
	   layer_count == 0 ||
	   layer_count > limits.max_layers ||
	   layer_count > u64(max(int)) ||
	   byte_count > limits.max_bytes {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}
	return {
		layer_count = layer_count,
		byte_count = byte_count,
	}, .None
}

layer_schedule_artifact_destroy :: proc(
	artifact: ^Layer_Schedule_Artifact,
	allocator := context.allocator,
) {
	slicing.fixed_layer_schedule_destroy(&artifact.result, allocator)
	artifact^ = {}
}

layer_schedule_artifact_byte_count :: proc(
	layer_count: u64,
) -> (u64, bool) {
	header_size := u64(LAYER_SCHEDULE_ARTIFACT_HEADER_SIZE)
	layer_size := u64(LAYER_SCHEDULE_ARTIFACT_LAYER_SIZE)
	if layer_count > (max(u64)-header_size)/layer_size {
		return 0, false
	}
	return header_size+layer_count*layer_size, true
}

layer_schedule_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for byte, byte_index in LAYER_SCHEDULE_ARTIFACT_MAGIC {
		if bytes[byte_index] != byte {return false}
	}
	return true
}

layer_schedule_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

layer_schedule_artifact_put_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: contracts.Content_Hash,
) {
	for byte, byte_index in hash {
		bytes[offset+byte_index] = byte
	}
}

layer_schedule_artifact_get_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: ^contracts.Content_Hash,
) {
	copy(hash[:], bytes[offset:offset+len(hash)])
}

layer_schedule_artifact_put_u32 :: proc(
	bytes: []u8,
	offset: int,
	value: u32,
) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

layer_schedule_artifact_put_u64 :: proc(
	bytes: []u8,
	offset: int,
	value: u64,
) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

layer_schedule_artifact_put_i64 :: proc(
	bytes: []u8,
	offset: int,
	value: i64,
) {
	layer_schedule_artifact_put_u64(bytes, offset, transmute(u64)value)
}

layer_schedule_artifact_get_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	value: u32
	for byte_index in 0..<4 {
		value |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return value
}

layer_schedule_artifact_get_u64 :: proc(bytes: []u8, offset: int) -> u64 {
	value: u64
	for byte_index in 0..<8 {
		value |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return value
}

layer_schedule_artifact_get_i64 :: proc(
	bytes: []u8,
	offset: int,
) -> i64 {
	return transmute(i64)layer_schedule_artifact_get_u64(bytes, offset)
}
