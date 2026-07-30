package features

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"

@(test)
unified_path_plan_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	layer_ids := []contracts.Stable_ID{10}
	sources := unified_path_plan_test_sources()
	defer unified_path_plan_test_sources_destroy(sources)
	result, result_error := unified_path_plan_build(
		layer_ids,
		sources,
		unified_path_plan_test_config(),
	)
	defer unified_path_plan_result_destroy(&result)
	testing.expect_value(
		t,
		result_error,
		Unified_Path_Plan_Error.None,
	)
	bytes, encode_error := unified_path_plan_artifact_encode(
		Unified_Path_Plan_Artifact_Test_Source_Hash,
		layer_ids,
		sources,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Unified_Path_Plan_Artifact_Error.None,
	)
	artifact, decode_error :=
		unified_path_plan_artifact_decode(bytes)
	defer unified_path_plan_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		decode_error,
		Unified_Path_Plan_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 2_048)
	testing.expect_value(t, len(artifact.result.layers), 1)
	testing.expect_value(t, len(artifact.result.paths), 6)
	testing.expect_value(t, len(artifact.result.moves), 16)
	testing.expect_value(
		t,
		artifact.source_paths_hash,
		Unified_Path_Plan_Artifact_Test_Source_Hash,
	)
	testing.expect_value(
		t,
		artifact.result.travel_move_count,
		u64(6),
	)
	testing.expect_value(
		t,
		artifact.result.extrude_move_count,
		u64(10),
	)
	for path, path_index in artifact.result.paths {
		testing.expect_value(t, path, result.paths[path_index])
	}
	for move, move_index in artifact.result.moves {
		testing.expect_value(t, move, result.moves[move_index])
	}
	reencoded, reencode_error :=
		unified_path_plan_artifact_encode(
			Unified_Path_Plan_Artifact_Test_Source_Hash,
			layer_ids,
			sources,
			artifact.result,
		)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Unified_Path_Plan_Artifact_Error.None,
	)
	testing.expect(
		t,
		unified_path_plan_artifact_test_bytes_equal(
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
		Unified_Path_Plan_Artifact_Test_Digest,
	)
}

@(test)
unified_path_plan_artifact_decode_is_source_independent_test :: proc(
	t: ^testing.T,
) {
	layer_ids := []contracts.Stable_ID{10}
	sources := unified_path_plan_test_sources()
	result, result_error := unified_path_plan_build(
		layer_ids,
		sources,
		unified_path_plan_test_config(),
	)
	testing.expect_value(
		t,
		result_error,
		Unified_Path_Plan_Error.None,
	)
	bytes, encode_error := unified_path_plan_artifact_encode(
		Unified_Path_Plan_Artifact_Test_Source_Hash,
		layer_ids,
		sources,
		result,
	)
	testing.expect_value(
		t,
		encode_error,
		Unified_Path_Plan_Artifact_Error.None,
	)
	unified_path_plan_result_destroy(&result)
	unified_path_plan_test_sources_destroy(sources)
	artifact, decode_error :=
		unified_path_plan_artifact_decode(bytes)
	defer {
		unified_path_plan_artifact_destroy(&artifact)
		delete(bytes)
	}
	testing.expect_value(
		t,
		decode_error,
		Unified_Path_Plan_Artifact_Error.None,
	)
	testing.expect_value(t, len(artifact.result.paths), 6)
	testing.expect_value(t, len(artifact.result.moves), 16)
}

@(test)
unified_path_plan_artifact_rejects_framing_content_and_limits_test :: proc(
	t: ^testing.T,
) {
	layer_ids := []contracts.Stable_ID{10}
	sources := unified_path_plan_test_sources()
	defer unified_path_plan_test_sources_destroy(sources)
	result, result_error := unified_path_plan_build(
		layer_ids,
		sources,
		unified_path_plan_test_config(),
	)
	defer unified_path_plan_result_destroy(&result)
	testing.expect_value(
		t,
		result_error,
		Unified_Path_Plan_Error.None,
	)
	bytes, encode_error := unified_path_plan_artifact_encode(
		Unified_Path_Plan_Artifact_Test_Source_Hash,
		layer_ids,
		sources,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Unified_Path_Plan_Artifact_Error.None,
	)
	_, truncated_error :=
		unified_path_plan_artifact_decode(bytes[:len(bytes)-1])
	testing.expect_value(
		t,
		truncated_error,
		Unified_Path_Plan_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = 0
	_, magic_error := unified_path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		magic_error,
		Unified_Path_Plan_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	unified_path_plan_artifact_put_u32(corrupt, 8, 2)
	_, version_error := unified_path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Unified_Path_Plan_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[114] = 1
	_, reserved_error := unified_path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Unified_Path_Plan_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, hash_error := unified_path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Unified_Path_Plan_Artifact_Error.Hash_Mismatch,
	)
	path_offset :=
		int(UNIFIED_PATH_PLAN_ARTIFACT_HEADER_SIZE)+
		int(UNIFIED_PATH_PLAN_ARTIFACT_LAYER_SIZE)
	copy(corrupt, bytes)
	corrupt[path_offset+65] = 0
	_, record_error := unified_path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		record_error,
		Unified_Path_Plan_Artifact_Error.Invalid_Record,
	)
	copy(corrupt, bytes)
	corrupt[path_offset+68] = 1
	_, path_reserved_error :=
		unified_path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		path_reserved_error,
		Unified_Path_Plan_Artifact_Error.Malformed,
	)
	limits := DEFAULT_UNIFIED_PATH_PLAN_ARTIFACT_LIMITS
	limits.max_moves = 15
	_, limit_error :=
		unified_path_plan_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		Unified_Path_Plan_Artifact_Error.Limit,
	)
	_, overflow_ok := unified_path_plan_artifact_byte_count(
		0,
		0,
		max(u64),
	)
	testing.expect(t, !overflow_ok)
	result.moves[0].point_b.x += 1
	_, invalid_encode_error := unified_path_plan_artifact_encode(
		Unified_Path_Plan_Artifact_Test_Source_Hash,
		layer_ids,
		sources,
		result,
	)
	testing.expect_value(
		t,
		invalid_encode_error,
		Unified_Path_Plan_Artifact_Error.Invalid_Record,
	)
}

unified_path_plan_artifact_test_bytes_equal :: proc(
	left, right: []u8,
) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

Unified_Path_Plan_Artifact_Test_Source_Hash ::
	contracts.Content_Hash{
		0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
		0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
		0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
		0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
	}

Unified_Path_Plan_Artifact_Test_Digest ::
	[sha2.DIGEST_SIZE_256]u8{
		0xd7, 0x25, 0x7f, 0x17, 0x28, 0x04, 0xde, 0x44,
		0x6d, 0x40, 0x60, 0xa0, 0x36, 0x2b, 0xf6, 0x1a,
		0xc2, 0x2f, 0x6e, 0x19, 0x06, 0x89, 0x15, 0x77,
		0x3c, 0x27, 0x60, 0xe8, 0xc8, 0xaf, 0xc1, 0xfa,
	}
