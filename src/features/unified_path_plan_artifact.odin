package features

import contracts "../contracts"
import profiles "../profiles"

UNIFIED_PATH_PLAN_ARTIFACT_SCHEMA_VERSION :: u32(1)
UNIFIED_PATH_PLAN_ARTIFACT_HEADER_SIZE    :: u32(160)
UNIFIED_PATH_PLAN_ARTIFACT_LAYER_SIZE     :: u32(32)
UNIFIED_PATH_PLAN_ARTIFACT_PATH_SIZE      :: u32(96)
UNIFIED_PATH_PLAN_ARTIFACT_MOVE_SIZE      :: u32(80)
UNIFIED_PATH_PLAN_ARTIFACT_FORMAT         :: "hws-unified-path-plan-le"

UNIFIED_PATH_PLAN_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'U', 'P', 'L', 'N', '\n',
}

Unified_Path_Plan_Artifact_Limits :: struct {
	max_layers: u64,
	max_paths:  u64,
	max_moves:  u64,
	max_bytes:  u64,
}

DEFAULT_UNIFIED_PATH_PLAN_ARTIFACT_LIMITS ::
	Unified_Path_Plan_Artifact_Limits{
		max_layers = 10_000_000,
		max_paths = 100_000_000,
		max_moves = 400_000_000,
		max_bytes = 2*1024*1024*1024,
	}

Unified_Path_Plan_Artifact :: struct {
	source_paths_hash: contracts.Content_Hash,
	result_hash:       contracts.Content_Hash,
	result:            Unified_Path_Plan_Result,
}

Unified_Path_Plan_Artifact_Summary :: struct {
	layer_count:        u64,
	path_count:         u64,
	move_count:         u64,
	travel_move_count:  u64,
	extrude_move_count: u64,
	byte_count:         u64,
}

Unified_Path_Plan_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

