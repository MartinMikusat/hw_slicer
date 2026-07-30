package evidence

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
layer_schedule_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	result := layer_schedule_artifact_test_result(t)
	defer slicing.fixed_layer_schedule_destroy(&result)
	bytes, encode_error := layer_schedule_artifact_encode(result)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Layer_Schedule_Artifact_Error.None,
	)
	artifact, decode_error := layer_schedule_artifact_decode(bytes)
	defer layer_schedule_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		decode_error,
		Layer_Schedule_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 224)
	testing.expect_value(t, len(artifact.result.layer_z), 4)
	testing.expect_value(t, artifact.result.request_hash, result.request_hash)
	for layer_z, layer_index in artifact.result.layer_z {
		testing.expect_value(t, layer_z, result.layer_z[layer_index])
		testing.expect_value(
			t,
			artifact.result.layer_ids[layer_index],
			result.layer_ids[layer_index],
		)
	}
	reencoded, reencode_error :=
		layer_schedule_artifact_encode(artifact.result)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Layer_Schedule_Artifact_Error.None,
	)
	testing.expect(
		t,
		layer_schedule_artifact_test_bytes_equal(reencoded, bytes),
	)
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(
		t,
		digest,
		Layer_Schedule_Artifact_Test_Digest,
	)
}

@(test)
layer_schedule_artifact_rejects_framing_content_and_limits_test :: proc(
	t: ^testing.T,
) {
	result := layer_schedule_artifact_test_result(t)
	defer slicing.fixed_layer_schedule_destroy(&result)
	bytes, encode_error := layer_schedule_artifact_encode(result)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Layer_Schedule_Artifact_Error.None,
	)
	_, truncated_error :=
		layer_schedule_artifact_decode(bytes[:len(bytes)-1])
	testing.expect_value(
		t,
		truncated_error,
		Layer_Schedule_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = 0
	_, magic_error := layer_schedule_artifact_decode(corrupt)
	testing.expect_value(
		t,
		magic_error,
		Layer_Schedule_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	layer_schedule_artifact_put_u32(corrupt, 8, 2)
	_, version_error := layer_schedule_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Layer_Schedule_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[128] = 1
	_, reserved_error := layer_schedule_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Layer_Schedule_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[56] = corrupt[56] ~ 1
	_, hash_error := layer_schedule_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Layer_Schedule_Artifact_Error.Hash_Mismatch,
	)
	copy(corrupt, bytes)
	layer_schedule_artifact_put_i64(
		corrupt,
		int(LAYER_SCHEDULE_ARTIFACT_HEADER_SIZE),
		201,
	)
	_, record_error := layer_schedule_artifact_decode(corrupt)
	testing.expect_value(
		t,
		record_error,
		Layer_Schedule_Artifact_Error.Invalid_Record,
	)
	limits := DEFAULT_LAYER_SCHEDULE_ARTIFACT_LIMITS
	limits.max_layers = 3
	_, limit_error := layer_schedule_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		Layer_Schedule_Artifact_Error.Limit,
	)
	_, overflow_ok := layer_schedule_artifact_byte_count(max(u64))
	testing.expect(t, !overflow_ok)
	result.layer_z[0] += 1
	_, invalid_encode_error := layer_schedule_artifact_encode(result)
	testing.expect_value(
		t,
		invalid_encode_error,
		Layer_Schedule_Artifact_Error.Invalid_Record,
	)
}

layer_schedule_artifact_test_result :: proc(
	t: ^testing.T,
) -> slicing.Fixed_Layer_Schedule {
	request_hash := Layer_Schedule_Artifact_Test_Request_Hash
	result, result_error := slicing.fixed_layer_schedule_build({
		request_hash = request_hash,
		minimum_z = 0,
		maximum_z = 1000,
		first_plane_z = 200,
		layer_step = 200,
		max_layer_count = 10,
	})
	testing.expect_value(t, result_error, slicing.Schedule_Error.None)
	return result
}

layer_schedule_artifact_test_bytes_equal :: proc(
	left, right: []u8,
) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

Layer_Schedule_Artifact_Test_Request_Hash :: contracts.Content_Hash{
	0x41, 0x63, 0x85, 0xa7, 0xc9, 0xeb, 0x0d, 0x2f,
	0xdd, 0xbb, 0x99, 0x77, 0x55, 0x33, 0x11, 0xff,
	0xff, 0x11, 0x33, 0x55, 0x77, 0x99, 0xbb, 0xdd,
	0x2f, 0x0d, 0xeb, 0xc9, 0xa7, 0x85, 0x63, 0x41,
}

Layer_Schedule_Artifact_Test_Digest :: [sha2.DIGEST_SIZE_256]u8{
	0xb6, 0xf8, 0xfc, 0xc3, 0xfc, 0x35, 0x46, 0x60,
	0x94, 0xf0, 0xef, 0xbf, 0x4a, 0xfb, 0x75, 0xbc,
	0x66, 0x84, 0x08, 0x08, 0x3f, 0x5b, 0xc9, 0x99,
	0x4d, 0x99, 0x63, 0x2f, 0x00, 0x94, 0xf2, 0x75,
}
