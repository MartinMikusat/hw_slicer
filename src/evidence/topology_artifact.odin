package evidence

import "core:slice"

import contracts "../contracts"
import geometry "../geometry"
import slicing "../slicing"

TOPOLOGY_ARTIFACT_SCHEMA_VERSION :: u32(1)
TOPOLOGY_ARTIFACT_HEADER_SIZE    :: u32(192)
TOPOLOGY_ARTIFACT_LAYER_SIZE     :: u32(24)
TOPOLOGY_ARTIFACT_VERTEX_SIZE    :: u32(32)
TOPOLOGY_ARTIFACT_PATH_SIZE      :: u32(72)
TOPOLOGY_ARTIFACT_INDEX_SIZE     :: u32(4)
TOPOLOGY_ARTIFACT_FORMAT         :: "hws-topology-le"

TOPOLOGY_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'T', 'O', 'P', 'O', '\n',
}

Topology_Artifact_Limits :: struct {
	max_layers:               u64,
	max_vertices:             u64,
	max_paths:                u64,
	max_path_vertex_indices:  u64,
	max_path_segment_indices: u64,
	max_source_segments:      u64,
	max_bytes:                u64,
}

DEFAULT_TOPOLOGY_ARTIFACT_LIMITS :: Topology_Artifact_Limits{
	max_layers = 10_000_000,
	max_vertices = 2_000_000_000,
	max_paths = 1_000_000_000,
	max_path_vertex_indices = 2_000_000_000,
	max_path_segment_indices = 2_000_000_000,
	max_source_segments = 2_000_000_000,
	max_bytes = 1024*1024*1024,
}

Topology_Artifact :: struct {
	snapped_hash:         contracts.Content_Hash,
	result_hash:          contracts.Content_Hash,
	source_segment_count: u64,
	result:               slicing.Topology_Result,
}

Topology_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

