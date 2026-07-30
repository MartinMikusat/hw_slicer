package evidence

import contracts "../contracts"
import features "../features"

PATH_PLAN_ARTIFACT_SCHEMA_VERSION :: u32(1)
PATH_PLAN_ARTIFACT_HEADER_SIZE    :: u32(192)
PATH_PLAN_ARTIFACT_LAYER_SIZE     :: u32(24)
PATH_PLAN_ARTIFACT_PATH_SIZE      :: u32(64)
PATH_PLAN_ARTIFACT_MOVE_SIZE      :: u32(56)
PATH_PLAN_ARTIFACT_FORMAT         :: "hws-path-plan-le"

PATH_PLAN_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'P', 'L', 'A', 'N', '\n',
}

Path_Plan_Artifact_Limits :: struct {
	max_layers: u64,
	max_paths:  u64,
	max_moves:  u64,
	max_bytes:  u64,
}

DEFAULT_PATH_PLAN_ARTIFACT_LIMITS :: Path_Plan_Artifact_Limits{
	max_layers = 10_000_000,
	max_paths = 1_000_000_000,
	max_moves = 4_000_000_000,
	max_bytes = 1024*1024*1024,
}

Path_Plan_Artifact :: struct {
	perimeter_hash: contracts.Content_Hash,
	infill_hash:    contracts.Content_Hash,
	result_hash:    contracts.Content_Hash,
	result:         features.Path_Plan_Result,
}

Path_Plan_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

path_plan_artifact_encode :: proc(
	perimeter_hash, infill_hash: contracts.Content_Hash,
	result: features.Path_Plan_Result,
	limits := DEFAULT_PATH_PLAN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Path_Plan_Artifact_Error) {
	result_hash, result_ok := features.path_plan_result_hash(
		perimeter_hash,
		infill_hash,
		result,
	)
	if !result_ok {return nil, .Invalid_Record}

	layer_count := u64(len(result.layers))
	path_count := u64(len(result.paths))
	move_count := u64(len(result.moves))
	byte_count, size_ok := path_plan_artifact_byte_count(
		layer_count,
		path_count,
		move_count,
	)
	if !size_ok ||
	   layer_count > limits.max_layers ||
	   path_count > limits.max_paths ||
	   move_count > limits.max_moves ||
	   byte_count > limits.max_bytes ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}

	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in PATH_PLAN_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	path_plan_artifact_put_u32(bytes, 8, PATH_PLAN_ARTIFACT_SCHEMA_VERSION)
	path_plan_artifact_put_u32(bytes, 12, PATH_PLAN_ARTIFACT_HEADER_SIZE)
	path_plan_artifact_put_u32(bytes, 16, PATH_PLAN_ARTIFACT_LAYER_SIZE)
	path_plan_artifact_put_u32(bytes, 20, PATH_PLAN_ARTIFACT_PATH_SIZE)
	path_plan_artifact_put_u32(bytes, 24, PATH_PLAN_ARTIFACT_MOVE_SIZE)
	for byte, byte_index in perimeter_hash {
		bytes[32+byte_index] = byte
	}
	for byte, byte_index in infill_hash {
		bytes[64+byte_index] = byte
	}
	for byte, byte_index in result_hash {
		bytes[96+byte_index] = byte
	}
	path_plan_artifact_put_i64(bytes, 128, i64(result.config.start.x))
	path_plan_artifact_put_i64(bytes, 136, i64(result.config.start.y))
	path_plan_artifact_put_u32(bytes, 144, u32(result.topology_policy))
	flags: u32
	if result.config.inner_perimeters_first {flags = 1}
	path_plan_artifact_put_u32(bytes, 148, flags)
	path_plan_artifact_put_u64(bytes, 152, layer_count)
	path_plan_artifact_put_u64(bytes, 160, path_count)
	path_plan_artifact_put_u64(bytes, 168, move_count)
	path_plan_artifact_put_u64(bytes, 176, result.travel_move_count)
	path_plan_artifact_put_u64(bytes, 184, result.extrude_move_count)

	offset := int(PATH_PLAN_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		path_plan_artifact_put_u64(bytes, offset, layer.path_offset)
		path_plan_artifact_put_u64(bytes, offset+8, layer.move_offset)
		path_plan_artifact_put_u32(bytes, offset+16, layer.path_count)
		path_plan_artifact_put_u32(bytes, offset+20, layer.move_count)
		offset += int(PATH_PLAN_ARTIFACT_LAYER_SIZE)
	}
	for path in result.paths {
		path_plan_artifact_put_u64(bytes, offset, u64(path.stable_id))
		path_plan_artifact_put_u64(bytes, offset+8, u64(path.source_id))
		path_plan_artifact_put_u64(bytes, offset+16, u64(path.region_id))
		path_plan_artifact_put_u64(bytes, offset+24, path.move_offset)
		path_plan_artifact_put_u32(bytes, offset+32, path.source_index)
		path_plan_artifact_put_u32(bytes, offset+36, path.region_index)
		path_plan_artifact_put_u32(bytes, offset+40, path.layer_index)
		path_plan_artifact_put_u32(bytes, offset+44, path.start_index)
		path_plan_artifact_put_u32(bytes, offset+48, path.move_count)
		bytes[offset+52] = u8(path.source_kind)
		bytes[offset+53] = u8(path.reversed)
		bytes[offset+54] = u8(path.closed)
		offset += int(PATH_PLAN_ARTIFACT_PATH_SIZE)
	}
	for move in result.moves {
		path_plan_artifact_put_u64(bytes, offset, u64(move.stable_id))
		path_plan_artifact_put_u64(bytes, offset+8, u64(move.path_id))
		path_plan_artifact_put_i64(bytes, offset+16, i64(move.point_a.x))
		path_plan_artifact_put_i64(bytes, offset+24, i64(move.point_a.y))
		path_plan_artifact_put_i64(bytes, offset+32, i64(move.point_b.x))
		path_plan_artifact_put_i64(bytes, offset+40, i64(move.point_b.y))
		path_plan_artifact_put_u32(bytes, offset+48, move.source_edge_index)
		bytes[offset+52] = u8(move.kind)
		offset += int(PATH_PLAN_ARTIFACT_MOVE_SIZE)
	}
	return bytes, .None
}

