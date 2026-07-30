package features

import contracts "../contracts"
import profiles "../profiles"

EXTRUSION_ARTIFACT_SCHEMA_VERSION :: u32(1)
EXTRUSION_ARTIFACT_HEADER_SIZE    :: u32(384)
EXTRUSION_ARTIFACT_LAYER_SIZE     :: u32(16)
EXTRUSION_ARTIFACT_MOVE_SIZE      :: u32(192)
EXTRUSION_ARTIFACT_FORMAT         :: "hws-extrusion-le"

EXTRUSION_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'E', 'X', 'T', 'R', '\n',
}

Extrusion_Artifact_Limits :: struct {
	max_layers: u64,
	max_moves:  u64,
	max_bytes:  u64,
}

DEFAULT_EXTRUSION_ARTIFACT_LIMITS :: Extrusion_Artifact_Limits{
	max_layers = 10_000_000,
	max_moves = 100_000_000,
	max_bytes = 2*1024*1024*1024,
}

Extrusion_Artifact :: struct {
	dependencies: Extrusion_Hash_Dependencies,
	result_hash:  contracts.Content_Hash,
	result:       Extrusion_Result,
}

Extrusion_Artifact_Summary :: struct {
	layer_count:           u64,
	move_count:            u64,
	byte_count:            u64,
	total_volume_cubic_um: u64,
	total_volume_numerator: u128,
	total_filament_nm:     u128,
}

Extrusion_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

