package features

import contracts "../contracts"
import polygon "../polygon"

INFILL_ARTIFACT_SCHEMA_VERSION :: u32(1)
INFILL_ARTIFACT_HEADER_SIZE    :: u32(192)
INFILL_ARTIFACT_LAYER_SIZE     :: u32(24)
INFILL_ARTIFACT_SEGMENT_SIZE   :: u32(96)
INFILL_ARTIFACT_HIT_SIZE       :: u32(64)
INFILL_ARTIFACT_FORMAT         :: "hws-infill-le"

INFILL_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'I', 'N', 'F', 'L', '\n',
}

Infill_Artifact_Limits :: struct {
	max_layers:    u64,
	max_segments:  u64,
	max_hits:      u64,
	max_scanlines: u64,
	max_bytes:     u64,
}

DEFAULT_INFILL_ARTIFACT_LIMITS :: Infill_Artifact_Limits{
	max_layers = 10_000_000,
	max_segments = 100_000_000,
	max_hits = 200_000_000,
	max_scanlines = 1_000_000_000,
	max_bytes = 2*1024*1024*1024,
}

Infill_Artifact :: struct {
	region_hash: contracts.Content_Hash,
	result_hash: contracts.Content_Hash,
	result:      Infill_Result,
}

Infill_Artifact_Summary :: struct {
	layer_count:    u64,
	segment_count:  u64,
	hit_count:      u64,
	scanline_count: u64,
	byte_count:     u64,
}

Infill_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

