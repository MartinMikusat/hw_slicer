package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"

SURFACE_ARTIFACT_SCHEMA_VERSION :: u32(1)
SURFACE_ARTIFACT_HEADER_SIZE    :: u32(192)
SURFACE_ARTIFACT_LAYER_SIZE     :: u32(32)
SURFACE_ARTIFACT_MASK_SIZE      :: u32(64)
SURFACE_ARTIFACT_PATH_SIZE      :: u32(64)
SURFACE_ARTIFACT_POINT_SIZE     :: u32(16)
SURFACE_ARTIFACT_FORMAT         :: "hws-surfaces-le"

SURFACE_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'S', 'U', 'R', 'F', '\n',
}

Surface_Artifact_Limits :: struct {
	max_layers: u64,
	max_masks:  u64,
	max_paths:  u64,
	max_points: u64,
	max_bytes:  u64,
}

DEFAULT_SURFACE_ARTIFACT_LIMITS :: Surface_Artifact_Limits{
	max_layers = 10_000_000,
	max_masks = 200_000_000,
	max_paths = 400_000_000,
	max_points = 2_000_000_000,
	max_bytes = 2*1024*1024*1024,
}

Surface_Artifact :: struct {
	region_hash: contracts.Content_Hash,
	result_hash: contracts.Content_Hash,
	result:      Surface_Result,
}

Surface_Artifact_Summary :: struct {
	layer_count:       u64,
	mask_count:        u64,
	path_count:        u64,
	point_count:       u64,
	bottom_mask_count: u64,
	top_mask_count:    u64,
	byte_count:        u64,
}

Surface_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

