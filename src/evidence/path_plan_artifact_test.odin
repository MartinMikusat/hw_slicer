package evidence

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"
import features "../features"

@(test)
path_plan_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	perimeter_hash, infill_hash, result := path_plan_artifact_test_fixture()
	defer features.path_plan_result_destroy(&result)
	bytes, encode_error := path_plan_artifact_encode(
		perimeter_hash,
		infill_hash,
		result,
	)
	defer delete(bytes)
	artifact, decode_error := path_plan_artifact_decode(bytes)
	defer path_plan_artifact_destroy(&artifact)
	testing.expect_value(t, encode_error, Path_Plan_Artifact_Error.None)
	testing.expect_value(t, decode_error, Path_Plan_Artifact_Error.None)
	testing.expect_value(t, len(bytes), 336)
	testing.expect_value(t, artifact.perimeter_hash, perimeter_hash)
	testing.expect_value(t, artifact.infill_hash, infill_hash)
	testing.expect_value(t, len(artifact.result.layers), 1)
	testing.expect_value(t, len(artifact.result.paths), 1)
	testing.expect_value(t, len(artifact.result.moves), 1)
	testing.expect_value(
		t,
		artifact.result.moves[0].point_b,
		result.moves[0].point_b,
	)

	reencoded, reencode_error := path_plan_artifact_encode(
		artifact.perimeter_hash,
		artifact.infill_hash,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Path_Plan_Artifact_Error.None,
	)
	testing.expect_value(t, string(reencoded), string(bytes))

	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	expected_digest := [sha2.DIGEST_SIZE_256]u8{
		0x4f, 0x86, 0x19, 0x13, 0x9f, 0x3e, 0xa9, 0xa6,
		0xb3, 0x82, 0x17, 0xaa, 0x3b, 0x86, 0xe4, 0xfb,
		0xb0, 0xd6, 0x50, 0x2d, 0x8d, 0xd3, 0x3f, 0x8f,
		0xb8, 0xba, 0x43, 0x2f, 0xbc, 0x03, 0x6d, 0x92,
	}
	testing.expect_value(t, digest, expected_digest)
}

@(test)
path_plan_artifact_rejects_header_and_length_corruption_test :: proc(
	t: ^testing.T,
) {
	perimeter_hash, infill_hash, result := path_plan_artifact_test_fixture()
	defer features.path_plan_result_destroy(&result)
	bytes, encode_error := path_plan_artifact_encode(
		perimeter_hash,
		infill_hash,
		result,
	)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Path_Plan_Artifact_Error.None)

	_, truncated_error := path_plan_artifact_decode(bytes[:len(bytes)-1])
	testing.expect_value(
		t,
		truncated_error,
		Path_Plan_Artifact_Error.Malformed,
	)

	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = corrupt[0] ~ 1
	_, magic_error := path_plan_artifact_decode(corrupt)
	testing.expect_value(t, magic_error, Path_Plan_Artifact_Error.Malformed)

	copy(corrupt, bytes)
	path_plan_artifact_put_u32(corrupt, 8, 2)
	_, version_error := path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		version_error,
		Path_Plan_Artifact_Error.Unsupported_Version,
	)

	copy(corrupt, bytes)
	corrupt[28] = 1
	_, reserved_error := path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Path_Plan_Artifact_Error.Malformed,
	)

	copy(corrupt, bytes)
	path_plan_artifact_put_u32(corrupt, 148, 2)
	_, flags_error := path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		flags_error,
		Path_Plan_Artifact_Error.Invalid_Record,
	)
}

@(test)
path_plan_artifact_rejects_record_and_hash_corruption_test :: proc(
	t: ^testing.T,
) {
	perimeter_hash, infill_hash, result := path_plan_artifact_test_fixture()
	defer features.path_plan_result_destroy(&result)
	bytes, encode_error := path_plan_artifact_encode(
		perimeter_hash,
		infill_hash,
		result,
	)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Path_Plan_Artifact_Error.None)

	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	path_record_offset := int(PATH_PLAN_ARTIFACT_HEADER_SIZE)+
		int(PATH_PLAN_ARTIFACT_LAYER_SIZE)
	corrupt[path_record_offset+55] = 1
	_, reserved_error := path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		reserved_error,
		Path_Plan_Artifact_Error.Malformed,
	)

	copy(corrupt, bytes)
	move_record_offset := path_record_offset+
		int(PATH_PLAN_ARTIFACT_PATH_SIZE)
	corrupt[move_record_offset+32] =
		corrupt[move_record_offset+32] ~ 1
	_, hash_error := path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		hash_error,
		Path_Plan_Artifact_Error.Hash_Mismatch,
	)

	copy(corrupt, bytes)
	corrupt[path_record_offset] =
		corrupt[path_record_offset] ~ 1
	_, record_error := path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		record_error,
		Path_Plan_Artifact_Error.Invalid_Record,
	)
}

