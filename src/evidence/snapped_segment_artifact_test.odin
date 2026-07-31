package evidence

import "core:crypto/sha2"
import "core:math"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
snapped_segment_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	result := snapped_segment_artifact_test_result()
	defer slicing.snapped_segments_destroy(&result)
	bytes, encode_error := snapped_segment_artifact_encode(
		SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Snapped_Segment_Artifact_Error.None,
	)
	artifact, decode_error := snapped_segment_artifact_decode(bytes)
	defer snapped_segment_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		decode_error,
		Snapped_Segment_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 384)
	testing.expect_value(
		t,
		artifact.parent_hash,
		SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH,
	)
	testing.expect_value(t, len(artifact.result.layers), 2)
	testing.expect_value(
		t,
		len(artifact.result.segments.segment_ids),
		2,
	)
	testing.expect_value(t, artifact.result.collapsed_count, u64(1))
	testing.expect(
		t,
		math.abs(artifact.result.maximum_snap_error_um-0.49) <
			0.000000000001,
	)
	testing.expect_value(
		t,
		artifact.result.segments.segment_ids[0],
		contracts.Stable_ID(40),
	)
	testing.expect_value(
		t,
		artifact.result.segments.segment_ids[1],
		contracts.Stable_ID(60),
	)
	testing.expect_value(
		t,
		artifact.result.segments.x0_error_um[0],
		result.segments.x0_error_um[0],
	)
	reencoded, reencode_error := snapped_segment_artifact_encode(
		artifact.parent_hash,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Snapped_Segment_Artifact_Error.None,
	)
	testing.expect(
		t,
		snapped_segment_artifact_test_bytes_equal(reencoded, bytes),
	)
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(
		t,
		digest,
		SNAPPED_SEGMENT_ARTIFACT_TEST_DIGEST,
	)
}

@(test)
snapped_segment_artifact_rejects_framing_content_and_limits_test :: proc(
	t: ^testing.T,
) {
	result := snapped_segment_artifact_test_result()
	defer slicing.snapped_segments_destroy(&result)
	bytes, encode_error := snapped_segment_artifact_encode(
		SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Snapped_Segment_Artifact_Error.None,
	)
	_, truncated_error := snapped_segment_artifact_decode(
		bytes[:len(bytes)-1],
	)
	testing.expect_value(
		t,
		truncated_error,
		Snapped_Segment_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = 0
	_, magic_error := snapped_segment_artifact_decode(corrupt)
	testing.expect_value(
		t,
		magic_error,
		Snapped_Segment_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	topology_artifact_put_u32(corrupt, 8, 2)
	_, version_error := snapped_segment_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Snapped_Segment_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[144] = 1
	_, header_reserved_error :=
		snapped_segment_artifact_decode(corrupt)
	testing.expect_value(
		t,
		header_reserved_error,
		Snapped_Segment_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	layer_offset := int(SNAPPED_SEGMENT_ARTIFACT_HEADER_SIZE)
	corrupt[layer_offset+12] = 1
	_, layer_reserved_error :=
		snapped_segment_artifact_decode(corrupt)
	testing.expect_value(
		t,
		layer_reserved_error,
		Snapped_Segment_Artifact_Error.Malformed,
	)
	segment_offset := layer_offset+
		2*int(SNAPPED_SEGMENT_ARTIFACT_LAYER_SIZE)
	copy(corrupt, bytes)
	corrupt[segment_offset+26] = 1
	_, segment_reserved_error :=
		snapped_segment_artifact_decode(corrupt)
	testing.expect_value(
		t,
		segment_reserved_error,
		Snapped_Segment_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, hash_error := snapped_segment_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Snapped_Segment_Artifact_Error.Hash_Mismatch,
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
	_, endpoint_error := snapped_segment_artifact_decode(corrupt)
	testing.expect_value(
		t,
		endpoint_error,
		Snapped_Segment_Artifact_Error.Invalid_Record,
	)
	limits := DEFAULT_SNAPPED_SEGMENT_ARTIFACT_LIMITS
	limits.max_segments = 1
	_, limit_error := snapped_segment_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		Snapped_Segment_Artifact_Error.Limit,
	)
	_, overflow_ok :=
		snapped_segment_artifact_byte_count(max(u64), 1)
	testing.expect(t, !overflow_ok)
	original_error := result.segments.x0_error_um[0]
	original_maximum := result.maximum_snap_error_um
	result.segments.x0_error_um[0] = 0.6
	result.maximum_snap_error_um = 0.6
	_, diagnostic_error := snapped_segment_artifact_encode(
		SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH,
		result,
	)
	testing.expect_value(
		t,
		diagnostic_error,
		Snapped_Segment_Artifact_Error.Invalid_Record,
	)
	result.segments.x0_error_um[0] = original_error
	result.maximum_snap_error_um = original_maximum
	original_segment_id := result.segments.segment_ids[1]
	result.segments.segment_ids[1] = result.segments.segment_ids[0]
	_, identity_error := snapped_segment_artifact_encode(
		SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH,
		result,
	)
	testing.expect_value(
		t,
		identity_error,
		Snapped_Segment_Artifact_Error.Invalid_Record,
	)
	result.segments.segment_ids[1] = original_segment_id
}

snapped_segment_artifact_test_result :: proc() ->
	slicing.Snapped_Segment_Result {
	raw := slicing.CPU_Intersection_Result{
		layers = []slicing.Intersection_Layer{
			{0, 2, 0, 0},
			{2, 1, 0, 0},
		},
		segments = {
			layer_indices = []u32{0, 0, 1},
			triangle_indices = []u32{4, 5, 6},
			segment_ids = []contracts.Stable_ID{40, 50, 60},
			triangle_ids = []contracts.Stable_ID{400, 500, 600},
			edge_a = []slicing.Triangle_Edge{.AB, .BC, .CA},
			edge_b = []slicing.Triangle_Edge{.CA, .CA, .AB},
			x0 = []f64{0.00049, 1.0001, 2},
			y0 = []f64{0.00049, 1.0001, 2},
			x1 = []f64{0.00151, 1.0004, 3},
			y1 = []f64{0.00249, 1.0004, 3},
		},
	}
	result, error := slicing.snapped_segments_build(raw)
	assert(error == .None)
	return result
}

snapped_segment_artifact_test_bytes_equal :: proc(
	left, right: []u8,
) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH :: contracts.Content_Hash{
	0x8d, 0x49, 0x17, 0x31, 0x36, 0x55, 0x79, 0x28,
	0xac, 0x1e, 0xd1, 0xb4, 0x18, 0xc4, 0xd0, 0x3f,
	0x46, 0xcf, 0xb0, 0x49, 0x63, 0xd5, 0x14, 0x94,
	0x27, 0x2e, 0x33, 0x6a, 0xc0, 0x66, 0x92, 0x07,
}

SNAPPED_SEGMENT_ARTIFACT_TEST_DIGEST :: [sha2.DIGEST_SIZE_256]u8{
	0x7c, 0xe0, 0xb6, 0x8a, 0x66, 0x91, 0x66, 0x5d,
	0x24, 0x14, 0xbe, 0xdc, 0xd4, 0x71, 0x1e, 0xa3,
	0x8b, 0x65, 0x1f, 0xc1, 0xb0, 0x24, 0x40, 0x8a,
	0x05, 0xe4, 0x85, 0x0a, 0x94, 0x5c, 0xfc, 0xe6,
}
