package evidence

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
planar_ownership_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	result := planar_ownership_artifact_test_result()
	defer slicing.planar_ownership_destroy(&result)
	bytes, encode_error := planar_ownership_artifact_encode(
		PLANAR_OWNERSHIP_ARTIFACT_TEST_INTERSECTION_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Planar_Ownership_Artifact_Error.None,
	)
	artifact, decode_error := planar_ownership_artifact_decode(bytes)
	defer planar_ownership_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		decode_error,
		Planar_Ownership_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 320)
	testing.expect_value(
		t,
		artifact.intersection_hash,
		PLANAR_OWNERSHIP_ARTIFACT_TEST_INTERSECTION_HASH,
	)
	testing.expect_value(t, len(artifact.result.layers), 2)
	testing.expect_value(
		t,
		len(artifact.result.segments.segment_ids),
		2,
	)
	testing.expect_value(t, artifact.result.incidence_count, u64(4))
	testing.expect_value(
		t,
		artifact.result.unresolved_group_count,
		u64(1),
	)
	testing.expect_value(
		t,
		artifact.result.suppressed_group_count,
		u64(1),
	)
	testing.expect_value(
		t,
		artifact.result.segments.segment_ids[1],
		contracts.Stable_ID(60),
	)
	reencoded, reencode_error := planar_ownership_artifact_encode(
		artifact.intersection_hash,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Planar_Ownership_Artifact_Error.None,
	)
	testing.expect(
		t,
		planar_ownership_artifact_test_bytes_equal(
			reencoded,
			bytes,
		),
	)
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(
		t,
		digest,
		PLANAR_OWNERSHIP_ARTIFACT_TEST_DIGEST,
	)
}

@(test)
planar_ownership_artifact_rejects_framing_content_and_limits_test :: proc(
	t: ^testing.T,
) {
	result := planar_ownership_artifact_test_result()
	defer slicing.planar_ownership_destroy(&result)
	bytes, encode_error := planar_ownership_artifact_encode(
		PLANAR_OWNERSHIP_ARTIFACT_TEST_INTERSECTION_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Planar_Ownership_Artifact_Error.None,
	)
	_, truncated_error := planar_ownership_artifact_decode(
		bytes[:len(bytes)-1],
	)
	testing.expect_value(
		t,
		truncated_error,
		Planar_Ownership_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = 0
	_, magic_error := planar_ownership_artifact_decode(corrupt)
	testing.expect_value(
		t,
		magic_error,
		Planar_Ownership_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	topology_artifact_put_u32(corrupt, 8, 2)
	_, version_error := planar_ownership_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Planar_Ownership_Artifact_Error.Unsupported_Version,
	)
	layer_offset := int(PLANAR_OWNERSHIP_ARTIFACT_HEADER_SIZE)
	copy(corrupt, bytes)
	corrupt[layer_offset+12] = 1
	_, layer_reserved_error :=
		planar_ownership_artifact_decode(corrupt)
	testing.expect_value(
		t,
		layer_reserved_error,
		Planar_Ownership_Artifact_Error.Malformed,
	)
	segment_offset := layer_offset+
		2*int(PLANAR_OWNERSHIP_ARTIFACT_LAYER_SIZE)
	copy(corrupt, bytes)
	corrupt[segment_offset+25] = 1
	_, segment_reserved_error :=
		planar_ownership_artifact_decode(corrupt)
	testing.expect_value(
		t,
		segment_reserved_error,
		Planar_Ownership_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, hash_error := planar_ownership_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Planar_Ownership_Artifact_Error.Hash_Mismatch,
	)
	copy(corrupt, bytes)
	topology_artifact_put_u64(
		corrupt,
		segment_offset+48,
		topology_artifact_get_u64(corrupt, segment_offset+32),
	)
	topology_artifact_put_u64(
		corrupt,
		segment_offset+56,
		topology_artifact_get_u64(corrupt, segment_offset+40),
	)
	_, endpoint_error := planar_ownership_artifact_decode(corrupt)
	testing.expect_value(
		t,
		endpoint_error,
		Planar_Ownership_Artifact_Error.Invalid_Record,
	)
	copy(corrupt, bytes)
	corrupt[segment_offset+24] = 255
	_, edge_error := planar_ownership_artifact_decode(corrupt)
	testing.expect_value(
		t,
		edge_error,
		Planar_Ownership_Artifact_Error.Invalid_Record,
	)
	limits := DEFAULT_PLANAR_OWNERSHIP_ARTIFACT_LIMITS
	limits.max_segments = 1
	_, limit_error := planar_ownership_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		Planar_Ownership_Artifact_Error.Limit,
	)
	_, overflow_ok :=
		planar_ownership_artifact_byte_count(max(u64), 1)
	testing.expect(t, !overflow_ok)
	original_incidence_count := result.incidence_count
	result.incidence_count = 3
	_, counter_error := planar_ownership_artifact_encode(
		PLANAR_OWNERSHIP_ARTIFACT_TEST_INTERSECTION_HASH,
		result,
	)
	testing.expect_value(
		t,
		counter_error,
		Planar_Ownership_Artifact_Error.Invalid_Record,
	)
	result.incidence_count = original_incidence_count
	original_segment_id := result.segments.segment_ids[1]
	result.segments.segment_ids[1] = result.segments.segment_ids[0]
	_, identity_error := planar_ownership_artifact_encode(
		PLANAR_OWNERSHIP_ARTIFACT_TEST_INTERSECTION_HASH,
		result,
	)
	testing.expect_value(
		t,
		identity_error,
		Planar_Ownership_Artifact_Error.Invalid_Record,
	)
	result.segments.segment_ids[1] = original_segment_id
}

