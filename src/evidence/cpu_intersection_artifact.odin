package evidence

import "core:slice"

import contracts "../contracts"
import slicing "../slicing"

CPU_INTERSECTION_ARTIFACT_SCHEMA_VERSION :: u32(1)
CPU_INTERSECTION_ARTIFACT_HEADER_SIZE    :: u32(160)
CPU_INTERSECTION_ARTIFACT_LAYER_SIZE     :: u32(24)
CPU_INTERSECTION_ARTIFACT_SEGMENT_SIZE   :: u32(64)
CPU_INTERSECTION_ARTIFACT_PLANAR_SIZE    :: u32(24)
CPU_INTERSECTION_ARTIFACT_FORMAT         :: "hws-cpu-intersections-le"

CPU_INTERSECTION_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'I', 'N', 'T', 'R', '\n',
}

CPU_Intersection_Artifact_Limits :: struct {
	max_layers:            u64,
	max_segments:          u64,
	max_planar_candidates: u64,
	max_bytes:             u64,
}

DEFAULT_CPU_INTERSECTION_ARTIFACT_LIMITS ::
	CPU_Intersection_Artifact_Limits {
	max_layers = 100_000_000,
	max_segments = 1_000_000_000,
	max_planar_candidates = 100_000_000,
	max_bytes = 2*1024*1024*1024,
}

CPU_Intersection_Artifact :: struct {
	span_hash:   contracts.Content_Hash,
	result_hash: contracts.Content_Hash,
	result:      slicing.CPU_Intersection_Result,
}

CPU_Intersection_Artifact_Summary :: struct {
	layer_count:           u64,
	segment_count:         u64,
	planar_candidate_count: u64,
	tangent_count:         u64,
	degenerate_count:      u64,
	exact_predicate_count: u64,
	byte_count:            u64,
}

CPU_Intersection_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

CPU_Intersection_Triangle_Identity :: struct {
	triangle_index: u32,
	triangle_id:    u64,
}

