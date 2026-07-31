package evidence

import "core:math"
import "core:slice"

import contracts "../contracts"
import slicing "../slicing"

SNAPPED_SEGMENT_ARTIFACT_SCHEMA_VERSION :: u32(1)
SNAPPED_SEGMENT_ARTIFACT_HEADER_SIZE    :: u32(160)
SNAPPED_SEGMENT_ARTIFACT_LAYER_SIZE     :: u32(16)
SNAPPED_SEGMENT_ARTIFACT_SEGMENT_SIZE   :: u32(96)
SNAPPED_SEGMENT_ARTIFACT_FORMAT         :: "hws-snapped-segments-le"
SNAPPED_SEGMENT_ARTIFACT_MAX_ERROR_UM   :: 0.500000000001

SNAPPED_SEGMENT_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'S', 'N', 'A', 'P', '\n',
}

Snapped_Segment_Artifact_Limits :: struct {
	max_layers:   u64,
	max_segments: u64,
	max_bytes:    u64,
}

DEFAULT_SNAPPED_SEGMENT_ARTIFACT_LIMITS ::
	Snapped_Segment_Artifact_Limits {
	max_layers = 100_000_000,
	max_segments = 20_000_000,
	max_bytes = 2*1024*1024*1024,
}

Snapped_Segment_Artifact :: struct {
	parent_hash: contracts.Content_Hash,
	result_hash: contracts.Content_Hash,
	result:      slicing.Snapped_Segment_Result,
}

Snapped_Segment_Artifact_Summary :: struct {
	layer_count:           u64,
	segment_count:         u64,
	collapsed_count:       u64,
	maximum_snap_error_um: f64,
	byte_count:            u64,
}

Snapped_Segment_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

Snapped_Segment_Triangle_Identity :: struct {
	triangle_index: u32,
	triangle_id:    u64,
}