extrusion_artifact_encode :: proc(
	path_plan_hash: contracts.Content_Hash,
	layer_schedule_hash: contracts.Content_Hash,
	material_hash: contracts.Content_Hash,
	process_hash: contracts.Content_Hash,
	plan: Unified_Path_Plan_Result,
	layer_heights: []contracts.Micrometres,
	material: profiles.Material_Profile,
	process: profiles.Resolved_Process_Profile,
	result: Extrusion_Result,
	limits := DEFAULT_EXTRUSION_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Extrusion_Artifact_Error) {
	result_hash, result_ok := extrusion_result_hash(
		path_plan_hash,
		layer_schedule_hash,
		material_hash,
		process_hash,
		plan,
		layer_heights,
		material,
		process,
		result,
		DEFAULT_EXTRUSION_LIMITS,
		allocator,
	)
	if !result_ok {return nil, .Invalid_Record}
	layer_count := u64(len(result.layers))
	move_count := u64(len(result.moves))
	byte_count, size_ok :=
		extrusion_artifact_byte_count(layer_count, move_count)
	if !size_ok ||
	   !extrusion_artifact_counts_fit_limits(
		layer_count,
		move_count,
		byte_count,
		limits,
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in EXTRUSION_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	extrusion_artifact_put_u32(
		bytes,
		8,
		EXTRUSION_ARTIFACT_SCHEMA_VERSION,
	)
	extrusion_artifact_put_u32(
		bytes,
		12,
		EXTRUSION_ARTIFACT_HEADER_SIZE,
	)
	extrusion_artifact_put_u32(
		bytes,
		16,
		EXTRUSION_ARTIFACT_LAYER_SIZE,
	)
	extrusion_artifact_put_u32(
		bytes,
		20,
		EXTRUSION_ARTIFACT_MOVE_SIZE,
	)
	extrusion_artifact_put_u32(
		bytes,
		24,
		SCHEMA_VERSION_EXTRUSION_HASH,
	)
	extrusion_artifact_put_hash(bytes, 32, path_plan_hash)
	extrusion_artifact_put_hash(bytes, 64, layer_schedule_hash)
	extrusion_artifact_put_hash(bytes, 96, material_hash)
	extrusion_artifact_put_hash(bytes, 128, process_hash)
	extrusion_artifact_put_hash(bytes, 160, result_hash)
	bytes[192] = u8(result.policy)
	bytes[193] = u8(result.cross_section_model)
	extrusion_artifact_put_u64(bytes, 200, result.pi_scale)
	extrusion_artifact_put_u64(bytes, 208, result.pi_scaled)
	extrusion_artifact_put_i64(
		bytes,
		216,
		i64(result.filament_diameter),
	)
	extrusion_artifact_put_u32(
		bytes,
		224,
		result.length_quantum_nm,
	)
	extrusion_artifact_put_u64(
		bytes,
		232,
		result.cross_section_denominator,
	)
	extrusion_artifact_put_u64(
		bytes,
		240,
		result.volume_denominator,
	)
	extrusion_artifact_put_u128(
		bytes,
		248,
		result.filament_length_denominator,
	)
	extrusion_artifact_put_u128(
		bytes,
		264,
		result.quantized_length_denominator,
	)
	extrusion_artifact_put_u64(bytes, 280, layer_count)
	extrusion_artifact_put_u64(bytes, 288, move_count)
	extrusion_artifact_put_u128(
		bytes,
		296,
		result.total_volume_numerator,
	)
	extrusion_artifact_put_u64(
		bytes,
		312,
		result.total_volume_cubic_um,
	)
	extrusion_artifact_put_u128(
		bytes,
		320,
		result.total_volume_error_numerator,
	)
	extrusion_artifact_put_u128(
		bytes,
		336,
		result.total_filament_nm,
	)
	extrusion_artifact_put_u128(
		bytes,
		352,
		result.final_remainder_numerator,
	)
	offset := int(EXTRUSION_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		extrusion_artifact_put_u64(bytes, offset, layer.move_offset)
		extrusion_artifact_put_u32(bytes, offset+8, layer.move_count)
		offset += int(EXTRUSION_ARTIFACT_LAYER_SIZE)
	}
	for move in result.moves {
		extrusion_artifact_put_u64(
			bytes,
			offset,
			u64(move.stable_id),
		)
		extrusion_artifact_put_u64(
			bytes,
			offset+8,
			u64(move.planned_move_id),
		)
		extrusion_artifact_put_u64(
			bytes,
			offset+16,
			u64(move.path_id),
		)
		extrusion_artifact_put_u32(
			bytes,
			offset+24,
			move.planned_move_index,
		)
		extrusion_artifact_put_u32(
			bytes,
			offset+28,
			move.layer_index,
		)
		bytes[offset+32] = u8(move.role)
		extrusion_artifact_put_u32(
			bytes,
			offset+40,
			u32(move.flow_ratio),
		)
		extrusion_artifact_put_i64(
			bytes,
			offset+48,
			i64(move.layer_height),
		)
		extrusion_artifact_put_i64(
			bytes,
			offset+56,
			i64(move.line_width_a),
		)
		extrusion_artifact_put_i64(
			bytes,
			offset+64,
			i64(move.line_width_b),
		)
		extrusion_artifact_put_u128(
			bytes,
			offset+72,
			move.distance_squared_um_2,
		)
		extrusion_artifact_put_u64(
			bytes,
			offset+88,
			move.path_length_nm,
		)
		extrusion_artifact_put_u128(
			bytes,
			offset+96,
			move.length_error_squared_nm_2,
		)
		extrusion_artifact_put_u128(
			bytes,
			offset+112,
			move.cross_section_numerator,
		)
		extrusion_artifact_put_u128(
			bytes,
			offset+128,
			move.volume_numerator,
		)
		extrusion_artifact_put_u64(
			bytes,
			offset+144,
			move.volume_cubic_um,
		)
		extrusion_artifact_put_u128(
			bytes,
			offset+152,
			move.volume_error_numerator,
		)
		extrusion_artifact_put_u64(
			bytes,
			offset+168,
			move.incremental_filament_nm,
		)
		extrusion_artifact_put_u128(
			bytes,
			offset+176,
			move.remainder_numerator_after,
		)
		offset += int(EXTRUSION_ARTIFACT_MOVE_SIZE)
	}
	return bytes, .None
}

extrusion_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_EXTRUSION_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Extrusion_Artifact, Extrusion_Artifact_Error) {
	summary, preflight_error :=
		extrusion_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Extrusion_Artifact
	extrusion_artifact_get_hash(
		bytes,
		32,
		&artifact.dependencies.path_plan_hash,
	)
	extrusion_artifact_get_hash(
		bytes,
		64,
		&artifact.dependencies.layer_schedule_hash,
	)
	extrusion_artifact_get_hash(
		bytes,
		96,
		&artifact.dependencies.material_hash,
	)
	extrusion_artifact_get_hash(
		bytes,
		128,
		&artifact.dependencies.process_hash,
	)
	extrusion_artifact_get_hash(bytes, 160, &artifact.result_hash)
	result := &artifact.result
	result.policy =
		transmute(profiles.Extrusion_Accumulation_Policy)bytes[192]
	result.cross_section_model =
		transmute(Extrusion_Cross_Section_Model)bytes[193]
	result.pi_scale = extrusion_artifact_get_u64(bytes, 200)
	result.pi_scaled = extrusion_artifact_get_u64(bytes, 208)
	result.filament_diameter = contracts.Micrometres(
		extrusion_artifact_get_i64(bytes, 216),
	)
	result.length_quantum_nm =
		extrusion_artifact_get_u32(bytes, 224)
	result.cross_section_denominator =
		extrusion_artifact_get_u64(bytes, 232)
	result.volume_denominator =
		extrusion_artifact_get_u64(bytes, 240)
	result.filament_length_denominator =
		extrusion_artifact_get_u128(bytes, 248)
	result.quantized_length_denominator =
		extrusion_artifact_get_u128(bytes, 264)
	result.total_volume_numerator =
		extrusion_artifact_get_u128(bytes, 296)
	result.total_volume_cubic_um =
		extrusion_artifact_get_u64(bytes, 312)
	result.total_volume_error_numerator =
		extrusion_artifact_get_u128(bytes, 320)
	result.total_filament_nm =
		extrusion_artifact_get_u128(bytes, 336)
	result.final_remainder_numerator =
		extrusion_artifact_get_u128(bytes, 352)
	result.layers = make(
		[]Extrusion_Layer,
		int(summary.layer_count),
		allocator,
	)
	result.moves = make(
		[]Extrusion_Move,
		int(summary.move_count),
		allocator,
	)
	if summary.layer_count > 0 && result.layers == nil ||
	   summary.move_count > 0 && result.moves == nil {
		extrusion_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	offset := int(EXTRUSION_ARTIFACT_HEADER_SIZE)
	for &layer in result.layers {
		if !extrusion_artifact_bytes_zero(bytes, offset+12, offset+16) {
			extrusion_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		layer.move_offset = extrusion_artifact_get_u64(bytes, offset)
		layer.move_count = extrusion_artifact_get_u32(bytes, offset+8)
		offset += int(EXTRUSION_ARTIFACT_LAYER_SIZE)
	}
	for &move in result.moves {
		if !extrusion_artifact_bytes_zero(bytes, offset+33, offset+40) ||
		   !extrusion_artifact_bytes_zero(bytes, offset+44, offset+48) {
			extrusion_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		move.stable_id = contracts.Stable_ID(
			extrusion_artifact_get_u64(bytes, offset),
		)
		move.planned_move_id = contracts.Stable_ID(
			extrusion_artifact_get_u64(bytes, offset+8),
		)
		move.path_id = contracts.Stable_ID(
			extrusion_artifact_get_u64(bytes, offset+16),
		)
		move.planned_move_index =
			extrusion_artifact_get_u32(bytes, offset+24)
		move.layer_index =
			extrusion_artifact_get_u32(bytes, offset+28)
		move.role =
			transmute(profiles.Printable_Role)bytes[offset+32]
		move.flow_ratio = profiles.Ratio_Ppm(
			extrusion_artifact_get_u32(bytes, offset+40),
		)
		move.layer_height = contracts.Micrometres(
			extrusion_artifact_get_i64(bytes, offset+48),
		)
		move.line_width_a = contracts.Micrometres(
			extrusion_artifact_get_i64(bytes, offset+56),
		)
		move.line_width_b = contracts.Micrometres(
			extrusion_artifact_get_i64(bytes, offset+64),
		)
		move.distance_squared_um_2 =
			extrusion_artifact_get_u128(bytes, offset+72)
		move.path_length_nm =
			extrusion_artifact_get_u64(bytes, offset+88)
		move.length_error_squared_nm_2 =
			extrusion_artifact_get_u128(bytes, offset+96)
		move.cross_section_numerator =
			extrusion_artifact_get_u128(bytes, offset+112)
		move.volume_numerator =
			extrusion_artifact_get_u128(bytes, offset+128)
		move.volume_cubic_um =
			extrusion_artifact_get_u64(bytes, offset+144)
		move.volume_error_numerator =
			extrusion_artifact_get_u128(bytes, offset+152)
		move.incremental_filament_nm =
			extrusion_artifact_get_u64(bytes, offset+168)
		move.remainder_numerator_after =
			extrusion_artifact_get_u128(bytes, offset+176)
		offset += int(EXTRUSION_ARTIFACT_MOVE_SIZE)
	}
	calculated_hash, result_ok := extrusion_result_content_hash(
		artifact.dependencies,
		artifact.result,
	)
	if !result_ok {
		extrusion_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		extrusion_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

extrusion_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_EXTRUSION_ARTIFACT_LIMITS,
) -> (Extrusion_Artifact_Summary, Extrusion_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(EXTRUSION_ARTIFACT_HEADER_SIZE) ||
	   !extrusion_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if extrusion_artifact_get_u32(bytes, 8) !=
	   EXTRUSION_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	layout_valid :=
		extrusion_artifact_get_u32(bytes, 12) ==
			EXTRUSION_ARTIFACT_HEADER_SIZE &&
		extrusion_artifact_get_u32(bytes, 16) ==
			EXTRUSION_ARTIFACT_LAYER_SIZE &&
		extrusion_artifact_get_u32(bytes, 20) ==
			EXTRUSION_ARTIFACT_MOVE_SIZE &&
		extrusion_artifact_get_u32(bytes, 24) ==
			SCHEMA_VERSION_EXTRUSION_HASH
	if !layout_valid ||
	   !extrusion_artifact_bytes_zero(bytes, 28, 32) ||
	   !extrusion_artifact_bytes_zero(bytes, 194, 200) ||
	   !extrusion_artifact_bytes_zero(bytes, 228, 232) ||
	   !extrusion_artifact_bytes_zero(bytes, 368, 384) {
		return {}, .Malformed
	}
	layer_count := extrusion_artifact_get_u64(bytes, 280)
	move_count := extrusion_artifact_get_u64(bytes, 288)
	byte_count, size_ok :=
		extrusion_artifact_byte_count(layer_count, move_count)
	if !size_ok ||
	   !extrusion_artifact_counts_fit_limits(
		layer_count,
		move_count,
		byte_count,
		limits,
	   ) ||
	   layer_count > u64(max(int)) ||
	   move_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}
	return {
		layer_count = layer_count,
		move_count = move_count,
		byte_count = byte_count,
		total_volume_cubic_um =
			extrusion_artifact_get_u64(bytes, 312),
		total_volume_numerator =
			extrusion_artifact_get_u128(bytes, 296),
		total_filament_nm =
			extrusion_artifact_get_u128(bytes, 336),
	}, .None
}

extrusion_artifact_destroy :: proc(
	artifact: ^Extrusion_Artifact,
	allocator := context.allocator,
) {
	extrusion_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

extrusion_artifact_byte_count :: proc(
	layer_count, move_count: u64,
) -> (u64, bool) {
	result := u64(EXTRUSION_ARTIFACT_HEADER_SIZE)
	if layer_count >
	   (max(u64)-result)/u64(EXTRUSION_ARTIFACT_LAYER_SIZE) {
		return 0, false
	}
	result += layer_count*u64(EXTRUSION_ARTIFACT_LAYER_SIZE)
	if move_count >
	   (max(u64)-result)/u64(EXTRUSION_ARTIFACT_MOVE_SIZE) {
		return 0, false
	}
	return result+move_count*u64(EXTRUSION_ARTIFACT_MOVE_SIZE), true
}

extrusion_artifact_counts_fit_limits :: proc(
	layer_count, move_count, byte_count: u64,
	limits: Extrusion_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		move_count <= limits.max_moves &&
		byte_count <= limits.max_bytes
}

extrusion_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for byte, byte_index in EXTRUSION_ARTIFACT_MAGIC {
		if bytes[byte_index] != byte {return false}
	}
	return true
}

extrusion_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

extrusion_artifact_put_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: contracts.Content_Hash,
) {
	for byte, byte_index in hash {
		bytes[offset+byte_index] = byte
	}
}

extrusion_artifact_get_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: ^contracts.Content_Hash,
) {
	copy(hash[:], bytes[offset:offset+len(hash)])
}

extrusion_artifact_put_u32 :: proc(
	bytes: []u8,
	offset: int,
	value: u32,
) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

extrusion_artifact_put_u64 :: proc(
	bytes: []u8,
	offset: int,
	value: u64,
) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

extrusion_artifact_put_i64 :: proc(
	bytes: []u8,
	offset: int,
	value: i64,
) {
	extrusion_artifact_put_u64(bytes, offset, transmute(u64)value)
}

extrusion_artifact_put_u128 :: proc(
	bytes: []u8,
	offset: int,
	value: u128,
) {
	extrusion_artifact_put_u64(bytes, offset, u64(value))
	extrusion_artifact_put_u64(bytes, offset+8, u64(value>>64))
}

extrusion_artifact_get_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	result: u32
	for byte_index in 0..<4 {
		result |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return result
}

extrusion_artifact_get_u64 :: proc(bytes: []u8, offset: int) -> u64 {
	result: u64
	for byte_index in 0..<8 {
		result |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return result
}

extrusion_artifact_get_i64 :: proc(bytes: []u8, offset: int) -> i64 {
	return transmute(i64)extrusion_artifact_get_u64(bytes, offset)
}

extrusion_artifact_get_u128 :: proc(bytes: []u8, offset: int) -> u128 {
	return u128(extrusion_artifact_get_u64(bytes, offset)) |
		u128(extrusion_artifact_get_u64(bytes, offset+8))<<64
}