@(test)
path_plan_artifact_enforces_encode_and_decode_limits_test :: proc(
	t: ^testing.T,
) {
	perimeter_hash, infill_hash, result := path_plan_artifact_test_fixture()
	defer features.path_plan_result_destroy(&result)
	bytes, encode_error := path_plan_artifact_encode(
		perimeter_hash,
		infill_hash,
		result,
	)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Path_Plan_Artifact_Error.None)

	limits := DEFAULT_PATH_PLAN_ARTIFACT_LIMITS
	limits.max_moves = 0
	_, limited_encode_error := path_plan_artifact_encode(
		perimeter_hash,
		infill_hash,
		result,
		limits,
	)
	testing.expect_value(
		t,
		limited_encode_error,
		Path_Plan_Artifact_Error.Limit,
	)
	_, limited_decode_error := path_plan_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limited_decode_error,
		Path_Plan_Artifact_Error.Limit,
	)

	limits = DEFAULT_PATH_PLAN_ARTIFACT_LIMITS
	limits.max_bytes = u64(len(bytes)-1)
	_, byte_limit_error := path_plan_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		byte_limit_error,
		Path_Plan_Artifact_Error.Limit,
	)

	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	path_plan_artifact_put_u64(corrupt, 168, 20_000_000)
	_, default_byte_limit_error := path_plan_artifact_decode(corrupt)
	testing.expect_value(
		t,
		default_byte_limit_error,
		Path_Plan_Artifact_Error.Limit,
	)
	_, overflow_ok := path_plan_artifact_byte_count(max(u64), 0, 0)
	testing.expect(t, !overflow_ok)

	result.moves[0].point_a.x += 1
	_, invalid_error := path_plan_artifact_encode(
		perimeter_hash,
		infill_hash,
		result,
	)
	testing.expect_value(
		t,
		invalid_error,
		Path_Plan_Artifact_Error.Invalid_Record,
	)
}

@(test)
path_plan_artifact_preserves_a_valid_empty_result_test :: proc(
	t: ^testing.T,
) {
	result := features.Path_Plan_Result{
		topology_policy = .Strict_Printable,
	}
	bytes, encode_error := path_plan_artifact_encode({}, {}, result)
	defer delete(bytes)
	artifact, decode_error := path_plan_artifact_decode(bytes)
	defer path_plan_artifact_destroy(&artifact)
	testing.expect_value(t, encode_error, Path_Plan_Artifact_Error.None)
	testing.expect_value(t, decode_error, Path_Plan_Artifact_Error.None)
	testing.expect_value(
		t,
		len(bytes),
		int(PATH_PLAN_ARTIFACT_HEADER_SIZE),
	)
	testing.expect_value(t, len(artifact.result.layers), 0)
	testing.expect_value(t, len(artifact.result.paths), 0)
	testing.expect_value(t, len(artifact.result.moves), 0)
}

@(test)
path_plan_capture_preflights_then_describes_the_artifact_test :: proc(
	t: ^testing.T,
) {
	perimeter_hash, infill_hash, result := path_plan_artifact_test_fixture()
	defer features.path_plan_result_destroy(&result)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 3,
		byte_limit = 336,
	}
	capture, capture_error := path_plan_capture_encode(
		"stages/plan-paths/path-plan.bin",
		request,
		{},
		perimeter_hash,
		infill_hash,
		result,
	)
	defer path_plan_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Path_Plan_Capture_Error.None)
	testing.expect_value(t, capture.additional.item_count, u64(3))
	testing.expect_value(t, capture.additional.byte_count, u64(336))
	testing.expect_value(
		t,
		capture.artifact.path,
		"stages/plan-paths/path-plan.bin",
	)
	testing.expect_value(
		t,
		capture.artifact.format,
		PATH_PLAN_ARTIFACT_FORMAT,
	)
	testing.expect_value(
		t,
		capture.artifact.sha256,
		"4f8619139f3ea9a6b38217aa3b86e4fbb0d6502d8dd33f8fb8ba432fbc036d92",
	)
	replayed, replay_error := path_plan_artifact_decode(capture.bytes)
	defer path_plan_artifact_destroy(&replayed)
	testing.expect_value(t, replay_error, Path_Plan_Artifact_Error.None)
}