infill_artifact_encode :: proc(
	region_hash: contracts.Content_Hash,
	result: Infill_Result,
	limits := DEFAULT_INFILL_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Infill_Artifact_Error) {
	result_hash, result_ok := infill_result_hash(region_hash, result)
	if !result_ok {return nil, .Invalid_Record}
	layer_count := u64(len(result.layers))
	segment_count := u64(len(result.segments))
	hit_count := u64(len(result.boundary_hits))
	byte_count, size_ok := infill_artifact_byte_count(
		layer_count,
		segment_count,
		hit_count,
	)
	if !size_ok ||
	   !infill_artifact_counts_fit_limits(
			layer_count,
			segment_count,
			hit_count,
			result.scanline_count,
			byte_count,
			limits,
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in INFILL_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	infill_artifact_put_u32(
		bytes,
		8,
		INFILL_ARTIFACT_SCHEMA_VERSION,
	)
	infill_artifact_put_u32(bytes, 12, INFILL_ARTIFACT_HEADER_SIZE)
	infill_artifact_put_u32(bytes, 16, INFILL_ARTIFACT_LAYER_SIZE)
	infill_artifact_put_u32(bytes, 20, INFILL_ARTIFACT_SEGMENT_SIZE)
	infill_artifact_put_u32(bytes, 24, INFILL_ARTIFACT_HIT_SIZE)
	infill_artifact_put_u32(bytes, 28, SCHEMA_VERSION_INFILL_HASH)
	infill_artifact_put_hash(bytes, 32, region_hash)
	infill_artifact_put_hash(bytes, 64, result_hash)
	infill_artifact_put_i64(bytes, 96, i64(result.config.spacing))
	infill_artifact_put_i64(
		bytes,
		104,
		i64(result.config.boundary_inset),
	)
	infill_artifact_put_i64(bytes, 112, i64(result.config.phase))
	infill_artifact_put_u64(
		bytes,
		120,
		transmute(u64)result.config.miter_limit,
	)
	infill_artifact_put_u64(
		bytes,
		128,
		transmute(u64)result.config.arc_tolerance,
	)
	infill_artifact_put_u64(bytes, 136, result.scanline_count)
	infill_artifact_put_u64(bytes, 144, layer_count)
	infill_artifact_put_u64(bytes, 152, segment_count)
	infill_artifact_put_u64(bytes, 160, hit_count)
	infill_artifact_put_u32(
		bytes,
		168,
		u32(result.config.topology_policy),
	)
	bytes[172] = u8(result.config.base_axis)
	if result.config.alternate_each_layer {bytes[173] = 1}
	bytes[174] = u8(result.config.join_type)
	offset := int(INFILL_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		infill_artifact_put_u64(bytes, offset, layer.segment_offset)
		infill_artifact_put_u32(bytes, offset+8, layer.segment_count)
		bytes[offset+12] = u8(layer.axis)
		offset += int(INFILL_ARTIFACT_LAYER_SIZE)
	}
	for segment in result.segments {
		infill_artifact_put_u64(
			bytes,
			offset,
			u64(segment.stable_id),
		)
		infill_artifact_put_u64(
			bytes,
			offset+8,
			u64(segment.region_id),
		)
		infill_artifact_put_u64(
			bytes,
			offset+16,
			segment.region_segment_index,
		)
		infill_artifact_put_i64(
			bytes,
			offset+24,
			i64(segment.line_coordinate),
		)
		infill_artifact_put_i64(
			bytes,
			offset+32,
			i64(segment.point_a.x),
		)
		infill_artifact_put_i64(
			bytes,
			offset+40,
			i64(segment.point_a.y),
		)
		infill_artifact_put_i64(
			bytes,
			offset+48,
			i64(segment.point_b.x),
		)
		infill_artifact_put_i64(
			bytes,
			offset+56,
			i64(segment.point_b.y),
		)
		infill_artifact_put_u64(
			bytes,
			offset+64,
			segment.hit_offset,
		)
		infill_artifact_put_u32(
			bytes,
			offset+72,
			segment.region_index,
		)
		infill_artifact_put_u32(
			bytes,
			offset+76,
			segment.layer_index,
		)
		bytes[offset+80] = u8(segment.axis)
		offset += int(INFILL_ARTIFACT_SEGMENT_SIZE)
	}
	for hit in result.boundary_hits {
		infill_artifact_put_u32(
			bytes,
			offset,
			hit.boundary_path_index,
		)
		infill_artifact_put_u32(
			bytes,
			offset+4,
			hit.boundary_edge_index,
		)
		infill_artifact_put_i128(bytes, offset+8, hit.numerator)
		infill_artifact_put_i128(bytes, offset+24, hit.denominator)
		infill_artifact_put_i64(
			bytes,
			offset+40,
			i64(hit.rounded_coordinate),
		)
		infill_artifact_put_u128(
			bytes,
			offset+48,
			hit.error_numerator,
		)
		offset += int(INFILL_ARTIFACT_HIT_SIZE)
	}
	return bytes, .None
}

infill_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_INFILL_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Infill_Artifact, Infill_Artifact_Error) {
	summary, preflight_error := infill_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Infill_Artifact
	infill_artifact_get_hash(bytes, 32, &artifact.region_hash)
	infill_artifact_get_hash(bytes, 64, &artifact.result_hash)
	result := &artifact.result
	result.config.spacing = contracts.Micrometres(
		infill_artifact_get_i64(bytes, 96),
	)
	result.config.boundary_inset = contracts.Micrometres(
		infill_artifact_get_i64(bytes, 104),
	)
	result.config.phase = contracts.Micrometres(
		infill_artifact_get_i64(bytes, 112),
	)
	result.config.miter_limit =
		transmute(f64)infill_artifact_get_u64(bytes, 120)
	result.config.arc_tolerance =
		transmute(f64)infill_artifact_get_u64(bytes, 128)
	result.scanline_count = summary.scanline_count
	topology_policy := infill_artifact_get_u32(bytes, 168)
	result.config.topology_policy =
		transmute(Feature_Topology_Policy)topology_policy
	result.config.base_axis = transmute(Infill_Axis)bytes[172]
	result.config.alternate_each_layer = bytes[173] != 0
	result.config.join_type =
		transmute(polygon.Polygon_Join_Type)bytes[174]
	result.layers = make(
		[]Infill_Layer,
		int(summary.layer_count),
		allocator,
	)
	result.segments = make(
		[]Infill_Segment,
		int(summary.segment_count),
		allocator,
	)
	result.boundary_hits = make(
		[]Infill_Boundary_Hit,
		int(summary.hit_count),
		allocator,
	)
	if summary.layer_count > 0 && result.layers == nil ||
	   summary.segment_count > 0 && result.segments == nil ||
	   summary.hit_count > 0 && result.boundary_hits == nil {
		infill_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	offset := int(INFILL_ARTIFACT_HEADER_SIZE)
	for &layer in result.layers {
		if !infill_artifact_bytes_zero(
			bytes,
			offset+13,
			offset+24,
		   ) {
			infill_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		layer.segment_offset = infill_artifact_get_u64(bytes, offset)
		layer.segment_count =
			infill_artifact_get_u32(bytes, offset+8)
		layer.axis = transmute(Infill_Axis)bytes[offset+12]
		offset += int(INFILL_ARTIFACT_LAYER_SIZE)
	}
	for &segment in result.segments {
		if !infill_artifact_bytes_zero(
			bytes,
			offset+81,
			offset+96,
		   ) {
			infill_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		segment.stable_id = contracts.Stable_ID(
			infill_artifact_get_u64(bytes, offset),
		)
		segment.region_id = contracts.Stable_ID(
			infill_artifact_get_u64(bytes, offset+8),
		)
		segment.region_segment_index =
			infill_artifact_get_u64(bytes, offset+16)
		segment.line_coordinate = contracts.Micrometres(
			infill_artifact_get_i64(bytes, offset+24),
		)
		segment.point_a = {
			contracts.Micrometres(
				infill_artifact_get_i64(bytes, offset+32),
			),
			contracts.Micrometres(
				infill_artifact_get_i64(bytes, offset+40),
			),
		}
		segment.point_b = {
			contracts.Micrometres(
				infill_artifact_get_i64(bytes, offset+48),
			),
			contracts.Micrometres(
				infill_artifact_get_i64(bytes, offset+56),
			),
		}
		segment.hit_offset =
			infill_artifact_get_u64(bytes, offset+64)
		segment.region_index =
			infill_artifact_get_u32(bytes, offset+72)
		segment.layer_index =
			infill_artifact_get_u32(bytes, offset+76)
		segment.axis = transmute(Infill_Axis)bytes[offset+80]
		offset += int(INFILL_ARTIFACT_SEGMENT_SIZE)
	}
	for &hit in result.boundary_hits {
		hit.boundary_path_index =
			infill_artifact_get_u32(bytes, offset)
		hit.boundary_edge_index =
			infill_artifact_get_u32(bytes, offset+4)
		hit.numerator = infill_artifact_get_i128(bytes, offset+8)
		hit.denominator = infill_artifact_get_i128(bytes, offset+24)
		hit.rounded_coordinate = contracts.Micrometres(
			infill_artifact_get_i64(bytes, offset+40),
		)
		hit.error_numerator =
			infill_artifact_get_u128(bytes, offset+48)
		offset += int(INFILL_ARTIFACT_HIT_SIZE)
	}
	calculated_hash, result_ok :=
		infill_result_hash(artifact.region_hash, artifact.result)
	if !result_ok {
		infill_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		infill_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

infill_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_INFILL_ARTIFACT_LIMITS,
) -> (Infill_Artifact_Summary, Infill_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(INFILL_ARTIFACT_HEADER_SIZE) ||
	   !infill_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if infill_artifact_get_u32(bytes, 8) !=
	   INFILL_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	layout_valid :=
		infill_artifact_get_u32(bytes, 12) ==
			INFILL_ARTIFACT_HEADER_SIZE &&
		infill_artifact_get_u32(bytes, 16) ==
			INFILL_ARTIFACT_LAYER_SIZE &&
		infill_artifact_get_u32(bytes, 20) ==
			INFILL_ARTIFACT_SEGMENT_SIZE &&
		infill_artifact_get_u32(bytes, 24) ==
			INFILL_ARTIFACT_HIT_SIZE &&
		infill_artifact_get_u32(bytes, 28) ==
			SCHEMA_VERSION_INFILL_HASH
	if !layout_valid ||
	   bytes[173] > 1 ||
	   !infill_artifact_bytes_zero(bytes, 175, 192) {
		return {}, .Malformed
	}
	scanline_count := infill_artifact_get_u64(bytes, 136)
	layer_count := infill_artifact_get_u64(bytes, 144)
	segment_count := infill_artifact_get_u64(bytes, 152)
	hit_count := infill_artifact_get_u64(bytes, 160)
	if segment_count > max(u64)/2 ||
	   hit_count != segment_count*2 {
		return {}, .Malformed
	}
	byte_count, size_ok := infill_artifact_byte_count(
		layer_count,
		segment_count,
		hit_count,
	)
	if !size_ok ||
	   !infill_artifact_counts_fit_limits(
			layer_count,
			segment_count,
			hit_count,
			scanline_count,
			byte_count,
			limits,
	   ) ||
	   layer_count > u64(max(int)) ||
	   segment_count > u64(max(int)) ||
	   hit_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}
	return {
		layer_count = layer_count,
		segment_count = segment_count,
		hit_count = hit_count,
		scanline_count = scanline_count,
		byte_count = byte_count,
	}, .None
}

infill_artifact_destroy :: proc(
	artifact: ^Infill_Artifact,
	allocator := context.allocator,
) {
	infill_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

infill_artifact_byte_count :: proc(
	layer_count, segment_count, hit_count: u64,
) -> (u64, bool) {
	result := u64(INFILL_ARTIFACT_HEADER_SIZE)
	if layer_count >
	   (max(u64)-result)/u64(INFILL_ARTIFACT_LAYER_SIZE) {
		return 0, false
	}
	result += layer_count*u64(INFILL_ARTIFACT_LAYER_SIZE)
	if segment_count >
	   (max(u64)-result)/u64(INFILL_ARTIFACT_SEGMENT_SIZE) {
		return 0, false
	}
	result += segment_count*u64(INFILL_ARTIFACT_SEGMENT_SIZE)
	if hit_count >
	   (max(u64)-result)/u64(INFILL_ARTIFACT_HIT_SIZE) {
		return 0, false
	}
	return result+hit_count*u64(INFILL_ARTIFACT_HIT_SIZE), true
}

infill_artifact_counts_fit_limits :: proc(
	layer_count, segment_count, hit_count, scanline_count: u64,
	byte_count: u64,
	limits: Infill_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		segment_count <= limits.max_segments &&
		hit_count <= limits.max_hits &&
		scanline_count <= limits.max_scanlines &&
		byte_count <= limits.max_bytes
}

infill_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for byte, byte_index in INFILL_ARTIFACT_MAGIC {
		if bytes[byte_index] != byte {return false}
	}
	return true
}

infill_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

infill_artifact_put_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: contracts.Content_Hash,
) {
	for byte, byte_index in hash {
		bytes[offset+byte_index] = byte
	}
}

infill_artifact_get_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: ^contracts.Content_Hash,
) {
	copy(hash[:], bytes[offset:offset+len(hash)])
}

infill_artifact_put_u32 :: proc(
	bytes: []u8,
	offset: int,
	value: u32,
) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

infill_artifact_put_u64 :: proc(
	bytes: []u8,
	offset: int,
	value: u64,
) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

infill_artifact_put_i64 :: proc(
	bytes: []u8,
	offset: int,
	value: i64,
) {
	infill_artifact_put_u64(bytes, offset, transmute(u64)value)
}

infill_artifact_put_u128 :: proc(
	bytes: []u8,
	offset: int,
	value: u128,
) {
	infill_artifact_put_u64(bytes, offset, u64(value))
	infill_artifact_put_u64(bytes, offset+8, u64(value>>64))
}

infill_artifact_put_i128 :: proc(
	bytes: []u8,
	offset: int,
	value: i128,
) {
	infill_artifact_put_u128(bytes, offset, transmute(u128)value)
}

infill_artifact_get_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	result: u32
	for byte_index in 0..<4 {
		result |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return result
}

infill_artifact_get_u64 :: proc(bytes: []u8, offset: int) -> u64 {
	result: u64
	for byte_index in 0..<8 {
		result |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return result
}

infill_artifact_get_i64 :: proc(bytes: []u8, offset: int) -> i64 {
	return transmute(i64)infill_artifact_get_u64(bytes, offset)
}

infill_artifact_get_u128 :: proc(bytes: []u8, offset: int) -> u128 {
	return u128(infill_artifact_get_u64(bytes, offset)) |
		u128(infill_artifact_get_u64(bytes, offset+8))<<64
}

infill_artifact_get_i128 :: proc(bytes: []u8, offset: int) -> i128 {
	return transmute(i128)infill_artifact_get_u128(bytes, offset)
}
