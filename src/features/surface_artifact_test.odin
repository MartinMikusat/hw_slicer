package features

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

@(test)
surface_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	result := surface_artifact_test_result(t)
	defer surface_result_destroy(&result)
	bytes, encode_error := surface_artifact_encode(
		Surface_Artifact_Test_Region_Hash,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Surface_Artifact_Error.None,
	)
	artifact, decode_error := surface_artifact_decode(bytes)
	defer surface_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		decode_error,
		Surface_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 992)
	testing.expect_value(t, len(artifact.result.layers), 3)
	testing.expect_value(t, len(artifact.result.masks), 3)
	testing.expect_value(t, len(artifact.result.paths), 4)
	testing.expect_value(t, len(artifact.result.points), 16)
	testing.expect_value(t, artifact.result.bottom_mask_count, u64(1))
	testing.expect_value(t, artifact.result.top_mask_count, u64(2))
	testing.expect_value(
		t,
		artifact.region_hash,
		Surface_Artifact_Test_Region_Hash,
	)
	for layer, layer_index in artifact.result.layers {
		testing.expect_value(t, layer, result.layers[layer_index])
	}
	for mask, mask_index in artifact.result.masks {
		testing.expect_value(t, mask, result.masks[mask_index])
	}
	for path, path_index in artifact.result.paths {
		testing.expect_value(t, path, result.paths[path_index])
	}
	for point, point_index in artifact.result.points {
		testing.expect_value(t, point, result.points[point_index])
	}
	reencoded, reencode_error := surface_artifact_encode(
		Surface_Artifact_Test_Region_Hash,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Surface_Artifact_Error.None,
	)
	testing.expect(t, surface_artifact_test_bytes_equal(reencoded, bytes))
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(t, digest, Surface_Artifact_Test_Digest)
}

@(test)
surface_artifact_decode_is_source_independent_test :: proc(
	t: ^testing.T,
) {
	result := surface_artifact_test_result(t)
	bytes, encode_error := surface_artifact_encode(
		Surface_Artifact_Test_Region_Hash,
		result,
	)
	testing.expect_value(
		t,
		encode_error,
		Surface_Artifact_Error.None,
	)
	surface_result_destroy(&result)
	artifact, decode_error := surface_artifact_decode(bytes)
	defer {
		surface_artifact_destroy(&artifact)
		delete(bytes)
	}
	testing.expect_value(
		t,
		decode_error,
		Surface_Artifact_Error.None,
	)
	testing.expect_value(t, len(artifact.result.masks), 3)
	testing.expect_value(t, len(artifact.result.points), 16)
}

@(test)
surface_artifact_rejects_framing_content_and_limits_test :: proc(
	t: ^testing.T,
) {
	result := surface_artifact_test_result(t)
	defer surface_result_destroy(&result)
	bytes, encode_error := surface_artifact_encode(
		Surface_Artifact_Test_Region_Hash,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Surface_Artifact_Error.None,
	)
	_, truncated_error := surface_artifact_decode(bytes[:len(bytes)-1])
	testing.expect_value(
		t,
		truncated_error,
		Surface_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = 0
	_, magic_error := surface_artifact_decode(corrupt)
	testing.expect_value(
		t,
		magic_error,
		Surface_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	surface_artifact_put_u32(corrupt, 8, 2)
	_, version_error := surface_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Surface_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[160] = 1
	_, reserved_error := surface_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Surface_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[72] = corrupt[72] ~ 1
	_, hash_error := surface_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Surface_Artifact_Error.Hash_Mismatch,
	)
	path_offset :=
		int(SURFACE_ARTIFACT_HEADER_SIZE)+
		3*int(SURFACE_ARTIFACT_LAYER_SIZE)+
		3*int(SURFACE_ARTIFACT_MASK_SIZE)
	copy(corrupt, bytes)
	corrupt[path_offset+48] = 1
	_, record_error := surface_artifact_decode(corrupt)
	testing.expect_value(
		t,
		record_error,
		Surface_Artifact_Error.Invalid_Record,
	)
	copy(corrupt, bytes)
	corrupt[path_offset+49] = 1
	_, path_reserved_error := surface_artifact_decode(corrupt)
	testing.expect_value(
		t,
		path_reserved_error,
		Surface_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	surface_artifact_put_u64(
		corrupt,
		int(SURFACE_ARTIFACT_HEADER_SIZE),
		max(u64),
	)
	_, offset_error := surface_artifact_decode(corrupt)
	testing.expect_value(
		t,
		offset_error,
		Surface_Artifact_Error.Invalid_Record,
	)
	limits := DEFAULT_SURFACE_ARTIFACT_LIMITS
	limits.max_points = 15
	_, limit_error := surface_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		Surface_Artifact_Error.Limit,
	)
	_, overflow_ok := surface_artifact_byte_count(
		0,
		0,
		0,
		max(u64),
	)
	testing.expect(t, !overflow_ok)
	result.paths[0].point_offset = 1
	_, invalid_encode_error := surface_artifact_encode(
		Surface_Artifact_Test_Region_Hash,
		result,
	)
	testing.expect_value(
		t,
		invalid_encode_error,
		Surface_Artifact_Error.Invalid_Record,
	)
}

surface_artifact_test_result :: proc(t: ^testing.T) -> Surface_Result {
	topology := surface_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, result_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, result_error, Surface_Error.None)
	return result
}

surface_artifact_test_bytes_equal :: proc(left, right: []u8) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

Surface_Artifact_Test_Region_Hash :: contracts.Content_Hash{
	0x31, 0x53, 0x75, 0x97, 0xb9, 0xdb, 0xfd, 0x1f,
	0xee, 0xcc, 0xaa, 0x88, 0x66, 0x44, 0x22, 0x00,
	0x00, 0x22, 0x44, 0x66, 0x88, 0xaa, 0xcc, 0xee,
	0x1f, 0xfd, 0xdb, 0xb9, 0x97, 0x75, 0x53, 0x31,
}

Surface_Artifact_Test_Digest :: [sha2.DIGEST_SIZE_256]u8{
	0xd4, 0x28, 0x80, 0xeb, 0x1f, 0xf1, 0x39, 0xec,
	0xec, 0xbc, 0xfd, 0xbd, 0xaa, 0x1f, 0x7c, 0xe1,
	0xaf, 0xf7, 0xb0, 0xa4, 0x90, 0x72, 0xc8, 0x05,
	0xaa, 0x2b, 0x51, 0x7b, 0xb4, 0x69, 0x51, 0x7f,
}
