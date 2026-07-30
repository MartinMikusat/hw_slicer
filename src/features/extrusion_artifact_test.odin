package features

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"
import profiles "../profiles"

@(test)
extrusion_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	plan := extrusion_test_plan(t, 400)
	defer unified_path_plan_result_destroy(&plan)
	process := extrusion_test_process(10)
	material := profiles.Material_Profile{filament_diameter = 1_750}
	heights := []contracts.Micrometres{200}
	result, result_error := extrusion_calculate(
		plan,
		heights,
		material,
		process,
	)
	defer extrusion_result_destroy(&result)
	testing.expect_value(t, result_error, Extrusion_Error.None)
	bytes, encode_error := extrusion_artifact_encode(
		Extrusion_Artifact_Test_Path_Hash,
		Extrusion_Artifact_Test_Schedule_Hash,
		Extrusion_Artifact_Test_Material_Hash,
		Extrusion_Artifact_Test_Process_Hash,
		plan,
		heights,
		material,
		process,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Extrusion_Artifact_Error.None,
	)
	artifact, decode_error := extrusion_artifact_decode(bytes)
	defer extrusion_artifact_destroy(&artifact)
	testing.expect_value(
		t,
		decode_error,
		Extrusion_Artifact_Error.None,
	)
	testing.expect_value(t, len(bytes), 784)
	testing.expect_value(t, len(artifact.result.layers), 1)
	testing.expect_value(t, len(artifact.result.moves), 2)
	testing.expect_value(
		t,
		artifact.dependencies.path_plan_hash,
		Extrusion_Artifact_Test_Path_Hash,
	)
	testing.expect_value(
		t,
		artifact.dependencies.layer_schedule_hash,
		Extrusion_Artifact_Test_Schedule_Hash,
	)
	testing.expect_value(
		t,
		artifact.dependencies.material_hash,
		Extrusion_Artifact_Test_Material_Hash,
	)
	testing.expect_value(
		t,
		artifact.dependencies.process_hash,
		Extrusion_Artifact_Test_Process_Hash,
	)
	for move, move_index in artifact.result.moves {
		testing.expect_value(t, move, result.moves[move_index])
	}
	reencoded, reencode_error := extrusion_artifact_encode(
		Extrusion_Artifact_Test_Path_Hash,
		Extrusion_Artifact_Test_Schedule_Hash,
		Extrusion_Artifact_Test_Material_Hash,
		Extrusion_Artifact_Test_Process_Hash,
		plan,
		heights,
		material,
		process,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Extrusion_Artifact_Error.None,
	)
	testing.expect(t, extrusion_artifact_test_bytes_equal(reencoded, bytes))
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(t, digest, Extrusion_Artifact_Test_Digest)
}

@(test)
extrusion_artifact_decode_is_source_independent_test :: proc(
	t: ^testing.T,
) {
	plan := extrusion_test_plan(t, 400)
	process := extrusion_test_process(10)
	material := profiles.Material_Profile{filament_diameter = 1_750}
	heights := []contracts.Micrometres{200}
	result, result_error := extrusion_calculate(
		plan,
		heights,
		material,
		process,
	)
	testing.expect_value(t, result_error, Extrusion_Error.None)
	bytes, encode_error := extrusion_artifact_encode(
		Extrusion_Artifact_Test_Path_Hash,
		Extrusion_Artifact_Test_Schedule_Hash,
		Extrusion_Artifact_Test_Material_Hash,
		Extrusion_Artifact_Test_Process_Hash,
		plan,
		heights,
		material,
		process,
		result,
	)
	testing.expect_value(
		t,
		encode_error,
		Extrusion_Artifact_Error.None,
	)
	extrusion_result_destroy(&result)
	unified_path_plan_result_destroy(&plan)
	artifact, decode_error := extrusion_artifact_decode(bytes)
	defer {
		extrusion_artifact_destroy(&artifact)
		delete(bytes)
	}
	testing.expect_value(
		t,
		decode_error,
		Extrusion_Artifact_Error.None,
	)
	testing.expect_value(t, len(artifact.result.layers), 1)
	testing.expect_value(t, len(artifact.result.moves), 2)
}