topology_artifact_encode :: proc(
	snapped_hash: contracts.Content_Hash,
	source_segment_count: int,
	result: slicing.Topology_Result,
	limits := DEFAULT_TOPOLOGY_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Topology_Artifact_Error) {
	result_hash, result_ok := slicing.topology_result_hash(
		snapped_hash,
		source_segment_count,
		result,
	)
	if !result_ok {return nil, .Invalid_Record}

	layer_count := u64(len(result.layers))
	vertex_count := u64(len(result.vertices))
	path_count := u64(len(result.paths))
	path_vertex_count := u64(len(result.path_vertex_indices))
	path_segment_count := u64(len(result.path_segment_indices))
	byte_count, size_ok := topology_artifact_byte_count(
		layer_count,
		vertex_count,
		path_count,
		path_vertex_count,
		path_segment_count,
	)
	if !size_ok ||
	   !topology_artifact_counts_fit_limits(
	   	u64(source_segment_count),
	   	layer_count,
	   	vertex_count,
	   	path_count,
	   	path_vertex_count,
	   	path_segment_count,
	   	byte_count,
	   	limits,
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	semantic_ok, allocation_failed :=
		topology_artifact_result_semantics_valid(
			source_segment_count,
			result,
			allocator,
		)
	if allocation_failed {return nil, .Allocation_Failed}
	if !semantic_ok {return nil, .Invalid_Record}

	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in TOPOLOGY_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	topology_artifact_put_u32(bytes, 8, TOPOLOGY_ARTIFACT_SCHEMA_VERSION)
	topology_artifact_put_u32(bytes, 12, TOPOLOGY_ARTIFACT_HEADER_SIZE)
	topology_artifact_put_u32(bytes, 16, TOPOLOGY_ARTIFACT_LAYER_SIZE)
	topology_artifact_put_u32(bytes, 20, TOPOLOGY_ARTIFACT_VERTEX_SIZE)
	topology_artifact_put_u32(bytes, 24, TOPOLOGY_ARTIFACT_PATH_SIZE)
	topology_artifact_put_u32(bytes, 28, TOPOLOGY_ARTIFACT_INDEX_SIZE)
	for byte, byte_index in snapped_hash {
		bytes[32+byte_index] = byte
	}
	for byte, byte_index in result_hash {
		bytes[64+byte_index] = byte
	}
	topology_artifact_put_u64(bytes, 96, u64(source_segment_count))
	topology_artifact_put_u64(bytes, 104, layer_count)
	topology_artifact_put_u64(bytes, 112, vertex_count)
	topology_artifact_put_u64(bytes, 120, path_count)
	topology_artifact_put_u64(bytes, 128, path_vertex_count)
	topology_artifact_put_u64(bytes, 136, path_segment_count)
	topology_artifact_put_u64(bytes, 144, result.open_chain_count)
	topology_artifact_put_u64(
		bytes,
		152,
		result.degenerate_loop_count,
	)
	topology_artifact_put_u64(
		bytes,
		160,
		result.non_manifold_vertex_count,
	)

	offset := int(TOPOLOGY_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		topology_artifact_put_u64(bytes, offset, layer.vertex_offset)
		topology_artifact_put_u32(bytes, offset+8, layer.vertex_count)
		topology_artifact_put_u64(bytes, offset+12, layer.path_offset)
		topology_artifact_put_u32(bytes, offset+20, layer.path_count)
		offset += int(TOPOLOGY_ARTIFACT_LAYER_SIZE)
	}
	for vertex in result.vertices {
		topology_artifact_put_u64(bytes, offset, u64(vertex.id))
		topology_artifact_put_u32(bytes, offset+8, vertex.layer_index)
		topology_artifact_put_u32(bytes, offset+12, vertex.degree)
		topology_artifact_put_i64(bytes, offset+16, i64(vertex.point.x))
		topology_artifact_put_i64(bytes, offset+24, i64(vertex.point.y))
		offset += int(TOPOLOGY_ARTIFACT_VERTEX_SIZE)
	}
	for path in result.paths {
		topology_artifact_put_u64(bytes, offset, u64(path.id))
		topology_artifact_put_u32(bytes, offset+8, path.layer_index)
		bytes[offset+12] = u8(path.kind)
		topology_artifact_put_u64(bytes, offset+16, path.vertex_offset)
		topology_artifact_put_u32(bytes, offset+24, path.vertex_count)
		topology_artifact_put_u64(bytes, offset+32, path.segment_offset)
		topology_artifact_put_u32(bytes, offset+40, path.segment_count)
		topology_artifact_put_i128(bytes, offset+48, path.signed_area_2)
		bytes[offset+64] = u8(i8(path.winding)+1)
		offset += int(TOPOLOGY_ARTIFACT_PATH_SIZE)
	}
	for vertex_index in result.path_vertex_indices {
		topology_artifact_put_u32(bytes, offset, vertex_index)
		offset += int(TOPOLOGY_ARTIFACT_INDEX_SIZE)
	}
	for segment_index in result.path_segment_indices {
		topology_artifact_put_u32(bytes, offset, segment_index)
		offset += int(TOPOLOGY_ARTIFACT_INDEX_SIZE)
	}
	return bytes, .None
}

topology_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_TOPOLOGY_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Topology_Artifact, Topology_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(TOPOLOGY_ARTIFACT_HEADER_SIZE) ||
	   !topology_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if topology_artifact_get_u32(bytes, 8) !=
	   TOPOLOGY_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	if topology_artifact_get_u32(bytes, 12) !=
	   TOPOLOGY_ARTIFACT_HEADER_SIZE ||
	   topology_artifact_get_u32(bytes, 16) !=
	   TOPOLOGY_ARTIFACT_LAYER_SIZE ||
	   topology_artifact_get_u32(bytes, 20) !=
	   TOPOLOGY_ARTIFACT_VERTEX_SIZE ||
	   topology_artifact_get_u32(bytes, 24) !=
	   TOPOLOGY_ARTIFACT_PATH_SIZE ||
	   topology_artifact_get_u32(bytes, 28) !=
	   TOPOLOGY_ARTIFACT_INDEX_SIZE ||
	   !topology_artifact_bytes_zero(bytes, 168, 192) {
		return {}, .Malformed
	}

	source_segment_count := topology_artifact_get_u64(bytes, 96)
	layer_count := topology_artifact_get_u64(bytes, 104)
	vertex_count := topology_artifact_get_u64(bytes, 112)
	path_count := topology_artifact_get_u64(bytes, 120)
	path_vertex_count := topology_artifact_get_u64(bytes, 128)
	path_segment_count := topology_artifact_get_u64(bytes, 136)
	byte_count, size_ok := topology_artifact_byte_count(
		layer_count,
		vertex_count,
		path_count,
		path_vertex_count,
		path_segment_count,
	)
	if !size_ok ||
	   !topology_artifact_counts_fit_limits(
	   	source_segment_count,
	   	layer_count,
	   	vertex_count,
	   	path_count,
	   	path_vertex_count,
	   	path_segment_count,
	   	byte_count,
	   	limits,
	   ) ||
	   source_segment_count > u64(max(int)) ||
	   layer_count > u64(max(int)) ||
	   vertex_count > u64(max(int)) ||
	   path_count > u64(max(int)) ||
	   path_vertex_count > u64(max(int)) ||
	   path_segment_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}

	artifact: Topology_Artifact
	copy(artifact.snapped_hash[:], bytes[32:64])
	copy(artifact.result_hash[:], bytes[64:96])
	artifact.source_segment_count = source_segment_count
	artifact.result.open_chain_count =
		topology_artifact_get_u64(bytes, 144)
	artifact.result.degenerate_loop_count =
		topology_artifact_get_u64(bytes, 152)
	artifact.result.non_manifold_vertex_count =
		topology_artifact_get_u64(bytes, 160)
	artifact.result.layers = make(
		[]slicing.Topology_Layer,
		int(layer_count),
		allocator,
	)
	artifact.result.vertices = make(
		[]slicing.Topology_Vertex,
		int(vertex_count),
		allocator,
	)
	artifact.result.paths = make(
		[]slicing.Topology_Path,
		int(path_count),
		allocator,
	)
	artifact.result.path_vertex_indices = make(
		[]u32,
		int(path_vertex_count),
		allocator,
	)
	artifact.result.path_segment_indices = make(
		[]u32,
		int(path_segment_count),
		allocator,
	)
	if layer_count > 0 && artifact.result.layers == nil ||
	   vertex_count > 0 && artifact.result.vertices == nil ||
	   path_count > 0 && artifact.result.paths == nil ||
	   path_vertex_count > 0 &&
	   	artifact.result.path_vertex_indices == nil ||
	   path_segment_count > 0 &&
	   	artifact.result.path_segment_indices == nil {
		topology_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}

	offset := int(TOPOLOGY_ARTIFACT_HEADER_SIZE)
	for &layer in artifact.result.layers {
		layer.vertex_offset = topology_artifact_get_u64(bytes, offset)
		layer.vertex_count = topology_artifact_get_u32(bytes, offset+8)
		layer.path_offset = topology_artifact_get_u64(bytes, offset+12)
		layer.path_count = topology_artifact_get_u32(bytes, offset+20)
		offset += int(TOPOLOGY_ARTIFACT_LAYER_SIZE)
	}
	for &vertex in artifact.result.vertices {
		vertex.id = contracts.Stable_ID(
			topology_artifact_get_u64(bytes, offset),
		)
		vertex.layer_index = topology_artifact_get_u32(bytes, offset+8)
		vertex.degree = topology_artifact_get_u32(bytes, offset+12)
		vertex.point = {
			contracts.Micrometres(
				topology_artifact_get_i64(bytes, offset+16),
			),
			contracts.Micrometres(
				topology_artifact_get_i64(bytes, offset+24),
			),
		}
		offset += int(TOPOLOGY_ARTIFACT_VERTEX_SIZE)
	}
	for &path in artifact.result.paths {
		if !topology_artifact_bytes_zero(bytes, offset+13, offset+16) ||
		   !topology_artifact_bytes_zero(bytes, offset+28, offset+32) ||
		   !topology_artifact_bytes_zero(bytes, offset+44, offset+48) ||
		   !topology_artifact_bytes_zero(bytes, offset+65, offset+72) ||
		   bytes[offset+12] < u8(slicing.Topology_Path_Kind.Loop) ||
		   bytes[offset+12] >
		   	u8(slicing.Topology_Path_Kind.Degenerate_Loop) ||
		   bytes[offset+64] > 2 {
			topology_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		path.id = contracts.Stable_ID(
			topology_artifact_get_u64(bytes, offset),
		)
		path.layer_index = topology_artifact_get_u32(bytes, offset+8)
		path.kind =
			transmute(slicing.Topology_Path_Kind)bytes[offset+12]
		path.vertex_offset = topology_artifact_get_u64(bytes, offset+16)
		path.vertex_count = topology_artifact_get_u32(bytes, offset+24)
		path.segment_offset = topology_artifact_get_u64(bytes, offset+32)
		path.segment_count = topology_artifact_get_u32(bytes, offset+40)
		path.signed_area_2 =
			topology_artifact_get_i128(bytes, offset+48)
		path.winding = geometry.Predicate_Sign(
			i8(bytes[offset+64])-1,
		)
		offset += int(TOPOLOGY_ARTIFACT_PATH_SIZE)
	}
	for &vertex_index in artifact.result.path_vertex_indices {
		vertex_index = topology_artifact_get_u32(bytes, offset)
		offset += int(TOPOLOGY_ARTIFACT_INDEX_SIZE)
	}
	for &segment_index in artifact.result.path_segment_indices {
		segment_index = topology_artifact_get_u32(bytes, offset)
		offset += int(TOPOLOGY_ARTIFACT_INDEX_SIZE)
	}

	calculated_hash, result_ok := slicing.topology_result_hash(
		artifact.snapped_hash,
		int(source_segment_count),
		artifact.result,
	)
	if !result_ok {
		topology_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	semantic_ok, allocation_failed :=
		topology_artifact_result_semantics_valid(
			int(source_segment_count),
			artifact.result,
			allocator,
		)
	if allocation_failed {
		topology_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	if !semantic_ok {
		topology_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		topology_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

topology_artifact_destroy :: proc(
	artifact: ^Topology_Artifact,
	allocator := context.allocator,
) {
	slicing.topology_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

topology_artifact_result_semantics_valid :: proc(
	source_segment_count: int,
	result: slicing.Topology_Result,
	allocator := context.allocator,
) -> (valid, allocation_failed: bool) {
	if source_segment_count < 0 ||
	   len(result.path_segment_indices) != source_segment_count {
		return false, false
	}
	open_chain_count: u64
	degenerate_loop_count: u64
	non_manifold_vertex_count: u64
	degrees := make([]u32, len(result.vertices), allocator)
	segment_seen := make(
		[]u8,
		(source_segment_count+7)/8,
		allocator,
	)
	vertex_ids := make([]u64, len(result.vertices), allocator)
	path_ids := make([]u64, len(result.paths), allocator)
	if len(result.vertices) > 0 &&
	   (degrees == nil || vertex_ids == nil) ||
	   source_segment_count > 0 && segment_seen == nil ||
	   len(result.paths) > 0 && path_ids == nil {
		delete(degrees, allocator)
		delete(segment_seen, allocator)
		delete(vertex_ids, allocator)
		delete(path_ids, allocator)
		return false, true
	}
	defer delete(degrees, allocator)
	defer delete(segment_seen, allocator)
	defer delete(vertex_ids, allocator)
	defer delete(path_ids, allocator)

	for layer, layer_index in result.layers {
		vertex_end := layer.vertex_offset+u64(layer.vertex_count)
		for vertex_index in layer.vertex_offset..<vertex_end {
			if result.vertices[vertex_index].layer_index != u32(layer_index) {
				return false, false
			}
		}
		path_end := layer.path_offset+u64(layer.path_count)
		for path_index in layer.path_offset..<path_end {
			if result.paths[path_index].layer_index != u32(layer_index) {
				return false, false
			}
		}
	}
	for vertex, vertex_index in result.vertices {
		vertex_ids[vertex_index] = u64(vertex.id)
		if vertex.degree > 2 {non_manifold_vertex_count += 1}
	}
	for path, path_index in result.paths {
		path_ids[path_index] = u64(path.id)
		vertices := result.path_vertex_indices[
			path.vertex_offset:
			path.vertex_offset+u64(path.vertex_count)
		]
		segments := result.path_segment_indices[
			path.segment_offset:
			path.segment_offset+u64(path.segment_count)
		]
		switch path.kind {
		case .Loop:
			if len(vertices) < 2 ||
			   path.winding == .Zero ||
			   path.signed_area_2 == 0 {
				return false, false
			}
		case .Degenerate_Loop:
			degenerate_loop_count += 1
			if len(vertices) < 2 ||
			   path.winding != .Zero ||
			   path.signed_area_2 != 0 {
				return false, false
			}
		case .Open_Chain:
			open_chain_count += 1
			if len(vertices) < 2 ||
			   path.winding != .Zero ||
			   path.signed_area_2 != 0 {
				return false, false
			}
		case .Invalid:
			return false, false
		}
		if path.kind == .Loop || path.kind == .Degenerate_Loop {
			area, winding :=
				slicing.topology_path_area(result.vertices, vertices)
			if area != path.signed_area_2 || winding != path.winding {
				return false, false
			}
		}
		for vertex_index, local_index in vertices {
			vertex := result.vertices[vertex_index]
			if vertex.layer_index != path.layer_index {return false, false}
			addition := u32(2)
			if path.kind == .Open_Chain &&
			   (local_index == 0 || local_index == len(vertices)-1) {
				addition = 1
			}
			if degrees[vertex_index] > max(u32)-addition {
				return false, false
			}
			degrees[vertex_index] += addition
		}
		for segment_index in segments {
			byte_index := int(segment_index/8)
			mask := u8(1<<u8(segment_index%8))
			if segment_seen[byte_index]&mask != 0 {
				return false, false
			}
			segment_seen[byte_index] |= mask
		}
	}
	for vertex, vertex_index in result.vertices {
		if degrees[vertex_index] != vertex.degree {return false, false}
	}
	for segment_index in 0..<source_segment_count {
		if segment_seen[segment_index/8]&u8(1<<u8(segment_index%8)) == 0 {
			return false, false
		}
	}
	slice.sort(vertex_ids)
	for id, id_index in vertex_ids[1:] {
		if id == vertex_ids[id_index] {return false, false}
	}
	slice.sort(path_ids)
	for id, id_index in path_ids[1:] {
		if id == path_ids[id_index] {return false, false}
	}
	return open_chain_count == result.open_chain_count &&
		degenerate_loop_count == result.degenerate_loop_count &&
		non_manifold_vertex_count == result.non_manifold_vertex_count,
		false
}

topology_artifact_counts_fit_limits :: proc(
	source_segment_count, layer_count, vertex_count, path_count: u64,
	path_vertex_count, path_segment_count, byte_count: u64,
	limits: Topology_Artifact_Limits,
) -> bool {
	return source_segment_count <= limits.max_source_segments &&
		layer_count <= limits.max_layers &&
		vertex_count <= limits.max_vertices &&
		path_count <= limits.max_paths &&
		path_vertex_count <= limits.max_path_vertex_indices &&
		path_segment_count <= limits.max_path_segment_indices &&
		byte_count <= limits.max_bytes
}

topology_artifact_byte_count :: proc(
	layer_count, vertex_count, path_count: u64,
	path_vertex_count, path_segment_count: u64,
) -> (u64, bool) {
	result := u64(TOPOLOGY_ARTIFACT_HEADER_SIZE)
	counts := [5]u64{
		layer_count,
		vertex_count,
		path_count,
		path_vertex_count,
		path_segment_count,
	}
	sizes := [5]u64{
		u64(TOPOLOGY_ARTIFACT_LAYER_SIZE),
		u64(TOPOLOGY_ARTIFACT_VERTEX_SIZE),
		u64(TOPOLOGY_ARTIFACT_PATH_SIZE),
		u64(TOPOLOGY_ARTIFACT_INDEX_SIZE),
		u64(TOPOLOGY_ARTIFACT_INDEX_SIZE),
	}
	for count, count_index in counts {
		if count > (max(u64)-result)/sizes[count_index] {
			return 0, false
		}
		result += count*sizes[count_index]
	}
	return result, true
}

topology_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for expected, byte_index in TOPOLOGY_ARTIFACT_MAGIC {
		if bytes[byte_index] != expected {return false}
	}
	return true
}

topology_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

topology_artifact_put_u32 :: proc(
	bytes: []u8,
	offset: int,
	value: u32,
) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

topology_artifact_get_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	value: u32
	for byte_index in 0..<4 {
		value |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return value
}

topology_artifact_put_u64 :: proc(
	bytes: []u8,
	offset: int,
	value: u64,
) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

topology_artifact_get_u64 :: proc(bytes: []u8, offset: int) -> u64 {
	value: u64
	for byte_index in 0..<8 {
		value |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return value
}

topology_artifact_put_i64 :: proc(
	bytes: []u8,
	offset: int,
	value: i64,
) {
	topology_artifact_put_u64(bytes, offset, transmute(u64)value)
}

topology_artifact_get_i64 :: proc(bytes: []u8, offset: int) -> i64 {
	return transmute(i64)topology_artifact_get_u64(bytes, offset)
}

topology_artifact_put_i128 :: proc(
	bytes: []u8,
	offset: int,
	value: i128,
) {
	unsigned := transmute(u128)value
	for byte_index in 0..<16 {
		bytes[offset+byte_index] =
			u8(unsigned>>u128(byte_index*8))
	}
}

topology_artifact_get_i128 :: proc(bytes: []u8, offset: int) -> i128 {
	value: u128
	for byte_index in 0..<16 {
		value |= u128(bytes[offset+byte_index])<<u128(byte_index*8)
	}
	return transmute(i128)value
}
