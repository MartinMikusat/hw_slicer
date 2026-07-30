package features

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"

@(test)
motion_plan_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	layer_ids, layer_z, model, plan, extrusion, profile :=
		motion_plan_test_inputs(t, true, 100)
	defer motion_plan_test_inputs_destroy(
		layer_ids,
		layer_z,
		model,
		&plan,
		&extrusion,
	)
	result, result_error := motion_plan_build(
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
	)
	defer motion_plan_result_destroy(&result)
	testing.expect_value(t, result_error, Motion_Plan_Error.None)
	bytes, encode_error := motion_plan_artifact_encode(
		Motion_Plan_Artifact_Test_Path_Hash,
		Motion_Plan_Artifact_Test_Extrusion_Hash,
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
		result,
	)
	defer delete(bytes)
	artifact, decode_error := motion_plan_artifact_decode(bytes)
	defer motion_plan_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		encode_error,
		Motion_Plan_Artifact_Error.None,
	)
	testing.expect_value(
		t,
		decode_error,
		Motion_Plan_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 1_048)
	testing.expect_value(t, len(artifact.dependencies.layers), 1)
	testing.expect_value(t, len(artifact.result.layers), 1)
	testing.expect_value(t, len(artifact.result.operations), 5)
	testing.expect_value(
		t,
		artifact.dependencies.path_plan_hash,
		Motion_Plan_Artifact_Test_Path_Hash,
	)
	testing.expect_value(
		t,
		artifact.dependencies.extrusion_hash,
		Motion_Plan_Artifact_Test_Extrusion_Hash,
	)
	for operation, operation_index in artifact.result.operations {
		testing.expect_value(
			t,
			operation,
			result.operations[operation_index],
		)
	}
	reencoded, reencode_error := motion_plan_artifact_encode(
		Motion_Plan_Artifact_Test_Path_Hash,
		Motion_Plan_Artifact_Test_Extrusion_Hash,
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Motion_Plan_Artifact_Error.None,
	)
	testing.expect(t, motion_plan_artifact_test_bytes_equal(reencoded, bytes))
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(t, digest, Motion_Plan_Artifact_Test_Digest)
}

@(test)
motion_plan_artifact_decode_is_source_independent_test :: proc(
	t: ^testing.T,
) {
	layer_ids, layer_z, model, plan, extrusion, profile :=
		motion_plan_test_inputs(t, false, 1_000)
	result, result_error := motion_plan_build(
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
	)
	testing.expect_value(t, result_error, Motion_Plan_Error.None)
	bytes, encode_error := motion_plan_artifact_encode(
		Motion_Plan_Artifact_Test_Path_Hash,
		Motion_Plan_Artifact_Test_Extrusion_Hash,
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
		result,
	)
	testing.expect_value(
		t,
		encode_error,
		Motion_Plan_Artifact_Error.None,
	)
	motion_plan_result_destroy(&result)
	motion_plan_test_inputs_destroy(
		layer_ids,
		layer_z,
		model,
		&plan,
		&extrusion,
	)
	artifact, decode_error := motion_plan_artifact_decode(bytes)
	defer {
		motion_plan_artifact_destroy(&artifact)
		delete(bytes)
	}
	testing.expect_value(
		t,
		decode_error,
		Motion_Plan_Artifact_Error.None,
	)
	testing.expect_value(t, len(artifact.result.layers), 1)
	testing.expect(t, len(artifact.result.operations) > 0)
}

@(test)
motion_plan_artifact_rejects_framing_limits_and_corruption_test :: proc(
	t: ^testing.T,
) {
	layer_ids, layer_z, model, plan, extrusion, profile :=
		motion_plan_test_inputs(t, true, 100)
	defer motion_plan_test_inputs_destroy(
		layer_ids,
		layer_z,
		model,
		&plan,
		&extrusion,
	)
	result, result_error := motion_plan_build(
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
	)
	defer motion_plan_result_destroy(&result)
	testing.expect_value(t, result_error, Motion_Plan_Error.None)
	bytes, encode_error := motion_plan_artifact_encode(
		Motion_Plan_Artifact_Test_Path_Hash,
		Motion_Plan_Artifact_Test_Extrusion_Hash,
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Motion_Plan_Artifact_Error.None,
	)
	_, truncated_error :=
		motion_plan_artifact_decode(bytes[:len(bytes)-1])
	testing.expect_value(
		t,
		truncated_error,
		Motion_Plan_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	motion_plan_artifact_put_u32(corrupt, 8, 2)
	_, version_error := motion_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Motion_Plan_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[272] = 1
	_, reserved_error := motion_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Motion_Plan_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	motion_plan_artifact_put_u64(corrupt, 192, 2)
	_, dependency_error := motion_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		dependency_error,
		Motion_Plan_Artifact_Error.Malformed,
	)
	operation_offset :=
		int(MOTION_PLAN_ARTIFACT_HEADER_SIZE)+
		int(MOTION_PLAN_ARTIFACT_DEPENDENCY_SIZE)+
		int(MOTION_PLAN_ARTIFACT_LAYER_SIZE)
	copy(corrupt, bytes)
	corrupt[operation_offset+40] = corrupt[operation_offset+40] ~ 1
	_, hash_error := motion_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Motion_Plan_Artifact_Error.Hash_Mismatch,
	)
	copy(corrupt, bytes)
	corrupt[operation_offset+32] = u8(Motion_Operation_Kind.Invalid)
	_, record_error := motion_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		record_error,
		Motion_Plan_Artifact_Error.Invalid_Record,
	)
	limits := DEFAULT_MOTION_PLAN_ARTIFACT_LIMITS
	limits.max_operations = u64(len(result.operations)-1)
	_, limit_error := motion_plan_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		Motion_Plan_Artifact_Error.Limit,
	)
	_, overflow_ok := motion_plan_artifact_byte_count(0, max(u64))
	testing.expect(t, !overflow_ok)
	result.operations[0].duration_us += 1
	_, invalid_encode_error := motion_plan_artifact_encode(
		Motion_Plan_Artifact_Test_Path_Hash,
		Motion_Plan_Artifact_Test_Extrusion_Hash,
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
		result,
	)
	testing.expect_value(
		t,
		invalid_encode_error,
		Motion_Plan_Artifact_Error.Invalid_Record,
	)
}

motion_plan_artifact_test_bytes_equal :: proc(left, right: []u8) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

Motion_Plan_Artifact_Test_Path_Hash :: contracts.Content_Hash{
	0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
	0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
	0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
	0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
}

Motion_Plan_Artifact_Test_Extrusion_Hash :: contracts.Content_Hash{
	0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
	0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
	0x00, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99,
	0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
}

Motion_Plan_Artifact_Test_Digest :: [sha2.DIGEST_SIZE_256]u8{
	0xc2, 0x30, 0x5b, 0xd4, 0x9b, 0x8d, 0xd5, 0xa0,
	0x70, 0xf2, 0xe2, 0x17, 0x55, 0xdb, 0x70, 0x15,
	0x85, 0x07, 0x6e, 0x5b, 0x9e, 0x0e, 0x53, 0xa2,
	0x40, 0x00, 0xfb, 0x4a, 0xde, 0x6a, 0xfb, 0xbf,
}