surface_artifact_encode :: proc(
	region_hash: contracts.Content_Hash,
	result: Surface_Result,
	limits := DEFAULT_SURFACE_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Surface_Artifact_Error) {
	result_hash, result_ok := surface_result_hash(region_hash, result)
	if !result_ok {return nil, .Invalid_Record}
	layer_count := u64(len(result.layers))
	mask_count := u64(len(result.masks))
	path_count := u64(len(result.paths))
	point_count := u64(len(result.points))
	byte_count, size_ok := surface_artifact_byte_count(
		layer_count,
		mask_count,
		path_count,
		point_count,
	)
	if !size_ok ||
	   !surface_artifact_counts_fit_limits(
			layer_count,
			mask_count,
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
	for byte, byte_index in SURFACE_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	surface_artifact_put_u32(bytes, 8, SURFACE_ARTIFACT_SCHEMA_VERSION)
	surface_artifact_put_u32(bytes, 12, SURFACE_ARTIFACT_HEADER_SIZE)
	surface_artifact_put_u32(bytes, 16, SURFACE_ARTIFACT_LAYER_SIZE)
	surface_artifact_put_u32(bytes, 20, SURFACE_ARTIFACT_MASK_SIZE)
	surface_artifact_put_u32(bytes, 24, SURFACE_ARTIFACT_PATH_SIZE)
	surface_artifact_put_u32(bytes, 28, SURFACE_ARTIFACT_POINT_SIZE)
	surface_artifact_put_u32(bytes, 32, SCHEMA_VERSION_SURFACE_HASH)
	surface_artifact_put_hash(bytes, 40, region_hash)
	surface_artifact_put_hash(bytes, 72, result_hash)
	surface_artifact_put_u32(
		bytes,
		104,
		u32(result.config.topology_policy),
	)
	bytes[108] = u8(result.config.fill_rule)
	surface_artifact_put_u64(bytes, 112, result.bottom_mask_count)
	surface_artifact_put_u64(bytes, 120, result.top_mask_count)
	surface_artifact_put_u64(bytes, 128, layer_count)
	surface_artifact_put_u64(bytes, 136, mask_count)
	surface_artifact_put_u64(bytes, 144, path_count)
	surface_artifact_put_u64(bytes, 152, point_count)

	offset := int(SURFACE_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		surface_artifact_put_u64(bytes, offset, layer.mask_offset)
		surface_artifact_put_u32(bytes, offset+8, layer.mask_count)
		surface_artifact_put_u64(bytes, offset+16, layer.path_offset)
		surface_artifact_put_u32(bytes, offset+24, layer.path_count)
		offset += int(SURFACE_ARTIFACT_LAYER_SIZE)
	}
	for mask in result.masks {
		surface_artifact_put_u64(
			bytes,
			offset,
			u64(mask.stable_id),
		)
		surface_artifact_put_u64(
			bytes,
			offset+8,
			u64(mask.region_id),
		)
		surface_artifact_put_u32(bytes, offset+16, mask.region_index)
		surface_artifact_put_u32(bytes, offset+20, mask.layer_index)
		bytes[offset+24] = u8(mask.kind)
		surface_artifact_put_u64(bytes, offset+32, mask.path_offset)
		surface_artifact_put_u32(bytes, offset+40, mask.path_count)
		surface_artifact_put_u64(bytes, offset+48, mask.point_offset)
		surface_artifact_put_u32(bytes, offset+56, mask.point_count)
		offset += int(SURFACE_ARTIFACT_MASK_SIZE)
	}
	for path in result.paths {
		surface_artifact_put_u64(
			bytes,
			offset,
			u64(path.stable_id),
		)
		surface_artifact_put_u64(bytes, offset+8, u64(path.mask_id))
		surface_artifact_put_u32(
			bytes,
			offset+16,
			path.mask_path_index,
		)
		surface_artifact_put_u32(bytes, offset+20, path.point_count)
		surface_artifact_put_u64(bytes, offset+24, path.point_offset)
		surface_artifact_put_i128(
			bytes,
			offset+32,
			path.signed_area_2,
		)
		bytes[offset+48] = u8(i8(path.winding)+1)
		offset += int(SURFACE_ARTIFACT_PATH_SIZE)
	}
	for point in result.points {
		surface_artifact_put_i64(bytes, offset, i64(point.x))
		surface_artifact_put_i64(bytes, offset+8, i64(point.y))
		offset += int(SURFACE_ARTIFACT_POINT_SIZE)
	}
	return bytes, .None
}

surface_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_SURFACE_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Surface_Artifact, Surface_Artifact_Error) {
	summary, preflight_error := surface_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Surface_Artifact
	surface_artifact_get_hash(bytes, 40, &artifact.region_hash)
	surface_artifact_get_hash(bytes, 72, &artifact.result_hash)
	result := &artifact.result
	topology_policy := surface_artifact_get_u32(bytes, 104)
	result.config.topology_policy =
		transmute(Feature_Topology_Policy)topology_policy
	result.config.fill_rule =
		transmute(polygon.Polygon_Fill_Rule)bytes[108]
	result.bottom_mask_count = summary.bottom_mask_count
	result.top_mask_count = summary.top_mask_count
	result.layers = make(
		[]Surface_Layer,
		int(summary.layer_count),
		allocator,
	)
	result.masks = make(
		[]Surface_Mask,
		int(summary.mask_count),
		allocator,
	)
	result.paths = make(
		[]Surface_Path,
		int(summary.path_count),
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		int(summary.point_count),
		allocator,
	)
	if summary.layer_count > 0 && result.layers == nil ||
	   summary.mask_count > 0 && result.masks == nil ||
	   summary.path_count > 0 && result.paths == nil ||
	   summary.point_count > 0 && result.points == nil {
		surface_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}

	offset := int(SURFACE_ARTIFACT_HEADER_SIZE)
	for &layer in result.layers {
		if !surface_artifact_bytes_zero(
			bytes,
			offset+12,
			offset+16,
		   ) ||
		   !surface_artifact_bytes_zero(
		   	bytes,
		   	offset+28,
		   	offset+32,
		   ) {
			surface_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		layer.mask_offset = surface_artifact_get_u64(bytes, offset)
		layer.mask_count = surface_artifact_get_u32(bytes, offset+8)
		layer.path_offset = surface_artifact_get_u64(bytes, offset+16)
		layer.path_count = surface_artifact_get_u32(bytes, offset+24)
		offset += int(SURFACE_ARTIFACT_LAYER_SIZE)
	}
	for &mask in result.masks {
		if !surface_artifact_bytes_zero(
			bytes,
			offset+25,
			offset+32,
		   ) ||
		   !surface_artifact_bytes_zero(
		   	bytes,
		   	offset+44,
		   	offset+48,
		   ) ||
		   !surface_artifact_bytes_zero(
		   	bytes,
		   	offset+60,
		   	offset+64,
		   ) {
			surface_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		mask.stable_id = contracts.Stable_ID(
			surface_artifact_get_u64(bytes, offset),
		)
		mask.region_id = contracts.Stable_ID(
			surface_artifact_get_u64(bytes, offset+8),
		)
		mask.region_index = surface_artifact_get_u32(bytes, offset+16)
		mask.layer_index = surface_artifact_get_u32(bytes, offset+20)
		mask.kind = transmute(Surface_Kind)bytes[offset+24]
		mask.path_offset = surface_artifact_get_u64(bytes, offset+32)
		mask.path_count = surface_artifact_get_u32(bytes, offset+40)
		mask.point_offset = surface_artifact_get_u64(bytes, offset+48)
		mask.point_count = surface_artifact_get_u32(bytes, offset+56)
		offset += int(SURFACE_ARTIFACT_MASK_SIZE)
	}
	for &path in result.paths {
		if bytes[offset+48] > 2 ||
		   !surface_artifact_bytes_zero(
		   	bytes,
		   	offset+49,
		   	offset+64,
		   ) {
			surface_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		path.stable_id = contracts.Stable_ID(
			surface_artifact_get_u64(bytes, offset),
		)
		path.mask_id = contracts.Stable_ID(
			surface_artifact_get_u64(bytes, offset+8),
		)
		path.mask_path_index =
			surface_artifact_get_u32(bytes, offset+16)
		path.point_count =
			surface_artifact_get_u32(bytes, offset+20)
		path.point_offset =
			surface_artifact_get_u64(bytes, offset+24)
		path.signed_area_2 =
			surface_artifact_get_i128(bytes, offset+32)
		path.winding = geometry.Predicate_Sign(
			i8(bytes[offset+48])-1,
		)
		offset += int(SURFACE_ARTIFACT_PATH_SIZE)
	}
	for &point in result.points {
		point.x = contracts.Micrometres(
			surface_artifact_get_i64(bytes, offset),
		)
		point.y = contracts.Micrometres(
			surface_artifact_get_i64(bytes, offset+8),
		)
		offset += int(SURFACE_ARTIFACT_POINT_SIZE)
	}
	calculated_hash, result_ok :=
		surface_result_hash(artifact.region_hash, artifact.result)
	if !result_ok {
		surface_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		surface_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

surface_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_SURFACE_ARTIFACT_LIMITS,
) -> (Surface_Artifact_Summary, Surface_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(SURFACE_ARTIFACT_HEADER_SIZE) ||
	   !surface_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if surface_artifact_get_u32(bytes, 8) !=
	   SURFACE_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	layout_valid :=
		surface_artifact_get_u32(bytes, 12) ==
			SURFACE_ARTIFACT_HEADER_SIZE &&
		surface_artifact_get_u32(bytes, 16) ==
			SURFACE_ARTIFACT_LAYER_SIZE &&
		surface_artifact_get_u32(bytes, 20) ==
			SURFACE_ARTIFACT_MASK_SIZE &&
		surface_artifact_get_u32(bytes, 24) ==
			SURFACE_ARTIFACT_PATH_SIZE &&
		surface_artifact_get_u32(bytes, 28) ==
			SURFACE_ARTIFACT_POINT_SIZE &&
		surface_artifact_get_u32(bytes, 32) ==
			SCHEMA_VERSION_SURFACE_HASH
	if !layout_valid ||
	   !surface_artifact_bytes_zero(bytes, 36, 40) ||
	   !surface_artifact_bytes_zero(bytes, 109, 112) ||
	   !surface_artifact_bytes_zero(bytes, 160, 192) {
		return {}, .Malformed
	}
	bottom_mask_count := surface_artifact_get_u64(bytes, 112)
	top_mask_count := surface_artifact_get_u64(bytes, 120)
	layer_count := surface_artifact_get_u64(bytes, 128)
	mask_count := surface_artifact_get_u64(bytes, 136)
	path_count := surface_artifact_get_u64(bytes, 144)
	point_count := surface_artifact_get_u64(bytes, 152)
	byte_count, size_ok := surface_artifact_byte_count(
		layer_count,
		mask_count,
		path_count,
		point_count,
	)
	if !size_ok ||
	   !surface_artifact_counts_fit_limits(
			layer_count,
			mask_count,
			path_count,
			point_count,
			byte_count,
			limits,
	   ) ||
	   layer_count > u64(max(int)) ||
	   mask_count > u64(max(int)) ||
	   path_count > u64(max(int)) ||
	   point_count > u64(max(int)) {
		return {}, .Limit
	}
	if bottom_mask_count > mask_count ||
	   top_mask_count > mask_count-bottom_mask_count ||
	   bottom_mask_count+top_mask_count != mask_count ||
	   byte_count != u64(len(bytes)) {
		return {}, .Malformed
	}
	return {
		layer_count = layer_count,
		mask_count = mask_count,
		path_count = path_count,
		point_count = point_count,
		bottom_mask_count = bottom_mask_count,
		top_mask_count = top_mask_count,
		byte_count = byte_count,
	}, .None
}

surface_artifact_destroy :: proc(
	artifact: ^Surface_Artifact,
	allocator := context.allocator,
) {
	surface_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

surface_artifact_byte_count :: proc(
	layer_count, mask_count, path_count, point_count: u64,
) -> (u64, bool) {
	result := u64(SURFACE_ARTIFACT_HEADER_SIZE)
	if layer_count >
	   (max(u64)-result)/u64(SURFACE_ARTIFACT_LAYER_SIZE) {
		return 0, false
	}
	result += layer_count*u64(SURFACE_ARTIFACT_LAYER_SIZE)
	if mask_count >
	   (max(u64)-result)/u64(SURFACE_ARTIFACT_MASK_SIZE) {
		return 0, false
	}
	result += mask_count*u64(SURFACE_ARTIFACT_MASK_SIZE)
	if path_count >
	   (max(u64)-result)/u64(SURFACE_ARTIFACT_PATH_SIZE) {
		return 0, false
	}
	result += path_count*u64(SURFACE_ARTIFACT_PATH_SIZE)
	if point_count >
	   (max(u64)-result)/u64(SURFACE_ARTIFACT_POINT_SIZE) {
		return 0, false
	}
	return result+point_count*u64(SURFACE_ARTIFACT_POINT_SIZE), true
}

surface_artifact_counts_fit_limits :: proc(
	layer_count, mask_count, path_count, point_count, byte_count: u64,
	limits: Surface_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		mask_count <= limits.max_masks &&
		path_count <= limits.max_paths &&
		point_count <= limits.max_points &&
		byte_count <= limits.max_bytes
}

surface_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for byte, byte_index in SURFACE_ARTIFACT_MAGIC {
		if bytes[byte_index] != byte {return false}
	}
	return true
}

surface_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

surface_artifact_put_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: contracts.Content_Hash,
) {
	for byte, byte_index in hash {
		bytes[offset+byte_index] = byte
	}
}

surface_artifact_get_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: ^contracts.Content_Hash,
) {
	copy(hash[:], bytes[offset:offset+len(hash)])
}

surface_artifact_put_u32 :: proc(
	bytes: []u8,
	offset: int,
	value: u32,
) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

surface_artifact_put_u64 :: proc(
	bytes: []u8,
	offset: int,
	value: u64,
) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

surface_artifact_put_i64 :: proc(
	bytes: []u8,
	offset: int,
	value: i64,
) {
	surface_artifact_put_u64(bytes, offset, transmute(u64)value)
}

surface_artifact_put_i128 :: proc(
	bytes: []u8,
	offset: int,
	value: i128,
) {
	unsigned := transmute(u128)value
	surface_artifact_put_u64(bytes, offset, u64(unsigned))
	surface_artifact_put_u64(bytes, offset+8, u64(unsigned>>64))
}

surface_artifact_get_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	value: u32
	for byte_index in 0..<4 {
		value |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return value
}

surface_artifact_get_u64 :: proc(bytes: []u8, offset: int) -> u64 {
	value: u64
	for byte_index in 0..<8 {
		value |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return value
}

surface_artifact_get_i64 :: proc(bytes: []u8, offset: int) -> i64 {
	return transmute(i64)surface_artifact_get_u64(bytes, offset)
}

surface_artifact_get_i128 :: proc(bytes: []u8, offset: int) -> i128 {
	value := u128(surface_artifact_get_u64(bytes, offset)) |
		u128(surface_artifact_get_u64(bytes, offset+8))<<64
	return transmute(i128)value
}