snapped_segment_artifact_encode :: proc(
	parent_hash: contracts.Content_Hash,
	result: slicing.Snapped_Segment_Result,
	limits := DEFAULT_SNAPPED_SEGMENT_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Snapped_Segment_Artifact_Error) {
	result_hash, result_ok :=
		slicing.snapped_segment_result_hash(parent_hash, result)
	if !result_ok {return nil, .Invalid_Record}
	summary := snapped_segment_artifact_summary(result)
	byte_count, size_ok := snapped_segment_artifact_byte_count(
		summary.layer_count,
		summary.segment_count,
	)
	if !size_ok ||
	   !snapped_segment_artifact_counts_fit_limits(
	   	summary.layer_count,
	   	summary.segment_count,
	   	byte_count,
	   	limits,
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	semantics_ok, allocation_failed :=
		snapped_segment_artifact_result_semantics(result, allocator)
	if allocation_failed {return nil, .Allocation_Failed}
	if !semantics_ok {return nil, .Invalid_Record}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in SNAPPED_SEGMENT_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	topology_artifact_put_u32(
		bytes,
		8,
		SNAPPED_SEGMENT_ARTIFACT_SCHEMA_VERSION,
	)
	topology_artifact_put_u32(
		bytes,
		12,
		SNAPPED_SEGMENT_ARTIFACT_HEADER_SIZE,
	)
	topology_artifact_put_u32(
		bytes,
		16,
		SNAPPED_SEGMENT_ARTIFACT_LAYER_SIZE,
	)
	topology_artifact_put_u32(
		bytes,
		20,
		SNAPPED_SEGMENT_ARTIFACT_SEGMENT_SIZE,
	)
	topology_artifact_put_u32(
		bytes,
		24,
		slicing.SCHEMA_VERSION_SNAPPED_SEGMENT_HASH,
	)
	for byte, byte_index in parent_hash {
		bytes[32+byte_index] = byte
	}
	for byte, byte_index in result_hash {
		bytes[64+byte_index] = byte
	}
	topology_artifact_put_u64(bytes, 96, summary.layer_count)
	topology_artifact_put_u64(bytes, 104, summary.segment_count)
	topology_artifact_put_u64(bytes, 112, summary.collapsed_count)
	topology_artifact_put_u64(
		bytes,
		120,
		transmute(u64)summary.maximum_snap_error_um,
	)
	topology_artifact_put_u64(bytes, 128, byte_count)
	topology_artifact_put_u64(
		bytes,
		136,
		transmute(u64)i64(slicing.ENDPOINT_SNAP_GRID_UM),
	)
	offset := int(SNAPPED_SEGMENT_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		topology_artifact_put_u64(bytes, offset, layer.offset)
		topology_artifact_put_u32(bytes, offset+8, layer.count)
		offset += int(SNAPPED_SEGMENT_ARTIFACT_LAYER_SIZE)
	}
	for segment_index in 0..<len(result.segments.segment_ids) {
		topology_artifact_put_u32(
			bytes,
			offset,
			result.segments.layer_indices[segment_index],
		)
		topology_artifact_put_u32(
			bytes,
			offset+4,
			result.segments.triangle_indices[segment_index],
		)
		topology_artifact_put_u64(
			bytes,
			offset+8,
			u64(result.segments.segment_ids[segment_index]),
		)
		topology_artifact_put_u64(
			bytes,
			offset+16,
			u64(result.segments.triangle_ids[segment_index]),
		)
		bytes[offset+24] = u8(result.segments.edge_a[segment_index])
		bytes[offset+25] = u8(result.segments.edge_b[segment_index])
		topology_artifact_put_u64(
			bytes,
			offset+32,
			transmute(u64)i64(result.segments.x0[segment_index]),
		)
		topology_artifact_put_u64(
			bytes,
			offset+40,
			transmute(u64)i64(result.segments.y0[segment_index]),
		)
		topology_artifact_put_u64(
			bytes,
			offset+48,
			transmute(u64)i64(result.segments.x1[segment_index]),
		)
		topology_artifact_put_u64(
			bytes,
			offset+56,
			transmute(u64)i64(result.segments.y1[segment_index]),
		)
		topology_artifact_put_u64(
			bytes,
			offset+64,
			transmute(u64)result.segments.x0_error_um[segment_index],
		)
		topology_artifact_put_u64(
			bytes,
			offset+72,
			transmute(u64)result.segments.y0_error_um[segment_index],
		)
		topology_artifact_put_u64(
			bytes,
			offset+80,
			transmute(u64)result.segments.x1_error_um[segment_index],
		)
		topology_artifact_put_u64(
			bytes,
			offset+88,
			transmute(u64)result.segments.y1_error_um[segment_index],
		)
		offset += int(SNAPPED_SEGMENT_ARTIFACT_SEGMENT_SIZE)
	}
	return bytes, .None
}

snapped_segment_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_SNAPPED_SEGMENT_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Snapped_Segment_Artifact, Snapped_Segment_Artifact_Error) {
	summary, preflight_error :=
		snapped_segment_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Snapped_Segment_Artifact
	copy(artifact.parent_hash[:], bytes[32:64])
	copy(artifact.result_hash[:], bytes[64:96])
	result := &artifact.result
	result.collapsed_count = summary.collapsed_count
	result.maximum_snap_error_um = summary.maximum_snap_error_um
	result.layers = make(
		[]slicing.Snapped_Layer,
		int(summary.layer_count),
		allocator,
	)
	if summary.layer_count > 0 && result.layers == nil {
		snapped_segment_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	if !slicing.snapped_segment_soa_allocate(
		&result.segments,
		int(summary.segment_count),
		allocator,
	) {
		snapped_segment_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	offset := int(SNAPPED_SEGMENT_ARTIFACT_HEADER_SIZE)
	for &layer in result.layers {
		if !topology_artifact_bytes_zero(bytes, offset+12, offset+16) {
			snapped_segment_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		layer = {
			offset = topology_artifact_get_u64(bytes, offset),
			count = topology_artifact_get_u32(bytes, offset+8),
		}
		offset += int(SNAPPED_SEGMENT_ARTIFACT_LAYER_SIZE)
	}
	for &segment_id, segment_index in result.segments.segment_ids {
		if !topology_artifact_bytes_zero(bytes, offset+26, offset+32) {
			snapped_segment_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		result.segments.layer_indices[segment_index] =
			topology_artifact_get_u32(bytes, offset)
		result.segments.triangle_indices[segment_index] =
			topology_artifact_get_u32(bytes, offset+4)
		segment_id = contracts.Stable_ID(
			topology_artifact_get_u64(bytes, offset+8),
		)
		result.segments.triangle_ids[segment_index] =
			contracts.Stable_ID(
				topology_artifact_get_u64(bytes, offset+16),
			)
		result.segments.edge_a[segment_index] =
			slicing.Triangle_Edge(bytes[offset+24])
		result.segments.edge_b[segment_index] =
			slicing.Triangle_Edge(bytes[offset+25])
		result.segments.x0[segment_index] = contracts.Micrometres(
			transmute(i64)topology_artifact_get_u64(bytes, offset+32),
		)
		result.segments.y0[segment_index] = contracts.Micrometres(
			transmute(i64)topology_artifact_get_u64(bytes, offset+40),
		)
		result.segments.x1[segment_index] = contracts.Micrometres(
			transmute(i64)topology_artifact_get_u64(bytes, offset+48),
		)
		result.segments.y1[segment_index] = contracts.Micrometres(
			transmute(i64)topology_artifact_get_u64(bytes, offset+56),
		)
		result.segments.x0_error_um[segment_index] =
			transmute(f64)topology_artifact_get_u64(bytes, offset+64)
		result.segments.y0_error_um[segment_index] =
			transmute(f64)topology_artifact_get_u64(bytes, offset+72)
		result.segments.x1_error_um[segment_index] =
			transmute(f64)topology_artifact_get_u64(bytes, offset+80)
		result.segments.y1_error_um[segment_index] =
			transmute(f64)topology_artifact_get_u64(bytes, offset+88)
		offset += int(SNAPPED_SEGMENT_ARTIFACT_SEGMENT_SIZE)
	}
	calculated_hash, result_ok :=
		slicing.snapped_segment_result_hash(
			artifact.parent_hash,
			artifact.result,
		)
	if !result_ok {
		snapped_segment_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	semantics_ok, allocation_failed :=
		snapped_segment_artifact_result_semantics(
			artifact.result,
			allocator,
		)
	if allocation_failed {
		snapped_segment_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	if !semantics_ok {
		snapped_segment_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		snapped_segment_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

snapped_segment_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_SNAPPED_SEGMENT_ARTIFACT_LIMITS,
) -> (
	Snapped_Segment_Artifact_Summary,
	Snapped_Segment_Artifact_Error,
) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(SNAPPED_SEGMENT_ARTIFACT_HEADER_SIZE) ||
	   !snapped_segment_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if topology_artifact_get_u32(bytes, 8) !=
	   SNAPPED_SEGMENT_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	if topology_artifact_get_u32(bytes, 12) !=
	   SNAPPED_SEGMENT_ARTIFACT_HEADER_SIZE ||
	   topology_artifact_get_u32(bytes, 16) !=
	   SNAPPED_SEGMENT_ARTIFACT_LAYER_SIZE ||
	   topology_artifact_get_u32(bytes, 20) !=
	   SNAPPED_SEGMENT_ARTIFACT_SEGMENT_SIZE ||
	   topology_artifact_get_u32(bytes, 24) !=
	   slicing.SCHEMA_VERSION_SNAPPED_SEGMENT_HASH ||
	   !topology_artifact_bytes_zero(bytes, 28, 32) ||
	   topology_artifact_get_u64(bytes, 136) !=
	   transmute(u64)i64(slicing.ENDPOINT_SNAP_GRID_UM) ||
	   !topology_artifact_bytes_zero(bytes, 144, 160) {
		return {}, .Malformed
	}
	maximum_snap_error_bits :=
		topology_artifact_get_u64(bytes, 120)
	summary := Snapped_Segment_Artifact_Summary{
		layer_count = topology_artifact_get_u64(bytes, 96),
		segment_count = topology_artifact_get_u64(bytes, 104),
		collapsed_count = topology_artifact_get_u64(bytes, 112),
		maximum_snap_error_um = transmute(f64)maximum_snap_error_bits,
		byte_count = topology_artifact_get_u64(bytes, 128),
	}
	byte_count, size_ok := snapped_segment_artifact_byte_count(
		summary.layer_count,
		summary.segment_count,
	)
	if !size_ok ||
	   summary.layer_count == 0 ||
	   !snapped_segment_artifact_counts_fit_limits(
	   	summary.layer_count,
	   	summary.segment_count,
	   	byte_count,
	   	limits,
	   ) ||
	   summary.layer_count > u64(max(int)) ||
	   summary.segment_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) ||
	   summary.byte_count != byte_count ||
	   !snapped_segment_artifact_error_valid(
	   	summary.maximum_snap_error_um,
	   ) ||
	   summary.maximum_snap_error_um < 0 {
		return {}, .Malformed
	}
	return summary, .None
}

snapped_segment_artifact_destroy :: proc(
	artifact: ^Snapped_Segment_Artifact,
	allocator := context.allocator,
) {
	slicing.snapped_segments_destroy(&artifact.result, allocator)
	artifact^ = {}
}

snapped_segment_artifact_summary :: proc(
	result: slicing.Snapped_Segment_Result,
) -> Snapped_Segment_Artifact_Summary {
	return {
		layer_count = u64(len(result.layers)),
		segment_count = u64(len(result.segments.segment_ids)),
		collapsed_count = result.collapsed_count,
		maximum_snap_error_um = result.maximum_snap_error_um,
	}
}

snapped_segment_artifact_result_semantics :: proc(
	result: slicing.Snapped_Segment_Result,
	allocator := context.allocator,
) -> (valid: bool, allocation_failed: bool) {
	segment_count := len(result.segments.segment_ids)
	if !snapped_segment_artifact_diagnostics_valid(result) {
		return false, false
	}
	segment_ids := make([]u64, segment_count, allocator)
	identities := make(
		[]Snapped_Segment_Triangle_Identity,
		segment_count,
		allocator,
	)
	if segment_count > 0 &&
	   (segment_ids == nil || identities == nil) {
		delete(segment_ids, allocator)
		delete(identities, allocator)
		return false, true
	}
	defer delete(segment_ids, allocator)
	defer delete(identities, allocator)
	for segment_id, segment_index in result.segments.segment_ids {
		segment_ids[segment_index] = u64(segment_id)
		identities[segment_index] = {
			triangle_index =
				result.segments.triangle_indices[segment_index],
			triangle_id = u64(
				result.segments.triangle_ids[segment_index],
			),
		}
	}
	slice.sort(segment_ids)
	if len(segment_ids) > 1 {
		for segment_id, segment_index in segment_ids[1:] {
			if segment_id == segment_ids[segment_index] {
				return false, false
			}
		}
	}
	slice.sort_by(
		identities,
		snapped_segment_identity_index_less,
	)
	if len(identities) > 1 {
		for identity, identity_index in identities[1:] {
			previous := identities[identity_index]
			if identity.triangle_index == previous.triangle_index &&
			   identity.triangle_id != previous.triangle_id {
				return false, false
			}
		}
	}
	slice.sort_by(
		identities,
		snapped_segment_identity_id_less,
	)
	if len(identities) > 1 {
		for identity, identity_index in identities[1:] {
			previous := identities[identity_index]
			if identity.triangle_id == previous.triangle_id &&
			   identity.triangle_index != previous.triangle_index {
				return false, false
			}
		}
	}
	return true, false
}

snapped_segment_artifact_diagnostics_valid :: proc(
	result: slicing.Snapped_Segment_Result,
) -> bool {
	maximum := result.maximum_snap_error_um
	if !snapped_segment_artifact_error_valid(maximum) ||
	   maximum < 0 ||
	   maximum > SNAPPED_SEGMENT_ARTIFACT_MAX_ERROR_UM {
		return false
	}
	segment_count := len(result.segments.segment_ids)
	for segment_index in 0..<segment_count {
		errors := [4]f64{
			result.segments.x0_error_um[segment_index],
			result.segments.y0_error_um[segment_index],
			result.segments.x1_error_um[segment_index],
			result.segments.y1_error_um[segment_index],
		}
		for error_value in errors {
			if !snapped_segment_artifact_error_valid(error_value) ||
			   math.abs(error_value) > maximum ||
			   math.abs(error_value) >
			   	SNAPPED_SEGMENT_ARTIFACT_MAX_ERROR_UM {
				return false
			}
		}
	}
	return true
}

snapped_segment_artifact_error_valid :: proc(value: f64) -> bool {
	if math.is_nan(value) || math.is_inf(value) {return false}
	return value != 0 || transmute(u64)value == 0
}

snapped_segment_identity_index_less :: proc(
	left, right: Snapped_Segment_Triangle_Identity,
) -> bool {
	if left.triangle_index != right.triangle_index {
		return left.triangle_index < right.triangle_index
	}
	return left.triangle_id < right.triangle_id
}

snapped_segment_identity_id_less :: proc(
	left, right: Snapped_Segment_Triangle_Identity,
) -> bool {
	if left.triangle_id != right.triangle_id {
		return left.triangle_id < right.triangle_id
	}
	return left.triangle_index < right.triangle_index
}

snapped_segment_artifact_counts_fit_limits :: proc(
	layer_count, segment_count, byte_count: u64,
	limits: Snapped_Segment_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		segment_count <= limits.max_segments &&
		byte_count <= limits.max_bytes
}

snapped_segment_artifact_byte_count :: proc(
	layer_count, segment_count: u64,
) -> (u64, bool) {
	result := u64(SNAPPED_SEGMENT_ARTIFACT_HEADER_SIZE)
	counts := [2]u64{layer_count, segment_count}
	sizes := [2]u64{
		u64(SNAPPED_SEGMENT_ARTIFACT_LAYER_SIZE),
		u64(SNAPPED_SEGMENT_ARTIFACT_SEGMENT_SIZE),
	}
	for count, count_index in counts {
		if count > (max(u64)-result)/sizes[count_index] {
			return 0, false
		}
		result += count*sizes[count_index]
	}
	return result, true
}

snapped_segment_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for expected, byte_index in SNAPPED_SEGMENT_ARTIFACT_MAGIC {
		if bytes[byte_index] != expected {return false}
	}
	return true
}
