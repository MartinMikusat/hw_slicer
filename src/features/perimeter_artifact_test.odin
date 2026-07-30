package features

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

@(test)
perimeter_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	result := perimeter_artifact_test_result(t)
	defer perimeter_result_destroy(&result)
	bytes, encode_error := perimeter_artifact_encode(
		Perimeter_Artifact_Test_Region_Hash,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Perimeter_Artifact_Error.None,
	)
	artifact, decode_error := perimeter_artifact_decode(bytes)
	defer perimeter_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		decode_error,
		Perimeter_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 864)
	testing.expect_value(t, len(artifact.result.layers), 1)
	testing.expect_value(t, len(artifact.result.groups), 2)
	testing.expect_value(t, len(artifact.result.paths), 4)
	testing.expect_value(t, len(artifact.result.points), 16)
	testing.expect_value(
		t,
		artifact.region_hash,
		Perimeter_Artifact_Test_Region_Hash,
	)
	for layer, layer_index in artifact.result.layers {
		testing.expect_value(t, layer, result.layers[layer_index])
	}
	for group, group_index in artifact.result.groups {
		testing.expect_value(t, group, result.groups[group_index])
	}
	for path, path_index in artifact.result.paths {
		testing.expect_value(t, path, result.paths[path_index])
	}
	for point, point_index in artifact.result.points {
		testing.expect_value(t, point, result.points[point_index])
	}
	reencoded, reencode_error := perimeter_artifact_encode(
		Perimeter_Artifact_Test_Region_Hash,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Perimeter_Artifact_Error.None,
	)
	testing.expect(
		t,
		perimeter_artifact_test_bytes_equal(reencoded, bytes),
	)
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(
		t,
		digest,
		Perimeter_Artifact_Test_Digest,
	)
}

@(test)
perimeter_artifact_decode_is_source_independent_test :: proc(
	t: ^testing.T,
) {
	result := perimeter_artifact_test_result(t)
	bytes, encode_error := perimeter_artifact_encode(
		Perimeter_Artifact_Test_Region_Hash,
		result,
	)
	testing.expect_value(
		t,
		encode_error,
		Perimeter_Artifact_Error.None,
	)
	perimeter_result_destroy(&result)
	artifact, decode_error := perimeter_artifact_decode(bytes)
	defer {
		perimeter_artifact_destroy(&artifact)
		delete(bytes)
	}
	testing.expect_value(
		t,
		decode_error,
		Perimeter_Artifact_Error.None,
	)
	testing.expect_value(t, len(artifact.result.paths), 4)
	testing.expect_value(t, len(artifact.result.points), 16)
}

@(test)
perimeter_artifact_rejects_framing_content_and_limits_test :: proc(
	t: ^testing.T,
) {
	result := perimeter_artifact_test_result(t)
	defer perimeter_result_destroy(&result)
	bytes, encode_error := perimeter_artifact_encode(
		Perimeter_Artifact_Test_Region_Hash,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Perimeter_Artifact_Error.None,
	)
	_, truncated_error :=
		perimeter_artifact_decode(bytes[:len(bytes)-1])
	testing.expect_value(
		t,
		truncated_error,
		Perimeter_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = 0
	_, magic_error := perimeter_artifact_decode(corrupt)
	testing.expect_value(
		t,
		magic_error,
		Perimeter_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	perimeter_artifact_put_u32(corrupt, 8, 2)
	_, version_error := perimeter_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Perimeter_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[169] = 1
	_, reserved_error := perimeter_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Perimeter_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[72] = corrupt[72] ~ 1
	_, hash_error := perimeter_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Perimeter_Artifact_Error.Hash_Mismatch,
	)
	path_offset :=
		int(PERIMETER_ARTIFACT_HEADER_SIZE)+
		int(PERIMETER_ARTIFACT_LAYER_SIZE)+
		2*int(PERIMETER_ARTIFACT_GROUP_SIZE)
	copy(corrupt, bytes)
	corrupt[path_offset+44] = 1
	_, record_error := perimeter_artifact_decode(corrupt)
	testing.expect_value(
		t,
		record_error,
		Perimeter_Artifact_Error.Invalid_Record,
	)
	copy(corrupt, bytes)
	corrupt[path_offset+45] = 1
	_, path_reserved_error := perimeter_artifact_decode(corrupt)
	testing.expect_value(
		t,
		path_reserved_error,
		Perimeter_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	perimeter_artifact_put_u64(
		corrupt,
		int(PERIMETER_ARTIFACT_HEADER_SIZE),
		max(u64),
	)
	_, offset_error := perimeter_artifact_decode(corrupt)
	testing.expect_value(
		t,
		offset_error,
		Perimeter_Artifact_Error.Invalid_Record,
	)
	limits := DEFAULT_PERIMETER_ARTIFACT_LIMITS
	limits.max_points = 15
	_, limit_error := perimeter_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		Perimeter_Artifact_Error.Limit,
	)
	_, overflow_ok := perimeter_artifact_byte_count(
		0,
		0,
		0,
		max(u64),
	)
	testing.expect(t, !overflow_ok)
	result.paths[0].point_offset = 1
	_, invalid_encode_error := perimeter_artifact_encode(
		Perimeter_Artifact_Test_Region_Hash,
		result,
	)
	testing.expect_value(
		t,
		invalid_encode_error,
		Perimeter_Artifact_Error.Invalid_Record,
	)
}

perimeter_artifact_test_result :: proc(t: ^testing.T) -> Perimeter_Result {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, result_error := perimeters_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			count = 2,
			line_width = 100,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = 0,
		},
	)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, result_error, Perimeter_Error.None)
	return result
}

perimeter_artifact_test_bytes_equal :: proc(left, right: []u8) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

Perimeter_Artifact_Test_Region_Hash :: contracts.Content_Hash{
	0x21, 0x43, 0x65, 0x87, 0xa9, 0xcb, 0xed, 0x0f,
	0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
	0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
	0x0f, 0xed, 0xcb, 0xa9, 0x87, 0x65, 0x43, 0x21,
}

Perimeter_Artifact_Test_Digest :: [sha2.DIGEST_SIZE_256]u8{
	0xc1, 0xcd, 0xe2, 0xa7, 0xcb, 0xe5, 0xb3, 0x21,
	0x8c, 0xbc, 0x48, 0x93, 0xd4, 0x8c, 0x96, 0x7c,
	0xd3, 0x6e, 0x9d, 0x7d, 0xb2, 0xb1, 0xc2, 0x6d,
	0x85, 0xc8, 0xdc, 0x70, 0x46, 0x65, 0x57, 0xa6,
}
