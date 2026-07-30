package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"

PERIMETER_ARTIFACT_SCHEMA_VERSION :: u32(1)
PERIMETER_ARTIFACT_HEADER_SIZE    :: u32(192)
PERIMETER_ARTIFACT_LAYER_SIZE     :: u32(32)
PERIMETER_ARTIFACT_GROUP_SIZE     :: u32(64)
PERIMETER_ARTIFACT_PATH_SIZE      :: u32(64)
PERIMETER_ARTIFACT_POINT_SIZE     :: u32(16)
PERIMETER_ARTIFACT_FORMAT         :: "hws-perimeters-le"

PERIMETER_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'P', 'E', 'R', 'I', '\n',
}

Perimeter_Artifact_Limits :: struct {
	max_layers: u64,
	max_groups: u64,
	max_paths:  u64,
	max_points: u64,
	max_bytes:  u64,
}

DEFAULT_PERIMETER_ARTIFACT_LIMITS :: Perimeter_Artifact_Limits{
	max_layers = 10_000_000,
	max_groups = 100_000_000,
	max_paths = 200_000_000,
	max_points = 1_000_000_000,
	max_bytes = 2*1024*1024*1024,
}

Perimeter_Artifact :: struct {
	region_hash: contracts.Content_Hash,
	result_hash: contracts.Content_Hash,
	result:      Perimeter_Result,
}

Perimeter_Artifact_Summary :: struct {
	layer_count: u64,
	group_count: u64,
	path_count:  u64,
	point_count: u64,
	byte_count:  u64,
}

Perimeter_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

