package features

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

@(test)
infill_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	result := infill_artifact_test_result(t)
	defer infill_result_destroy(&result)
	bytes, encode_error := infill_artifact_encode(
		Infill_Artifact_Test_Region_Hash,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Infill_Artifact_Error.None,
	)
	artifact, decode_error := infill_artifact_decode(bytes)
	defer infill_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		decode_error,
		Infill_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 1_560)
	testing.expect_value(t, len(artifact.result.layers), 1)
	testing.expect_value(t, len(artifact.result.segments), 6)
	testing.expect_value(t, len(artifact.result.boundary_hits), 12)
	testing.expect_value(
		t,
		artifact.region_hash,
		Infill_Artifact_Test_Region_Hash,
	)
	testing.expect_value(
		t,
		artifact.result.scanline_count,
		u64(4),
	)
	for segment, segment_index in artifact.result.segments {
		testing.expect_value(
			t,
			segment,
			result.segments[segment_index],
		)
	}
	for hit, hit_index in artifact.result.boundary_hits {
		testing.expect_value(
			t,
			hit,
			result.boundary_hits[hit_index],
		)
	}
	reencoded, reencode_error := infill_artifact_encode(
		Infill_Artifact_Test_Region_Hash,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Infill_Artifact_Error.None,
	)
	testing.expect(
		t,
		infill_artifact_test_bytes_equal(reencoded, bytes),
	)
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(
		t,
		digest,
		Infill_Artifact_Test_Digest,
	)
}

@(test)
infill_artifact_decode_is_source_independent_test :: proc(
	t: ^testing.T,
) {
	result := infill_artifact_test_result(t)
	bytes, encode_error := infill_artifact_encode(
		Infill_Artifact_Test_Region_Hash,
		result,
	)
	testing.expect_value(
		t,
		encode_error,
		Infill_Artifact_Error.None,
	)
	infill_result_destroy(&result)
	artifact, decode_error := infill_artifact_decode(bytes)
	defer {
		infill_artifact_destroy(&artifact)
		delete(bytes)
	}
	testing.expect_value(
		t,
		decode_error,
		Infill_Artifact_Error.None,
	)
	testing.expect_value(t, len(artifact.result.segments), 6)
	testing.expect_value(t, len(artifact.result.boundary_hits), 12)
}

@(test)
infill_artifact_rejects_framing_content_and_limits_test :: proc(
	t: ^testing.T,
) {
	result := infill_artifact_test_result(t)
	defer infill_result_destroy(&result)
	bytes, encode_error := infill_artifact_encode(
		Infill_Artifact_Test_Region_Hash,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Infill_Artifact_Error.None,
	)
	_, truncated_error :=
		infill_artifact_decode(bytes[:len(bytes)-1])
	testing.expect_value(
		t,
		truncated_error,
		Infill_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = 0
	_, magic_error := infill_artifact_decode(corrupt)
	testing.expect_value(
		t,
		magic_error,
		Infill_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	infill_artifact_put_u32(corrupt, 8, 2)
	_, version_error := infill_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Infill_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[175] = 1
	_, reserved_error := infill_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Infill_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, hash_error := infill_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Infill_Artifact_Error.Hash_Mismatch,
	)
	segment_offset :=
		int(INFILL_ARTIFACT_HEADER_SIZE)+
		int(INFILL_ARTIFACT_LAYER_SIZE)
	copy(corrupt, bytes)
	corrupt[segment_offset+80] = 0
	_, record_error := infill_artifact_decode(corrupt)
	testing.expect_value(
		t,
		record_error,
		Infill_Artifact_Error.Invalid_Record,
	)
	copy(corrupt, bytes)
	corrupt[segment_offset+81] = 1
	_, segment_reserved_error := infill_artifact_decode(corrupt)
	testing.expect_value(
		t,
		segment_reserved_error,
		Infill_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	infill_artifact_put_u64(
		corrupt,
		int(INFILL_ARTIFACT_HEADER_SIZE),
		max(u64),
	)
	_, offset_error := infill_artifact_decode(corrupt)
	testing.expect_value(
		t,
		offset_error,
		Infill_Artifact_Error.Invalid_Record,
	)
	limits := DEFAULT_INFILL_ARTIFACT_LIMITS
	limits.max_hits = 11
	_, limit_error := infill_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		Infill_Artifact_Error.Limit,
	)
	_, overflow_ok := infill_artifact_byte_count(
		0,
		0,
		max(u64),
	)
	testing.expect(t, !overflow_ok)
	result.boundary_hits[0].error_numerator += 1
	_, invalid_encode_error := infill_artifact_encode(
		Infill_Artifact_Test_Region_Hash,
		result,
	)
	testing.expect_value(
		t,
		invalid_encode_error,
		Infill_Artifact_Error.Invalid_Record,
	)
}

infill_artifact_test_result :: proc(t: ^testing.T) -> Infill_Result {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, result_error := infill_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			spacing = 200,
			boundary_inset = 100,
			phase = 0,
			base_axis = .Vertical,
			alternate_each_layer = true,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = 0,
		},
	)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, result_error, Infill_Error.None)
	return result
}

infill_artifact_test_bytes_equal :: proc(left, right: []u8) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

Infill_Artifact_Test_Region_Hash :: contracts.Content_Hash{
	0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
	0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
	0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
	0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
}

Infill_Artifact_Test_Digest :: [sha2.DIGEST_SIZE_256]u8{
	0xa1, 0x46, 0x07, 0xc4, 0xdf, 0x59, 0x9d, 0x4f,
	0xec, 0x80, 0x79, 0x50, 0x63, 0xd8, 0xfc, 0x05,
	0x85, 0x31, 0x4c, 0x09, 0xb4, 0xe3, 0xc6, 0x06,
	0x12, 0xf3, 0x29, 0x1a, 0xe8, 0x7f, 0x36, 0x19,
}