planar_ownership_artifact_test_result :: proc() ->
	slicing.Planar_Ownership_Result {
	result: slicing.Planar_Ownership_Result
	result.layers = make([]slicing.Snapped_Layer, 2)
	result.layers[0] = {0, 1}
	result.layers[1] = {1, 1}
	segments_ok := slicing.snapped_segment_soa_allocate(
		&result.segments,
		2,
		context.allocator,
	)
	assert(segments_ok)
	result.segments.layer_indices[0] = 0
	result.segments.layer_indices[1] = 1
	result.segments.triangle_indices[0] = 4
	result.segments.triangle_indices[1] = 6
	result.segments.segment_ids[0] = 40
	result.segments.segment_ids[1] = 60
	result.segments.triangle_ids[0] = 400
	result.segments.triangle_ids[1] = 600
	result.segments.edge_a[0] = .AB
	result.segments.edge_a[1] = .CA
	result.segments.edge_b[0] = .AB
	result.segments.edge_b[1] = .CA
	result.segments.x0[0] = 0
	result.segments.x0[1] = 1
	result.segments.y0[0] = 0
	result.segments.y0[1] = 1
	result.segments.x1[0] = 10
	result.segments.x1[1] = 2
	result.segments.y1[0] = 0
	result.segments.y1[1] = 2
	result.incidence_count = 4
	result.unresolved_group_count = 1
	result.suppressed_group_count = 1
	result.collapsed_incidence_count = 1
	result.exact_predicate_count = 3
	return result
}

planar_ownership_artifact_test_bytes_equal :: proc(
	left, right: []u8,
) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

PLANAR_OWNERSHIP_ARTIFACT_TEST_INTERSECTION_HASH ::
	contracts.Content_Hash{
	0xe4, 0x30, 0x2b, 0x83, 0xa0, 0x71, 0xf5, 0x39,
	0x9c, 0xcd, 0x3a, 0xe2, 0xd6, 0xb2, 0xf7, 0x4d,
	0xb7, 0xaf, 0x28, 0x0f, 0x9b, 0x13, 0x75, 0x44,
	0xc8, 0x76, 0x0c, 0xb9, 0x55, 0x39, 0x65, 0xda,
}

PLANAR_OWNERSHIP_ARTIFACT_TEST_DIGEST :: [sha2.DIGEST_SIZE_256]u8{
	0x0c, 0x0c, 0x40, 0x6c, 0x49, 0x76, 0xe0, 0x85,
	0x6e, 0x18, 0x2c, 0x00, 0xe7, 0x08, 0xf4, 0xb7,
	0x34, 0x22, 0x42, 0x2e, 0x6d, 0xfe, 0x27, 0x5f,
	0xa4, 0xf6, 0x17, 0x93, 0x6a, 0xfe, 0xde, 0x04,
}
