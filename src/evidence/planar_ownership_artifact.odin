package evidence

import "core:slice"

import contracts "../contracts"
import slicing "../slicing"

PLANAR_OWNERSHIP_ARTIFACT_SCHEMA_VERSION :: u32(1)
PLANAR_OWNERSHIP_ARTIFACT_HEADER_SIZE    :: u32(160)
PLANAR_OWNERSHIP_ARTIFACT_LAYER_SIZE     :: u32(16)
PLANAR_OWNERSHIP_ARTIFACT_SEGMENT_SIZE   :: u32(64)
PLANAR_OWNERSHIP_ARTIFACT_FORMAT         :: "hws-planar-ownership-le"

PLANAR_OWNERSHIP_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'O', 'W', 'N', 'R', '\n',
}

Planar_Ownership_Artifact_Limits :: struct {
	max_layers:   u64,
	max_segments: u64,
	max_bytes:    u64,
}

DEFAULT_PLANAR_OWNERSHIP_ARTIFACT_LIMITS ::
	Planar_Ownership_Artifact_Limits {
	max_layers = 100_000_000,
	max_segments = 30_000_000,
	max_bytes = 2*1024*1024*1024,
}

Planar_Ownership_Artifact :: struct {
	intersection_hash: contracts.Content_Hash,
	result_hash:       contracts.Content_Hash,
	result:            slicing.Planar_Ownership_Result,
}

Planar_Ownership_Artifact_Summary :: struct {
	layer_count:               u64,
	segment_count:             u64,
	incidence_count:           u64,
	unresolved_group_count:    u64,
	suppressed_group_count:    u64,
	collapsed_incidence_count: u64,
	exact_predicate_count:     u64,
	byte_count:                u64,
}

Planar_Ownership_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

