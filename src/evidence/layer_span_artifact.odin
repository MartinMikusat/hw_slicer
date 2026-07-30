package evidence

import "core:slice"

import contracts "../contracts"
import slicing "../slicing"

LAYER_SPAN_ARTIFACT_SCHEMA_VERSION :: u32(1)
LAYER_SPAN_ARTIFACT_HEADER_SIZE    :: u32(160)
LAYER_SPAN_ARTIFACT_RANGE_SIZE     :: u32(16)
LAYER_SPAN_ARTIFACT_LAYER_SIZE     :: u32(16)
LAYER_SPAN_ARTIFACT_PAIR_SIZE      :: u32(16)
LAYER_SPAN_ARTIFACT_FORMAT         :: "hws-layer-spans-le"

LAYER_SPAN_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'S', 'P', 'A', 'N', '\n',
}

Layer_Span_Artifact_Limits :: struct {
	max_triangles: u64,
	max_layers:    u64,
	max_pairs:     u64,
	max_bytes:     u64,
}

DEFAULT_LAYER_SPAN_ARTIFACT_LIMITS :: Layer_Span_Artifact_Limits{
	max_triangles = 1_000_000_000,
	max_layers = 100_000_000,
	max_pairs = 1_000_000_000,
	max_bytes = 2*1024*1024*1024,
}

Layer_Span_Artifact :: struct {
	schedule_hash: contracts.Content_Hash,
	result_hash:   contracts.Content_Hash,
	result:        slicing.Layer_Span_Index,
}

Layer_Span_Artifact_Summary :: struct {
	triangle_count:          u64,
	layer_count:             u64,
	pair_count:              u64,
	crossing_triangle_count: u64,
	planar_triangle_count:   u64,
	inactive_triangle_count: u64,
	byte_count:              u64,
}

Layer_Span_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

