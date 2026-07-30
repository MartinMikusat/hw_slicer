package evidence

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
layer_span_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	result := layer_span_artifact_test_result()
	defer slicing.layer_span_index_destroy(&result)
	bytes, encode_error := layer_span_artifact_encode(
		LAYER_SPAN_ARTIFACT_TEST_SCHEDULE_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Layer_Span_Artifact_Error.None,
	)
	artifact, decode_error := layer_span_artifact_decode(bytes)
	defer layer_span_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		decode_error,
		Layer_Span_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 416)
	testing.expect_value(
		t,
		artifact.schedule_hash,
		LAYER_SPAN_ARTIFACT_TEST_SCHEDULE_HASH,
	)
	testing.expect_value(t, len(artifact.result.triangle_ranges), 5)
	testing.expect_value(t, len(artifact.result.layers), 4)
	testing.expect_value(t, len(artifact.result.triangle_ids), 7)
	for range_value, range_index in artifact.result.triangle_ranges {
		testing.expect_value(
			t,
			range_value,
			result.triangle_ranges[range_index],
		)
	}
	for layer, layer_index in artifact.result.layers {
		testing.expect_value(t, layer, result.layers[layer_index])
	}
	for triangle_index, pair_index in artifact.result.triangle_indices {
		testing.expect_value(
			t,
			triangle_index,
			result.triangle_indices[pair_index],
		)
		testing.expect_value(
			t,
			artifact.result.triangle_ids[pair_index],
			result.triangle_ids[pair_index],
		)
	}
	reencoded, reencode_error := layer_span_artifact_encode(
		artifact.schedule_hash,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Layer_Span_Artifact_Error.None,
	)
	testing.expect(t, layer_span_artifact_test_bytes_equal(reencoded, bytes))
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(t, digest, LAYER_SPAN_ARTIFACT_TEST_DIGEST)
}

@(test)
layer_span_artifact_rejects_framing_content_and_limits_test :: proc(
	t: ^testing.T,
) {
	result := layer_span_artifact_test_result()
	defer slicing.layer_span_index_destroy(&result)
	bytes, encode_error := layer_span_artifact_encode(
		LAYER_SPAN_ARTIFACT_TEST_SCHEDULE_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Layer_Span_Artifact_Error.None,
	)
	_, truncated_error := layer_span_artifact_decode(
		bytes[:len(bytes)-1],
	)
	testing.expect_value(
		t,
		truncated_error,
		Layer_Span_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = 0
	_, magic_error := layer_span_artifact_decode(corrupt)
	testing.expect_value(
		t,
		magic_error,
		Layer_Span_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	topology_artifact_put_u32(corrupt, 8, 2)
	_, version_error := layer_span_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Layer_Span_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[144] = 1
	_, header_reserved_error := layer_span_artifact_decode(corrupt)
	testing.expect_value(
		t,
		header_reserved_error,
		Layer_Span_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[int(LAYER_SPAN_ARTIFACT_HEADER_SIZE)+9] = 1
	_, range_reserved_error := layer_span_artifact_decode(corrupt)
	testing.expect_value(
		t,
		range_reserved_error,
		Layer_Span_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, hash_error := layer_span_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Layer_Span_Artifact_Error.Hash_Mismatch,
	)
	copy(corrupt, bytes)
	corrupt[int(LAYER_SPAN_ARTIFACT_HEADER_SIZE)+8] = 255
	_, kind_error := layer_span_artifact_decode(corrupt)
	testing.expect_value(
		t,
		kind_error,
		Layer_Span_Artifact_Error.Invalid_Record,
	)
	copy(corrupt, bytes)
	pair_offset := int(LAYER_SPAN_ARTIFACT_HEADER_SIZE)+
		len(result.triangle_ranges)*int(LAYER_SPAN_ARTIFACT_RANGE_SIZE)+
		len(result.layers)*int(LAYER_SPAN_ARTIFACT_LAYER_SIZE)
	topology_artifact_put_u64(corrupt, pair_offset+2*16+8, 99)
	_, identity_error := layer_span_artifact_decode(corrupt)
	testing.expect_value(
		t,
		identity_error,
		Layer_Span_Artifact_Error.Invalid_Record,
	)
	limits := DEFAULT_LAYER_SPAN_ARTIFACT_LIMITS
	limits.max_pairs = 6
	_, limit_error := layer_span_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		Layer_Span_Artifact_Error.Limit,
	)
	_, overflow_ok := layer_span_artifact_byte_count(max(u64), 1, 1)
	testing.expect(t, !overflow_ok)
	result.triangle_ids[2] = 99
	_, invalid_encode_error := layer_span_artifact_encode(
		LAYER_SPAN_ARTIFACT_TEST_SCHEDULE_HASH,
		result,
	)
	testing.expect_value(
		t,
		invalid_encode_error,
		Layer_Span_Artifact_Error.Invalid_Record,
	)
}

layer_span_artifact_test_result :: proc() -> slicing.Layer_Span_Index {
	result: slicing.Layer_Span_Index
	result.triangle_ranges = make([]slicing.Triangle_Layer_Range, 5)
	result.layers = make([]slicing.Layer_Descriptor, 4)
	result.triangle_indices = make([]u32, 7)
	result.triangle_ids = make([]contracts.Stable_ID, 7)
	copy(
		result.triangle_ranges,
		[]slicing.Triangle_Layer_Range{
			{0, 4, .Crossing_Candidates},
			{1, 1, .Quantized_Planar},
			{},
			{1, 1, .Quantized_Planar},
			{0, 1, .Crossing_Candidates},
		},
	)
	copy(
		result.layers,
		[]slicing.Layer_Descriptor{
			{0, 2},
			{2, 3},
			{5, 1},
			{6, 1},
		},
	)
	copy(result.triangle_indices, []u32{0, 4, 0, 1, 3, 0, 0})
	copy(
		result.triangle_ids,
		[]contracts.Stable_ID{10, 14, 10, 11, 13, 10, 10},
	)
	return result
}

layer_span_artifact_test_bytes_equal :: proc(
	left, right: []u8,
) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

LAYER_SPAN_ARTIFACT_TEST_SCHEDULE_HASH :: contracts.Content_Hash{
	0x2c, 0x3f, 0xc7, 0xfd, 0x4d, 0x04, 0x72, 0xab,
	0x5e, 0xf5, 0x2b, 0x06, 0x4b, 0xce, 0xf7, 0xe2,
	0x3d, 0xb6, 0xa0, 0x07, 0x4b, 0xec, 0x1a, 0x71,
	0x57, 0x10, 0xad, 0xef, 0x09, 0x0a, 0x37, 0xdb,
}

LAYER_SPAN_ARTIFACT_TEST_DIGEST :: [sha2.DIGEST_SIZE_256]u8{
	0x1b, 0xc6, 0x21, 0x67, 0x9b, 0x3c, 0xcb, 0x28,
	0x3a, 0x96, 0xb0, 0x21, 0x37, 0xfa, 0x1e, 0xf2,
	0xab, 0x21, 0xf9, 0x1b, 0x5c, 0xc7, 0x9f, 0x6b,
	0x6a, 0x53, 0x25, 0x48, 0xfa, 0xfc, 0x3d, 0x67,
}
