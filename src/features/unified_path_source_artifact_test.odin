package features

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"

@(test)
unified_path_source_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	perimeters, bridges, gaps, solids, infill, supports, process :=
		unified_path_source_test_inputs()
	defer unified_path_source_test_inputs_destroy(
		&perimeters,
		&bridges,
		&gaps,
		&solids,
		&infill,
		&supports,
	)
	layer_ids := []contracts.Stable_ID{10}
	result, result_error := unified_path_sources_build(
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		true,
	)
	defer unified_path_source_result_destroy(&result)
	testing.expect_value(
		t,
		result_error,
		Unified_Path_Source_Error.None,
	)
	bytes, encode_error := unified_path_source_artifact_encode(
		unified_path_source_artifact_test_hash(1),
		unified_path_source_artifact_test_hash(33),
		unified_path_source_artifact_test_hash(65),
		unified_path_source_artifact_test_hash(97),
		unified_path_source_artifact_test_hash(129),
		unified_path_source_artifact_test_hash(161),
		unified_path_source_artifact_test_hash(193),
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Unified_Path_Source_Artifact_Error.None,
	)
	artifact, decode_error :=
		unified_path_source_artifact_decode(bytes)
	defer unified_path_source_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		decode_error,
		Unified_Path_Source_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 1_288)
	testing.expect_value(t, len(artifact.result.layers), 1)
	testing.expect_value(t, len(artifact.result.sources), 7)
	testing.expect_value(t, len(artifact.result.points), 19)
	testing.expect_value(
		t,
		artifact.dependencies.perimeter_hash,
		unified_path_source_artifact_test_hash(1),
	)
	for source, source_index in artifact.result.sources {
		expected := result.sources[source_index]
		testing.expect_value(t, source.stable_id, expected.stable_id)
		testing.expect_value(t, source.layer_id, expected.layer_id)
		testing.expect_value(t, source.role, expected.role)
		testing.expect_value(
			t,
			len(source.points),
			len(expected.points),
		)
		for point, point_index in source.points {
			testing.expect_value(
				t,
				point,
				expected.points[point_index],
			)
			testing.expect_value(
				t,
				source.line_widths[point_index],
				expected.line_widths[point_index],
			)
		}
	}
	reencoded, reencode_error :=
		unified_path_source_artifact_encode(
			unified_path_source_artifact_test_hash(1),
			unified_path_source_artifact_test_hash(33),
			unified_path_source_artifact_test_hash(65),
			unified_path_source_artifact_test_hash(97),
			unified_path_source_artifact_test_hash(129),
			unified_path_source_artifact_test_hash(161),
			unified_path_source_artifact_test_hash(193),
			layer_ids,
			perimeters,
			bridges,
			gaps,
			solids,
			infill,
			supports,
			process,
			artifact.result,
		)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Unified_Path_Source_Artifact_Error.None,
	)
	testing.expect(
		t,
		unified_path_source_artifact_test_bytes_equal(
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
		Unified_Path_Source_Artifact_Test_Digest,
	)
}

@(test)
unified_path_source_artifact_decode_is_source_independent_test :: proc(
	t: ^testing.T,
) {
	perimeters, bridges, gaps, solids, infill, supports, process :=
		unified_path_source_test_inputs()
	layer_ids := []contracts.Stable_ID{10}
	result, result_error := unified_path_sources_build(
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		true,
	)
	testing.expect_value(
		t,
		result_error,
		Unified_Path_Source_Error.None,
	)
	bytes, encode_error := unified_path_source_artifact_encode(
		unified_path_source_artifact_test_hash(1),
		unified_path_source_artifact_test_hash(33),
		unified_path_source_artifact_test_hash(65),
		unified_path_source_artifact_test_hash(97),
		unified_path_source_artifact_test_hash(129),
		unified_path_source_artifact_test_hash(161),
		unified_path_source_artifact_test_hash(193),
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		result,
	)
	testing.expect_value(
		t,
		encode_error,
		Unified_Path_Source_Artifact_Error.None,
	)
	unified_path_source_result_destroy(&result)
	unified_path_source_test_inputs_destroy(
		&perimeters,
		&bridges,
		&gaps,
		&solids,
		&infill,
		&supports,
	)
	artifact, decode_error :=
		unified_path_source_artifact_decode(bytes)
	defer {
		unified_path_source_artifact_destroy(&artifact)
		delete(bytes)
	}
	testing.expect_value(
		t,
		decode_error,
		Unified_Path_Source_Artifact_Error.None,
	)
	testing.expect_value(t, len(artifact.result.sources), 7)
	testing.expect_value(t, len(artifact.result.points), 19)
}

