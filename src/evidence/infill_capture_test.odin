package evidence

import "core:testing"

import contracts "../contracts"
import features "../features"
import polygon "../polygon"

@(test)
infill_capture_preflights_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	bytes := infill_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := infill_capture_describe(
		"stages/09-generate-features/primitives/infill.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer infill_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Infill_Capture_Error.None)
	testing.expect_value(t, capture.additional.item_count, u64(1))
	testing.expect_value(
		t,
		capture.additional.byte_count,
		u64(len(bytes)),
	)
	testing.expect_value(
		t,
		capture.artifact.format,
		features.INFILL_ARTIFACT_FORMAT,
	)
	decoded, decode_error := features.infill_artifact_decode(capture.bytes)
	defer features.infill_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Infill_Artifact_Error.None,
	)
	testing.expect_value(t, len(decoded.result.layers), 1)
	testing.expect_value(t, len(decoded.result.segments), 0)
	testing.expect_value(t, len(decoded.result.boundary_hits), 0)
}

@(test)
infill_capture_rejects_budget_path_and_content_test :: proc(
	t: ^testing.T,
) {
	bytes := infill_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := infill_capture_describe(
		"infill.bin",
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
		Infill_Capture_Error.Item_Limit,
	)
	_, path_error := infill_capture_describe(
		"../infill.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		Infill_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, content_error := infill_capture_describe(
		"infill.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		Infill_Capture_Error.Invalid_Record,
	)
}

infill_capture_test_artifact :: proc(t: ^testing.T) -> []u8 {
	result := features.Infill_Result{
		config = {
			spacing = 200,
			boundary_inset = 100,
			base_axis = .Vertical,
			alternate_each_layer = true,
			join_type = polygon.Polygon_Join_Type.Miter,
			miter_limit = 2,
		},
		layers = []features.Infill_Layer{
			{axis = .Vertical},
		},
	}
	result_hash, result_ok := features.infill_result_hash(
		INFILL_CAPTURE_TEST_REGION_HASH,
		result,
	)
	testing.expect(t, result_ok)
	byte_count, byte_count_ok :=
		features.infill_artifact_byte_count(1, 0, 0)
	testing.expect(t, byte_count_ok)
	bytes := make([]u8, int(byte_count))
	testing.expect(t, bytes != nil)
	for byte, byte_index in features.INFILL_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	features.infill_artifact_put_u32(
		bytes,
		8,
		features.INFILL_ARTIFACT_SCHEMA_VERSION,
	)
	features.infill_artifact_put_u32(
		bytes,
		12,
		features.INFILL_ARTIFACT_HEADER_SIZE,
	)
	features.infill_artifact_put_u32(
		bytes,
		16,
		features.INFILL_ARTIFACT_LAYER_SIZE,
	)
	features.infill_artifact_put_u32(
		bytes,
		20,
		features.INFILL_ARTIFACT_SEGMENT_SIZE,
	)
	features.infill_artifact_put_u32(
		bytes,
		24,
		features.INFILL_ARTIFACT_HIT_SIZE,
	)
	features.infill_artifact_put_u32(
		bytes,
		28,
		features.SCHEMA_VERSION_INFILL_HASH,
	)
	features.infill_artifact_put_hash(
		bytes,
		32,
		INFILL_CAPTURE_TEST_REGION_HASH,
	)
	features.infill_artifact_put_hash(bytes, 64, result_hash)
	features.infill_artifact_put_i64(bytes, 96, 200)
	features.infill_artifact_put_i64(bytes, 104, 100)
	features.infill_artifact_put_u64(
		bytes,
		120,
		transmute(u64)result.config.miter_limit,
	)
	features.infill_artifact_put_u64(
		bytes,
		128,
		transmute(u64)result.config.arc_tolerance,
	)
	features.infill_artifact_put_u64(bytes, 144, 1)
	features.infill_artifact_put_u32(
		bytes,
		168,
		u32(result.config.topology_policy),
	)
	bytes[172] = u8(result.config.base_axis)
	bytes[173] = 1
	bytes[174] = u8(result.config.join_type)
	bytes[int(features.INFILL_ARTIFACT_HEADER_SIZE)+12] =
		u8(features.Infill_Axis.Vertical)
	return bytes
}

INFILL_CAPTURE_TEST_REGION_HASH :: contracts.Content_Hash{
	0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
	0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
	0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
	0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
}
