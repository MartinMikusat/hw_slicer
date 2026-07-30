package evidence

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
cpu_intersection_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	result := cpu_intersection_artifact_test_result()
	defer slicing.cpu_intersections_destroy(&result)
	bytes, encode_error := cpu_intersection_artifact_encode(
		CPU_INTERSECTION_ARTIFACT_TEST_SPAN_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		CPU_Intersection_Artifact_Error.None,
	)
	artifact, decode_error := cpu_intersection_artifact_decode(bytes)
	defer cpu_intersection_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		decode_error,
		CPU_Intersection_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 320)
	testing.expect_value(
		t,
		artifact.span_hash,
		CPU_INTERSECTION_ARTIFACT_TEST_SPAN_HASH,
	)
	testing.expect_value(t, len(artifact.result.layers), 2)
	testing.expect_value(t, len(artifact.result.segments.segment_ids), 1)
	testing.expect_value(t, len(artifact.result.planar_candidates), 2)
	testing.expect_value(
		t,
		artifact.result.segments.segment_ids[0],
		result.segments.segment_ids[0],
	)
	testing.expect_value(
		t,
		artifact.result.segments.x0[0],
		result.segments.x0[0],
	)
	testing.expect_value(
		t,
		artifact.result.planar_candidates[1],
		result.planar_candidates[1],
	)
	reencoded, reencode_error := cpu_intersection_artifact_encode(
		artifact.span_hash,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		CPU_Intersection_Artifact_Error.None,
	)
	testing.expect(
		t,
		cpu_intersection_artifact_test_bytes_equal(reencoded, bytes),
	)
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(
		t,
		digest,
		CPU_INTERSECTION_ARTIFACT_TEST_DIGEST,
	)
}

