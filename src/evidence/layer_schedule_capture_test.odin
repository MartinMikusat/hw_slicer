package evidence

import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
layer_schedule_capture_preflights_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	bytes := layer_schedule_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := layer_schedule_capture_describe(
		"stages/04-schedule-layers/primitives/layer-schedule.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer layer_schedule_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Layer_Schedule_Capture_Error.None,
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
		LAYER_SCHEDULE_ARTIFACT_FORMAT,
	)
	decoded, decode_error := layer_schedule_artifact_decode(capture.bytes)
	defer layer_schedule_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		Layer_Schedule_Artifact_Error.None,
	)
	testing.expect_value(t, len(decoded.result.layer_z), 1)
}

@(test)
layer_schedule_capture_rejects_budget_path_and_content_test :: proc(
	t: ^testing.T,
) {
	bytes := layer_schedule_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := layer_schedule_capture_describe(
		"layer-schedule.bin",
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
		Layer_Schedule_Capture_Error.Item_Limit,
	)
	_, path_error := layer_schedule_capture_describe(
		"../layer-schedule.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		Layer_Schedule_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[56] = corrupt[56] ~ 1
	_, content_error := layer_schedule_capture_describe(
		"layer-schedule.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		Layer_Schedule_Capture_Error.Invalid_Record,
	)
}

layer_schedule_capture_test_artifact :: proc(t: ^testing.T) -> []u8 {
	root_id := contracts.stable_id_root(
		LAYER_SCHEDULE_CAPTURE_TEST_REQUEST_HASH,
		.Layer,
	)
	result := slicing.Fixed_Layer_Schedule{
		request_hash = LAYER_SCHEDULE_CAPTURE_TEST_REQUEST_HASH,
		minimum_z = 0,
		maximum_z = 400,
		first_plane_z = 200,
		layer_step = 200,
		layer_z = []contracts.Micrometres{200},
		layer_ids = []contracts.Stable_ID{
			contracts.stable_id_child(root_id, .Layer, 0),
		},
	}
	result_hash, result_ok := slicing.fixed_layer_schedule_hash(result)
	testing.expect(t, result_ok)
	byte_count, byte_count_ok := layer_schedule_artifact_byte_count(1)
	testing.expect(t, byte_count_ok)
	bytes := make([]u8, int(byte_count))
	testing.expect(t, bytes != nil)
	for byte, byte_index in LAYER_SCHEDULE_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	layer_schedule_artifact_put_u32(
		bytes,
		8,
		LAYER_SCHEDULE_ARTIFACT_SCHEMA_VERSION,
	)
	layer_schedule_artifact_put_u32(
		bytes,
		12,
		LAYER_SCHEDULE_ARTIFACT_HEADER_SIZE,
	)
	layer_schedule_artifact_put_u32(
		bytes,
		16,
		LAYER_SCHEDULE_ARTIFACT_LAYER_SIZE,
	)
	layer_schedule_artifact_put_u32(
		bytes,
		20,
		slicing.SCHEMA_VERSION_FIXED_LAYER_SCHEDULE_HASH,
	)
	layer_schedule_artifact_put_hash(
		bytes,
		24,
		result.request_hash,
	)
	layer_schedule_artifact_put_hash(bytes, 56, result_hash)
	layer_schedule_artifact_put_i64(bytes, 96, 400)
	layer_schedule_artifact_put_i64(bytes, 104, 200)
	layer_schedule_artifact_put_i64(bytes, 112, 200)
	layer_schedule_artifact_put_u64(bytes, 120, 1)
	offset := int(LAYER_SCHEDULE_ARTIFACT_HEADER_SIZE)
	layer_schedule_artifact_put_i64(bytes, offset, 200)
	layer_schedule_artifact_put_u64(
		bytes,
		offset+8,
		u64(result.layer_ids[0]),
	)
	return bytes
}

LAYER_SCHEDULE_CAPTURE_TEST_REQUEST_HASH :: contracts.Content_Hash{
	0x04, 0x26, 0x48, 0x6a, 0x8c, 0xae, 0xd0, 0xe2,
	0x13, 0x35, 0x57, 0x79, 0x9b, 0xbd, 0xdf, 0xf1,
	0xf1, 0xdf, 0xbd, 0x9b, 0x79, 0x57, 0x35, 0x13,
	0xe2, 0xd0, 0xae, 0x8c, 0x6a, 0x48, 0x26, 0x04,
}