planar_ownership_artifact_encode :: proc(
	intersection_hash: contracts.Content_Hash,
	result: slicing.Planar_Ownership_Result,
	limits := DEFAULT_PLANAR_OWNERSHIP_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Planar_Ownership_Artifact_Error) {
	result_hash, result_ok :=
		slicing.planar_ownership_result_hash(intersection_hash, result)
	if !result_ok {return nil, .Invalid_Record}
	summary := planar_ownership_artifact_summary(result)
	byte_count, size_ok := planar_ownership_artifact_byte_count(
		summary.layer_count,
		summary.segment_count,
	)
	if !size_ok ||
	   !planar_ownership_artifact_counts_fit_limits(
	   	summary.layer_count,
	   	summary.segment_count,
	   	byte_count,
	   	limits,
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	semantics_ok, allocation_failed :=
		planar_ownership_artifact_result_semantics(result, allocator)
	if allocation_failed {return nil, .Allocation_Failed}
	if !semantics_ok {return nil, .Invalid_Record}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in PLANAR_OWNERSHIP_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	topology_artifact_put_u32(
		bytes,
		8,
		PLANAR_OWNERSHIP_ARTIFACT_SCHEMA_VERSION,
	)
	topology_artifact_put_u32(
		bytes,
		12,
		PLANAR_OWNERSHIP_ARTIFACT_HEADER_SIZE,
	)
	topology_artifact_put_u32(
		bytes,
		16,
		PLANAR_OWNERSHIP_ARTIFACT_LAYER_SIZE,
	)
	topology_artifact_put_u32(
		bytes,
		20,
		PLANAR_OWNERSHIP_ARTIFACT_SEGMENT_SIZE,
	)
	topology_artifact_put_u32(
		bytes,
		24,
		slicing.SCHEMA_VERSION_PLANAR_OWNERSHIP_HASH,
	)
	topology_artifact_put_u32(
		bytes,
		28,
		slicing.SCHEMA_VERSION_SNAPPED_SEGMENT_HASH,
	)
	for byte, byte_index in intersection_hash {
		bytes[32+byte_index] = byte
	}
	for byte, byte_index in result_hash {
		bytes[64+byte_index] = byte
	}
	topology_artifact_put_u64(bytes, 96, summary.layer_count)
	topology_artifact_put_u64(bytes, 104, summary.segment_count)
	topology_artifact_put_u64(bytes, 112, summary.incidence_count)
	topology_artifact_put_u64(
		bytes,
		120,
		summary.unresolved_group_count,
	)
	topology_artifact_put_u64(
		bytes,
		128,
		summary.suppressed_group_count,
	)
	topology_artifact_put_u64(
		bytes,
		136,
		summary.collapsed_incidence_count,
	)
	topology_artifact_put_u64(
		bytes,
		144,
		summary.exact_predicate_count,
	)
	topology_artifact_put_u64(bytes, 152, byte_count)
	offset := int(PLANAR_OWNERSHIP_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		topology_artifact_put_u64(bytes, offset, layer.offset)
		topology_artifact_put_u32(bytes, offset+8, layer.count)
		offset += int(PLANAR_OWNERSHIP_ARTIFACT_LAYER_SIZE)
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
		offset += int(PLANAR_OWNERSHIP_ARTIFACT_SEGMENT_SIZE)
	}
	return bytes, .None
}

planar_ownership_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_PLANAR_OWNERSHIP_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Planar_Ownership_Artifact, Planar_Ownership_Artifact_Error) {
	summary, preflight_error :=
		planar_ownership_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Planar_Ownership_Artifact
	copy(artifact.intersection_hash[:], bytes[32:64])
	copy(artifact.result_hash[:], bytes[64:96])
	result := &artifact.result
	result.incidence_count = summary.incidence_count
	result.unresolved_group_count = summary.unresolved_group_count
	result.suppressed_group_count = summary.suppressed_group_count
	result.collapsed_incidence_count =
		summary.collapsed_incidence_count
	result.exact_predicate_count = summary.exact_predicate_count
	result.layers = make(
		[]slicing.Snapped_Layer,
		int(summary.layer_count),
		allocator,
	)
	if summary.layer_count > 0 && result.layers == nil {
		planar_ownership_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	if !slicing.snapped_segment_soa_allocate(
		&result.segments,
		int(summary.segment_count),
		allocator,
	) {
		planar_ownership_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	offset := int(PLANAR_OWNERSHIP_ARTIFACT_HEADER_SIZE)
	for &layer in result.layers {
		if !topology_artifact_bytes_zero(bytes, offset+12, offset+16) {
			planar_ownership_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		layer = {
			offset = topology_artifact_get_u64(bytes, offset),
			count = topology_artifact_get_u32(bytes, offset+8),
		}
		offset += int(PLANAR_OWNERSHIP_ARTIFACT_LAYER_SIZE)
	}
	for &segment_id, segment_index in result.segments.segment_ids {
		if !topology_artifact_bytes_zero(bytes, offset+25, offset+32) {
			planar_ownership_artifact_destroy(&artifact, allocator)
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
		source_edge := slicing.Triangle_Edge(bytes[offset+24])
		result.segments.edge_a[segment_index] = source_edge
		result.segments.edge_b[segment_index] = source_edge
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
		offset += int(PLANAR_OWNERSHIP_ARTIFACT_SEGMENT_SIZE)
	}
	calculated_hash, result_ok :=
		slicing.planar_ownership_result_hash(
			artifact.intersection_hash,
			artifact.result,
		)
	if !result_ok {
		planar_ownership_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	semantics_ok, allocation_failed :=
		planar_ownership_artifact_result_semantics(
			artifact.result,
			allocator,
		)
	if allocation_failed {
		planar_ownership_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	if !semantics_ok {
		planar_ownership_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		planar_ownership_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

planar_ownership_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_PLANAR_OWNERSHIP_ARTIFACT_LIMITS,
) -> (
	Planar_Ownership_Artifact_Summary,
	Planar_Ownership_Artifact_Error,
) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(PLANAR_OWNERSHIP_ARTIFACT_HEADER_SIZE) ||
	   !planar_ownership_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if topology_artifact_get_u32(bytes, 8) !=
	   PLANAR_OWNERSHIP_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	if topology_artifact_get_u32(bytes, 12) !=
	   PLANAR_OWNERSHIP_ARTIFACT_HEADER_SIZE ||
	   topology_artifact_get_u32(bytes, 16) !=
	   PLANAR_OWNERSHIP_ARTIFACT_LAYER_SIZE ||
	   topology_artifact_get_u32(bytes, 20) !=
	   PLANAR_OWNERSHIP_ARTIFACT_SEGMENT_SIZE ||
	   topology_artifact_get_u32(bytes, 24) !=
	   slicing.SCHEMA_VERSION_PLANAR_OWNERSHIP_HASH ||
	   topology_artifact_get_u32(bytes, 28) !=
	   slicing.SCHEMA_VERSION_SNAPPED_SEGMENT_HASH {
		return {}, .Malformed
	}
	summary := Planar_Ownership_Artifact_Summary{
		layer_count = topology_artifact_get_u64(bytes, 96),
		segment_count = topology_artifact_get_u64(bytes, 104),
		incidence_count = topology_artifact_get_u64(bytes, 112),
		unresolved_group_count =
			topology_artifact_get_u64(bytes, 120),
		suppressed_group_count =
			topology_artifact_get_u64(bytes, 128),
		collapsed_incidence_count =
			topology_artifact_get_u64(bytes, 136),
		exact_predicate_count =
			topology_artifact_get_u64(bytes, 144),
		byte_count = topology_artifact_get_u64(bytes, 152),
	}
	byte_count, size_ok := planar_ownership_artifact_byte_count(
		summary.layer_count,
		summary.segment_count,
	)
	if !size_ok ||
	   summary.layer_count == 0 ||
	   !planar_ownership_artifact_counts_fit_limits(
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
	   summary.byte_count != byte_count {
		return {}, .Malformed
	}
	return summary, .None
}

planar_ownership_artifact_destroy :: proc(
	artifact: ^Planar_Ownership_Artifact,
	allocator := context.allocator,
) {
	slicing.planar_ownership_destroy(&artifact.result, allocator)
	artifact^ = {}
}

planar_ownership_artifact_summary :: proc(
	result: slicing.Planar_Ownership_Result,
) -> Planar_Ownership_Artifact_Summary {
	return {
		layer_count = u64(len(result.layers)),
		segment_count = u64(len(result.segments.segment_ids)),
		incidence_count = result.incidence_count,
		unresolved_group_count = result.unresolved_group_count,
		suppressed_group_count = result.suppressed_group_count,
		collapsed_incidence_count =
			result.collapsed_incidence_count,
		exact_predicate_count = result.exact_predicate_count,
	}
}

planar_ownership_artifact_result_semantics :: proc(
	result: slicing.Planar_Ownership_Result,
	allocator := context.allocator,
) -> (valid: bool, allocation_failed: bool) {
	segment_count := len(result.segments.segment_ids)
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

planar_ownership_artifact_counts_fit_limits :: proc(
	layer_count, segment_count, byte_count: u64,
	limits: Planar_Ownership_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		segment_count <= limits.max_segments &&
		byte_count <= limits.max_bytes
}

planar_ownership_artifact_byte_count :: proc(
	layer_count, segment_count: u64,
) -> (u64, bool) {
	result := u64(PLANAR_OWNERSHIP_ARTIFACT_HEADER_SIZE)
	counts := [2]u64{layer_count, segment_count}
	sizes := [2]u64{
		u64(PLANAR_OWNERSHIP_ARTIFACT_LAYER_SIZE),
		u64(PLANAR_OWNERSHIP_ARTIFACT_SEGMENT_SIZE),
	}
	for count, count_index in counts {
		if count > (max(u64)-result)/sizes[count_index] {
			return 0, false
		}
		result += count*sizes[count_index]
	}
	return result, true
}

planar_ownership_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for expected, byte_index in PLANAR_OWNERSHIP_ARTIFACT_MAGIC {
		if bytes[byte_index] != expected {return false}
	}
	return true
}