layer_span_artifact_encode :: proc(
	schedule_hash: contracts.Content_Hash,
	result: slicing.Layer_Span_Index,
	limits := DEFAULT_LAYER_SPAN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Layer_Span_Artifact_Error) {
	result_hash, result_ok :=
		slicing.layer_span_index_hash(schedule_hash, result)
	if !result_ok {return nil, .Invalid_Record}
	summary, semantics_ok, allocation_failed :=
		layer_span_artifact_result_semantics(result, allocator)
	if allocation_failed {return nil, .Allocation_Failed}
	if !semantics_ok {return nil, .Invalid_Record}
	byte_count, size_ok := layer_span_artifact_byte_count(
		summary.triangle_count,
		summary.layer_count,
		summary.pair_count,
	)
	if !size_ok ||
	   !layer_span_artifact_counts_fit_limits(
	   	summary.triangle_count,
	   	summary.layer_count,
	   	summary.pair_count,
	   	byte_count,
	   	limits,
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in LAYER_SPAN_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	topology_artifact_put_u32(
		bytes,
		8,
		LAYER_SPAN_ARTIFACT_SCHEMA_VERSION,
	)
	topology_artifact_put_u32(bytes, 12, LAYER_SPAN_ARTIFACT_HEADER_SIZE)
	topology_artifact_put_u32(bytes, 16, LAYER_SPAN_ARTIFACT_RANGE_SIZE)
	topology_artifact_put_u32(bytes, 20, LAYER_SPAN_ARTIFACT_LAYER_SIZE)
	topology_artifact_put_u32(bytes, 24, LAYER_SPAN_ARTIFACT_PAIR_SIZE)
	topology_artifact_put_u32(
		bytes,
		28,
		slicing.SCHEMA_VERSION_LAYER_SPAN_INDEX_HASH,
	)
	for byte, byte_index in schedule_hash {
		bytes[32+byte_index] = byte
	}
	for byte, byte_index in result_hash {
		bytes[64+byte_index] = byte
	}
	topology_artifact_put_u64(bytes, 96, summary.triangle_count)
	topology_artifact_put_u64(bytes, 104, summary.layer_count)
	topology_artifact_put_u64(bytes, 112, summary.pair_count)
	topology_artifact_put_u64(
		bytes,
		120,
		summary.crossing_triangle_count,
	)
	topology_artifact_put_u64(
		bytes,
		128,
		summary.planar_triangle_count,
	)
	topology_artifact_put_u64(
		bytes,
		136,
		summary.inactive_triangle_count,
	)
	offset := int(LAYER_SPAN_ARTIFACT_HEADER_SIZE)
	for range_value in result.triangle_ranges {
		topology_artifact_put_u32(bytes, offset, range_value.first_layer)
		topology_artifact_put_u32(bytes, offset+4, range_value.layer_count)
		bytes[offset+8] = u8(range_value.kind)
		offset += int(LAYER_SPAN_ARTIFACT_RANGE_SIZE)
	}
	for layer in result.layers {
		topology_artifact_put_u64(bytes, offset, layer.offset)
		topology_artifact_put_u32(bytes, offset+8, layer.count)
		offset += int(LAYER_SPAN_ARTIFACT_LAYER_SIZE)
	}
	for triangle_index, pair_index in result.triangle_indices {
		topology_artifact_put_u32(bytes, offset, triangle_index)
		topology_artifact_put_u64(
			bytes,
			offset+8,
			u64(result.triangle_ids[pair_index]),
		)
		offset += int(LAYER_SPAN_ARTIFACT_PAIR_SIZE)
	}
	return bytes, .None
}

layer_span_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_LAYER_SPAN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Layer_Span_Artifact, Layer_Span_Artifact_Error) {
	summary, preflight_error :=
		layer_span_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Layer_Span_Artifact
	copy(artifact.schedule_hash[:], bytes[32:64])
	copy(artifact.result_hash[:], bytes[64:96])
	result := &artifact.result
	result.triangle_ranges = make(
		[]slicing.Triangle_Layer_Range,
		int(summary.triangle_count),
		allocator,
	)
	result.layers = make(
		[]slicing.Layer_Descriptor,
		int(summary.layer_count),
		allocator,
	)
	result.triangle_indices = make(
		[]u32,
		int(summary.pair_count),
		allocator,
	)
	result.triangle_ids = make(
		[]contracts.Stable_ID,
		int(summary.pair_count),
		allocator,
	)
	if summary.triangle_count > 0 && result.triangle_ranges == nil ||
	   summary.layer_count > 0 && result.layers == nil ||
	   summary.pair_count > 0 &&
	   	(result.triangle_indices == nil || result.triangle_ids == nil) {
		layer_span_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	offset := int(LAYER_SPAN_ARTIFACT_HEADER_SIZE)
	for &range_value in result.triangle_ranges {
		if !topology_artifact_bytes_zero(bytes, offset+9, offset+16) {
			layer_span_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		range_value = {
			first_layer = topology_artifact_get_u32(bytes, offset),
			layer_count = topology_artifact_get_u32(bytes, offset+4),
			kind = slicing.Triangle_Span_Kind(bytes[offset+8]),
		}
		offset += int(LAYER_SPAN_ARTIFACT_RANGE_SIZE)
	}
	for &layer in result.layers {
		if !topology_artifact_bytes_zero(bytes, offset+12, offset+16) {
			layer_span_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		layer = {
			offset = topology_artifact_get_u64(bytes, offset),
			count = topology_artifact_get_u32(bytes, offset+8),
		}
		offset += int(LAYER_SPAN_ARTIFACT_LAYER_SIZE)
	}
	for &triangle_index, pair_index in result.triangle_indices {
		if !topology_artifact_bytes_zero(bytes, offset+4, offset+8) {
			layer_span_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		triangle_index = topology_artifact_get_u32(bytes, offset)
		result.triangle_ids[pair_index] = contracts.Stable_ID(
			topology_artifact_get_u64(bytes, offset+8),
		)
		offset += int(LAYER_SPAN_ARTIFACT_PAIR_SIZE)
	}
	calculated_hash, result_ok :=
		slicing.layer_span_index_hash(
			artifact.schedule_hash,
			artifact.result,
		)
	if !result_ok {
		layer_span_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	decoded_summary, semantics_ok, allocation_failed :=
		layer_span_artifact_result_semantics(artifact.result, allocator)
	if allocation_failed {
		layer_span_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	if !semantics_ok ||
	   decoded_summary.crossing_triangle_count !=
	   	summary.crossing_triangle_count ||
	   decoded_summary.planar_triangle_count !=
	   	summary.planar_triangle_count ||
	   decoded_summary.inactive_triangle_count !=
	   	summary.inactive_triangle_count {
		layer_span_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		layer_span_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

layer_span_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_LAYER_SPAN_ARTIFACT_LIMITS,
) -> (Layer_Span_Artifact_Summary, Layer_Span_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(LAYER_SPAN_ARTIFACT_HEADER_SIZE) ||
	   !layer_span_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if topology_artifact_get_u32(bytes, 8) !=
	   LAYER_SPAN_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	if topology_artifact_get_u32(bytes, 12) !=
	   LAYER_SPAN_ARTIFACT_HEADER_SIZE ||
	   topology_artifact_get_u32(bytes, 16) !=
	   LAYER_SPAN_ARTIFACT_RANGE_SIZE ||
	   topology_artifact_get_u32(bytes, 20) !=
	   LAYER_SPAN_ARTIFACT_LAYER_SIZE ||
	   topology_artifact_get_u32(bytes, 24) !=
	   LAYER_SPAN_ARTIFACT_PAIR_SIZE ||
	   topology_artifact_get_u32(bytes, 28) !=
	   slicing.SCHEMA_VERSION_LAYER_SPAN_INDEX_HASH ||
	   !topology_artifact_bytes_zero(bytes, 144, 160) {
		return {}, .Malformed
	}
	summary := Layer_Span_Artifact_Summary{
		triangle_count = topology_artifact_get_u64(bytes, 96),
		layer_count = topology_artifact_get_u64(bytes, 104),
		pair_count = topology_artifact_get_u64(bytes, 112),
		crossing_triangle_count =
			topology_artifact_get_u64(bytes, 120),
		planar_triangle_count =
			topology_artifact_get_u64(bytes, 128),
		inactive_triangle_count =
			topology_artifact_get_u64(bytes, 136),
	}
	byte_count, size_ok := layer_span_artifact_byte_count(
		summary.triangle_count,
		summary.layer_count,
		summary.pair_count,
	)
	if !size_ok ||
	   summary.triangle_count == 0 ||
	   summary.layer_count == 0 ||
	   !layer_span_artifact_counts_fit_limits(
	   	summary.triangle_count,
	   	summary.layer_count,
	   	summary.pair_count,
	   	byte_count,
	   	limits,
	   ) ||
	   summary.triangle_count > u64(max(int)) ||
	   summary.layer_count > u64(max(int)) ||
	   summary.pair_count > u64(max(int)) {
		return {}, .Limit
	}
	if summary.crossing_triangle_count >
	   	summary.triangle_count ||
	   summary.planar_triangle_count >
	   	summary.triangle_count-summary.crossing_triangle_count ||
	   summary.inactive_triangle_count !=
	   	summary.triangle_count-
	   	summary.crossing_triangle_count-
	   	summary.planar_triangle_count {
		return {}, .Malformed
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}
	summary.byte_count = byte_count
	return summary, .None
}

layer_span_artifact_destroy :: proc(
	artifact: ^Layer_Span_Artifact,
	allocator := context.allocator,
) {
	slicing.layer_span_index_destroy(&artifact.result, allocator)
	artifact^ = {}
}

layer_span_artifact_result_semantics :: proc(
	result: slicing.Layer_Span_Index,
	allocator := context.allocator,
) -> (
	summary: Layer_Span_Artifact_Summary,
	valid: bool,
	allocation_failed: bool,
) {
	summary.triangle_count = u64(len(result.triangle_ranges))
	summary.layer_count = u64(len(result.layers))
	summary.pair_count = u64(len(result.triangle_ids))
	triangle_ids := make(
		[]u64,
		len(result.triangle_ranges),
		allocator,
	)
	if len(result.triangle_ranges) > 0 && triangle_ids == nil {
		return {}, false, true
	}
	defer delete(triangle_ids, allocator)
	for range_value in result.triangle_ranges {
		switch range_value.kind {
		case .None:
			summary.inactive_triangle_count += 1
		case .Crossing_Candidates:
			summary.crossing_triangle_count += 1
		case .Quantized_Planar:
			summary.planar_triangle_count += 1
		case:
			return {}, false, false
		}
	}
	for triangle_id, pair_index in result.triangle_ids {
		triangle_index := result.triangle_indices[pair_index]
		stored_id := triangle_ids[triangle_index]
		if stored_id == 0 {
			triangle_ids[triangle_index] = u64(triangle_id)
		} else if stored_id != u64(triangle_id) {
			return {}, false, false
		}
	}
	slice.sort(triangle_ids)
	previous_id: u64
	previous_valid := false
	for triangle_id in triangle_ids {
		if triangle_id == 0 {continue}
		if previous_valid && triangle_id == previous_id {
			return {}, false, false
		}
		previous_id = triangle_id
		previous_valid = true
	}
	return summary, true, false
}

layer_span_artifact_counts_fit_limits :: proc(
	triangle_count, layer_count, pair_count, byte_count: u64,
	limits: Layer_Span_Artifact_Limits,
) -> bool {
	return triangle_count <= limits.max_triangles &&
		layer_count <= limits.max_layers &&
		pair_count <= limits.max_pairs &&
		byte_count <= limits.max_bytes
}

layer_span_artifact_byte_count :: proc(
	triangle_count, layer_count, pair_count: u64,
) -> (u64, bool) {
	result := u64(LAYER_SPAN_ARTIFACT_HEADER_SIZE)
	counts := [3]u64{triangle_count, layer_count, pair_count}
	sizes := [3]u64{
		u64(LAYER_SPAN_ARTIFACT_RANGE_SIZE),
		u64(LAYER_SPAN_ARTIFACT_LAYER_SIZE),
		u64(LAYER_SPAN_ARTIFACT_PAIR_SIZE),
	}
	for count, count_index in counts {
		if count > (max(u64)-result)/sizes[count_index] {
			return 0, false
		}
		result += count*sizes[count_index]
	}
	return result, true
}

layer_span_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for expected, byte_index in LAYER_SPAN_ARTIFACT_MAGIC {
		if bytes[byte_index] != expected {return false}
	}
	return true
}
