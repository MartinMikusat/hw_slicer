package evidence

import "core:testing"

import contracts "../contracts"
import features "../features"
import polygon "../polygon"

@(test)
perimeter_capture_preflights_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	bytes := perimeter_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := perimeter_capture_describe(
		"stages/09-generate-features/primitives/perimeters.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer perimeter_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Perimeter_Capture_Error.None,
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
		features.PERIMETER_ARTIFACT_FORMAT,
	)
	decoded, decode_error :=
		features.perimeter_artifact_decode(capture.bytes)
	defer features.perimeter_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Perimeter_Artifact_Error.None,
	)
	testing.expect_value(t, len(decoded.result.layers), 1)
	testing.expect_value(t, len(decoded.result.groups), 0)
	testing.expect_value(t, len(decoded.result.paths), 0)
	testing.expect_value(t, len(decoded.result.points), 0)
}

@(test)
perimeter_capture_rejects_budget_path_and_content_test :: proc(
	t: ^testing.T,
) {
	bytes := perimeter_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := perimeter_capture_describe(
		"perimeters.bin",
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
		Perimeter_Capture_Error.Item_Limit,
	)
	_, path_error := perimeter_capture_describe(
		"../perimeters.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		Perimeter_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[72] = corrupt[72] ~ 1
	_, content_error := perimeter_capture_describe(
		"perimeters.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		Perimeter_Capture_Error.Invalid_Record,
	)
}

perimeter_capture_test_artifact :: proc(t: ^testing.T) -> []u8 {
	result := features.Perimeter_Result{
		config = {
			count = 1,
			line_width = 100,
			join_type = polygon.Polygon_Join_Type.Miter,
			miter_limit = 2,
		},
		layers = []features.Perimeter_Layer{{}},
	}
	result_hash, result_ok := features.perimeter_result_hash(
		PERIMETER_CAPTURE_TEST_REGION_HASH,
		result,
	)
	testing.expect(t, result_ok)
	byte_count, byte_count_ok :=
		features.perimeter_artifact_byte_count(1, 0, 0, 0)
	testing.expect(t, byte_count_ok)
	bytes := make([]u8, int(byte_count))
	testing.expect(t, bytes != nil)
	for byte, byte_index in features.PERIMETER_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	features.perimeter_artifact_put_u32(
		bytes,
		8,
		features.PERIMETER_ARTIFACT_SCHEMA_VERSION,
	)
	features.perimeter_artifact_put_u32(
		bytes,
		12,
		features.PERIMETER_ARTIFACT_HEADER_SIZE,
	)
	features.perimeter_artifact_put_u32(
		bytes,
		16,
		features.PERIMETER_ARTIFACT_LAYER_SIZE,
	)
	features.perimeter_artifact_put_u32(
		bytes,
		20,
		features.PERIMETER_ARTIFACT_GROUP_SIZE,
	)
	features.perimeter_artifact_put_u32(
		bytes,
		24,
		features.PERIMETER_ARTIFACT_PATH_SIZE,
	)
	features.perimeter_artifact_put_u32(
		bytes,
		28,
		features.PERIMETER_ARTIFACT_POINT_SIZE,
	)
	features.perimeter_artifact_put_u32(
		bytes,
		32,
		features.SCHEMA_VERSION_PERIMETER_HASH,
	)
	features.perimeter_artifact_put_hash(
		bytes,
		40,
		PERIMETER_CAPTURE_TEST_REGION_HASH,
	)
	features.perimeter_artifact_put_hash(bytes, 72, result_hash)
	features.perimeter_artifact_put_u32(bytes, 104, 1)
	features.perimeter_artifact_put_i64(bytes, 112, 100)
	features.perimeter_artifact_put_u64(
		bytes,
		120,
		transmute(u64)result.config.miter_limit,
	)
	features.perimeter_artifact_put_u64(bytes, 136, 1)
	bytes[168] = u8(result.config.join_type)
	return bytes
}

PERIMETER_CAPTURE_TEST_REGION_HASH :: contracts.Content_Hash{
	0x02, 0x24, 0x46, 0x68, 0x8a, 0xac, 0xce, 0xe0,
	0x11, 0x33, 0x55, 0x77, 0x99, 0xbb, 0xdd, 0xff,
	0xff, 0xdd, 0xbb, 0x99, 0x77, 0x55, 0x33, 0x11,
	0xe0, 0xce, 0xac, 0x8a, 0x68, 0x46, 0x24, 0x02,
}