cpu_intersection_artifact_encode :: proc(
	span_hash: contracts.Content_Hash,
	result: slicing.CPU_Intersection_Result,
	limits := DEFAULT_CPU_INTERSECTION_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, CPU_Intersection_Artifact_Error) {
	result_hash, result_ok :=
		slicing.cpu_intersection_result_hash(span_hash, result)
	if !result_ok {return nil, .Invalid_Record}
	summary := cpu_intersection_artifact_summary(result)
	byte_count, size_ok := cpu_intersection_artifact_byte_count(
		summary.layer_count,
		summary.segment_count,
		summary.planar_candidate_count,
	)
	if !size_ok ||
	   !cpu_intersection_artifact_counts_fit_limits(
	   	summary.layer_count,
	   	summary.segment_count,
	   	summary.planar_candidate_count,
	   	byte_count,
	   	limits,
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	semantics_ok, allocation_failed :=
		cpu_intersection_artifact_result_semantics(result, allocator)
	if allocation_failed {return nil, .Allocation_Failed}
	if !semantics_ok {return nil, .Invalid_Record}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in CPU_INTERSECTION_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	topology_artifact_put_u32(
		bytes,
		8,
		CPU_INTERSECTION_ARTIFACT_SCHEMA_VERSION,
	)
	topology_artifact_put_u32(
		bytes,
		12,
		CPU_INTERSECTION_ARTIFACT_HEADER_SIZE,
	)
	topology_artifact_put_u32(
		bytes,
		16,
		CPU_INTERSECTION_ARTIFACT_LAYER_SIZE,
	)
	topology_artifact_put_u32(
		bytes,
		20,
		CPU_INTERSECTION_ARTIFACT_SEGMENT_SIZE,
	)
	topology_artifact_put_u32(
		bytes,
		24,
		CPU_INTERSECTION_ARTIFACT_PLANAR_SIZE,
	)
	topology_artifact_put_u32(
		bytes,
		28,
		slicing.SCHEMA_VERSION_CPU_INTERSECTION_HASH,
	)
	for byte, byte_index in span_hash {
		bytes[32+byte_index] = byte
	}
	for byte, byte_index in result_hash {
		bytes[64+byte_index] = byte
	}
	topology_artifact_put_u64(bytes, 96, summary.layer_count)
	topology_artifact_put_u64(bytes, 104, summary.segment_count)
	topology_artifact_put_u64(
		bytes,
		112,
		summary.planar_candidate_count,
	)
	topology_artifact_put_u64(bytes, 120, summary.tangent_count)
	topology_artifact_put_u64(bytes, 128, summary.degenerate_count)
	topology_artifact_put_u64(
		bytes,
		136,
		summary.exact_predicate_count,
	)
	offset := int(CPU_INTERSECTION_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		topology_artifact_put_u64(bytes, offset, layer.segment_offset)
		topology_artifact_put_u32(bytes, offset+8, layer.segment_count)
		topology_artifact_put_u64(bytes, offset+12, layer.planar_offset)
		topology_artifact_put_u32(bytes, offset+20, layer.planar_count)
		offset += int(CPU_INTERSECTION_ARTIFACT_LAYER_SIZE)
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
			transmute(u64)result.segments.x0[segment_index],
		)
		topology_artifact_put_u64(
			bytes,
			offset+40,
			transmute(u64)result.segments.y0[segment_index],
		)
		topology_artifact_put_u64(
			bytes,
			offset+48,
			transmute(u64)result.segments.x1[segment_index],
		)
		topology_artifact_put_u64(
			bytes,
			offset+56,
			transmute(u64)result.segments.y1[segment_index],
		)
		offset += int(CPU_INTERSECTION_ARTIFACT_SEGMENT_SIZE)
	}
	for planar in result.planar_candidates {
		topology_artifact_put_u32(bytes, offset, planar.layer_index)
		topology_artifact_put_u32(bytes, offset+4, planar.triangle_index)
		topology_artifact_put_u64(
			bytes,
			offset+8,
			u64(planar.triangle_id),
		)
		bytes[offset+16] = u8(planar.kind)
		bytes[offset+17] = u8(planar.source_edge)
		offset += int(CPU_INTERSECTION_ARTIFACT_PLANAR_SIZE)
	}
	return bytes, .None
}