@(test)
cpu_intersection_artifact_rejects_framing_content_and_limits_test :: proc(
	t: ^testing.T,
) {
	result := cpu_intersection_artifact_test_result()
	defer slicing.cpu_intersections_destroy(&result)
	bytes, encode_error := cpu_intersection_artifact_encode(
		CPU_INTERSECTION_ARTIFACT_TEST_SPAN_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		CPU_Intersection_Artifact_Error.None,
	)
	_, truncated_error := cpu_intersection_artifact_decode(
		bytes[:len(bytes)-1],
	)
	testing.expect_value(
		t,
		truncated_error,
		CPU_Intersection_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = 0
	_, magic_error := cpu_intersection_artifact_decode(corrupt)
	testing.expect_value(
		t,
		magic_error,
		CPU_Intersection_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	topology_artifact_put_u32(corrupt, 8, 2)
	_, version_error := cpu_intersection_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		CPU_Intersection_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[144] = 1
	_, header_reserved_error := cpu_intersection_artifact_decode(corrupt)
	testing.expect_value(
		t,
		header_reserved_error,
		CPU_Intersection_Artifact_Error.Malformed,
	)
	segment_offset := int(CPU_INTERSECTION_ARTIFACT_HEADER_SIZE)+
		2*int(CPU_INTERSECTION_ARTIFACT_LAYER_SIZE)
	copy(corrupt, bytes)
	corrupt[segment_offset+26] = 1
	_, segment_reserved_error :=
		cpu_intersection_artifact_decode(corrupt)
	testing.expect_value(
		t,
		segment_reserved_error,
		CPU_Intersection_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, hash_error := cpu_intersection_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		CPU_Intersection_Artifact_Error.Hash_Mismatch,
	)
	copy(corrupt, bytes)
	topology_artifact_put_u64(
		corrupt,
		segment_offset+32,
		transmute(u64)f64(2),
	)
	_, endpoint_error := cpu_intersection_artifact_decode(corrupt)
	testing.expect_value(
		t,
		endpoint_error,
		CPU_Intersection_Artifact_Error.Invalid_Record,
	)
	planar_offset := segment_offset+
		int(CPU_INTERSECTION_ARTIFACT_SEGMENT_SIZE)
	copy(corrupt, bytes)
	topology_artifact_put_u32(corrupt, planar_offset+4, 0)
	_, identity_error := cpu_intersection_artifact_decode(corrupt)
	testing.expect_value(
		t,
		identity_error,
		CPU_Intersection_Artifact_Error.Invalid_Record,
	)
	limits := DEFAULT_CPU_INTERSECTION_ARTIFACT_LIMITS
	limits.max_segments = 0
	_, limit_error := cpu_intersection_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		CPU_Intersection_Artifact_Error.Limit,
	)
	_, overflow_ok :=
		cpu_intersection_artifact_byte_count(max(u64), 1, 1)
	testing.expect(t, !overflow_ok)
	result.planar_candidates[0].triangle_index = 0
	_, invalid_encode_error := cpu_intersection_artifact_encode(
		CPU_INTERSECTION_ARTIFACT_TEST_SPAN_HASH,
		result,
	)
	testing.expect_value(
		t,
		invalid_encode_error,
		CPU_Intersection_Artifact_Error.Invalid_Record,
	)
}

cpu_intersection_artifact_test_result :: proc() ->
	slicing.CPU_Intersection_Result {
	result: slicing.CPU_Intersection_Result
	result.layers = make([]slicing.Intersection_Layer, 2)
	result.layers[0] = {0, 1, 0, 2}
	result.layers[1] = {1, 0, 2, 0}
	segments_ok := slicing.raw_segment_soa_allocate(
		&result.segments,
		1,
		context.allocator,
	)
	assert(segments_ok)
	result.segments.layer_indices[0] = 0
	result.segments.triangle_indices[0] = 0
	result.segments.segment_ids[0] = 1_000
	result.segments.triangle_ids[0] = 100
	result.segments.edge_a[0] = .AB
	result.segments.edge_b[0] = .BC
	result.segments.x0[0] = 1
	result.segments.y0[0] = 0
	result.segments.x1[0] = 1
	result.segments.y1[0] = 1
	result.planar_candidates = make([]slicing.Planar_Candidate, 2)
	result.planar_candidates[0] = {
		layer_index = 0,
		triangle_index = 1,
		triangle_id = 101,
		kind = .Exact_Edge,
		source_edge = .CA,
	}
	result.planar_candidates[1] = {
		layer_index = 0,
		triangle_index = 3,
		triangle_id = 103,
		kind = .Quantized_Face,
		source_edge = .Invalid,
	}
	result.tangent_count = 1
	result.exact_predicate_count = 3
	return result
}

cpu_intersection_artifact_test_bytes_equal :: proc(
	left, right: []u8,
) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

CPU_INTERSECTION_ARTIFACT_TEST_SPAN_HASH :: contracts.Content_Hash{
	0x56, 0xb0, 0x38, 0xc3, 0xb9, 0x1b, 0x3a, 0xba,
	0x4e, 0xdc, 0x8a, 0xec, 0x23, 0x9d, 0xb5, 0x38,
	0x31, 0xc2, 0xcd, 0x5a, 0xda, 0x25, 0xa5, 0x0e,
	0x5a, 0xd6, 0xfd, 0x3d, 0x52, 0xa7, 0xa2, 0xcf,
}

CPU_INTERSECTION_ARTIFACT_TEST_DIGEST :: [sha2.DIGEST_SIZE_256]u8{
	0x55, 0x25, 0x8a, 0xe0, 0x3c, 0xfd, 0xe0, 0xb1,
	0x19, 0xbe, 0x52, 0x76, 0x1b, 0xf8, 0x26, 0x5c,
	0x80, 0xa4, 0xc3, 0x80, 0xd7, 0x7c, 0x2d, 0x72,
	0x1f, 0x86, 0x26, 0x61, 0x95, 0xaa, 0xb1, 0x88,
}