path_plan_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_PATH_PLAN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Path_Plan_Artifact, Path_Plan_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(PATH_PLAN_ARTIFACT_HEADER_SIZE) ||
	   !path_plan_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if path_plan_artifact_get_u32(bytes, 8) !=
	   PATH_PLAN_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	if path_plan_artifact_get_u32(bytes, 12) !=
	   PATH_PLAN_ARTIFACT_HEADER_SIZE ||
	   path_plan_artifact_get_u32(bytes, 16) !=
	   PATH_PLAN_ARTIFACT_LAYER_SIZE ||
	   path_plan_artifact_get_u32(bytes, 20) !=
	   PATH_PLAN_ARTIFACT_PATH_SIZE ||
	   path_plan_artifact_get_u32(bytes, 24) !=
	   PATH_PLAN_ARTIFACT_MOVE_SIZE ||
	   !path_plan_artifact_bytes_zero(bytes, 28, 32) {
		return {}, .Malformed
	}

	layer_count := path_plan_artifact_get_u64(bytes, 152)
	path_count := path_plan_artifact_get_u64(bytes, 160)
	move_count := path_plan_artifact_get_u64(bytes, 168)
	byte_count, size_ok := path_plan_artifact_byte_count(
		layer_count,
		path_count,
		move_count,
	)
	if !size_ok ||
	   layer_count > limits.max_layers ||
	   path_count > limits.max_paths ||
	   move_count > limits.max_moves ||
	   byte_count > limits.max_bytes ||
	   layer_count > u64(max(int)) ||
	   path_count > u64(max(int)) ||
	   move_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}

	topology_policy := path_plan_artifact_get_u32(bytes, 144)
	flags := path_plan_artifact_get_u32(bytes, 148)
	if (topology_policy != u32(features.Feature_Topology_Policy.Strict_Printable) &&
	    topology_policy !=
	    	u32(features.Feature_Topology_Policy.Diagnostic_Closed_Regions)) ||
	   flags &~ u32(1) != 0 {
		return {}, .Invalid_Record
	}

	artifact: Path_Plan_Artifact
	copy(artifact.perimeter_hash[:], bytes[32:64])
	copy(artifact.infill_hash[:], bytes[64:96])
	copy(artifact.result_hash[:], bytes[96:128])
	artifact.result.config = {
		start = {
			contracts.Micrometres(
				path_plan_artifact_get_i64(bytes, 128),
			),
			contracts.Micrometres(
				path_plan_artifact_get_i64(bytes, 136),
			),
		},
		inner_perimeters_first = flags & 1 != 0,
	}
	artifact.result.topology_policy =
		transmute(features.Feature_Topology_Policy)topology_policy
	artifact.result.travel_move_count =
		path_plan_artifact_get_u64(bytes, 176)
	artifact.result.extrude_move_count =
		path_plan_artifact_get_u64(bytes, 184)
	artifact.result.layers = make(
		[]features.Planned_Layer,
		int(layer_count),
		allocator,
	)
	artifact.result.paths = make(
		[]features.Planned_Path,
		int(path_count),
		allocator,
	)
	artifact.result.moves = make(
		[]features.Planned_Move,
		int(move_count),
		allocator,
	)
	if layer_count > 0 && artifact.result.layers == nil ||
	   path_count > 0 && artifact.result.paths == nil ||
	   move_count > 0 && artifact.result.moves == nil {
		path_plan_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}

	offset := int(PATH_PLAN_ARTIFACT_HEADER_SIZE)
	for &layer in artifact.result.layers {
		layer.path_offset = path_plan_artifact_get_u64(bytes, offset)
		layer.move_offset = path_plan_artifact_get_u64(bytes, offset+8)
		layer.path_count = path_plan_artifact_get_u32(bytes, offset+16)
		layer.move_count = path_plan_artifact_get_u32(bytes, offset+20)
		offset += int(PATH_PLAN_ARTIFACT_LAYER_SIZE)
	}
	for &path in artifact.result.paths {
		if !path_plan_artifact_bytes_zero(bytes, offset+55, offset+64) ||
		   bytes[offset+53] > 1 || bytes[offset+54] > 1 {
			path_plan_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		path.stable_id = contracts.Stable_ID(
			path_plan_artifact_get_u64(bytes, offset),
		)
		path.source_id = contracts.Stable_ID(
			path_plan_artifact_get_u64(bytes, offset+8),
		)
		path.region_id = contracts.Stable_ID(
			path_plan_artifact_get_u64(bytes, offset+16),
		)
		path.move_offset = path_plan_artifact_get_u64(bytes, offset+24)
		path.source_index = path_plan_artifact_get_u32(bytes, offset+32)
		path.region_index = path_plan_artifact_get_u32(bytes, offset+36)
		path.layer_index = path_plan_artifact_get_u32(bytes, offset+40)
		path.start_index = path_plan_artifact_get_u32(bytes, offset+44)
		path.move_count = path_plan_artifact_get_u32(bytes, offset+48)
		path.source_kind =
			transmute(features.Planned_Source_Kind)bytes[offset+52]
		path.reversed = bytes[offset+53] != 0
		path.closed = bytes[offset+54] != 0
		offset += int(PATH_PLAN_ARTIFACT_PATH_SIZE)
	}
	for &move in artifact.result.moves {
		if !path_plan_artifact_bytes_zero(bytes, offset+53, offset+56) {
			path_plan_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		move.stable_id = contracts.Stable_ID(
			path_plan_artifact_get_u64(bytes, offset),
		)
		move.path_id = contracts.Stable_ID(
			path_plan_artifact_get_u64(bytes, offset+8),
		)
		move.point_a = {
			contracts.Micrometres(
				path_plan_artifact_get_i64(bytes, offset+16),
			),
			contracts.Micrometres(
				path_plan_artifact_get_i64(bytes, offset+24),
			),
		}
		move.point_b = {
			contracts.Micrometres(
				path_plan_artifact_get_i64(bytes, offset+32),
			),
			contracts.Micrometres(
				path_plan_artifact_get_i64(bytes, offset+40),
			),
		}
		move.source_edge_index =
			path_plan_artifact_get_u32(bytes, offset+48)
		move.kind =
			transmute(features.Planned_Move_Kind)bytes[offset+52]
		offset += int(PATH_PLAN_ARTIFACT_MOVE_SIZE)
	}

	calculated_hash, result_ok := features.path_plan_result_hash(
		artifact.perimeter_hash,
		artifact.infill_hash,
		artifact.result,
	)
	if !result_ok {
		path_plan_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		path_plan_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

path_plan_artifact_destroy :: proc(
	artifact: ^Path_Plan_Artifact,
	allocator := context.allocator,
) {
	features.path_plan_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

path_plan_artifact_byte_count :: proc(
	layer_count, path_count, move_count: u64,
) -> (u64, bool) {
	result := u64(PATH_PLAN_ARTIFACT_HEADER_SIZE)
	counts := [3]u64{layer_count, path_count, move_count}
	sizes := [3]u64{
		u64(PATH_PLAN_ARTIFACT_LAYER_SIZE),
		u64(PATH_PLAN_ARTIFACT_PATH_SIZE),
		u64(PATH_PLAN_ARTIFACT_MOVE_SIZE),
	}
	for count, index in counts {
		if count > (max(u64)-result)/sizes[index] {return 0, false}
		result += count*sizes[index]
	}
	return result, true
}

path_plan_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for expected, index in PATH_PLAN_ARTIFACT_MAGIC {
		if bytes[index] != expected {return false}
	}
	return true
}

path_plan_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

path_plan_artifact_put_u32 :: proc(
	bytes: []u8,
	offset: int,
	value: u32,
) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

path_plan_artifact_put_u64 :: proc(
	bytes: []u8,
	offset: int,
	value: u64,
) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

path_plan_artifact_put_i64 :: proc(
	bytes: []u8,
	offset: int,
	value: i64,
) {
	path_plan_artifact_put_u64(bytes, offset, transmute(u64)value)
}

path_plan_artifact_get_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	result: u32
	for byte_index in 0..<4 {
		result |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return result
}

path_plan_artifact_get_u64 :: proc(bytes: []u8, offset: int) -> u64 {
	result: u64
	for byte_index in 0..<8 {
		result |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return result
}

path_plan_artifact_get_i64 :: proc(bytes: []u8, offset: int) -> i64 {
	return transmute(i64)path_plan_artifact_get_u64(bytes, offset)
}
