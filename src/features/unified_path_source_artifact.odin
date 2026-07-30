package features

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

UNIFIED_PATH_SOURCE_ARTIFACT_SCHEMA_VERSION :: u32(1)
UNIFIED_PATH_SOURCE_ARTIFACT_HEADER_SIZE    :: u32(352)
UNIFIED_PATH_SOURCE_ARTIFACT_LAYER_SIZE     :: u32(32)
UNIFIED_PATH_SOURCE_ARTIFACT_SOURCE_SIZE    :: u32(64)
UNIFIED_PATH_SOURCE_ARTIFACT_POINT_SIZE     :: u32(24)
UNIFIED_PATH_SOURCE_ARTIFACT_FORMAT :: "hws-unified-path-sources-le"

UNIFIED_PATH_SOURCE_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'U', 'S', 'R', 'C', '\n',
}

Unified_Path_Source_Artifact_Limits :: struct {
	max_layers:  u64,
	max_sources: u64,
	max_points:  u64,
	max_bytes:   u64,
}

DEFAULT_UNIFIED_PATH_SOURCE_ARTIFACT_LIMITS ::
	Unified_Path_Source_Artifact_Limits{
		max_layers = 10_000_000,
		max_sources = 100_000_000,
		max_points = 400_000_000,
		max_bytes = 2*1024*1024*1024,
	}

Unified_Path_Source_Artifact :: struct {
	dependencies: Unified_Path_Source_Hash_Dependencies,
	result_hash:  contracts.Content_Hash,
	result:       Unified_Path_Source_Result,
}

Unified_Path_Source_Artifact_Summary :: struct {
	layer_count:  u64,
	source_count: u64,
	point_count:  u64,
	byte_count:   u64,
}

Unified_Path_Source_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

