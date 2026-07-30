package gcode

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

@(test)
marlin_artifact_round_trip_preserves_bytes_and_correlation_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	motion_hash := Marlin_Artifact_Test_Motion_Hash
	bytes, encode_error :=
		marlin_artifact_encode(motion_hash, motion, profile, result)
	defer delete(bytes)
	artifact, decode_error := marlin_artifact_decode(bytes)
	defer marlin_artifact_destroy(&artifact)
	testing.expect_value(t, encode_error, Marlin_Artifact_Error.None)
	testing.expect_value(t, decode_error, Marlin_Artifact_Error.None)
	testing.expect_value(t, artifact.motion_hash, motion_hash)
	testing.expect_value(
		t,
		artifact.profile_revisions,
		profiles.profile_revisions(profile),
	)
	testing.expect_value(t, artifact.result.layer_count, result.layer_count)
	testing.expect_value(
		t,
		artifact.result.motion_operation_count,
		result.motion_operation_count,
	)
	testing.expect(
		t,
		marlin_test_bytes_equal(artifact.result.bytes, result.bytes),
	)
	testing.expect_value(
		t,
		len(artifact.result.commands),
		len(result.commands),
	)
	for command, command_index in artifact.result.commands {
		testing.expect_value(t, command, result.commands[command_index])
	}

	reencoded, reencode_error := marlin_artifact_encode(
		artifact.motion_hash,
		motion,
		profile,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Marlin_Artifact_Error.None,
	)
	testing.expect(t, marlin_test_bytes_equal(reencoded, bytes))

	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(t, digest, Marlin_Artifact_Test_Digest)
}

@(test)
marlin_artifact_decode_is_source_independent_test :: proc(t: ^testing.T) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	result, emit_error := marlin_emit(motion, profile)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	bytes, encode_error := marlin_artifact_encode(
		Marlin_Artifact_Test_Motion_Hash,
		motion,
		profile,
		result,
	)
	testing.expect_value(t, encode_error, Marlin_Artifact_Error.None)
	marlin_result_destroy(&result)
	features.motion_plan_result_destroy(&motion)

	artifact, decode_error := marlin_artifact_decode(bytes)
	defer {
		marlin_artifact_destroy(&artifact)
		delete(bytes)
	}
	testing.expect_value(t, decode_error, Marlin_Artifact_Error.None)
	testing.expect(t, len(artifact.result.bytes) > 0)
	testing.expect(t, len(artifact.result.commands) > 0)
}

@(test)
marlin_artifact_rejects_header_length_and_limit_corruption_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	bytes, encode_error := marlin_artifact_encode(
		Marlin_Artifact_Test_Motion_Hash,
		motion,
		profile,
		result,
	)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Marlin_Artifact_Error.None)

	_, truncated_error := marlin_artifact_decode(bytes[:len(bytes)-1])
	testing.expect_value(
		t,
		truncated_error,
		Marlin_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = corrupt[0] ~ 1
	_, magic_error := marlin_artifact_decode(corrupt)
	testing.expect_value(t, magic_error, Marlin_Artifact_Error.Malformed)
	copy(corrupt, bytes)
	marlin_artifact_put_u32(corrupt, 8, 2)
	_, version_error := marlin_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Marlin_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[24] = 1
	_, reserved_error := marlin_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Marlin_Artifact_Error.Malformed,
	)

	limits := DEFAULT_MARLIN_ARTIFACT_LIMITS
	limits.max_commands = u64(len(result.commands)-1)
	_, command_limit_error := marlin_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		command_limit_error,
		Marlin_Artifact_Error.Limit,
	)
	_, overflow_ok := marlin_artifact_byte_count(max(u64), 0)
	testing.expect(t, !overflow_ok)
}

@(test)
marlin_artifact_rejects_record_and_hash_corruption_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	bytes, encode_error := marlin_artifact_encode(
		Marlin_Artifact_Test_Motion_Hash,
		motion,
		profile,
		result,
	)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Marlin_Artifact_Error.None)
	corrupt := make([]u8, len(bytes), context.temp_allocator)

	copy(corrupt, bytes)
	command_offset := int(MARLIN_ARTIFACT_HEADER_SIZE)
	corrupt[command_offset+13] = 1
	_, reserved_error := marlin_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Marlin_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[32] = corrupt[32] ~ 1
	_, dependency_error := marlin_artifact_decode(corrupt)
	testing.expect_value(
		t,
		dependency_error,
		Marlin_Artifact_Error.Hash_Mismatch,
	)
	copy(corrupt, bytes)
	gcode_offset := int(MARLIN_ARTIFACT_HEADER_SIZE)+
		len(result.commands)*int(MARLIN_ARTIFACT_COMMAND_SIZE)
	corrupt[gcode_offset+2] = corrupt[gcode_offset+2] ~ 1
	_, content_error := marlin_artifact_decode(corrupt)
	testing.expect_value(
		t,
		content_error,
		Marlin_Artifact_Error.Hash_Mismatch,
	)
	copy(corrupt, bytes)
	corrupt[len(corrupt)-1] = 'X'
	_, record_error := marlin_artifact_decode(corrupt)
	testing.expect_value(
		t,
		record_error,
		Marlin_Artifact_Error.Invalid_Record,
	)
}

Marlin_Artifact_Test_Motion_Hash :: contracts.Content_Hash{
	0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
	0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
	0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
	0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
}

Marlin_Artifact_Test_Digest :: [sha2.DIGEST_SIZE_256]u8{
	0x7f, 0x68, 0x78, 0x51, 0xba, 0x67, 0x4c, 0x1c,
	0x89, 0x87, 0xa2, 0xd9, 0xeb, 0x85, 0x26, 0xe0,
	0x22, 0x24, 0x3b, 0xe7, 0xad, 0x64, 0x85, 0x9a,
	0x0d, 0xb7, 0x51, 0x70, 0x1e, 0x40, 0x68, 0x80,
}