perimeter_artifact_encode :: proc(
	region_hash: contracts.Content_Hash,
	result: Perimeter_Result,
	limits := DEFAULT_PERIMETER_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Perimeter_Artifact_Error) {
	result_hash, result_ok := perimeter_result_hash(region_hash, result)
	if !result_ok {return nil, .Invalid_Record}
	layer_count := u64(len(result.layers))
	group_count := u64(len(result.groups))
	path_count := u64(len(result.paths))
	point_count := u64(len(result.points))
	byte_count, size_ok := perimeter_artifact_byte_count(
		layer_count,
		group_count,
		path_count,
		point_count,
	)
	if !size_ok ||
	   !perimeter_artifact_counts_fit_limits(
			layer_count,
			group_count,
			path_count,
			point_count,
			byte_count,
			limits,
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in PERIMETER_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	perimeter_artifact_put_u32(
		bytes,
		8,
		PERIMETER_ARTIFACT_SCHEMA_VERSION,
	)
	perimeter_artifact_put_u32(bytes, 12, PERIMETER_ARTIFACT_HEADER_SIZE)
	perimeter_artifact_put_u32(bytes, 16, PERIMETER_ARTIFACT_LAYER_SIZE)
	perimeter_artifact_put_u32(bytes, 20, PERIMETER_ARTIFACT_GROUP_SIZE)
	perimeter_artifact_put_u32(bytes, 24, PERIMETER_ARTIFACT_PATH_SIZE)
	perimeter_artifact_put_u32(bytes, 28, PERIMETER_ARTIFACT_POINT_SIZE)
	perimeter_artifact_put_u32(bytes, 32, SCHEMA_VERSION_PERIMETER_HASH)
	perimeter_artifact_put_hash(bytes, 40, region_hash)
	perimeter_artifact_put_hash(bytes, 72, result_hash)
	perimeter_artifact_put_u32(bytes, 104, result.config.count)
	perimeter_artifact_put_u32(
		bytes,
		108,
		u32(result.config.topology_policy),
	)
	perimeter_artifact_put_i64(
		bytes,
		112,
		i64(result.config.line_width),
	)
	perimeter_artifact_put_u64(
		bytes,
		120,
		transmute(u64)result.config.miter_limit,
	)
	perimeter_artifact_put_u64(
		bytes,
		128,
		transmute(u64)result.config.arc_tolerance,
	)
	perimeter_artifact_put_u64(bytes, 136, layer_count)
	perimeter_artifact_put_u64(bytes, 144, group_count)
	perimeter_artifact_put_u64(bytes, 152, path_count)
	perimeter_artifact_put_u64(bytes, 160, point_count)
	bytes[168] = u8(result.config.join_type)

	offset := int(PERIMETER_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		perimeter_artifact_put_u64(bytes, offset, layer.group_offset)
		perimeter_artifact_put_u32(bytes, offset+8, layer.group_count)
		perimeter_artifact_put_u64(bytes, offset+16, layer.path_offset)
		perimeter_artifact_put_u32(bytes, offset+24, layer.path_count)
		offset += int(PERIMETER_ARTIFACT_LAYER_SIZE)
	}
	for group in result.groups {
		perimeter_artifact_put_u64(
			bytes,
			offset,
			u64(group.region_id),
		)
		perimeter_artifact_put_u32(bytes, offset+8, group.region_index)
		perimeter_artifact_put_u32(bytes, offset+12, group.layer_index)
		perimeter_artifact_put_u32(
			bytes,
			offset+16,
			group.perimeter_index,
		)
		perimeter_artifact_put_u32(bytes, offset+20, group.path_count)
		perimeter_artifact_put_i64(bytes, offset+24, i64(group.delta))
		perimeter_artifact_put_u64(bytes, offset+32, group.path_offset)
		offset += int(PERIMETER_ARTIFACT_GROUP_SIZE)
	}
	for path in result.paths {
		perimeter_artifact_put_u64(
			bytes,
			offset,
			u64(path.stable_id),
		)
		perimeter_artifact_put_u64(
			bytes,
			offset+8,
			u64(path.region_id),
		)
		perimeter_artifact_put_u32(bytes, offset+16, path.region_index)
		perimeter_artifact_put_u32(bytes, offset+20, path.layer_index)
		perimeter_artifact_put_u32(
			bytes,
			offset+24,
			path.perimeter_index,
		)
		perimeter_artifact_put_u32(
			bytes,
			offset+28,
			path.group_path_index,
		)
		perimeter_artifact_put_u64(bytes, offset+32, path.point_offset)
		perimeter_artifact_put_u32(bytes, offset+40, path.point_count)
		bytes[offset+44] = u8(i8(path.winding)+1)
		perimeter_artifact_put_i128(
			bytes,
			offset+48,
			path.signed_area_2,
		)
		offset += int(PERIMETER_ARTIFACT_PATH_SIZE)
	}
	for point in result.points {
		perimeter_artifact_put_i64(bytes, offset, i64(point.x))
		perimeter_artifact_put_i64(bytes, offset+8, i64(point.y))
		offset += int(PERIMETER_ARTIFACT_POINT_SIZE)
	}
	return bytes, .None
}

perimeter_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_PERIMETER_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Perimeter_Artifact, Perimeter_Artifact_Error) {
	summary, preflight_error := perimeter_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Perimeter_Artifact
	perimeter_artifact_get_hash(bytes, 40, &artifact.region_hash)
	perimeter_artifact_get_hash(bytes, 72, &artifact.result_hash)
	result := &artifact.result
	result.config.count = perimeter_artifact_get_u32(bytes, 104)
	topology_policy := perimeter_artifact_get_u32(bytes, 108)
	result.config.topology_policy =
		transmute(Feature_Topology_Policy)topology_policy
	result.config.line_width = contracts.Micrometres(
		perimeter_artifact_get_i64(bytes, 112),
	)
	result.config.miter_limit =
		transmute(f64)perimeter_artifact_get_u64(bytes, 120)
	result.config.arc_tolerance =
		transmute(f64)perimeter_artifact_get_u64(bytes, 128)
	result.config.join_type =
		transmute(polygon.Polygon_Join_Type)bytes[168]
	result.layers = make(
		[]Perimeter_Layer,
		int(summary.layer_count),
		allocator,
	)
	result.groups = make(
		[]Perimeter_Group,
		int(summary.group_count),
		allocator,
	)
	result.paths = make(
		[]Perimeter_Path,
		int(summary.path_count),
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		int(summary.point_count),
		allocator,
	)
	if summary.layer_count > 0 && result.layers == nil ||
	   summary.group_count > 0 && result.groups == nil ||
	   summary.path_count > 0 && result.paths == nil ||
	   summary.point_count > 0 && result.points == nil {
		perimeter_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}

	offset := int(PERIMETER_ARTIFACT_HEADER_SIZE)
	for &layer in result.layers {
		if !perimeter_artifact_bytes_zero(
			bytes,
			offset+12,
			offset+16,
		   ) ||
		   !perimeter_artifact_bytes_zero(
		   	bytes,
		   	offset+28,
		   	offset+32,
		   ) {
			perimeter_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		layer.group_offset = perimeter_artifact_get_u64(bytes, offset)
		layer.group_count = perimeter_artifact_get_u32(bytes, offset+8)
		layer.path_offset =
			perimeter_artifact_get_u64(bytes, offset+16)
		layer.path_count =
			perimeter_artifact_get_u32(bytes, offset+24)
		offset += int(PERIMETER_ARTIFACT_LAYER_SIZE)
	}
	for &group in result.groups {
		if !perimeter_artifact_bytes_zero(
			bytes,
			offset+40,
			offset+64,
		   ) {
			perimeter_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		group.region_id = contracts.Stable_ID(
			perimeter_artifact_get_u64(bytes, offset),
		)
		group.region_index =
			perimeter_artifact_get_u32(bytes, offset+8)
		group.layer_index =
			perimeter_artifact_get_u32(bytes, offset+12)
		group.perimeter_index =
			perimeter_artifact_get_u32(bytes, offset+16)
		group.path_count =
			perimeter_artifact_get_u32(bytes, offset+20)
		group.delta = contracts.Micrometres(
			perimeter_artifact_get_i64(bytes, offset+24),
		)
		group.path_offset =
			perimeter_artifact_get_u64(bytes, offset+32)
		offset += int(PERIMETER_ARTIFACT_GROUP_SIZE)
	}
	for &path in result.paths {
		if bytes[offset+44] > 2 ||
		   !perimeter_artifact_bytes_zero(
		   	bytes,
		   	offset+45,
		   	offset+48,
		   ) {
			perimeter_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		path.stable_id = contracts.Stable_ID(
			perimeter_artifact_get_u64(bytes, offset),
		)
		path.region_id = contracts.Stable_ID(
			perimeter_artifact_get_u64(bytes, offset+8),
		)
		path.region_index =
			perimeter_artifact_get_u32(bytes, offset+16)
		path.layer_index =
			perimeter_artifact_get_u32(bytes, offset+20)
		path.perimeter_index =
			perimeter_artifact_get_u32(bytes, offset+24)
		path.group_path_index =
			perimeter_artifact_get_u32(bytes, offset+28)
		path.point_offset =
			perimeter_artifact_get_u64(bytes, offset+32)
		path.point_count =
			perimeter_artifact_get_u32(bytes, offset+40)
		path.winding = geometry.Predicate_Sign(
			i8(bytes[offset+44])-1,
		)
		path.signed_area_2 =
			perimeter_artifact_get_i128(bytes, offset+48)
		offset += int(PERIMETER_ARTIFACT_PATH_SIZE)
	}
	for &point in result.points {
		point.x = contracts.Micrometres(
			perimeter_artifact_get_i64(bytes, offset),
		)
		point.y = contracts.Micrometres(
			perimeter_artifact_get_i64(bytes, offset+8),
		)
		offset += int(PERIMETER_ARTIFACT_POINT_SIZE)
	}
	calculated_hash, result_ok :=
		perimeter_result_hash(artifact.region_hash, artifact.result)
	if !result_ok {
		perimeter_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		perimeter_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

perimeter_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_PERIMETER_ARTIFACT_LIMITS,
) -> (Perimeter_Artifact_Summary, Perimeter_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(PERIMETER_ARTIFACT_HEADER_SIZE) ||
	   !perimeter_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if perimeter_artifact_get_u32(bytes, 8) !=
	   PERIMETER_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	layout_valid :=
		perimeter_artifact_get_u32(bytes, 12) ==
			PERIMETER_ARTIFACT_HEADER_SIZE &&
		perimeter_artifact_get_u32(bytes, 16) ==
			PERIMETER_ARTIFACT_LAYER_SIZE &&
		perimeter_artifact_get_u32(bytes, 20) ==
			PERIMETER_ARTIFACT_GROUP_SIZE &&
		perimeter_artifact_get_u32(bytes, 24) ==
			PERIMETER_ARTIFACT_PATH_SIZE &&
		perimeter_artifact_get_u32(bytes, 28) ==
			PERIMETER_ARTIFACT_POINT_SIZE &&
		perimeter_artifact_get_u32(bytes, 32) ==
			SCHEMA_VERSION_PERIMETER_HASH
	if !layout_valid ||
	   !perimeter_artifact_bytes_zero(bytes, 36, 40) ||
	   !perimeter_artifact_bytes_zero(bytes, 169, 192) {
		return {}, .Malformed
	}
	layer_count := perimeter_artifact_get_u64(bytes, 136)
	group_count := perimeter_artifact_get_u64(bytes, 144)
	path_count := perimeter_artifact_get_u64(bytes, 152)
	point_count := perimeter_artifact_get_u64(bytes, 160)
	byte_count, size_ok := perimeter_artifact_byte_count(
		layer_count,
		group_count,
		path_count,
		point_count,
	)
	if !size_ok ||
	   !perimeter_artifact_counts_fit_limits(
			layer_count,
			group_count,
			path_count,
			point_count,
			byte_count,
			limits,
	   ) ||
	   layer_count > u64(max(int)) ||
	   group_count > u64(max(int)) ||
	   path_count > u64(max(int)) ||
	   point_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}
	return {
		layer_count = layer_count,
		group_count = group_count,
		path_count = path_count,
		point_count = point_count,
		byte_count = byte_count,
	}, .None
}

perimeter_artifact_destroy :: proc(
	artifact: ^Perimeter_Artifact,
	allocator := context.allocator,
) {
	perimeter_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

perimeter_artifact_byte_count :: proc(
	layer_count, group_count, path_count, point_count: u64,
) -> (u64, bool) {
	result := u64(PERIMETER_ARTIFACT_HEADER_SIZE)
	if layer_count >
	   (max(u64)-result)/u64(PERIMETER_ARTIFACT_LAYER_SIZE) {
		return 0, false
	}
	result += layer_count*u64(PERIMETER_ARTIFACT_LAYER_SIZE)
	if group_count >
	   (max(u64)-result)/u64(PERIMETER_ARTIFACT_GROUP_SIZE) {
		return 0, false
	}
	result += group_count*u64(PERIMETER_ARTIFACT_GROUP_SIZE)
	if path_count >
	   (max(u64)-result)/u64(PERIMETER_ARTIFACT_PATH_SIZE) {
		return 0, false
	}
	result += path_count*u64(PERIMETER_ARTIFACT_PATH_SIZE)
	if point_count >
	   (max(u64)-result)/u64(PERIMETER_ARTIFACT_POINT_SIZE) {
		return 0, false
	}
	return result+point_count*u64(PERIMETER_ARTIFACT_POINT_SIZE), true
}

perimeter_artifact_counts_fit_limits :: proc(
	layer_count, group_count, path_count, point_count, byte_count: u64,
	limits: Perimeter_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		group_count <= limits.max_groups &&
		path_count <= limits.max_paths &&
		point_count <= limits.max_points &&
		byte_count <= limits.max_bytes
}

perimeter_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for byte, byte_index in PERIMETER_ARTIFACT_MAGIC {
		if bytes[byte_index] != byte {return false}
	}
	return true
}

perimeter_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

perimeter_artifact_put_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: contracts.Content_Hash,
) {
	for byte, byte_index in hash {
		bytes[offset+byte_index] = byte
	}
}

perimeter_artifact_get_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: ^contracts.Content_Hash,
) {
	copy(hash[:], bytes[offset:offset+len(hash)])
}

perimeter_artifact_put_u32 :: proc(
	bytes: []u8,
	offset: int,
	value: u32,
) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

perimeter_artifact_put_u64 :: proc(
	bytes: []u8,
	offset: int,
	value: u64,
) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

perimeter_artifact_put_i64 :: proc(
	bytes: []u8,
	offset: int,
	value: i64,
) {
	perimeter_artifact_put_u64(bytes, offset, transmute(u64)value)
}

perimeter_artifact_put_i128 :: proc(
	bytes: []u8,
	offset: int,
	value: i128,
) {
	unsigned := transmute(u128)value
	perimeter_artifact_put_u64(bytes, offset, u64(unsigned))
	perimeter_artifact_put_u64(bytes, offset+8, u64(unsigned>>64))
}

perimeter_artifact_get_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	value: u32
	for byte_index in 0..<4 {
		value |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return value
}

perimeter_artifact_get_u64 :: proc(bytes: []u8, offset: int) -> u64 {
	value: u64
	for byte_index in 0..<8 {
		value |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return value
}

perimeter_artifact_get_i64 :: proc(bytes: []u8, offset: int) -> i64 {
	return transmute(i64)perimeter_artifact_get_u64(bytes, offset)
}

perimeter_artifact_get_i128 :: proc(bytes: []u8, offset: int) -> i128 {
	value := u128(perimeter_artifact_get_u64(bytes, offset)) |
		u128(perimeter_artifact_get_u64(bytes, offset+8))<<64
	return transmute(i128)value
}
