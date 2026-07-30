package evidence

import "core:testing"

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

@(test)
motion_plan_capture_preflights_validates_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	bytes := motion_plan_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	capture, capture_error := motion_plan_capture_describe(
		"stages/10-plan-paths/primitives/motion.bin",
		request,
		{},
		bytes,
	)
	defer motion_plan_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Motion_Plan_Capture_Error.None,
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
		features.MOTION_PLAN_ARTIFACT_FORMAT,
	)
	decoded, decode_error :=
		features.motion_plan_artifact_decode(capture.bytes)
	defer features.motion_plan_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Motion_Plan_Artifact_Error.None,
	)
	testing.expect_value(t, len(decoded.result.layers), 1)
	testing.expect_value(t, len(decoded.result.operations), 0)
}

@(test)
motion_plan_capture_rejects_budget_path_and_content_failures_test :: proc(
	t: ^testing.T,
) {
	bytes := motion_plan_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := motion_plan_capture_describe(
		"motion.bin",
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
		Motion_Plan_Capture_Error.Item_Limit,
	)
	_, path_error := motion_plan_capture_describe(
		"../motion.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		Motion_Plan_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	layer_offset :=
		int(features.MOTION_PLAN_ARTIFACT_HEADER_SIZE)+
		int(features.MOTION_PLAN_ARTIFACT_DEPENDENCY_SIZE)
	corrupt[layer_offset+8] = 1
	_, content_error := motion_plan_capture_describe(
		"motion.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		Motion_Plan_Capture_Error.Invalid_Record,
	)
}

motion_plan_capture_test_artifact :: proc(t: ^testing.T) -> []u8 {
	dependency_layer := features.Motion_Plan_Layer_Dependency{
		stable_id = 10,
		z = 200,
		model_hash = MOTION_CAPTURE_TEST_HASH,
	}
	dependencies := features.Motion_Plan_Hash_Dependencies{
		path_plan_hash = MOTION_CAPTURE_TEST_HASH,
		extrusion_hash = MOTION_CAPTURE_TEST_HASH,
		printer_hash = MOTION_CAPTURE_TEST_HASH,
		process_hash = MOTION_CAPTURE_TEST_HASH,
		layers = []features.Motion_Plan_Layer_Dependency{dependency_layer},
	}
	result := features.Motion_Plan_Result{
		layers = []features.Motion_Layer{
			{
				stable_id = 10,
				z = 200,
				speed_scale_ppm = profiles.RATIO_SCALE,
			},
		},
	}
	result_hash, result_ok :=
		features.motion_plan_result_content_hash(dependencies, result)
	testing.expect(t, result_ok)
	byte_count, size_ok := features.motion_plan_artifact_byte_count(1, 0)
	testing.expect(t, size_ok)
	bytes := make([]u8, int(byte_count))
	testing.expect(t, bytes != nil)
	for byte, byte_index in features.MOTION_PLAN_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	features.motion_plan_artifact_put_u32(
		bytes,
		8,
		features.MOTION_PLAN_ARTIFACT_SCHEMA_VERSION,
	)
	features.motion_plan_artifact_put_u32(
		bytes,
		12,
		features.MOTION_PLAN_ARTIFACT_HEADER_SIZE,
	)
	features.motion_plan_artifact_put_u32(
		bytes,
		16,
		features.MOTION_PLAN_ARTIFACT_DEPENDENCY_SIZE,
	)
	features.motion_plan_artifact_put_u32(
		bytes,
		20,
		features.MOTION_PLAN_ARTIFACT_LAYER_SIZE,
	)
	features.motion_plan_artifact_put_u32(
		bytes,
		24,
		features.MOTION_PLAN_ARTIFACT_OPERATION_SIZE,
	)
	features.motion_plan_artifact_put_u32(
		bytes,
		28,
		features.SCHEMA_VERSION_MOTION_PLAN_HASH,
	)
	features.motion_plan_artifact_put_hash(
		bytes,
		32,
		dependencies.path_plan_hash,
	)
	features.motion_plan_artifact_put_hash(
		bytes,
		64,
		dependencies.extrusion_hash,
	)
	features.motion_plan_artifact_put_hash(
		bytes,
		96,
		dependencies.printer_hash,
	)
	features.motion_plan_artifact_put_hash(
		bytes,
		128,
		dependencies.process_hash,
	)
	features.motion_plan_artifact_put_hash(bytes, 160, result_hash)
	features.motion_plan_artifact_put_u64(bytes, 192, 1)
	features.motion_plan_artifact_put_u64(bytes, 200, 1)
	offset := int(features.MOTION_PLAN_ARTIFACT_HEADER_SIZE)
	features.motion_plan_artifact_put_u64(
		bytes,
		offset,
		u64(dependency_layer.stable_id),
	)
	features.motion_plan_artifact_put_i64(
		bytes,
		offset+8,
		i64(dependency_layer.z),
	)
	features.motion_plan_artifact_put_hash(
		bytes,
		offset+16,
		dependency_layer.model_hash,
	)
	offset += int(features.MOTION_PLAN_ARTIFACT_DEPENDENCY_SIZE)
	layer := result.layers[0]
	features.motion_plan_artifact_put_u64(
		bytes,
		offset,
		u64(layer.stable_id),
	)
	features.motion_plan_artifact_put_u32(
		bytes,
		offset+8,
		layer.layer_index,
	)
	features.motion_plan_artifact_put_u32(
		bytes,
		offset+12,
		layer.operation_count,
	)
	features.motion_plan_artifact_put_i64(
		bytes,
		offset+16,
		i64(layer.z),
	)
	features.motion_plan_artifact_put_u64(
		bytes,
		offset+24,
		layer.operation_offset,
	)
	features.motion_plan_artifact_put_u32(
		bytes,
		offset+32,
		layer.speed_scale_ppm,
	)
	return bytes
}

MOTION_CAPTURE_TEST_HASH :: contracts.Content_Hash{
	0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
	0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
	0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
	0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
}