@(test)
unified_path_source_artifact_rejects_invalid_content_and_limits_test :: proc(
	t: ^testing.T,
) {
	perimeters, bridges, gaps, solids, infill, supports, process :=
		unified_path_source_test_inputs()
	defer unified_path_source_test_inputs_destroy(
		&perimeters,
		&bridges,
		&gaps,
		&solids,
		&infill,
		&supports,
	)
	layer_ids := []contracts.Stable_ID{10}
	result, result_error := unified_path_sources_build(
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		true,
	)
	defer unified_path_source_result_destroy(&result)
	testing.expect_value(
		t,
		result_error,
		Unified_Path_Source_Error.None,
	)
	bytes, encode_error := unified_path_source_artifact_encode(
		unified_path_source_artifact_test_hash(1),
		unified_path_source_artifact_test_hash(33),
		unified_path_source_artifact_test_hash(65),
		unified_path_source_artifact_test_hash(97),
		unified_path_source_artifact_test_hash(129),
		unified_path_source_artifact_test_hash(161),
		unified_path_source_artifact_test_hash(193),
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Unified_Path_Source_Artifact_Error.None,
	)
	_, truncated_error := unified_path_source_artifact_decode(
		bytes[:len(bytes)-1],
	)
	testing.expect_value(
		t,
		truncated_error,
		Unified_Path_Source_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	unified_path_source_artifact_put_u32(corrupt, 8, 2)
	_, version_error := unified_path_source_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Unified_Path_Source_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[328] = 1
	_, reserved_error := unified_path_source_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Unified_Path_Source_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[32] = corrupt[32] ~ 1
	_, hash_error := unified_path_source_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Unified_Path_Source_Artifact_Error.Hash_Mismatch,
	)
	source_offset :=
		int(UNIFIED_PATH_SOURCE_ARTIFACT_HEADER_SIZE)+
		int(UNIFIED_PATH_SOURCE_ARTIFACT_LAYER_SIZE)
	copy(corrupt, bytes)
	corrupt[source_offset+44] = 0
	_, record_error := unified_path_source_artifact_decode(corrupt)
	testing.expect_value(
		t,
		record_error,
		Unified_Path_Source_Artifact_Error.Invalid_Record,
	)
	limits := DEFAULT_UNIFIED_PATH_SOURCE_ARTIFACT_LIMITS
	limits.max_points = 18
	_, limit_error :=
		unified_path_source_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		Unified_Path_Source_Artifact_Error.Limit,
	)
	_, overflow_ok := unified_path_source_artifact_byte_count(
		0,
		0,
		max(u64),
	)
	testing.expect(t, !overflow_ok)
	result.points[0].x += 1
	_, invalid_encode_error := unified_path_source_artifact_encode(
		unified_path_source_artifact_test_hash(1),
		unified_path_source_artifact_test_hash(33),
		unified_path_source_artifact_test_hash(65),
		unified_path_source_artifact_test_hash(97),
		unified_path_source_artifact_test_hash(129),
		unified_path_source_artifact_test_hash(161),
		unified_path_source_artifact_test_hash(193),
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		result,
	)
	testing.expect_value(
		t,
		invalid_encode_error,
		Unified_Path_Source_Artifact_Error.Invalid_Record,
	)
}

unified_path_source_artifact_test_hash :: proc(
	seed: u8,
) -> (result: contracts.Content_Hash) {
	for &byte, byte_index in result {
		byte = seed+u8(byte_index)
	}
	return
}

unified_path_source_artifact_test_bytes_equal :: proc(
	left, right: []u8,
) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

Unified_Path_Source_Artifact_Test_Digest ::
	[sha2.DIGEST_SIZE_256]u8{
		0x22, 0x0e, 0xd9, 0x30, 0x19, 0x4a, 0x23, 0xdf,
		0x2c, 0x29, 0x86, 0xdf, 0xac, 0x6b, 0x05, 0xf8,
		0x91, 0xb5, 0x43, 0xb2, 0x83, 0xcc, 0xfc, 0xc3,
		0xf4, 0x94, 0x3c, 0x45, 0xe7, 0xf9, 0xdf, 0xff,
	}