cpu_intersection_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_CPU_INTERSECTION_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (CPU_Intersection_Artifact, CPU_Intersection_Artifact_Error) {
	summary, preflight_error :=
		cpu_intersection_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: CPU_Intersection_Artifact
	copy(artifact.span_hash[:], bytes[32:64])
	copy(artifact.result_hash[:], bytes[64:96])
	result := &artifact.result
	result.tangent_count = summary.tangent_count
	result.degenerate_count = summary.degenerate_count
	result.exact_predicate_count = summary.exact_predicate_count
	result.layers = make(
		[]slicing.Intersection_Layer,
		int(summary.layer_count),
		allocator,
	)
	if summary.layer_count > 0 && result.layers == nil {
		cpu_intersection_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	if !slicing.raw_segment_soa_allocate(
		&result.segments,
		int(summary.segment_count),
		allocator,
	) {
		cpu_intersection_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	result.planar_candidates = make(
		[]slicing.Planar_Candidate,
		int(summary.planar_candidate_count),
		allocator,
	)
	if summary.planar_candidate_count > 0 &&
	   result.planar_candidates == nil {
		cpu_intersection_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	offset := int(CPU_INTERSECTION_ARTIFACT_HEADER_SIZE)
	for &layer in result.layers {
		layer = {
			segment_offset = topology_artifact_get_u64(bytes, offset),
			segment_count = topology_artifact_get_u32(bytes, offset+8),
			planar_offset = topology_artifact_get_u64(bytes, offset+12),
			planar_count = topology_artifact_get_u32(bytes, offset+20),
		}
		offset += int(CPU_INTERSECTION_ARTIFACT_LAYER_SIZE)
	}
	for &segment_id, segment_index in result.segments.segment_ids {
		if !topology_artifact_bytes_zero(bytes, offset+26, offset+32) {
			cpu_intersection_artifact_destroy(&artifact, allocator)
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
		x0_bits := topology_artifact_get_u64(bytes, offset+32)
		y0_bits := topology_artifact_get_u64(bytes, offset+40)
		x1_bits := topology_artifact_get_u64(bytes, offset+48)
		y1_bits := topology_artifact_get_u64(bytes, offset+56)
		result.segments.x0[segment_index] = transmute(f64)x0_bits
		result.segments.y0[segment_index] = transmute(f64)y0_bits
		result.segments.x1[segment_index] = transmute(f64)x1_bits
		result.segments.y1[segment_index] = transmute(f64)y1_bits
		offset += int(CPU_INTERSECTION_ARTIFACT_SEGMENT_SIZE)
	}
	for &planar in result.planar_candidates {
		if !topology_artifact_bytes_zero(bytes, offset+18, offset+24) {
			cpu_intersection_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		planar = {
			layer_index = topology_artifact_get_u32(bytes, offset),
			triangle_index =
				topology_artifact_get_u32(bytes, offset+4),
			triangle_id = contracts.Stable_ID(
				topology_artifact_get_u64(bytes, offset+8),
			),
			kind =
				slicing.Planar_Candidate_Kind(bytes[offset+16]),
			source_edge = slicing.Triangle_Edge(bytes[offset+17]),
		}
		offset += int(CPU_INTERSECTION_ARTIFACT_PLANAR_SIZE)
	}
	calculated_hash, result_ok :=
		slicing.cpu_intersection_result_hash(
			artifact.span_hash,
			artifact.result,
		)
	if !result_ok {
		cpu_intersection_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	semantics_ok, allocation_failed :=
		cpu_intersection_artifact_result_semantics(
			artifact.result,
			allocator,
		)
	if allocation_failed {
		cpu_intersection_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	if !semantics_ok {
		cpu_intersection_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		cpu_intersection_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

cpu_intersection_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_CPU_INTERSECTION_ARTIFACT_LIMITS,
) -> (
	CPU_Intersection_Artifact_Summary,
	CPU_Intersection_Artifact_Error,
) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(CPU_INTERSECTION_ARTIFACT_HEADER_SIZE) ||
	   !cpu_intersection_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if topology_artifact_get_u32(bytes, 8) !=
	   CPU_INTERSECTION_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	if topology_artifact_get_u32(bytes, 12) !=
	   CPU_INTERSECTION_ARTIFACT_HEADER_SIZE ||
	   topology_artifact_get_u32(bytes, 16) !=
	   CPU_INTERSECTION_ARTIFACT_LAYER_SIZE ||
	   topology_artifact_get_u32(bytes, 20) !=
	   CPU_INTERSECTION_ARTIFACT_SEGMENT_SIZE ||
	   topology_artifact_get_u32(bytes, 24) !=
	   CPU_INTERSECTION_ARTIFACT_PLANAR_SIZE ||
	   topology_artifact_get_u32(bytes, 28) !=
	   slicing.SCHEMA_VERSION_CPU_INTERSECTION_HASH ||
	   !topology_artifact_bytes_zero(bytes, 144, 160) {
		return {}, .Malformed
	}
	summary := CPU_Intersection_Artifact_Summary{
		layer_count = topology_artifact_get_u64(bytes, 96),
		segment_count = topology_artifact_get_u64(bytes, 104),
		planar_candidate_count =
			topology_artifact_get_u64(bytes, 112),
		tangent_count = topology_artifact_get_u64(bytes, 120),
		degenerate_count = topology_artifact_get_u64(bytes, 128),
		exact_predicate_count =
			topology_artifact_get_u64(bytes, 136),
	}
	byte_count, size_ok := cpu_intersection_artifact_byte_count(
		summary.layer_count,
		summary.segment_count,
		summary.planar_candidate_count,
	)
	if !size_ok ||
	   summary.layer_count == 0 ||
	   !cpu_intersection_artifact_counts_fit_limits(
	   	summary.layer_count,
	   	summary.segment_count,
	   	summary.planar_candidate_count,
	   	byte_count,
	   	limits,
	   ) ||
	   summary.layer_count > u64(max(int)) ||
	   summary.segment_count > u64(max(int)) ||
	   summary.planar_candidate_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}
	summary.byte_count = byte_count
	return summary, .None
}

cpu_intersection_artifact_destroy :: proc(
	artifact: ^CPU_Intersection_Artifact,
	allocator := context.allocator,
) {
	slicing.cpu_intersections_destroy(&artifact.result, allocator)
	artifact^ = {}
}

cpu_intersection_artifact_summary :: proc(
	result: slicing.CPU_Intersection_Result,
) -> CPU_Intersection_Artifact_Summary {
	return {
		layer_count = u64(len(result.layers)),
		segment_count = u64(len(result.segments.segment_ids)),
		planar_candidate_count = u64(len(result.planar_candidates)),
		tangent_count = result.tangent_count,
		degenerate_count = result.degenerate_count,
		exact_predicate_count = result.exact_predicate_count,
	}
}

cpu_intersection_artifact_result_semantics :: proc(
	result: slicing.CPU_Intersection_Result,
	allocator := context.allocator,
) -> (valid: bool, allocation_failed: bool) {
	segment_count := len(result.segments.segment_ids)
	planar_count := len(result.planar_candidates)
	record_count_64 := u64(segment_count)+u64(planar_count)
	if record_count_64 > u64(max(int)) {return false, false}
	segment_ids := make([]u64, segment_count, allocator)
	identities := make(
		[]CPU_Intersection_Triangle_Identity,
		int(record_count_64),
		allocator,
	)
	if segment_count > 0 && segment_ids == nil ||
	   record_count_64 > 0 && identities == nil {
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
	for planar, planar_index in result.planar_candidates {
		identities[segment_count+planar_index] = {
			triangle_index = planar.triangle_index,
			triangle_id = u64(planar.triangle_id),
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
		cpu_intersection_identity_index_less,
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
		cpu_intersection_identity_id_less,
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

cpu_intersection_identity_index_less :: proc(
	left, right: CPU_Intersection_Triangle_Identity,
) -> bool {
	if left.triangle_index != right.triangle_index {
		return left.triangle_index < right.triangle_index
	}
	return left.triangle_id < right.triangle_id
}

cpu_intersection_identity_id_less :: proc(
	left, right: CPU_Intersection_Triangle_Identity,
) -> bool {
	if left.triangle_id != right.triangle_id {
		return left.triangle_id < right.triangle_id
	}
	return left.triangle_index < right.triangle_index
}

cpu_intersection_artifact_counts_fit_limits :: proc(
	layer_count, segment_count, planar_count, byte_count: u64,
	limits: CPU_Intersection_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		segment_count <= limits.max_segments &&
		planar_count <= limits.max_planar_candidates &&
		byte_count <= limits.max_bytes
}

cpu_intersection_artifact_byte_count :: proc(
	layer_count, segment_count, planar_count: u64,
) -> (u64, bool) {
	result := u64(CPU_INTERSECTION_ARTIFACT_HEADER_SIZE)
	counts := [3]u64{layer_count, segment_count, planar_count}
	sizes := [3]u64{
		u64(CPU_INTERSECTION_ARTIFACT_LAYER_SIZE),
		u64(CPU_INTERSECTION_ARTIFACT_SEGMENT_SIZE),
		u64(CPU_INTERSECTION_ARTIFACT_PLANAR_SIZE),
	}
	for count, count_index in counts {
		if count > (max(u64)-result)/sizes[count_index] {
			return 0, false
		}
		result += count*sizes[count_index]
	}
	return result, true
}

cpu_intersection_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for expected, byte_index in CPU_INTERSECTION_ARTIFACT_MAGIC {
		if bytes[byte_index] != expected {return false}
	}
	return true
}