@(test)
extrusion_artifact_rejects_framing_limits_and_corruption_test :: proc(
	t: ^testing.T,
) {
	plan := extrusion_test_plan(t, 400)
	defer unified_path_plan_result_destroy(&plan)
	process := extrusion_test_process(10)
	material := profiles.Material_Profile{filament_diameter = 1_750}
	heights := []contracts.Micrometres{200}
	result, result_error := extrusion_calculate(
		plan,
		heights,
		material,
		process,
	)
	defer extrusion_result_destroy(&result)
	testing.expect_value(t, result_error, Extrusion_Error.None)
	bytes, encode_error := extrusion_artifact_encode(
		Extrusion_Artifact_Test_Path_Hash,
		Extrusion_Artifact_Test_Schedule_Hash,
		Extrusion_Artifact_Test_Material_Hash,
		Extrusion_Artifact_Test_Process_Hash,
		plan,
		heights,
		material,
		process,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Extrusion_Artifact_Error.None,
	)
	_, truncated_error := extrusion_artifact_decode(
		bytes[:len(bytes)-1],
	)
	testing.expect_value(
		t,
		truncated_error,
		Extrusion_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	extrusion_artifact_put_u32(corrupt, 8, 2)
	_, version_error := extrusion_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Extrusion_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[368] = 1
	_, reserved_error := extrusion_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Extrusion_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[32] = corrupt[32] ~ 1
	_, hash_error := extrusion_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Extrusion_Artifact_Error.Hash_Mismatch,
	)
	move_offset :=
		int(EXTRUSION_ARTIFACT_HEADER_SIZE)+
		int(EXTRUSION_ARTIFACT_LAYER_SIZE)
	copy(corrupt, bytes)
	corrupt[move_offset+32] = u8(profiles.Printable_Role.Invalid)
	_, record_error := extrusion_artifact_decode(corrupt)
	testing.expect_value(
		t,
		record_error,
		Extrusion_Artifact_Error.Invalid_Record,
	)
	limits := DEFAULT_EXTRUSION_ARTIFACT_LIMITS
	limits.max_moves = 1
	_, limit_error := extrusion_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limit_error,
		Extrusion_Artifact_Error.Limit,
	)
	_, overflow_ok := extrusion_artifact_byte_count(0, max(u64))
	testing.expect(t, !overflow_ok)
	result.moves[0].incremental_filament_nm += 1
	_, invalid_encode_error := extrusion_artifact_encode(
		Extrusion_Artifact_Test_Path_Hash,
		Extrusion_Artifact_Test_Schedule_Hash,
		Extrusion_Artifact_Test_Material_Hash,
		Extrusion_Artifact_Test_Process_Hash,
		plan,
		heights,
		material,
		process,
		result,
	)
	testing.expect_value(
		t,
		invalid_encode_error,
		Extrusion_Artifact_Error.Invalid_Record,
	)
}

extrusion_artifact_test_bytes_equal :: proc(left, right: []u8) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

Extrusion_Artifact_Test_Path_Hash :: contracts.Content_Hash{
	0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
	0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
	0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
	0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
}

Extrusion_Artifact_Test_Schedule_Hash :: contracts.Content_Hash{
	0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
	0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
	0x00, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99,
	0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
}

Extrusion_Artifact_Test_Material_Hash :: contracts.Content_Hash{
	0x21, 0x43, 0x65, 0x87, 0xa9, 0xcb, 0xed, 0x0f,
	0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
	0xf0, 0xde, 0xbc, 0x9a, 0x78, 0x56, 0x34, 0x12,
	0x0f, 0xed, 0xcb, 0xa9, 0x87, 0x65, 0x43, 0x21,
}

Extrusion_Artifact_Test_Process_Hash :: contracts.Content_Hash{
	0x31, 0x42, 0x53, 0x64, 0x75, 0x86, 0x97, 0xa8,
	0xb9, 0xca, 0xdb, 0xec, 0xfd, 0x0e, 0x1f, 0x20,
	0x20, 0x1f, 0x0e, 0xfd, 0xec, 0xdb, 0xca, 0xb9,
	0xa8, 0x97, 0x86, 0x75, 0x64, 0x53, 0x42, 0x31,
}

Extrusion_Artifact_Test_Digest :: [sha2.DIGEST_SIZE_256]u8{
	0x55, 0xad, 0x53, 0x4d, 0x21, 0x55, 0x36, 0x1d,
	0xfb, 0x11, 0xe7, 0xfd, 0xbc, 0x97, 0x55, 0x30,
	0x2c, 0x28, 0xaa, 0xe5, 0x54, 0x80, 0xdb, 0xd3,
	0xd0, 0x2d, 0x3f, 0x16, 0xa2, 0x5a, 0x7e, 0x02,
}
