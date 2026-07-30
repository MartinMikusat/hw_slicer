package evidence

import "core:testing"

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

@(test)
unified_plan_capture_preflights_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	bytes := unified_path_plan_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := unified_path_plan_capture_describe(
		"stages/10-plan-paths/primitives/unified-path-plan.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer unified_path_plan_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Unified_Path_Plan_Capture_Error.None,
	)
	testing.expect_value(t, capture.additional.item_count, u64(1))
	testing.expect_value(
		t,
		capture.additional.byte_count,
		u64(len(bytes)),
	)
	testing.expect_value(
		t,
		capture.artifact.format,
		features.UNIFIED_PATH_PLAN_ARTIFACT_FORMAT,
	)
	decoded, decode_error :=
		features.unified_path_plan_artifact_decode(capture.bytes)
	defer features.unified_path_plan_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Unified_Path_Plan_Artifact_Error.None,
	)
	testing.expect_value(t, len(decoded.result.layers), 1)
	testing.expect_value(t, len(decoded.result.paths), 0)
	testing.expect_value(t, len(decoded.result.moves), 0)
}

@(test)
unified_plan_capture_rejects_budget_path_and_content_test :: proc(
	t: ^testing.T,
) {
	bytes := unified_path_plan_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := unified_path_plan_capture_describe(
		"unified-path-plan.bin",
		{
			level = .Primitives,
			item_limit = 0,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	testing.expect_value(
		t,
		item_error,
		Unified_Path_Plan_Capture_Error.Item_Limit,
	)
	_, path_error := unified_path_plan_capture_describe(
		"../unified-path-plan.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		Unified_Path_Plan_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, content_error := unified_path_plan_capture_describe(
		"unified-path-plan.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		Unified_Path_Plan_Capture_Error.Invalid_Record,
	)
}

unified_path_plan_capture_test_artifact :: proc(
	t: ^testing.T,
) -> []u8 {
	result := features.Unified_Path_Plan_Result{
		config = {
			seam = profiles.Seam_Policy.Deterministic_Cost,
			seam_visibility =
				profiles.Seam_Visibility_Policy.Rear_Maximum_Y,
		},
		layers = []features.Unified_Planned_Layer{{}},
	}
	result_hash, result_ok :=
		features.unified_path_plan_result_content_hash(
			UNIFIED_PLAN_CAPTURE_TEST_SOURCE_HASH,
			result,
		)
	testing.expect(t, result_ok)
	byte_count, byte_count_ok :=
		features.unified_path_plan_artifact_byte_count(1, 0, 0)
	testing.expect(t, byte_count_ok)
	bytes := make([]u8, int(byte_count))
	testing.expect(t, bytes != nil)
	for byte, byte_index in features.UNIFIED_PATH_PLAN_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	features.unified_path_plan_artifact_put_u32(
		bytes,
		8,
		features.UNIFIED_PATH_PLAN_ARTIFACT_SCHEMA_VERSION,
	)
	features.unified_path_plan_artifact_put_u32(
		bytes,
		12,
		features.UNIFIED_PATH_PLAN_ARTIFACT_HEADER_SIZE,
	)
	features.unified_path_plan_artifact_put_u32(
		bytes,
		16,
		features.UNIFIED_PATH_PLAN_ARTIFACT_LAYER_SIZE,
	)
	features.unified_path_plan_artifact_put_u32(
		bytes,
		20,
		features.UNIFIED_PATH_PLAN_ARTIFACT_PATH_SIZE,
	)
	features.unified_path_plan_artifact_put_u32(
		bytes,
		24,
		features.UNIFIED_PATH_PLAN_ARTIFACT_MOVE_SIZE,
	)
	features.unified_path_plan_artifact_put_u32(
		bytes,
		28,
		features.SCHEMA_VERSION_UNIFIED_PATH_PLAN_HASH,
	)
	features.unified_path_plan_artifact_put_hash(
		bytes,
		32,
		UNIFIED_PLAN_CAPTURE_TEST_SOURCE_HASH,
	)
	features.unified_path_plan_artifact_put_hash(
		bytes,
		64,
		result_hash,
	)
	bytes[112] = u8(result.config.seam)
	bytes[113] = u8(result.config.seam_visibility)
	features.unified_path_plan_artifact_put_u64(bytes, 120, 1)
	return bytes
}

UNIFIED_PLAN_CAPTURE_TEST_SOURCE_HASH :: contracts.Content_Hash{
	0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
	0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
	0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
	0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
}