unified_path_source_artifact_encode :: proc(
	perimeter_hash, bridge_hash, gap_hash: contracts.Content_Hash,
	solid_hash, infill_hash, support_hash: contracts.Content_Hash,
	process_hash: contracts.Content_Hash,
	layer_ids: []contracts.Stable_ID,
	perimeters: Perimeter_Result,
	bridges: Bridge_Path_Result,
	gaps: Gap_Centerline_Result,
	solids: Solid_Path_Result,
	infill: Infill_Result,
	supports: Support_Path_Result,
	process: profiles.Resolved_Process_Profile,
	result: Unified_Path_Source_Result,
	limits := DEFAULT_UNIFIED_PATH_SOURCE_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Unified_Path_Source_Artifact_Error) {
	result_hash, result_ok := unified_path_source_result_hash(
		perimeter_hash,
		bridge_hash,
		gap_hash,
		solid_hash,
		infill_hash,
		support_hash,
		process_hash,
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		result,
		DEFAULT_UNIFIED_PATH_SOURCE_LIMITS,
		allocator,
	)
	if !result_ok {return nil, .Invalid_Record}
	layer_count := u64(len(result.layers))
	source_count := u64(len(result.sources))
	point_count := u64(len(result.points))
	byte_count, size_ok := unified_path_source_artifact_byte_count(
		layer_count,
		source_count,
		point_count,
	)
	if !size_ok ||
	   !unified_path_source_artifact_counts_fit_limits(
		layer_count,
		source_count,
		point_count,
		byte_count,
		limits,
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in UNIFIED_PATH_SOURCE_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	unified_path_source_artifact_put_u32(
		bytes,
		8,
		UNIFIED_PATH_SOURCE_ARTIFACT_SCHEMA_VERSION,
	)
	unified_path_source_artifact_put_u32(
		bytes,
		12,
		UNIFIED_PATH_SOURCE_ARTIFACT_HEADER_SIZE,
	)
	unified_path_source_artifact_put_u32(
		bytes,
		16,
		UNIFIED_PATH_SOURCE_ARTIFACT_LAYER_SIZE,
	)
	unified_path_source_artifact_put_u32(
		bytes,
		20,
		UNIFIED_PATH_SOURCE_ARTIFACT_SOURCE_SIZE,
	)
	unified_path_source_artifact_put_u32(
		bytes,
		24,
		UNIFIED_PATH_SOURCE_ARTIFACT_POINT_SIZE,
	)
	unified_path_source_artifact_put_u32(
		bytes,
		28,
		SCHEMA_VERSION_UNIFIED_PATH_SOURCE_HASH,
	)
	dependencies := Unified_Path_Source_Hash_Dependencies{
		perimeter_hash = perimeter_hash,
		bridge_hash = bridge_hash,
		gap_hash = gap_hash,
		solid_hash = solid_hash,
		infill_hash = infill_hash,
		support_hash = support_hash,
		process_hash = process_hash,
	}
	unified_path_source_artifact_put_hash(
		bytes,
		32,
		dependencies.perimeter_hash,
	)
	unified_path_source_artifact_put_hash(
		bytes,
		64,
		dependencies.bridge_hash,
	)
	unified_path_source_artifact_put_hash(
		bytes,
		96,
		dependencies.gap_hash,
	)
	unified_path_source_artifact_put_hash(
		bytes,
		128,
		dependencies.solid_hash,
	)
	unified_path_source_artifact_put_hash(
		bytes,
		160,
		dependencies.infill_hash,
	)
	unified_path_source_artifact_put_hash(
		bytes,
		192,
		dependencies.support_hash,
	)
	unified_path_source_artifact_put_hash(
		bytes,
		224,
		dependencies.process_hash,
	)
	unified_path_source_artifact_put_hash(bytes, 256, result_hash)
	if result.inner_perimeters_first {bytes[288] = 1}
	unified_path_source_artifact_put_i64(
		bytes,
		296,
		i64(result.nominal_line_width),
	)
	unified_path_source_artifact_put_u64(bytes, 304, layer_count)
	unified_path_source_artifact_put_u64(bytes, 312, source_count)
	unified_path_source_artifact_put_u64(bytes, 320, point_count)
	offset := int(UNIFIED_PATH_SOURCE_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		unified_path_source_artifact_put_u64(
			bytes,
			offset,
			layer.source_offset,
		)
		unified_path_source_artifact_put_u32(
			bytes,
			offset+8,
			layer.source_count,
		)
		unified_path_source_artifact_put_u64(
			bytes,
			offset+16,
			layer.point_offset,
		)
		unified_path_source_artifact_put_u32(
			bytes,
			offset+24,
			layer.point_count,
		)
		offset += int(UNIFIED_PATH_SOURCE_ARTIFACT_LAYER_SIZE)
	}
	point_offset: u64
	for source in result.sources {
		unified_path_source_artifact_put_u64(
			bytes,
			offset,
			u64(source.stable_id),
		)
		unified_path_source_artifact_put_u64(
			bytes,
			offset+8,
			u64(source.layer_id),
		)
		unified_path_source_artifact_put_u64(
			bytes,
			offset+16,
			source.source_order,
		)
		unified_path_source_artifact_put_u64(
			bytes,
			offset+24,
			point_offset,
		)
		unified_path_source_artifact_put_u32(
			bytes,
			offset+32,
			source.layer_index,
		)
		unified_path_source_artifact_put_u32(
			bytes,
			offset+36,
			source.source_index,
		)
		unified_path_source_artifact_put_u32(
			bytes,
			offset+40,
			u32(len(source.points)),
		)
		bytes[offset+44] = u8(source.role)
		bytes[offset+45] = u8(source.source_kind)
		if source.closed {bytes[offset+46] = 1}
		point_offset += u64(len(source.points))
		offset += int(UNIFIED_PATH_SOURCE_ARTIFACT_SOURCE_SIZE)
	}
	for point, point_index in result.points {
		unified_path_source_artifact_put_i64(
			bytes,
			offset,
			i64(point.x),
		)
		unified_path_source_artifact_put_i64(
			bytes,
			offset+8,
			i64(point.y),
		)
		unified_path_source_artifact_put_i64(
			bytes,
			offset+16,
			i64(result.line_widths[point_index]),
		)
		offset += int(UNIFIED_PATH_SOURCE_ARTIFACT_POINT_SIZE)
	}
	return bytes, .None
}

unified_path_source_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_UNIFIED_PATH_SOURCE_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (
	Unified_Path_Source_Artifact,
	Unified_Path_Source_Artifact_Error,
) {
	summary, preflight_error :=
		unified_path_source_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Unified_Path_Source_Artifact
	unified_path_source_artifact_get_hash(
		bytes,
		32,
		&artifact.dependencies.perimeter_hash,
	)
	unified_path_source_artifact_get_hash(
		bytes,
		64,
		&artifact.dependencies.bridge_hash,
	)
	unified_path_source_artifact_get_hash(
		bytes,
		96,
		&artifact.dependencies.gap_hash,
	)
	unified_path_source_artifact_get_hash(
		bytes,
		128,
		&artifact.dependencies.solid_hash,
	)
	unified_path_source_artifact_get_hash(
		bytes,
		160,
		&artifact.dependencies.infill_hash,
	)
	unified_path_source_artifact_get_hash(
		bytes,
		192,
		&artifact.dependencies.support_hash,
	)
	unified_path_source_artifact_get_hash(
		bytes,
		224,
		&artifact.dependencies.process_hash,
	)
	unified_path_source_artifact_get_hash(
		bytes,
		256,
		&artifact.result_hash,
	)
	result := &artifact.result
	result.inner_perimeters_first = bytes[288] != 0
	result.nominal_line_width = contracts.Micrometres(
		unified_path_source_artifact_get_i64(bytes, 296),
	)
	result.layers = make(
		[]Unified_Path_Source_Layer,
		int(summary.layer_count),
		allocator,
	)
	result.sources = make(
		[]Unified_Path_Source,
		int(summary.source_count),
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		int(summary.point_count),
		allocator,
	)
	result.line_widths = make(
		[]contracts.Micrometres,
		int(summary.point_count),
		allocator,
	)
	if summary.layer_count > 0 && result.layers == nil ||
	   summary.source_count > 0 && result.sources == nil ||
	   summary.point_count > 0 &&
		(result.points == nil || result.line_widths == nil) {
		unified_path_source_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	offset := int(UNIFIED_PATH_SOURCE_ARTIFACT_HEADER_SIZE)
	for &layer in result.layers {
		if !unified_path_source_artifact_bytes_zero(
			bytes,
			offset+12,
			offset+16,
		) ||
		   !unified_path_source_artifact_bytes_zero(
			bytes,
			offset+28,
			offset+32,
		   ) {
			unified_path_source_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		layer.source_offset =
			unified_path_source_artifact_get_u64(bytes, offset)
		layer.source_count =
			unified_path_source_artifact_get_u32(bytes, offset+8)
		layer.point_offset =
			unified_path_source_artifact_get_u64(bytes, offset+16)
		layer.point_count =
			unified_path_source_artifact_get_u32(bytes, offset+24)
		offset += int(UNIFIED_PATH_SOURCE_ARTIFACT_LAYER_SIZE)
	}
	for &source in result.sources {
		if bytes[offset+46] > 1 ||
		   !unified_path_source_artifact_bytes_zero(
			bytes,
			offset+47,
			offset+64,
		   ) {
			unified_path_source_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		source.stable_id = contracts.Stable_ID(
			unified_path_source_artifact_get_u64(bytes, offset),
		)
		source.layer_id = contracts.Stable_ID(
			unified_path_source_artifact_get_u64(bytes, offset+8),
		)
		source.source_order =
			unified_path_source_artifact_get_u64(bytes, offset+16)
		point_offset :=
			unified_path_source_artifact_get_u64(bytes, offset+24)
		source.layer_index =
			unified_path_source_artifact_get_u32(bytes, offset+32)
		source.source_index =
			unified_path_source_artifact_get_u32(bytes, offset+36)
		point_count :=
			unified_path_source_artifact_get_u32(bytes, offset+40)
		source.role =
			transmute(profiles.Printable_Role)bytes[offset+44]
		source.source_kind =
			transmute(Unified_Path_Source_Kind)bytes[offset+45]
		source.closed = bytes[offset+46] != 0
		if point_offset > u64(len(result.points)) ||
		   u64(point_count) >
			u64(len(result.points))-point_offset {
			unified_path_source_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		point_start := int(point_offset)
		point_end := point_start+int(point_count)
		source.points = result.points[point_start:point_end]
		source.line_widths =
			result.line_widths[point_start:point_end]
		offset += int(UNIFIED_PATH_SOURCE_ARTIFACT_SOURCE_SIZE)
	}
	for &point, point_index in result.points {
		point.x = contracts.Micrometres(
			unified_path_source_artifact_get_i64(bytes, offset),
		)
		point.y = contracts.Micrometres(
			unified_path_source_artifact_get_i64(bytes, offset+8),
		)
		result.line_widths[point_index] = contracts.Micrometres(
			unified_path_source_artifact_get_i64(bytes, offset+16),
		)
		offset += int(UNIFIED_PATH_SOURCE_ARTIFACT_POINT_SIZE)
	}
	calculated_hash, result_ok :=
		unified_path_source_result_content_hash(
			artifact.dependencies,
			artifact.result,
		)
	if !result_ok {
		unified_path_source_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		unified_path_source_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

unified_path_source_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_UNIFIED_PATH_SOURCE_ARTIFACT_LIMITS,
) -> (
	Unified_Path_Source_Artifact_Summary,
	Unified_Path_Source_Artifact_Error,
) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(UNIFIED_PATH_SOURCE_ARTIFACT_HEADER_SIZE) ||
	   !unified_path_source_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if unified_path_source_artifact_get_u32(bytes, 8) !=
	   UNIFIED_PATH_SOURCE_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	layout_valid :=
		unified_path_source_artifact_get_u32(bytes, 12) ==
			UNIFIED_PATH_SOURCE_ARTIFACT_HEADER_SIZE &&
		unified_path_source_artifact_get_u32(bytes, 16) ==
			UNIFIED_PATH_SOURCE_ARTIFACT_LAYER_SIZE &&
		unified_path_source_artifact_get_u32(bytes, 20) ==
			UNIFIED_PATH_SOURCE_ARTIFACT_SOURCE_SIZE &&
		unified_path_source_artifact_get_u32(bytes, 24) ==
			UNIFIED_PATH_SOURCE_ARTIFACT_POINT_SIZE &&
		unified_path_source_artifact_get_u32(bytes, 28) ==
			SCHEMA_VERSION_UNIFIED_PATH_SOURCE_HASH
	if !layout_valid ||
	   bytes[288] > 1 ||
	   !unified_path_source_artifact_bytes_zero(bytes, 289, 296) ||
	   !unified_path_source_artifact_bytes_zero(bytes, 328, 352) {
		return {}, .Malformed
	}
	layer_count := unified_path_source_artifact_get_u64(bytes, 304)
	source_count := unified_path_source_artifact_get_u64(bytes, 312)
	point_count := unified_path_source_artifact_get_u64(bytes, 320)
	byte_count, size_ok := unified_path_source_artifact_byte_count(
		layer_count,
		source_count,
		point_count,
	)
	if !size_ok ||
	   !unified_path_source_artifact_counts_fit_limits(
		layer_count,
		source_count,
		point_count,
		byte_count,
		limits,
	   ) ||
	   layer_count > u64(max(int)) ||
	   source_count > u64(max(int)) ||
	   point_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}
	return {
		layer_count = layer_count,
		source_count = source_count,
		point_count = point_count,
		byte_count = byte_count,
	}, .None
}

unified_path_source_artifact_destroy :: proc(
	artifact: ^Unified_Path_Source_Artifact,
	allocator := context.allocator,
) {
	unified_path_source_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

unified_path_source_artifact_byte_count :: proc(
	layer_count, source_count, point_count: u64,
) -> (u64, bool) {
	result := u64(UNIFIED_PATH_SOURCE_ARTIFACT_HEADER_SIZE)
	if layer_count >
	   (max(u64)-result)/u64(UNIFIED_PATH_SOURCE_ARTIFACT_LAYER_SIZE) {
		return 0, false
	}
	result += layer_count*u64(UNIFIED_PATH_SOURCE_ARTIFACT_LAYER_SIZE)
	if source_count >
	   (max(u64)-result)/u64(UNIFIED_PATH_SOURCE_ARTIFACT_SOURCE_SIZE) {
		return 0, false
	}
	result += source_count*u64(UNIFIED_PATH_SOURCE_ARTIFACT_SOURCE_SIZE)
	if point_count >
	   (max(u64)-result)/u64(UNIFIED_PATH_SOURCE_ARTIFACT_POINT_SIZE) {
		return 0, false
	}
	return result+
		point_count*u64(UNIFIED_PATH_SOURCE_ARTIFACT_POINT_SIZE), true
}

unified_path_source_artifact_counts_fit_limits :: proc(
	layer_count, source_count, point_count, byte_count: u64,
	limits: Unified_Path_Source_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		source_count <= limits.max_sources &&
		point_count <= limits.max_points &&
		byte_count <= limits.max_bytes
}

unified_path_source_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for byte, byte_index in UNIFIED_PATH_SOURCE_ARTIFACT_MAGIC {
		if bytes[byte_index] != byte {return false}
	}
	return true
}

unified_path_source_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

unified_path_source_artifact_put_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: contracts.Content_Hash,
) {
	for byte, byte_index in hash {
		bytes[offset+byte_index] = byte
	}
}

unified_path_source_artifact_get_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: ^contracts.Content_Hash,
) {
	copy(hash[:], bytes[offset:offset+len(hash)])
}

unified_path_source_artifact_put_u32 :: proc(
	bytes: []u8,
	offset: int,
	value: u32,
) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

unified_path_source_artifact_put_u64 :: proc(
	bytes: []u8,
	offset: int,
	value: u64,
) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

unified_path_source_artifact_put_i64 :: proc(
	bytes: []u8,
	offset: int,
	value: i64,
) {
	unified_path_source_artifact_put_u64(
		bytes,
		offset,
		transmute(u64)value,
	)
}

unified_path_source_artifact_get_u32 :: proc(
	bytes: []u8,
	offset: int,
) -> u32 {
	result: u32
	for byte_index in 0..<4 {
		result |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return result
}

unified_path_source_artifact_get_u64 :: proc(
	bytes: []u8,
	offset: int,
) -> u64 {
	result: u64
	for byte_index in 0..<8 {
		result |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return result
}

unified_path_source_artifact_get_i64 :: proc(
	bytes: []u8,
	offset: int,
) -> i64 {
	return transmute(i64)unified_path_source_artifact_get_u64(
		bytes,
		offset,
	)
}