@(test)
path_plan_capture_enforces_level_and_accumulated_budgets_test :: proc(
	t: ^testing.T,
) {
	perimeter_hash, infill_hash, result := path_plan_artifact_test_fixture()
	defer features.path_plan_result_destroy(&result)
	request := contracts.Evidence_Request{
		level = .Summary,
		item_limit = 5,
		byte_limit = 436,
	}
	_, level_error := path_plan_capture_encode(
		"stages/plan-paths/path-plan.bin",
		request,
		{2, 100},
		perimeter_hash,
		infill_hash,
		result,
	)
	testing.expect_value(
		t,
		level_error,
		Path_Plan_Capture_Error.Level_Insufficient,
	)

	request.level = .Disabled
	_, disabled_error := path_plan_capture_encode(
		"stages/plan-paths/path-plan.bin",
		request,
		{},
		perimeter_hash,
		infill_hash,
		result,
	)
	testing.expect_value(
		t,
		disabled_error,
		Path_Plan_Capture_Error.Capture_Disabled,
	)

	request.level = .Primitives
	capture, exact_error := path_plan_capture_encode(
		"stages/plan-paths/path-plan.bin",
		request,
		{2, 100},
		perimeter_hash,
		infill_hash,
		result,
	)
	path_plan_capture_destroy(&capture)
	testing.expect_value(t, exact_error, Path_Plan_Capture_Error.None)

	request.item_limit = 4
	_, item_error := path_plan_capture_encode(
		"stages/plan-paths/path-plan.bin",
		request,
		{2, 100},
		perimeter_hash,
		infill_hash,
		result,
	)
	testing.expect_value(
		t,
		item_error,
		Path_Plan_Capture_Error.Item_Limit,
	)

	request.item_limit = 5
	request.byte_limit = 435
	_, byte_error := path_plan_capture_encode(
		"stages/plan-paths/path-plan.bin",
		request,
		{2, 100},
		perimeter_hash,
		infill_hash,
		result,
	)
	testing.expect_value(
		t,
		byte_error,
		Path_Plan_Capture_Error.Byte_Limit,
	)
}

@(test)
path_plan_capture_rejects_invalid_paths_records_and_artifact_limits_test :: proc(
	t: ^testing.T,
) {
	perimeter_hash, infill_hash, result := path_plan_artifact_test_fixture()
	defer features.path_plan_result_destroy(&result)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 3,
		byte_limit = 336,
	}
	_, path_error := path_plan_capture_encode(
		"../path-plan.bin",
		request,
		{},
		perimeter_hash,
		infill_hash,
		result,
	)
	testing.expect_value(
		t,
		path_error,
		Path_Plan_Capture_Error.Invalid_Path,
	)

	limits := DEFAULT_PATH_PLAN_ARTIFACT_LIMITS
	limits.max_moves = 0
	_, limit_error := path_plan_capture_encode(
		"stages/plan-paths/path-plan.bin",
		request,
		{},
		perimeter_hash,
		infill_hash,
		result,
		limits,
	)
	testing.expect_value(
		t,
		limit_error,
		Path_Plan_Capture_Error.Artifact_Limit,
	)

	result.moves[0].point_a.x += 1
	_, record_error := path_plan_capture_encode(
		"stages/plan-paths/path-plan.bin",
		request,
		{},
		perimeter_hash,
		infill_hash,
		result,
	)
	testing.expect_value(
		t,
		record_error,
		Path_Plan_Capture_Error.Invalid_Record,
	)
}

path_plan_artifact_test_fixture :: proc() -> (
	perimeter_hash, infill_hash: contracts.Content_Hash,
	result: features.Path_Plan_Result,
) {
	for &byte, byte_index in perimeter_hash {
		byte = u8(byte_index)
	}
	for &byte, byte_index in infill_hash {
		byte = u8(0x80+byte_index)
	}
	source_id := contracts.Stable_ID(0x1122334455667788)
	region_id := contracts.Stable_ID(0x8877665544332211)
	path_id := contracts.stable_id_child(source_id, .Path, 0)
	layers := make([]features.Planned_Layer, 1)
	paths := make([]features.Planned_Path, 1)
	moves := make([]features.Planned_Move, 1)
	layers[0] = {
		path_offset = 0,
		path_count = 1,
		move_offset = 0,
		move_count = 1,
	}
	paths[0] = {
		stable_id = path_id,
		source_id = source_id,
		source_kind = .Infill,
		source_index = 0,
		region_id = region_id,
		region_index = 0,
		layer_index = 0,
		start_index = 0,
		reversed = false,
		closed = false,
		move_offset = 0,
		move_count = 1,
	}
	moves[0] = {
		stable_id = contracts.stable_id_child(path_id, .Path, 0),
		path_id = path_id,
		kind = .Extrude,
		source_edge_index = 0,
		point_a = {0, 0},
		point_b = {100, -25},
	}
	result = {
		config = {
			start = {0, 0},
			inner_perimeters_first = true,
		},
		topology_policy = .Strict_Printable,
		layers = layers,
		paths = paths,
		moves = moves,
		travel_move_count = 0,
		extrude_move_count = 1,
	}
	return
}