unified_path_plan_artifact_encode :: proc(
	source_paths_hash: contracts.Content_Hash,
	layer_ids: []contracts.Stable_ID,
	sources: []Unified_Path_Source,
	result: Unified_Path_Plan_Result,
	limits := DEFAULT_UNIFIED_PATH_PLAN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Unified_Path_Plan_Artifact_Error) {
	result_hash, result_ok := unified_path_plan_result_hash(
		source_paths_hash,
		layer_ids,
		sources,
		result,
		DEFAULT_UNIFIED_PATH_PLAN_LIMITS,
		allocator,
	)
	if !result_ok {return nil, .Invalid_Record}
	layer_count := u64(len(result.layers))
	path_count := u64(len(result.paths))
	move_count := u64(len(result.moves))
	byte_count, size_ok := unified_path_plan_artifact_byte_count(
		layer_count,
		path_count,
		move_count,
	)
	if !size_ok ||
	   !unified_path_plan_artifact_counts_fit_limits(
			layer_count,
			path_count,
			move_count,
			byte_count,
			limits,
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in UNIFIED_PATH_PLAN_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	unified_path_plan_artifact_put_u32(
		bytes,
		8,
		UNIFIED_PATH_PLAN_ARTIFACT_SCHEMA_VERSION,
	)
	unified_path_plan_artifact_put_u32(
		bytes,
		12,
		UNIFIED_PATH_PLAN_ARTIFACT_HEADER_SIZE,
	)
	unified_path_plan_artifact_put_u32(
		bytes,
		16,
		UNIFIED_PATH_PLAN_ARTIFACT_LAYER_SIZE,
	)
	unified_path_plan_artifact_put_u32(
		bytes,
		20,
		UNIFIED_PATH_PLAN_ARTIFACT_PATH_SIZE,
	)
	unified_path_plan_artifact_put_u32(
		bytes,
		24,
		UNIFIED_PATH_PLAN_ARTIFACT_MOVE_SIZE,
	)
	unified_path_plan_artifact_put_u32(
		bytes,
		28,
		SCHEMA_VERSION_UNIFIED_PATH_PLAN_HASH,
	)
	unified_path_plan_artifact_put_hash(bytes, 32, source_paths_hash)
	unified_path_plan_artifact_put_hash(bytes, 64, result_hash)
	unified_path_plan_artifact_put_i64(
		bytes,
		96,
		i64(result.config.start.x),
	)
	unified_path_plan_artifact_put_i64(
		bytes,
		104,
		i64(result.config.start.y),
	)
	bytes[112] = u8(result.config.seam)
	bytes[113] = u8(result.config.seam_visibility)
	unified_path_plan_artifact_put_u64(bytes, 120, layer_count)
	unified_path_plan_artifact_put_u64(bytes, 128, path_count)
	unified_path_plan_artifact_put_u64(bytes, 136, move_count)
	unified_path_plan_artifact_put_u64(
		bytes,
		144,
		result.travel_move_count,
	)
	unified_path_plan_artifact_put_u64(
		bytes,
		152,
		result.extrude_move_count,
	)
	offset := int(UNIFIED_PATH_PLAN_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		unified_path_plan_artifact_put_u64(
			bytes,
			offset,
			layer.path_offset,
		)
		unified_path_plan_artifact_put_u32(
			bytes,
			offset+8,
			layer.path_count,
		)
		unified_path_plan_artifact_put_u64(
			bytes,
			offset+16,
			layer.move_offset,
		)
		unified_path_plan_artifact_put_u32(
			bytes,
			offset+24,
			layer.move_count,
		)
		offset += int(UNIFIED_PATH_PLAN_ARTIFACT_LAYER_SIZE)
	}
	for path in result.paths {
		unified_path_plan_artifact_put_u64(
			bytes,
			offset,
			u64(path.stable_id),
		)
		unified_path_plan_artifact_put_u64(
			bytes,
			offset+8,
			u64(path.path_set_id),
		)
		unified_path_plan_artifact_put_u64(
			bytes,
			offset+16,
			u64(path.source_id),
		)
		unified_path_plan_artifact_put_u64(
			bytes,
			offset+24,
			path.source_order,
		)
		unified_path_plan_artifact_put_u64(
			bytes,
			offset+32,
			u64(path.layer_id),
		)
		unified_path_plan_artifact_put_u64(
			bytes,
			offset+40,
			path.move_offset,
		)
		unified_path_plan_artifact_put_u32(
			bytes,
			offset+48,
			path.source_index,
		)
		unified_path_plan_artifact_put_u32(
			bytes,
			offset+52,
			path.layer_index,
		)
		unified_path_plan_artifact_put_u32(
			bytes,
			offset+56,
			path.start_index,
		)
		unified_path_plan_artifact_put_u32(
			bytes,
			offset+60,
			path.move_count,
		)
		bytes[offset+64] = u8(path.source_kind)
		bytes[offset+65] = u8(path.role)
		bytes[offset+66] = path.priority
		if path.reversed {bytes[offset+67] |= 1}
		if path.closed {bytes[offset+67] |= 2}
		offset += int(UNIFIED_PATH_PLAN_ARTIFACT_PATH_SIZE)
	}
	for move in result.moves {
		unified_path_plan_artifact_put_u64(
			bytes,
			offset,
			u64(move.stable_id),
		)
		unified_path_plan_artifact_put_u64(
			bytes,
			offset+8,
			u64(move.path_id),
		)
		unified_path_plan_artifact_put_i64(
			bytes,
			offset+16,
			i64(move.point_a.x),
		)
		unified_path_plan_artifact_put_i64(
			bytes,
			offset+24,
			i64(move.point_a.y),
		)
		unified_path_plan_artifact_put_i64(
			bytes,
			offset+32,
			i64(move.point_b.x),
		)
		unified_path_plan_artifact_put_i64(
			bytes,
			offset+40,
			i64(move.point_b.y),
		)
		unified_path_plan_artifact_put_i64(
			bytes,
			offset+48,
			i64(move.line_width_a),
		)
		unified_path_plan_artifact_put_i64(
			bytes,
			offset+56,
			i64(move.line_width_b),
		)
		unified_path_plan_artifact_put_u32(
			bytes,
			offset+64,
			move.source_edge_index,
		)
		bytes[offset+68] = u8(move.kind)
		bytes[offset+69] = u8(move.role)
		offset += int(UNIFIED_PATH_PLAN_ARTIFACT_MOVE_SIZE)
	}
	return bytes, .None
}

unified_path_plan_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_UNIFIED_PATH_PLAN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (
	Unified_Path_Plan_Artifact,
	Unified_Path_Plan_Artifact_Error,
) {
	summary, preflight_error :=
		unified_path_plan_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Unified_Path_Plan_Artifact
	unified_path_plan_artifact_get_hash(
		bytes,
		32,
		&artifact.source_paths_hash,
	)
	unified_path_plan_artifact_get_hash(
		bytes,
		64,
		&artifact.result_hash,
	)
	result := &artifact.result
	result.config.start = {
		contracts.Micrometres(
			unified_path_plan_artifact_get_i64(bytes, 96),
		),
		contracts.Micrometres(
			unified_path_plan_artifact_get_i64(bytes, 104),
		),
	}
	result.config.seam =
		transmute(profiles.Seam_Policy)bytes[112]
	result.config.seam_visibility =
		transmute(profiles.Seam_Visibility_Policy)bytes[113]
	result.travel_move_count = summary.travel_move_count
	result.extrude_move_count = summary.extrude_move_count
	result.layers = make(
		[]Unified_Planned_Layer,
		int(summary.layer_count),
		allocator,
	)
	result.paths = make(
		[]Unified_Planned_Path,
		int(summary.path_count),
		allocator,
	)
	result.moves = make(
		[]Unified_Planned_Move,
		int(summary.move_count),
		allocator,
	)
	if summary.layer_count > 0 && result.layers == nil ||
	   summary.path_count > 0 && result.paths == nil ||
	   summary.move_count > 0 && result.moves == nil {
		unified_path_plan_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	offset := int(UNIFIED_PATH_PLAN_ARTIFACT_HEADER_SIZE)
	for &layer in result.layers {
		if !unified_path_plan_artifact_bytes_zero(
			bytes,
			offset+12,
			offset+16,
		) ||
		   !unified_path_plan_artifact_bytes_zero(
			bytes,
			offset+28,
			offset+32,
		   ) {
			unified_path_plan_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		layer.path_offset =
			unified_path_plan_artifact_get_u64(bytes, offset)
		layer.path_count =
			unified_path_plan_artifact_get_u32(bytes, offset+8)
		layer.move_offset =
			unified_path_plan_artifact_get_u64(bytes, offset+16)
		layer.move_count =
			unified_path_plan_artifact_get_u32(bytes, offset+24)
		offset += int(UNIFIED_PATH_PLAN_ARTIFACT_LAYER_SIZE)
	}
	for &path in result.paths {
		flags := bytes[offset+67]
		if flags&~u8(3) != 0 ||
		   !unified_path_plan_artifact_bytes_zero(
			bytes,
			offset+68,
			offset+96,
		   ) {
			unified_path_plan_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		path.stable_id = contracts.Stable_ID(
			unified_path_plan_artifact_get_u64(bytes, offset),
		)
		path.path_set_id = contracts.Stable_ID(
			unified_path_plan_artifact_get_u64(bytes, offset+8),
		)
		path.source_id = contracts.Stable_ID(
			unified_path_plan_artifact_get_u64(bytes, offset+16),
		)
		path.source_order =
			unified_path_plan_artifact_get_u64(bytes, offset+24)
		path.layer_id = contracts.Stable_ID(
			unified_path_plan_artifact_get_u64(bytes, offset+32),
		)
		path.move_offset =
			unified_path_plan_artifact_get_u64(bytes, offset+40)
		path.source_index =
			unified_path_plan_artifact_get_u32(bytes, offset+48)
		path.layer_index =
			unified_path_plan_artifact_get_u32(bytes, offset+52)
		path.start_index =
			unified_path_plan_artifact_get_u32(bytes, offset+56)
		path.move_count =
			unified_path_plan_artifact_get_u32(bytes, offset+60)
		path.source_kind =
			transmute(Unified_Path_Source_Kind)bytes[offset+64]
		path.role =
			transmute(profiles.Printable_Role)bytes[offset+65]
		path.priority = bytes[offset+66]
		path.reversed = flags&1 != 0
		path.closed = flags&2 != 0
		offset += int(UNIFIED_PATH_PLAN_ARTIFACT_PATH_SIZE)
	}
	for &move in result.moves {
		if !unified_path_plan_artifact_bytes_zero(
			bytes,
			offset+70,
			offset+80,
		   ) {
			unified_path_plan_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		move.stable_id = contracts.Stable_ID(
			unified_path_plan_artifact_get_u64(bytes, offset),
		)
		move.path_id = contracts.Stable_ID(
			unified_path_plan_artifact_get_u64(bytes, offset+8),
		)
		move.point_a = {
			contracts.Micrometres(
				unified_path_plan_artifact_get_i64(bytes, offset+16),
			),
			contracts.Micrometres(
				unified_path_plan_artifact_get_i64(bytes, offset+24),
			),
		}
		move.point_b = {
			contracts.Micrometres(
				unified_path_plan_artifact_get_i64(bytes, offset+32),
			),
			contracts.Micrometres(
				unified_path_plan_artifact_get_i64(bytes, offset+40),
			),
		}
		move.line_width_a = contracts.Micrometres(
			unified_path_plan_artifact_get_i64(bytes, offset+48),
		)
		move.line_width_b = contracts.Micrometres(
			unified_path_plan_artifact_get_i64(bytes, offset+56),
		)
		move.source_edge_index =
			unified_path_plan_artifact_get_u32(bytes, offset+64)
		move.kind =
			transmute(Planned_Move_Kind)bytes[offset+68]
		move.role =
			transmute(profiles.Printable_Role)bytes[offset+69]
		offset += int(UNIFIED_PATH_PLAN_ARTIFACT_MOVE_SIZE)
	}
	calculated_hash, result_ok :=
		unified_path_plan_result_content_hash(
			artifact.source_paths_hash,
			artifact.result,
		)
	if !result_ok {
		unified_path_plan_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		unified_path_plan_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

unified_path_plan_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_UNIFIED_PATH_PLAN_ARTIFACT_LIMITS,
) -> (
	Unified_Path_Plan_Artifact_Summary,
	Unified_Path_Plan_Artifact_Error,
) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(UNIFIED_PATH_PLAN_ARTIFACT_HEADER_SIZE) ||
	   !unified_path_plan_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if unified_path_plan_artifact_get_u32(bytes, 8) !=
	   UNIFIED_PATH_PLAN_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	layout_valid :=
		unified_path_plan_artifact_get_u32(bytes, 12) ==
			UNIFIED_PATH_PLAN_ARTIFACT_HEADER_SIZE &&
		unified_path_plan_artifact_get_u32(bytes, 16) ==
			UNIFIED_PATH_PLAN_ARTIFACT_LAYER_SIZE &&
		unified_path_plan_artifact_get_u32(bytes, 20) ==
			UNIFIED_PATH_PLAN_ARTIFACT_PATH_SIZE &&
		unified_path_plan_artifact_get_u32(bytes, 24) ==
			UNIFIED_PATH_PLAN_ARTIFACT_MOVE_SIZE &&
		unified_path_plan_artifact_get_u32(bytes, 28) ==
			SCHEMA_VERSION_UNIFIED_PATH_PLAN_HASH
	if !layout_valid ||
	   !unified_path_plan_artifact_bytes_zero(bytes, 114, 120) {
		return {}, .Malformed
	}
	layer_count := unified_path_plan_artifact_get_u64(bytes, 120)
	path_count := unified_path_plan_artifact_get_u64(bytes, 128)
	move_count := unified_path_plan_artifact_get_u64(bytes, 136)
	travel_move_count :=
		unified_path_plan_artifact_get_u64(bytes, 144)
	extrude_move_count :=
		unified_path_plan_artifact_get_u64(bytes, 152)
	byte_count, size_ok := unified_path_plan_artifact_byte_count(
		layer_count,
		path_count,
		move_count,
	)
	if !size_ok ||
	   !unified_path_plan_artifact_counts_fit_limits(
			layer_count,
			path_count,
			move_count,
			byte_count,
			limits,
	   ) ||
	   layer_count > u64(max(int)) ||
	   path_count > u64(max(int)) ||
	   move_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}
	return {
		layer_count = layer_count,
		path_count = path_count,
		move_count = move_count,
		travel_move_count = travel_move_count,
		extrude_move_count = extrude_move_count,
		byte_count = byte_count,
	}, .None
}

unified_path_plan_artifact_destroy :: proc(
	artifact: ^Unified_Path_Plan_Artifact,
	allocator := context.allocator,
) {
	unified_path_plan_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

unified_path_plan_artifact_byte_count :: proc(
	layer_count, path_count, move_count: u64,
) -> (u64, bool) {
	result := u64(UNIFIED_PATH_PLAN_ARTIFACT_HEADER_SIZE)
	if layer_count >
	   (max(u64)-result)/u64(UNIFIED_PATH_PLAN_ARTIFACT_LAYER_SIZE) {
		return 0, false
	}
	result += layer_count*u64(UNIFIED_PATH_PLAN_ARTIFACT_LAYER_SIZE)
	if path_count >
	   (max(u64)-result)/u64(UNIFIED_PATH_PLAN_ARTIFACT_PATH_SIZE) {
		return 0, false
	}
	result += path_count*u64(UNIFIED_PATH_PLAN_ARTIFACT_PATH_SIZE)
	if move_count >
	   (max(u64)-result)/u64(UNIFIED_PATH_PLAN_ARTIFACT_MOVE_SIZE) {
		return 0, false
	}
	return result+
		move_count*u64(UNIFIED_PATH_PLAN_ARTIFACT_MOVE_SIZE), true
}

unified_path_plan_artifact_counts_fit_limits :: proc(
	layer_count, path_count, move_count, byte_count: u64,
	limits: Unified_Path_Plan_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		path_count <= limits.max_paths &&
		move_count <= limits.max_moves &&
		byte_count <= limits.max_bytes
}

unified_path_plan_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for byte, byte_index in UNIFIED_PATH_PLAN_ARTIFACT_MAGIC {
		if bytes[byte_index] != byte {return false}
	}
	return true
}

unified_path_plan_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

unified_path_plan_artifact_put_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: contracts.Content_Hash,
) {
	for byte, byte_index in hash {
		bytes[offset+byte_index] = byte
	}
}

unified_path_plan_artifact_get_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: ^contracts.Content_Hash,
) {
	copy(hash[:], bytes[offset:offset+len(hash)])
}

unified_path_plan_artifact_put_u32 :: proc(
	bytes: []u8,
	offset: int,
	value: u32,
) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

unified_path_plan_artifact_put_u64 :: proc(
	bytes: []u8,
	offset: int,
	value: u64,
) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

unified_path_plan_artifact_put_i64 :: proc(
	bytes: []u8,
	offset: int,
	value: i64,
) {
	unified_path_plan_artifact_put_u64(
		bytes,
		offset,
		transmute(u64)value,
	)
}

unified_path_plan_artifact_get_u32 :: proc(
	bytes: []u8,
	offset: int,
) -> u32 {
	result: u32
	for byte_index in 0..<4 {
		result |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return result
}

unified_path_plan_artifact_get_u64 :: proc(
	bytes: []u8,
	offset: int,
) -> u64 {
	result: u64
	for byte_index in 0..<8 {
		result |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return result
}

unified_path_plan_artifact_get_i64 :: proc(
	bytes: []u8,
	offset: int,
) -> i64 {
	return transmute(i64)unified_path_plan_artifact_get_u64(
		bytes,
		offset,
	)
}
